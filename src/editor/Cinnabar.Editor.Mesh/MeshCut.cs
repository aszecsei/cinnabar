using System.Collections.Immutable;
using Cinnabar.Editor.Maths;
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
        points = Extended(mesh, points);
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

    // Points inside a face with no boundary point on one side of them, or both, get one: the line through the run's
    // points goes on to where it leaves the face, as Hammer's clipping line does, so two clicks inside a wall cut it
    // across. A lone point inside a face next to a boundary point of that face extends away from it.
    static List<CutPoint> Extended(MeshData mesh, IReadOnlyList<CutPoint> points)
    {
        var result = new List<CutPoint>();
        var i = 0;
        while (i < points.Count)
        {
            if (points[i] is not CutPoint.OnFace first)
            {
                result.Add(points[i]);
                i++;
                continue;
            }
            var j = i;
            while (j < points.Count && points[j] is CutPoint.OnFace p && p.Face == first.Face)
            {
                j++;
            }
            var run = points.Skip(i).Take(j - i).Cast<CutPoint.OnFace>().ToList();
            var face = first.Face;
            var before = i > 0 && IsOn(mesh, points[i - 1], face) ? Position(mesh, points[i - 1]) : null;
            var after = j < points.Count && IsOn(mesh, points[j], face) ? Position(mesh, points[j]) : null;
            if (before == null)
            {
                var through = run.Count > 1 ? run[1].Position : after;
                if (through is { } t && Leave(mesh, face, t, run[0].Position) is { } edge)
                {
                    result.Add(edge);
                }
            }
            result.AddRange(run);
            if (after == null)
            {
                var through = run.Count > 1 ? run[^2].Position : before;
                if (through is { } t && Leave(mesh, face, t, run[^1].Position) is { } edge)
                {
                    result.Add(edge);
                }
            }
            i = j;
        }
        return result;
    }

    static bool IsOn(MeshData mesh, CutPoint point, int face) => point switch
    {
        CutPoint.OnVertex v => mesh.Faces[face].Corners.Contains(v.Vertex),
        CutPoint.OnEdge e => mesh.FacesOfEdge(new MeshEdge(e.A, e.B)).Contains(face),
        _ => false,
    };

    static Vec3? Position(MeshData mesh, CutPoint point) => point switch
    {
        CutPoint.OnVertex v when v.Vertex < mesh.Vertices.Length => mesh.Vertices[v.Vertex],
        CutPoint.OnEdge e when e.A < mesh.Vertices.Length && e.B < mesh.Vertices.Length => mesh.Vertices[e.A] + (mesh.Vertices[e.B] - mesh.Vertices[e.A]) * Math.Clamp(e.T, 0, 1),
        CutPoint.OnFace f => f.Position,
        _ => null,
    };

    // Where the line from one point through another leaves a face: the first edge it crosses past the second point,
    // as a point on that edge, or null when it crosses none.
    static CutPoint.OnEdge? Leave(MeshData mesh, int face, Vec3 from, Vec3 through)
    {
        var direction = through - from;
        if (direction.Length < 1e-9)
        {
            return null;
        }
        var normal = mesh.FaceNormal(face);
        var (u, v) = Polygon2D.Axes(normal);
        var corners = mesh.Faces[face].Corners;
        CutPoint.OnEdge? best = null;
        var bestAlong = double.MaxValue;
        for (var k = 0; k < corners.Length; k++)
        {
            var (a, b) = (corners[k], corners[(k + 1) % corners.Length]);
            var (pa, pb) = (mesh.Vertices[a], mesh.Vertices[b]);
            // The ray from the second point along the direction, against the edge, in the face's plane.
            var (dx, dy) = (direction[u], direction[v]);
            var (ex, ey) = (pb[u] - pa[u], pb[v] - pa[v]);
            var denominator = dx * ey - dy * ex;
            if (Math.Abs(denominator) < 1e-12)
            {
                continue;
            }
            var (ox, oy) = (pa[u] - through[u], pa[v] - through[v]);
            var along = (ox * ey - oy * ex) / denominator;
            var t = (ox * dy - oy * dx) / denominator;
            if (along > 1e-9 && t >= -1e-9 && t <= 1 + 1e-9 && along < bestAlong)
            {
                bestAlong = along;
                best = new CutPoint.OnEdge(a, b, Math.Clamp(t, 0, 1));
            }
        }
        return best;
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
    /// The points of a loop cut from an edge: a share of the way along it, then through each quad beside it to the
    /// opposite edge at the same share, both ways around the mesh, until the loop closes or a face that is not a quad
    /// or an open edge stops it. The points are in order along the loop, and a closed loop ends with its first point.
    /// </summary>
    public static List<CutPoint.OnEdge> Loop(MeshData mesh, int edge, double t)
    {
        if (edge < 0 || edge >= mesh.Edges.Length)
        {
            return [];
        }
        var start = mesh.Edges[edge];
        t = Math.Clamp(t, 0, 1);
        var points = new List<CutPoint.OnEdge> { new(start.A, start.B, t) };
        var visited = new HashSet<int>();
        // One way around, then the other from the start, prepended.
        var forward = Walk(mesh, start, t, visited, out var closed);
        points.AddRange(forward);
        if (closed)
        {
            points.Add(points[0]);
            return points;
        }
        var backward = Walk(mesh, start, t, visited, out _);
        backward.Reverse();
        return [.. backward, .. points];
    }

    // From an edge at a share along it, through the quads beside it that are not yet visited.
    static List<CutPoint.OnEdge> Walk(MeshData mesh, MeshEdge start, double t, HashSet<int> visited, out bool closed)
    {
        var points = new List<CutPoint.OnEdge>();
        closed = false;
        var (a, b, share) = (start.A, start.B, t);
        while (true)
        {
            var face = mesh.FacesOfEdge(new MeshEdge(a, b)).FirstOrDefault(f => !visited.Contains(f), -1);
            if (face < 0 || mesh.Faces[face].Corners.Length != 4)
            {
                return points;
            }
            visited.Add(face);
            var corners = mesh.Faces[face].Corners;
            var k = corners.IndexOf(a);
            // The entry edge is a to b, in or against the face's winding; the exit is the opposite edge, so that the
            // same share from the entry's a lands across from it.
            var forward = corners[(k + 1) % 4] == b;
            var (c, d) = forward ? (corners[(k + 3) % 4], corners[(k + 2) % 4]) : (corners[(k + 1) % 4], corners[(k + 2) % 4]);
            if (c == start.A && d == start.B || c == start.B && d == start.A)
            {
                closed = true;
                return points;
            }
            points.Add(new CutPoint.OnEdge(c, d, share));
            (a, b) = (c, d);
        }
    }

    /// <summary>A loop cut from an edge, as <see cref="Loop"/> gives it, applied with <see cref="Cut"/>.</summary>
    public static (ToolResult Result, string? Reason) LoopCut(MeshData mesh, int edge, double t)
    {
        var points = Loop(mesh, edge, t);
        return points.Count < 2 ? (new ToolResult(mesh, MeshElement.Vertices, []), "a loop cut goes through a quad beside the edge") : Cut(mesh, [.. points]);
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
        if (points.Any(p => !Polygon2D.Inside(outerPoints, normal, p)))
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
        if (points.Count < 3 || Polygon2D.Crosses(points))
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
}
