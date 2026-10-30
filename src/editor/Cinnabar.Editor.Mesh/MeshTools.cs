using System.Collections.Immutable;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Mesh;

/// <summary>
/// The mesh tools (see docs/editor/mesh-editing.md#mesh-tools): each takes a mesh and the selection and gives a new
/// mesh. They are pure, so every one is a unit test without a host.
/// </summary>
public static partial class MeshTools
{
    /// <summary>
    /// Deletes elements: vertices with every face that uses them; edges' faces; faces, then the vertices that nothing
    /// uses. The mesh is compacted, so indices change.
    /// </summary>
    public static MeshData Delete(MeshData mesh, MeshElement kind, IEnumerable<int> indices)
    {
        var chosen = indices.ToHashSet();
        var removedFaces = new HashSet<int>();
        var removedVertices = new HashSet<int>();
        switch (kind)
        {
            case MeshElement.Vertices:
                removedVertices.UnionWith(chosen.Where(v => v < mesh.Vertices.Length));
                for (var i = 0; i < mesh.Faces.Length; i++)
                {
                    if (mesh.Faces[i].Corners.Any(removedVertices.Contains))
                    {
                        removedFaces.Add(i);
                    }
                }
                break;
            case MeshElement.Edges:
                foreach (var e in chosen.Where(e => e < mesh.Edges.Length))
                {
                    removedFaces.UnionWith(mesh.FacesOfEdge(mesh.Edges[e]));
                }
                break;
            default:
                removedFaces.UnionWith(chosen.Where(f => f < mesh.Faces.Length));
                var used = new HashSet<int>();
                for (var i = 0; i < mesh.Faces.Length; i++)
                {
                    if (!removedFaces.Contains(i))
                    {
                        used.UnionWith(mesh.Faces[i].Corners);
                    }
                }
                removedVertices.UnionWith(Enumerable.Range(0, mesh.Vertices.Length).Where(v => !used.Contains(v)));
                break;
        }
        return Compact(mesh, removedVertices, removedFaces);
    }

    /// <summary>The mesh without some vertices and faces, with the rest renumbered and the sharp edges that survive.</summary>
    public static MeshData Compact(MeshData mesh, HashSet<int> removedVertices, HashSet<int> removedFaces)
    {
        var remap = new int[mesh.Vertices.Length];
        var vertices = ImmutableArray.CreateBuilder<Vec3>();
        for (var i = 0; i < mesh.Vertices.Length; i++)
        {
            remap[i] = removedVertices.Contains(i) ? -1 : vertices.Count;
            if (remap[i] >= 0)
            {
                vertices.Add(mesh.Vertices[i]);
            }
        }
        var faces = mesh.Faces.Where((f, i) => !removedFaces.Contains(i) && f.Corners.All(c => c < remap.Length && remap[c] >= 0))
            .Select(f => f with { Corners = [.. f.Corners.Select(c => remap[c])] });
        var sharp = mesh.SharpEdges.Where(e => e.A < remap.Length && e.B < remap.Length && remap[e.A] >= 0 && remap[e.B] >= 0)
            .Select(e => new MeshEdge(remap[e.A], remap[e.B]));
        return mesh.With(vertices: vertices, faces: faces, sharpEdges: sharp);
    }

    /// <summary>The mesh with some vertices moved by a function of their position, which a gizmo drag is.</summary>
    public static MeshData MoveVertices(MeshData mesh, IEnumerable<int> indices, Func<Vec3, Vec3> move)
    {
        var chosen = indices.ToHashSet();
        return mesh.With(vertices: mesh.Vertices.Select((v, i) => chosen.Contains(i) ? move(v) : v));
    }

    /// <summary>The middle of some vertices, in the mesh's space.</summary>
    public static Vec3 Centroid(MeshData mesh, IEnumerable<int> vertices)
    {
        var sum = Vec3.Zero;
        var count = 0;
        foreach (var v in vertices.Where(v => v < mesh.Vertices.Length))
        {
            sum += mesh.Vertices[v];
            count++;
        }
        return count == 0 ? Vec3.Zero : sum / count;
    }
}
