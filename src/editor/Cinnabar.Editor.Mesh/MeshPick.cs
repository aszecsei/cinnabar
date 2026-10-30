using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Mesh;

/// <summary>
/// Where a mesh is, relative to the camera, in meters: its entity's world pose with the camera's position taken off,
/// so picking happens in doubles near the origin (see docs/editor/mesh-editing.md#overlay-and-picking).
/// </summary>
public sealed record MeshPlacement(Vec3 Origin, Quat Rotation, Vec3 Scale)
{
    /// <summary>A mesh's placement from its entity's pose and the camera's position.</summary>
    public static MeshPlacement Of(Pose pose, long[] cameraPosition) =>
        new(Vec3.Between(cameraPosition, pose.Position), pose.Rotation, Vec3.From(pose.Scale));

    /// <summary>A position in the mesh's space, relative to the camera.</summary>
    public Vec3 ToView(Vec3 local) => Origin + Vec3.From(Rotation.Rotate(Vec3.Scale(local, Scale).ToArray()));

    /// <summary>A position relative to the camera, in the mesh's space.</summary>
    public Vec3 ToLocal(Vec3 view)
    {
        var unrotated = Vec3.From(Rotation.Conjugate.Rotate((view - Origin).ToArray()));
        return new Vec3(Divide(unrotated.X, Scale.X), Divide(unrotated.Y, Scale.Y), Divide(unrotated.Z, Scale.Z));
    }

    /// <summary>A direction in the mesh's space, relative to the camera, as a face's normal is: unit, whatever the scale.</summary>
    public Vec3 NormalToView(Vec3 local)
    {
        // A normal transforms by the inverse transpose, which for a rotation and a scale divides by the scale.
        var scaled = new Vec3(Divide(local.X, Scale.X), Divide(local.Y, Scale.Y), Divide(local.Z, Scale.Z));
        return Vec3.From(Rotation.Rotate(scaled.ToArray())).Normalized();
    }

    static double Divide(double a, double b) => Math.Abs(b) < 1e-12 ? 0 : a / b;
}

/// <summary>A face that a ray hit: its index, the view-space distance along the ray, and the point, relative to the camera.</summary>
public readonly record struct FaceHit(int Face, double Distance, Vec3 Point);

/// <summary>
/// Picking in mesh mode, which the editor does itself, synchronously, from the edited meshes, the camera and the
/// entities' poses (see docs/editor/mesh-editing.md#overlay-and-picking): a ray against the faces, nearest first, and
/// for edges and vertices the nearest on screen within <see cref="HitPixels"/> that is not behind the face under the
/// mouse. It ignores the scene's other entities, as Hammer does.
/// </summary>
public static class MeshPick
{
    /// <summary>How near the mouse must be to a vertex or an edge, in pixels of the frame.</summary>
    public const double HitPixels = 8;

    // A vertex or an edge counts as in front of the face hit when its depth is within this share of the hit's.
    const double DepthSlack = 0.02;

    /// <summary>The nearest face along a ray from the camera, or null. Back faces count only with <paramref name="through"/>.</summary>
    public static FaceHit? Face(MeshData mesh, MeshPlacement placement, Vec3 ray, bool through = false)
    {
        FaceHit? best = null;
        for (var i = 0; i < mesh.Faces.Length; i++)
        {
            if (HitFace(mesh, placement, i, ray, through) is { } hit && (best == null || hit.Distance < best.Value.Distance))
            {
                best = hit;
            }
        }
        return best;
    }

    /// <summary>Where a ray meets one face, or null when it misses it or comes from behind.</summary>
    public static FaceHit? HitFace(MeshData mesh, MeshPlacement placement, int face, Vec3 ray, bool through)
    {
        var corners = mesh.Faces[face].Corners;
        if (corners.Length < 3)
        {
            return null;
        }
        var normal = placement.NormalToView(MeshData.FaceNormal(mesh.Vertices, corners));
        var facing = Vec3.Dot(normal, ray);
        if (normal == Vec3.Zero || (!through && facing >= 0) || Math.Abs(facing) < 1e-12)
        {
            return null;
        }
        var points = corners.Select(c => placement.ToView(mesh.Vertices[c])).ToArray();
        var t = Vec3.Dot(normal, points[0]) / facing;
        if (t <= 0)
        {
            return null;
        }
        var point = ray * t;
        return Polygon2D.Inside(points, normal, point) ? new FaceHit(face, t, point) : null;
    }

    /// <summary>
    /// The vertex nearest the mouse within <see cref="HitPixels"/> that is not behind the face hit, or the nearest of
    /// all when nothing was hit, or null. <paramref name="faceDepth"/> is the hit's distance, or null.
    /// </summary>
    public static int? Vertex(MeshData mesh, MeshPlacement placement, EditorCamera camera, Vec2 mouse, double width, double height, double? faceDepth)
    {
        int? best = null;
        var bestDistance = HitPixels;
        for (var i = 0; i < mesh.Vertices.Length; i++)
        {
            var view = placement.ToView(mesh.Vertices[i]);
            if (camera.Project(view, width, height) is not { } screen || !InFront(camera, view, faceDepth))
            {
                continue;
            }
            var distance = (screen - mouse).Length;
            if (distance < bestDistance)
            {
                best = i;
                bestDistance = distance;
            }
        }
        return best;
    }

    /// <summary>The edge nearest the mouse within <see cref="HitPixels"/> that is not behind the face hit, by its index, or null.</summary>
    public static int? Edge(MeshData mesh, MeshPlacement placement, EditorCamera camera, Vec2 mouse, double width, double height, double? faceDepth)
    {
        int? best = null;
        var bestDistance = HitPixels;
        for (var i = 0; i < mesh.Edges.Length; i++)
        {
            var edge = mesh.Edges[i];
            var (a, b) = (placement.ToView(mesh.Vertices[edge.A]), placement.ToView(mesh.Vertices[edge.B]));
            if (camera.Project(a, width, height) is not { } sa || camera.Project(b, width, height) is not { } sb)
            {
                continue;
            }
            var distance = Vec2.DistanceToSegment(mouse, sa, sb);
            if (distance >= bestDistance)
            {
                continue;
            }
            // The depth at the point of the edge nearest the mouse on screen.
            var ab = sb - sa;
            var lengthSquared = ab.X * ab.X + ab.Y * ab.Y;
            var t = lengthSquared < 1e-12 ? 0 : Math.Clamp(((mouse.X - sa.X) * ab.X + (mouse.Y - sa.Y) * ab.Y) / lengthSquared, 0, 1);
            if (!InFront(camera, a + (b - a) * t, faceDepth))
            {
                continue;
            }
            best = i;
            bestDistance = distance;
        }
        return best;
    }

    static bool InFront(EditorCamera camera, Vec3 view, double? faceDepth)
    {
        var depth = Vec3.Dot(view, camera.Forward);
        return depth > camera.Near && (faceDepth == null || depth <= faceDepth.Value * (1 + DepthSlack) + 0.01);
    }

    /// <summary>
    /// The elements of a kind inside a box of the frame: a vertex inside it, an edge with both ends inside, a face with
    /// every vertex inside. Without <paramref name="through"/>, a face whose normal faces away is skipped, and so are
    /// the vertices and edges that no front face uses.
    /// </summary>
    public static IEnumerable<int> InBox(MeshData mesh, MeshPlacement placement, EditorCamera camera, MeshElement kind, Vec2 min, Vec2 max, double width, double height, bool through)
    {
        var inside = new bool[mesh.Vertices.Length];
        for (var i = 0; i < mesh.Vertices.Length; i++)
        {
            var view = placement.ToView(mesh.Vertices[i]);
            inside[i] = Vec3.Dot(view, camera.Forward) > camera.Near && camera.Project(view, width, height) is { } s
                && s.X >= min.X && s.X <= max.X && s.Y >= min.Y && s.Y <= max.Y;
        }
        var front = new bool[mesh.Faces.Length];
        for (var i = 0; i < mesh.Faces.Length; i++)
        {
            var corners = mesh.Faces[i].Corners;
            if (through)
            {
                front[i] = true;
                continue;
            }
            var normal = placement.NormalToView(MeshData.FaceNormal(mesh.Vertices, corners));
            var center = Vec3.Zero;
            foreach (var c in corners)
            {
                center += placement.ToView(mesh.Vertices[c]);
            }
            front[i] = corners.Length > 0 && Vec3.Dot(normal, center / corners.Length) < 0;
        }
        bool Used(int vertex) => through || mesh.FacesOfVertex(vertex).Any(f => front[f]);
        switch (kind)
        {
            case MeshElement.Vertices:
                return Enumerable.Range(0, mesh.Vertices.Length).Where(v => inside[v] && Used(v));
            case MeshElement.Edges:
                return Enumerable.Range(0, mesh.Edges.Length).Where(i =>
                    inside[mesh.Edges[i].A] && inside[mesh.Edges[i].B] && (through || mesh.FacesOfEdge(mesh.Edges[i]).Any(f => front[f])));
            default:
                return Enumerable.Range(0, mesh.Faces.Length).Where(i => front[i] && mesh.Faces[i].Corners.All(c => inside[c]));
        }
    }
}
