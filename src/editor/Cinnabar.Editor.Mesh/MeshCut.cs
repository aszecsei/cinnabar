using System.Collections.Immutable;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Mesh;

/// <summary>A point of a cut or a drawn polygon: on a vertex, on an edge a share of the way from a to b, or inside a face.</summary>
public abstract record CutPoint
{
    public sealed record OnVertex(int Vertex) : CutPoint;

    public sealed record OnEdge(int A, int B, double T) : CutPoint;

    public sealed record OnFace(int Face, Vec3 Position) : CutPoint;
}

/// <summary>
/// Cut and Draw (see docs/editor/mesh-editing.md#mesh-tools): a line of points splits every face it crosses along it,
/// with vertices where it crosses edges, and a polygon drawn on a face is cut into it, the face keeping its outside as
/// a ring around the new face.
/// </summary>
public static class MeshCut
{
    /// <summary>
    /// Splits faces along a line of points. Each run of the line from one point on a face's boundary to the next, with
    /// any points inside the face between them, splits that face in two. The result's selection is the new vertices.
    /// The reason is set when nothing could be cut.
    /// </summary>
    public static (ToolResult Result, string? Reason) Cut(MeshData mesh, IReadOnlyList<CutPoint> points)
    {
        if (points.Count < 2)
        {
            return (new ToolResult(mesh, MeshElement.Vertices, []), "a cut needs two points or more");
        }
        var positions = mesh.Vertices.ToBuilder();
        var faces = mesh.Faces.Select(f => f.Corners.ToList()).ToList();
        var slots = mesh.Faces.Select(f => (f.Slot, f.Mapping)).ToList();
        var sharp = mesh.SharpEdges.ToList();
        var added = new List<int>();
        // Points on edges become vertices in every face along the edge, in order along it.
        var onEdges = new Dictionary<MeshEdge, List<(double T, int Vertex)>>();
        var corners = new int?[points.Count];
        for (var i = 0; i < points.Count; i++)
        {
            switch (points[i])
            {
                case CutPoint.OnVertex v when v.Vertex >= 0 && v.Vertex < mesh.Vertices.Length:
                    corners[i] = v.Vertex;
                    break;
                case CutPoint.OnEdge e when e.A != e.B && e.A >= 0 && e.B >= 0 && e.A < mesh.Vertices.Length && e.B < mesh.Vertices.Length:
                    var edge = new MeshEdge(e.A, e.B);
                    var t = Math.Clamp(e.T, 0, 1);
                    // Along the edge from its lower vertex, whichever way the point gave it.
                    var along = edge.A == e.A ? t : 1 - t;
                    if (!onEdges.TryGetValue(edge, out var list))
                    {
                        onEdges[edge] = list = [];
                    }
                    // The same point again, as a line that closes on itself gives, is the same vertex.
                    if (list.FirstOrDefault(p => Math.Abs(p.T - along) < 1e-9) is { Vertex: > 0 } same)
                    {
                        corners[i] = same.Vertex;
                        break;
                    }
                    positions.Add(mesh.Vertices[edge.A] + (mesh.Vertices[edge.B] - mesh.Vertices[edge.A]) * along);
                    corners[i] = positions.Count - 1;
                    added.Add(corners[i]!.Value);
                    list.Add((along, corners[i]!.Value));
                    break;
            }
        }
        foreach (var (edge, list) in onEdges)
        {
            list.Sort((x, y) => x.T.CompareTo(y.T));
            foreach (var f in faces)
            {
                for (var k = 0; k < f.Count; k++)
                {
                    var (a, b) = (f[k], f[(k + 1) % f.Count]);
                    if (a == edge.A && b == edge.B)
                    {
                        f.InsertRange(k + 1, list.Select(p => p.Vertex));
                        break;
                    }
                    if (a == edge.B && b == edge.A)
                    {
                        f.InsertRange(k + 1, list.Select(p => p.Vertex).Reverse());
                        break;
                    }
                }
            }
            var wasSharp = sharp.Remove(edge);
            if (wasSharp)
            {
                var chain = new[] { edge.A }.Concat(list.Select(p => p.Vertex)).Append(edge.B).ToList();
                for (var k = 0; k + 1 < chain.Count; k++)
                {
                    sharp.Add(new MeshEdge(chain[k], chain[k + 1]));
                }
            }
        }
        // Chords: from a boundary point to the next, through the face points between them.
        var cuts = 0;
        var start = 0;
        while (start < points.Count)
        {
            if (corners[start] == null)
            {
                start++;
                continue;
            }
            var end = start + 1;
            var inside = new List<Vec3>();
            while (end < points.Count && corners[end] == null)
            {
                if (points[end] is CutPoint.OnFace p)
                {
                    inside.Add(p.Position);
                }
                end++;
            }
            if (end >= points.Count)
            {
                break;
            }
            var (a, b) = (corners[start]!.Value, corners[end]!.Value);
            if (a != b && SplitFace(faces, slots, positions, a, b, inside, points[start + 1 < end ? start + 1 : start] is CutPoint.OnFace hint ? hint.Face : -1, added))
            {
                cuts++;
            }
            start = end;
        }
        if (cuts == 0)
        {
            return (new ToolResult(mesh, MeshElement.Vertices, []), "a cut goes from an edge or a vertex of a face to another of the same face");
        }
        var result = mesh.With(vertices: positions, faces: faces.Select((c, i) => new MeshFace(slots[i].Slot, [.. c], slots[i].Mapping)), sharpEdges: sharp);
        return (new ToolResult(result, MeshElement.Vertices, added), null);
    }

    // Splits the face that has both corners along the chord between them, through the points inside, and reports
    // whether one did. The face hint, from a point inside, says which when several faces have both corners.
    static bool SplitFace(List<List<int>> faces, List<(int Slot, Mapping Mapping)> slots, ImmutableArray<Vec3>.Builder positions, int a, int b, List<Vec3> inside, int hint, List<int> added)
    {
        var candidates = Enumerable.Range(0, faces.Count).Where(f => faces[f].Contains(a) && faces[f].Contains(b)).ToList();
        if (candidates.Count == 0)
        {
            return false;
        }
        var face = candidates.Contains(hint) ? hint : candidates[0];
        var corners = faces[face];
        var (i, j) = (corners.IndexOf(a), corners.IndexOf(b));
        // A chord along an existing edge cuts nothing.
        if (inside.Count == 0 && ((i + 1) % corners.Count == j || (j + 1) % corners.Count == i))
        {
            return false;
        }
        var interior = inside.Select(p =>
        {
            positions.Add(p);
            added.Add(positions.Count - 1);
            return positions.Count - 1;
        }).ToList();
        var first = new List<int>();
        for (var k = i; ; k = (k + 1) % corners.Count)
        {
            first.Add(corners[k]);
            if (k == j)
            {
                break;
            }
        }
        first.AddRange(Enumerable.Reverse(interior));
        var second = new List<int>();
        for (var k = j; ; k = (k + 1) % corners.Count)
        {
            second.Add(corners[k]);
            if (k == i)
            {
                break;
            }
        }
        second.AddRange(interior);
        faces[face] = first;
        faces.Add(second);
        slots.Add(slots[face]);
        return true;
    }

    /// <summary>
    /// Cuts a polygon into a face: the polygon becomes a new face with the face's slot and mapping, selected, and the
    /// face keeps its outside as a ring of two faces around it. The polygon's corners are in the mesh's space, on the
    /// face's plane, and are turned to front as the face does. A polygon that crosses itself, has fewer than three
    /// corners or leaves the face is refused with the reason.
    /// </summary>
    public static (ToolResult Result, string? Reason) Draw(MeshData mesh, int face, IReadOnlyList<Vec3> polygon)
    {
        if (face < 0 || face >= mesh.Faces.Length)
        {
            return (new ToolResult(mesh, MeshElement.Faces, []), "there is no face to draw on");
        }
        var points = Oriented(polygon, mesh.FaceNormal(face));
        if (points == null)
        {
            return (new ToolResult(mesh, MeshElement.Faces, []), "a polygon has three or more corners and does not cross itself");
        }
        var outer = mesh.Faces[face].Corners;
        var normal = mesh.FaceNormal(face);
        var outerPoints = outer.Select(c => mesh.Vertices[c]).ToArray();
        if (points.Any(p => !Inside(outerPoints, normal, p)))
        {
            return (new ToolResult(mesh, MeshElement.Faces, []), "the polygon leaves the face");
        }
        var positions = mesh.Vertices.ToBuilder();
        var inner = points.Select(p =>
        {
            positions.Add(p);
            return positions.Count - 1;
        }).ToList();
        // The ring: two faces, each from an outer corner around to another and back along the polygon the other way.
        int Nearest(Vec3 p, int not) => Enumerable.Range(0, outer.Length).Where(k => k != not).MinBy(k => (outerPoints[k] - p).Length);
        var q = Nearest(points[0], -1);
        var half = inner.Count / 2;
        var q2 = Nearest(points[half], q);
        var ringA = new List<int>();
        for (var k = q; ; k = (k + 1) % outer.Length)
        {
            ringA.Add(outer[k]);
            if (k == q2)
            {
                break;
            }
        }
        for (var k = half; ; k = (k + inner.Count - 1) % inner.Count)
        {
            ringA.Add(inner[k]);
            if (k == 0)
            {
                break;
            }
        }
        var ringB = new List<int>();
        for (var k = q2; ; k = (k + 1) % outer.Length)
        {
            ringB.Add(outer[k]);
            if (k == q)
            {
                break;
            }
        }
        for (var k = 0; ; k = (k + inner.Count - 1) % inner.Count)
        {
            ringB.Add(inner[k]);
            if (k == half)
            {
                break;
            }
        }
        var original = mesh.Faces[face];
        var faces = mesh.Faces.ToBuilder();
        faces[face] = original with { Corners = [.. ringA] };
        faces.Add(original with { Corners = [.. ringB] });
        faces.Add(original with { Corners = [.. inner] });
        var result = mesh.With(vertices: positions, faces: faces);
        return (new ToolResult(result, MeshElement.Faces, [faces.Count - 1]), null);
    }

    /// <summary>
    /// A drawn polygon on nothing: a mesh of one face, a Plane, fronting along a normal, with a world-aligned mapping.
    /// Null when the polygon is refused.
    /// </summary>
    public static MeshData? Plane(IReadOnlyList<Vec3> polygon, Vec3 front, string material = "", double mappingScale = Mapping.DefaultScale)
    {
        var points = Oriented(polygon, front);
        if (points == null)
        {
            return null;
        }
        var face = new MeshFace(0, [.. Enumerable.Range(0, points.Count)], Mapping.WorldAligned(MeshData.FaceNormal([.. points], [.. Enumerable.Range(0, points.Count)]), mappingScale));
        return new MeshData([material], points, [face], []);
    }

    // The polygon with repeats dropped, turned to front along a normal, or null when it crosses itself or is too small.
    static List<Vec3>? Oriented(IReadOnlyList<Vec3> polygon, Vec3 front)
    {
        var points = new List<Vec3>();
        foreach (var p in polygon)
        {
            if (points.Count == 0 || (points[^1] - p).Length > 1e-9)
            {
                points.Add(p);
            }
        }
        if (points.Count > 1 && (points[0] - points[^1]).Length <= 1e-9)
        {
            points.RemoveAt(points.Count - 1);
        }
        if (points.Count < 3 || Crosses(points))
        {
            return null;
        }
        var normal = MeshData.FaceNormal([.. points], [.. Enumerable.Range(0, points.Count)]);
        if (normal == Vec3.Zero)
        {
            return null;
        }
        if (Vec3.Dot(normal, front) < 0)
        {
            points.Reverse();
        }
        return points;
    }

    /// <summary>Whether a polygon's edges cross each other, tested in the plane of its two largest extents.</summary>
    public static bool Crosses(IReadOnlyList<Vec3> points)
    {
        var normal = MeshData.FaceNormal([.. points], [.. Enumerable.Range(0, points.Count)]);
        var (u, v) = Axes(normal);
        var n = points.Count;
        for (var i = 0; i < n; i++)
        {
            for (var j = i + 1; j < n; j++)
            {
                // Edges that share a corner do not count.
                if (j == i + 1 || (i == 0 && j == n - 1))
                {
                    continue;
                }
                var (a, b) = (points[i], points[(i + 1) % n]);
                var (c, d) = (points[j], points[(j + 1) % n]);
                if (Intersect((a[u], a[v]), (b[u], b[v]), (c[u], c[v]), (d[u], d[v])))
                {
                    return true;
                }
            }
        }
        return false;
    }

    static bool Intersect((double X, double Y) a, (double X, double Y) b, (double X, double Y) c, (double X, double Y) d)
    {
        static double Cross((double X, double Y) p, (double X, double Y) q, (double X, double Y) r) => (q.X - p.X) * (r.Y - p.Y) - (q.Y - p.Y) * (r.X - p.X);
        var (d1, d2, d3, d4) = (Cross(c, d, a), Cross(c, d, b), Cross(a, b, c), Cross(a, b, d));
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
    }

    static (int, int) Axes(Vec3 normal)
    {
        var (ax, ay, az) = (Math.Abs(normal.X), Math.Abs(normal.Y), Math.Abs(normal.Z));
        return ax >= ay && ax >= az ? (1, 2) : ay >= az ? (0, 2) : (0, 1);
    }

    static bool Inside(Vec3[] points, Vec3 normal, Vec3 point)
    {
        var (u, v) = Axes(normal);
        var inside = false;
        for (int i = 0, j = points.Length - 1; i < points.Length; j = i++)
        {
            var (pi, pj) = (points[i], points[j]);
            if (pi[v] > point[v] != pj[v] > point[v])
            {
                var x = (pj[u] - pi[u]) * (point[v] - pi[v]) / (pj[v] - pi[v]) + pi[u];
                if (point[u] < x)
                {
                    inside = !inside;
                }
            }
        }
        return inside;
    }
}
