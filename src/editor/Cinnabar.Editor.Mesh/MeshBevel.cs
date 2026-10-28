using System.Collections.Immutable;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Mesh;

/// <summary>
/// Bevel (see docs/editor/mesh-editing.md#mesh-tools): a vertex becomes a small face, and an edge a strip of faces
/// along a circular profile, with segments and a width. Each edge bevels on its own: where beveled edges meet at a
/// vertex, the end caps overlap, which a Clean does not yet mend.
/// </summary>
public static class MeshBevel
{
    /// <summary>Replaces vertices with a face each, a width along each edge from the vertex, and gives the new faces to select.</summary>
    public static ToolResult Vertices(MeshData mesh, IEnumerable<int> vertices, double width)
    {
        var chosen = vertices.Where(v => v >= 0 && v < mesh.Vertices.Length && mesh.FacesOfVertex(v).Count > 0).Distinct().Order().ToList();
        if (chosen.Count == 0)
        {
            return new ToolResult(mesh, MeshElement.Faces, []);
        }
        var positions = mesh.Vertices.ToBuilder();
        var faces = mesh.Faces.Select(f => f.Corners.ToList()).ToList();
        var mappings = mesh.Faces.Select(f => (f.Slot, f.Mapping)).ToList();
        var sharp = mesh.SharpEdges.ToBuilder();
        var selected = new List<int>();
        foreach (var v in chosen)
        {
            var p = mesh.Vertices[v];
            var around = mesh.FacesOfVertex(v);
            // A new vertex a width along each edge from the vertex, at most half way.
            var along = new Dictionary<int, int>();
            int Along(int u)
            {
                if (!along.TryGetValue(u, out var index))
                {
                    var edge = positions[u] - p;
                    var distance = Math.Min(width, edge.Length / 2);
                    index = positions.Count;
                    positions.Add(p + edge.Normalized() * distance);
                    along[u] = index;
                    if (sharp.Contains(new MeshEdge(v, u)))
                    {
                        sharp.Add(new MeshEdge(index, u));
                    }
                }
                return index;
            }
            foreach (var f in around)
            {
                var corners = faces[f];
                var k = corners.IndexOf(v);
                if (k < 0)
                {
                    continue;
                }
                var (prev, next) = (corners[(k + corners.Count - 1) % corners.Count], corners[(k + 1) % corners.Count]);
                corners[k] = Along(prev);
                corners.Insert(k + 1, Along(next));
            }
            // The cap: the new vertices around the vertex, in order about its normal, fronting out.
            var normal = around.Aggregate(Vec3.Zero, (s, f) => s + mesh.FaceNormal(f)).Normalized();
            if (normal == Vec3.Zero)
            {
                normal = Vec3.UnitY;
            }
            var (u, w) = Basis(normal);
            var cap = along.Values.OrderBy(i => Math.Atan2(Vec3.Dot(positions[i] - p, w), Vec3.Dot(positions[i] - p, u))).ToList();
            if (cap.Count < 3)
            {
                continue;
            }
            if (Vec3.Dot(MeshData.FaceNormal([.. positions], [.. cap]), normal) < 0)
            {
                cap.Reverse();
            }
            selected.Add(faces.Count);
            faces.Add(cap);
            mappings.Add((mappings[around[0]].Slot, mappings[around[0]].Mapping));
            for (var i = 0; i < cap.Count; i++)
            {
                sharp.Add(new MeshEdge(cap[i], cap[(i + 1) % cap.Count]));
            }
        }
        return Finish(mesh, positions, faces, mappings, sharp, chosen.ToHashSet(), selected);
    }

    /// <summary>
    /// Replaces edges with a strip of faces along a circular profile of a width, in segments, and gives the strip to
    /// select. An edge with only one face is left alone. The faces beside the edge keep their mappings, and the new
    /// faces take the mapping of the face each is nearest.
    /// </summary>
    public static ToolResult Edges(MeshData mesh, IEnumerable<int> edges, double width, int segments = 1)
    {
        segments = Math.Clamp(segments, 1, 16);
        var chosen = edges.Where(e => e >= 0 && e < mesh.Edges.Length && mesh.FacesOfEdge(mesh.Edges[e]).Count == 2).Distinct().Order().ToList();
        if (chosen.Count == 0)
        {
            return new ToolResult(mesh, MeshElement.Faces, []);
        }
        var positions = mesh.Vertices.ToBuilder();
        var faces = mesh.Faces.Select(f => f.Corners.ToList()).ToList();
        var mappings = mesh.Faces.Select(f => (f.Slot, f.Mapping)).ToList();
        var sharp = mesh.SharpEdges.ToBuilder();
        var selected = new List<int>();
        foreach (var e in chosen)
        {
            var edge = mesh.Edges[e];
            var beside = mesh.FacesOfEdge(edge);
            var (f1, f2) = (beside[0], beside[1]);
            // a to b in f1's winding.
            var (a, b) = (edge.A, edge.B);
            var c1 = faces[f1];
            var ka = c1.IndexOf(a);
            if (ka < 0 || c1.IndexOf(b) < 0 || faces[f2].IndexOf(a) < 0 || faces[f2].IndexOf(b) < 0)
            {
                continue;
            }
            if (c1[(ka + 1) % c1.Count] != b)
            {
                (a, b) = (b, a);
            }
            var (n1, n2) = (mesh.FaceNormal(f1), mesh.FaceNormal(f2));
            var direction = (mesh.Vertices[b] - mesh.Vertices[a]).Normalized();
            // Inward in each face, perpendicular to the edge.
            var m1 = Vec3.Cross(n1, direction).Normalized();
            var m2 = Vec3.Cross(n2, -direction).Normalized();
            var distance = Math.Min(width, (mesh.Vertices[b] - mesh.Vertices[a]).Length / 2);
            // The profile: unit directions from the edge, from m1 to m2 around the circle between them.
            var profile = new Vec3[segments + 1];
            var angle = Math.Acos(Math.Clamp(Vec3.Dot(m1, m2), -1, 1));
            var axis = Vec3.Cross(m1, m2);
            for (var i = 0; i <= segments; i++)
            {
                var t = (double)i / segments;
                profile[i] = axis.Length < 1e-9 || angle < 1e-6
                    ? (m1 * (1 - t) + m2 * t).Normalized()
                    : Rotations.AxisAngle(axis.Normalized(), angle * t).Rotate(m1);
            }
            var atA = profile.Select(m => Add(positions, mesh.Vertices[a] + m * distance)).ToArray();
            var atB = profile.Select(m => Add(positions, mesh.Vertices[b] + m * distance)).ToArray();
            Replace(faces[f1], a, atA[0]);
            Replace(faces[f1], b, atB[0]);
            Replace(faces[f2], a, atA[segments]);
            Replace(faces[f2], b, atB[segments]);
            var outward = (n1 + n2).Normalized();
            for (var i = 0; i < segments; i++)
            {
                var quad = new List<int> { atA[i], atB[i], atB[i + 1], atA[i + 1] };
                if (Vec3.Dot(MeshData.FaceNormal([.. positions], [.. quad]), outward) < 0)
                {
                    quad.Reverse();
                }
                selected.Add(faces.Count);
                faces.Add(quad);
                var near = i < segments / 2.0 ? f1 : f2;
                mappings.Add((mappings[near].Slot, mappings[near].Mapping));
            }
            // The gap at each end, where the other faces at the vertex keep it, closes with a fan from the vertex.
            foreach (var (vertex, strip, other) in new[] { (a, atA, b), (b, atB, a) })
            {
                if (mesh.FacesOfVertex(vertex).Count <= 2)
                {
                    continue;
                }
                var away = mesh.Vertices[vertex] - mesh.Vertices[other];
                for (var i = 0; i < segments; i++)
                {
                    var cap = new List<int> { vertex, strip[i], strip[i + 1] };
                    if (Vec3.Dot(MeshData.FaceNormal([.. positions], [.. cap]), away) < 0)
                    {
                        cap.Reverse();
                    }
                    faces.Add(cap);
                    mappings.Add((mappings[f1].Slot, mappings[f1].Mapping));
                }
            }
            var wasSharp = sharp.Contains(edge);
            sharp.Remove(edge);
            if (wasSharp)
            {
                sharp.Add(new MeshEdge(atA[0], atB[0]));
                sharp.Add(new MeshEdge(atA[segments], atB[segments]));
            }
        }
        return Finish(mesh, positions, faces, mappings, sharp, [], selected);
    }

    static int Add(ImmutableArray<Vec3>.Builder positions, Vec3 p)
    {
        positions.Add(p);
        return positions.Count - 1;
    }

    static void Replace(List<int> corners, int from, int to)
    {
        for (var i = 0; i < corners.Count; i++)
        {
            if (corners[i] == from)
            {
                corners[i] = to;
            }
        }
    }

    static (Vec3 U, Vec3 W) Basis(Vec3 normal)
    {
        var helper = Math.Abs(normal.Y) < 0.9 ? Vec3.UnitY : Vec3.UnitX;
        var u = Vec3.Cross(helper, normal).Normalized();
        return (u, Vec3.Cross(normal, u));
    }

    // The mesh from the builders, without the removed vertices, with the selected faces' indices after compaction.
    static ToolResult Finish(MeshData mesh, ImmutableArray<Vec3>.Builder positions, List<List<int>> faces, List<(int Slot, Mapping Mapping)> mappings,
        ImmutableArray<MeshEdge>.Builder sharp, HashSet<int> removedVertices, List<int> selected)
    {
        var built = mesh.With(vertices: positions, faces: faces.Select((c, i) => new MeshFace(mappings[i].Slot, [.. c], mappings[i].Mapping)), sharpEdges: sharp.Distinct());
        var degenerate = built.Faces.Select((f, i) => (f, i)).Where(p => p.f.Corners.Distinct().Count() < 3).Select(p => p.i).ToHashSet();
        var result = MeshTools.Compact(built, removedVertices, degenerate);
        var kept = Enumerable.Range(0, built.Faces.Length).Where(i => !degenerate.Contains(i)).Select((old, @new) => (old, @new)).ToDictionary(p => p.old, p => p.@new);
        return new ToolResult(result, MeshElement.Faces, [.. selected.Where(kept.ContainsKey).Select(i => kept[i])]);
    }
}
