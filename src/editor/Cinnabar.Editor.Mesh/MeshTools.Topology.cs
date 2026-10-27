using System.Collections.Immutable;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Mesh;

/// <summary>Collapse, Merge Faces, Clean and Recalculate Normals (see docs/editor/mesh-editing.md#mesh-tools).</summary>
public static partial class MeshTools
{
    /// <summary>Vertices nearer than this merge, in meters: a tenth of a millimeter.</summary>
    public const double WeldDistance = 0.0001;

    /// <summary>Faces whose planes differ by less than this merge, in degrees.</summary>
    public const double CoplanarDegrees = 1;

    /// <summary>
    /// Collapses: vertices into one at their centroid; each edge's two vertices into one at its middle; each face's
    /// vertices into one at its centroid. Faces left with fewer than three distinct vertices go.
    /// </summary>
    public static ToolResult Collapse(MeshData mesh, MeshElement kind, IEnumerable<int> indices)
    {
        var chosen = indices.ToList();
        // Groups of vertices that become one, joined by union-find, and where each lands.
        var parent = Enumerable.Range(0, mesh.Vertices.Length).ToArray();
        int Find(int v)
        {
            while (parent[v] != v)
            {
                v = parent[v] = parent[parent[v]];
            }
            return v;
        }
        void Union(int a, int b) => parent[Find(a)] = Find(b);
        switch (kind)
        {
            case MeshElement.Vertices:
                var vs = chosen.Where(v => v >= 0 && v < mesh.Vertices.Length).ToList();
                for (var i = 1; i < vs.Count; i++)
                {
                    Union(vs[i], vs[0]);
                }
                break;
            case MeshElement.Edges:
                foreach (var e in chosen.Where(e => e >= 0 && e < mesh.Edges.Length))
                {
                    Union(mesh.Edges[e].A, mesh.Edges[e].B);
                }
                break;
            default:
                foreach (var f in chosen.Where(f => f >= 0 && f < mesh.Faces.Length))
                {
                    var corners = mesh.Faces[f].Corners;
                    for (var k = 1; k < corners.Length; k++)
                    {
                        Union(corners[k], corners[0]);
                    }
                }
                break;
        }
        var groups = Enumerable.Range(0, mesh.Vertices.Length).GroupBy(Find).Where(g => g.Count() > 1).ToList();
        var vertices = mesh.Vertices.ToBuilder();
        var removed = new HashSet<int>();
        var survivors = new List<int>();
        foreach (var g in groups)
        {
            var members = g.Order().ToList();
            var survivor = members[0];
            vertices[survivor] = Centroid(mesh, members);
            survivors.Add(survivor);
            removed.UnionWith(members.Skip(1));
            foreach (var m in members.Skip(1))
            {
                parent[m] = survivor;
            }
        }
        var faces = mesh.Faces.Select(f => f with { Corners = Dedupe(f.Corners.Select(Find)) }).ToList();
        var degenerate = faces.Select((f, i) => (f, i)).Where(p => p.f.Corners.Distinct().Count() < 3).Select(p => p.i).ToHashSet();
        var sharp = mesh.SharpEdges.Select(e => new MeshEdge(Find(e.A), Find(e.B))).Where(e => e.A != e.B).Distinct();
        var result = Compact(mesh.With(vertices: vertices, faces: faces, sharpEdges: sharp), removed, degenerate);
        // The survivors' new indices.
        var remap = Remap(mesh.Vertices.Length, removed);
        return new ToolResult(result, MeshElement.Vertices, [.. survivors.Select(s => remap[s]).Where(i => i >= 0)]);
    }

    /// <summary>
    /// Dissolves the edges between selected faces that share a plane within <see cref="CoplanarDegrees"/> into one
    /// n-gon each. Faces that do not share a plane, or whose union has a hole, stay as they are.
    /// </summary>
    public static ToolResult MergeFaces(MeshData mesh, IEnumerable<int> faces)
    {
        var chosen = faces.Where(f => f >= 0 && f < mesh.Faces.Length).ToHashSet();
        var removed = new HashSet<int>();
        var added = new List<MeshFace>();
        var cos = Math.Cos(CoplanarDegrees * Math.PI / 180);
        // Groups grow from a face over shared edges to faces in its plane.
        var seen = new HashSet<int>();
        foreach (var start in chosen.Order())
        {
            if (!seen.Add(start))
            {
                continue;
            }
            var normal = mesh.FaceNormal(start);
            var group = new HashSet<int> { start };
            var queue = new Queue<int>([start]);
            while (queue.Count > 0)
            {
                var f = queue.Dequeue();
                var corners = mesh.Faces[f].Corners;
                for (var k = 0; k < corners.Length; k++)
                {
                    foreach (var other in mesh.FacesOfEdge(new MeshEdge(corners[k], corners[(k + 1) % corners.Length])))
                    {
                        if (chosen.Contains(other) && !group.Contains(other) && Vec3.Dot(mesh.FaceNormal(other), normal) >= cos)
                        {
                            group.Add(other);
                            seen.Add(other);
                            queue.Enqueue(other);
                        }
                    }
                }
            }
            if (group.Count < 2 || new MeshRegion(mesh, group).Loops() is not [var loop])
            {
                continue;
            }
            removed.UnionWith(group);
            added.Add(mesh.Faces[start] with { Corners = [.. loop] });
        }
        if (removed.Count == 0)
        {
            return new ToolResult(mesh, MeshElement.Faces, [.. chosen.Order()]);
        }
        var kept = mesh.Faces.Where((f, i) => !removed.Contains(i)).ToList();
        var withMerged = mesh.With(faces: kept.Concat(added));
        var used = withMerged.Faces.SelectMany(f => f.Corners).ToHashSet();
        var result = Compact(withMerged, [.. Enumerable.Range(0, mesh.Vertices.Length).Where(v => !used.Contains(v))], []);
        return new ToolResult(result, MeshElement.Faces, [.. Enumerable.Range(kept.Count, added.Count)]);
    }

    /// <summary>
    /// Acts on the whole mesh: merges vertices within <see cref="WeldDistance"/>, removes faces with fewer than three
    /// distinct vertices, dissolves a vertex that lies on a straight line between its neighbors in every face around
    /// it, and removes the vertices no face uses. The problems are the edges with more than two faces.
    /// </summary>
    public static (MeshData Mesh, IReadOnlyList<string> Problems) Clean(MeshData mesh)
    {
        // Welding: each vertex joins the first earlier vertex within the distance, through cells of that size.
        var cells = new Dictionary<(long, long, long), List<int>>();
        var target = Enumerable.Range(0, mesh.Vertices.Length).ToArray();
        for (var i = 0; i < mesh.Vertices.Length; i++)
        {
            var v = mesh.Vertices[i];
            var cell = ((long)Math.Floor(v.X / WeldDistance), (long)Math.Floor(v.Y / WeldDistance), (long)Math.Floor(v.Z / WeldDistance));
            var found = false;
            for (var dx = -1L; dx <= 1 && !found; dx++)
            {
                for (var dy = -1L; dy <= 1 && !found; dy++)
                {
                    for (var dz = -1L; dz <= 1 && !found; dz++)
                    {
                        if (cells.TryGetValue((cell.Item1 + dx, cell.Item2 + dy, cell.Item3 + dz), out var near))
                        {
                            foreach (var j in near)
                            {
                                if ((mesh.Vertices[j] - v).Length <= WeldDistance)
                                {
                                    target[i] = j;
                                    found = true;
                                    break;
                                }
                            }
                        }
                    }
                }
            }
            if (!found)
            {
                if (!cells.TryGetValue(cell, out var list))
                {
                    cells[cell] = list = [];
                }
                list.Add(i);
            }
        }
        var faces = mesh.Faces.Select(f => f with { Corners = Dedupe(f.Corners.Select(c => target[c])) }).ToList();
        var sharp = mesh.SharpEdges.Select(e => new MeshEdge(target[e.A], target[e.B])).Where(e => e.A != e.B).Distinct().ToList();
        var welded = mesh.With(faces: faces, sharpEdges: sharp);
        // Collinear vertices: on a straight line between their neighbors in every face that uses them.
        var dissolve = new HashSet<int>();
        for (var v = 0; v < welded.Vertices.Length; v++)
        {
            var around = welded.FacesOfVertex(v);
            if (around.Count == 0)
            {
                continue;
            }
            var collinear = true;
            foreach (var f in around)
            {
                var corners = welded.Faces[f].Corners;
                var k = corners.IndexOf(v);
                var (prev, next) = (welded.Vertices[corners[(k + corners.Length - 1) % corners.Length]], welded.Vertices[corners[(k + 1) % corners.Length]]);
                var line = (next - prev).Normalized();
                var off = welded.Vertices[v] - prev;
                collinear &= corners.Length > 3 && (off - line * Vec3.Dot(off, line)).Length <= WeldDistance;
            }
            if (collinear)
            {
                dissolve.Add(v);
            }
        }
        faces = welded.Faces.Select(f => f with { Corners = [.. f.Corners.Where(c => !dissolve.Contains(c))] }).ToList();
        var degenerate = faces.Select((f, i) => (f, i)).Where(p => p.f.Corners.Distinct().Count() < 3).Select(p => p.i).ToHashSet();
        var used = faces.Where((f, i) => !degenerate.Contains(i)).SelectMany(f => f.Corners).ToHashSet();
        var unused = Enumerable.Range(0, welded.Vertices.Length).Where(v => !used.Contains(v)).ToHashSet();
        var result = Compact(welded.With(faces: faces), unused, degenerate);
        var problems = result.Edges.Where(e => result.FacesOfEdge(e).Count > 2).Select(e => $"the edge {e.A} {e.B} has {result.FacesOfEdge(e).Count} faces").ToList();
        return (result, problems);
    }

    /// <summary>
    /// Marks an edge sharp where its two faces' normals differ by more than an angle, and smooth otherwise: every edge
    /// of the mesh, or with faces given, only the edges that touch them.
    /// </summary>
    public static MeshData RecalculateNormals(MeshData mesh, double angleDegrees, IEnumerable<int>? faces = null)
    {
        var chosen = faces?.Where(f => f >= 0 && f < mesh.Faces.Length).ToHashSet();
        var cos = Math.Cos(angleDegrees * Math.PI / 180);
        var sharp = new List<MeshEdge>();
        foreach (var e in mesh.Edges)
        {
            var beside = mesh.FacesOfEdge(e);
            if (chosen != null && !beside.Any(chosen.Contains))
            {
                if (mesh.SharpEdges.Contains(e))
                {
                    sharp.Add(e);
                }
                continue;
            }
            if (beside.Count == 2 && Vec3.Dot(mesh.FaceNormal(beside[0]), mesh.FaceNormal(beside[1])) < cos)
            {
                sharp.Add(e);
            }
        }
        return mesh.With(sharpEdges: sharp);
    }

    // Corners without a repeat of the one before, around the face.
    static ImmutableArray<int> Dedupe(IEnumerable<int> corners)
    {
        var list = corners.ToList();
        var result = new List<int>();
        foreach (var c in list)
        {
            if (result.Count == 0 || result[^1] != c)
            {
                result.Add(c);
            }
        }
        if (result.Count > 1 && result[0] == result[^1])
        {
            result.RemoveAt(result.Count - 1);
        }
        return [.. result];
    }

    // Old vertex indices to new ones after some are removed, or -1.
    static int[] Remap(int count, HashSet<int> removed)
    {
        var remap = new int[count];
        var next = 0;
        for (var i = 0; i < count; i++)
        {
            remap[i] = removed.Contains(i) ? -1 : next++;
        }
        return remap;
    }
}
