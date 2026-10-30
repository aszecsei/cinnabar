using System.Collections.Immutable;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Mesh;

/// <summary>A tool's result: the new mesh and the elements to select, of the kind the tool leaves selected.</summary>
public readonly record struct ToolResult(MeshData Mesh, MeshElement Kind, IReadOnlyList<int> Selected);

/// <summary>The region tools: Extrude, Push/Pull, Offset, Inset, Duplicate (see docs/editor/mesh-editing.md#mesh-tools).</summary>
public static partial class MeshTools
{
    /// <summary>
    /// Pulls faces out along their average normal by a distance, with walls along the region's boundary, and gives the
    /// moved faces to select, so the following drag sets the distance. Faces that share an edge extrude as one, without
    /// a wall between them. A wall takes its face's material and a world-aligned mapping, and its edges are sharp.
    /// </summary>
    public static ToolResult Extrude(MeshData mesh, IEnumerable<int> faces, double distance, double mappingScale = Mapping.DefaultScale)
    {
        var region = new MeshRegion(mesh, faces);
        if (region.Faces.Count == 0)
        {
            return new ToolResult(mesh, MeshElement.Faces, []);
        }
        var normal = region.Normal;
        var move = normal * distance;
        var vertices = mesh.Vertices.ToBuilder();
        var map = new Dictionary<int, int>();
        // Boundary vertices are copied, so the faces outside keep theirs; interior ones move in place.
        foreach (var v in region.Vertices.Order())
        {
            if (region.BoundaryVertices.Contains(v))
            {
                map[v] = vertices.Count;
                vertices.Add(mesh.Vertices[v] + move);
            }
            else
            {
                map[v] = v;
                vertices[v] = mesh.Vertices[v] + move;
            }
        }
        var newFaces = mesh.Faces.ToBuilder();
        foreach (var f in region.Faces)
        {
            newFaces[f] = newFaces[f] with { Corners = [.. newFaces[f].Corners.Select(c => map[c])] };
        }
        var sharp = mesh.SharpEdges.ToBuilder();
        foreach (var h in region.Boundary)
        {
            var (a, b) = (h.From, h.To);
            var wallNormal = Vec3.Cross(mesh.Vertices[b] - mesh.Vertices[a], normal).Normalized();
            newFaces.Add(new MeshFace(mesh.Faces[h.Face].Slot, [a, b, map[b], map[a]], Mapping.WorldAligned(wallNormal, mappingScale)));
            foreach (var e in new[] { new MeshEdge(a, b), new MeshEdge(map[a], map[b]), new MeshEdge(a, map[a]), new MeshEdge(b, map[b]) })
            {
                if (!sharp.Contains(e))
                {
                    sharp.Add(e);
                }
            }
        }
        return new ToolResult(mesh.With(vertices: vertices, faces: newFaces, sharpEdges: sharp), MeshElement.Faces, [.. region.Faces.Order()]);
    }

    /// <summary>
    /// Pulls open edges out: a quad along each, along the normal of the face beside it, with the new edges selected.
    /// Each edge gets copies of its own, so every quad is planar; an edge with two faces already is left alone, since a
    /// fin on it would give it three.
    /// </summary>
    public static ToolResult ExtrudeEdges(MeshData mesh, IEnumerable<int> edges, double distance, double mappingScale = Mapping.DefaultScale)
    {
        var chosen = edges.Where(e => e >= 0 && e < mesh.Edges.Length && mesh.FacesOfEdge(mesh.Edges[e]).Count < 2).Distinct().ToList();
        if (chosen.Count == 0)
        {
            return new ToolResult(mesh, MeshElement.Edges, []);
        }
        Vec3 EdgeNormal(MeshEdge e)
        {
            var sum = Vec3.Zero;
            foreach (var f in mesh.FacesOfEdge(e))
            {
                sum += mesh.FaceNormal(f);
            }
            return sum.Length > 1e-9 ? sum.Normalized() : Vec3.UnitY;
        }
        var vertices = mesh.Vertices.ToBuilder();
        var newFaces = mesh.Faces.ToBuilder();
        var sharp = mesh.SharpEdges.ToBuilder();
        var selected = new List<MeshEdge>();
        foreach (var e in chosen)
        {
            var edge = mesh.Edges[e];
            var move = EdgeNormal(edge) * distance;
            var map = new Dictionary<int, int>();
            foreach (var v in new[] { edge.A, edge.B })
            {
                map[v] = vertices.Count;
                vertices.Add(mesh.Vertices[v] + move);
            }
            // The quad fronts as the first face beside the edge does: a to b in that face's winding.
            var (a, b) = (edge.A, edge.B);
            var slot = 0;
            if (mesh.FacesOfEdge(edge) is [var first, ..])
            {
                var corners = mesh.Faces[first].Corners;
                slot = mesh.Faces[first].Slot;
                for (var k = 0; k < corners.Length; k++)
                {
                    if (corners[k] == edge.B && corners[(k + 1) % corners.Length] == edge.A)
                    {
                        (a, b) = (edge.B, edge.A);
                    }
                }
            }
            var wallNormal = Vec3.Cross(mesh.Vertices[b] - mesh.Vertices[a], EdgeNormal(edge)).Normalized();
            newFaces.Add(new MeshFace(slot, [a, b, map[b], map[a]], Mapping.WorldAligned(wallNormal, mappingScale)));
            selected.Add(new MeshEdge(map[a], map[b]));
            foreach (var s in new[] { new MeshEdge(map[a], map[b]), new MeshEdge(a, map[a]), new MeshEdge(b, map[b]) })
            {
                if (!sharp.Contains(s))
                {
                    sharp.Add(s);
                }
            }
        }
        var result = mesh.With(vertices: vertices, faces: newFaces, sharpEdges: sharp);
        return new ToolResult(result, MeshElement.Edges, [.. selected.Select(e => result.EdgeIndex(e.A, e.B)).Where(i => i >= 0)]);
    }

    /// <summary>Moves faces along the selection's average normal; the faces beside them stretch.</summary>
    public static ToolResult PushPull(MeshData mesh, IEnumerable<int> faces, double distance)
    {
        var region = new MeshRegion(mesh, faces);
        var move = region.Normal * distance;
        return new ToolResult(MoveVertices(mesh, region.Vertices, v => v + move), MeshElement.Faces, [.. region.Faces.Order()]);
    }

    /// <summary>
    /// Shells: moves each face along its own normal by a distance, moving a shared vertex to where the moved planes
    /// meet, so each face stays parallel to where it was and corners stay sharp.
    /// </summary>
    public static ToolResult Offset(MeshData mesh, IEnumerable<int> faces, double distance)
    {
        var region = new MeshRegion(mesh, faces);
        var moves = new Dictionary<int, Vec3>();
        foreach (var v in region.Vertices)
        {
            var normals = mesh.FacesOfVertex(v).Where(region.Faces.Contains).Select(mesh.FaceNormal).Where(n => n != Vec3.Zero).ToList();
            moves[v] = MeshRegion.Bisector(normals) * distance;
        }
        return new ToolResult(mesh.With(vertices: mesh.Vertices.Select((v, i) => moves.TryGetValue(i, out var m) ? v + m : v)), MeshElement.Faces, [.. region.Faces.Order()]);
    }

    /// <summary>
    /// Shrinks each region's boundary toward its inside by a distance, in the faces' planes, with a ring of new faces
    /// around it. Faces that share an edge inset as one region. A negative distance outsets.
    /// </summary>
    public static ToolResult Inset(MeshData mesh, IEnumerable<int> faces, double distance)
    {
        var chosen = faces.Where(f => f >= 0 && f < mesh.Faces.Length).ToHashSet();
        if (chosen.Count == 0)
        {
            return new ToolResult(mesh, MeshElement.Faces, []);
        }
        var vertices = mesh.Vertices.ToBuilder();
        var newFaces = mesh.Faces.ToBuilder();
        var sharp = mesh.SharpEdges.ToBuilder();
        foreach (var group in MeshRegion.Connected(mesh, chosen))
        {
            var region = new MeshRegion(mesh, group);
            var offsets = region.InsetOffsets(distance);
            var map = new Dictionary<int, int>();
            foreach (var (v, offset) in offsets.OrderBy(p => p.Key))
            {
                map[v] = vertices.Count;
                vertices.Add(mesh.Vertices[v] + offset);
            }
            foreach (var f in group)
            {
                newFaces[f] = newFaces[f] with { Corners = [.. newFaces[f].Corners.Select(c => map.GetValueOrDefault(c, c))] };
            }
            foreach (var h in region.Boundary)
            {
                var (a, b) = (h.From, h.To);
                newFaces.Add(new MeshFace(mesh.Faces[h.Face].Slot, [a, b, map[b], map[a]], mesh.Faces[h.Face].Mapping));
                var inner = new MeshEdge(map[a], map[b]);
                if (!sharp.Contains(inner) && sharp.Contains(new MeshEdge(a, b)))
                {
                    sharp.Add(inner);
                }
            }
        }
        return new ToolResult(mesh.With(vertices: vertices, faces: newFaces, sharpEdges: sharp), MeshElement.Faces, [.. chosen.Order()]);
    }

    /// <summary>Copies faces in place, with their own vertices, and gives the copies to select, so a drag moves them.</summary>
    public static ToolResult Duplicate(MeshData mesh, IEnumerable<int> faces)
    {
        var chosen = faces.Where(f => f >= 0 && f < mesh.Faces.Length).Distinct().Order().ToList();
        var vertices = mesh.Vertices.ToBuilder();
        var map = new Dictionary<int, int>();
        foreach (var v in chosen.SelectMany(f => mesh.Faces[f].Corners).Distinct().Order())
        {
            map[v] = vertices.Count;
            vertices.Add(mesh.Vertices[v]);
        }
        var newFaces = mesh.Faces.ToBuilder();
        var selected = new List<int>();
        foreach (var f in chosen)
        {
            selected.Add(newFaces.Count);
            newFaces.Add(mesh.Faces[f] with { Corners = [.. mesh.Faces[f].Corners.Select(c => map[c])] });
        }
        var sharp = mesh.SharpEdges.ToBuilder();
        foreach (var e in mesh.SharpEdges)
        {
            if (map.ContainsKey(e.A) && map.ContainsKey(e.B))
            {
                sharp.Add(new MeshEdge(map[e.A], map[e.B]));
            }
        }
        return new ToolResult(mesh.With(vertices: vertices, faces: newFaces, sharpEdges: sharp), MeshElement.Faces, selected);
    }

    /// <summary>Reverses faces, so they face the other way, and mirrors their mappings' v axis so the texture reads the same.</summary>
    public static ToolResult Invert(MeshData mesh, IEnumerable<int> faces)
    {
        var chosen = faces.Where(f => f >= 0 && f < mesh.Faces.Length).ToHashSet();
        var newFaces = mesh.Faces.Select((f, i) => chosen.Contains(i)
            ? f with { Corners = [.. f.Corners.Reverse()], Mapping = f.Mapping with { VAxis = -f.Mapping.VAxis } }
            : f);
        return new ToolResult(mesh.With(faces: newFaces), MeshElement.Faces, [.. chosen.Order()]);
    }

    /// <summary>
    /// The faces as a mesh of their own, with their vertices copied and the sharp edges among them, and the mesh
    /// without them, for Detach; Extract keeps the source as it is.
    /// </summary>
    public static (MeshData Extracted, MeshData Remaining) Split(MeshData mesh, IEnumerable<int> faces)
    {
        var chosen = faces.Where(f => f >= 0 && f < mesh.Faces.Length).ToHashSet();
        var kept = Enumerable.Range(0, mesh.Faces.Length).Where(f => !chosen.Contains(f)).ToHashSet();
        var extracted = Compact(mesh, [.. Enumerable.Range(0, mesh.Vertices.Length).Where(v => !chosen.Any(f => mesh.Faces[f].Corners.Contains(v)))], kept);
        var used = kept.SelectMany(f => mesh.Faces[f].Corners).ToHashSet();
        var remaining = Compact(mesh, [.. Enumerable.Range(0, mesh.Vertices.Length).Where(v => !used.Contains(v))], chosen);
        return (extracted, remaining);
    }
}
