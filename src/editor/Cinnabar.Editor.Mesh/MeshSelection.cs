using System.Collections.Immutable;

namespace Cinnabar.Editor.Mesh;

/// <summary>The kind of element that mesh mode selects (see docs/editor/mesh-editing.md#mesh-mode), as Hammer's 1, 2 and 3.</summary>
public enum MeshElement
{
    Vertices,
    Edges,
    Faces,
}

/// <summary>One element of one mesh: a vertex or a face by index, or an edge by its index in the mesh's edge list.</summary>
public readonly record struct MeshItem(string Guid, int Index);

/// <summary>
/// The sub-selection of mesh mode: a set of elements of one kind across the edited meshes. It is immutable, so a
/// change is a new one. Changing the kind converts the selection through the vertices: faces give their vertices and
/// edges, and vertices give the edges and the faces whose every vertex is selected.
/// </summary>
public sealed class MeshSelection
{
    public static readonly MeshSelection Empty = new(MeshElement.Faces, ImmutableHashSet<MeshItem>.Empty);

    public MeshSelection(MeshElement kind, ImmutableHashSet<MeshItem> items)
    {
        Kind = kind;
        Items = items;
    }

    public MeshElement Kind { get; }

    public ImmutableHashSet<MeshItem> Items { get; }

    public int Count => Items.Count;

    public bool IsEmpty => Items.IsEmpty;

    public IEnumerable<string> Guids => Items.Select(i => i.Guid).Distinct();

    public IEnumerable<int> Of(string guid) => Items.Where(i => i.Guid == guid).Select(i => i.Index);

    public bool Contains(string guid, int index) => Items.Contains(new MeshItem(guid, index));

    public MeshSelection With(IEnumerable<MeshItem> items) => new(Kind, [.. items]);

    public MeshSelection Add(IEnumerable<MeshItem> items) => new(Kind, Items.Union(items));

    public MeshSelection Toggle(IEnumerable<MeshItem> items)
    {
        var set = Items;
        foreach (var item in items)
        {
            set = set.Contains(item) ? set.Remove(item) : set.Add(item);
        }
        return new MeshSelection(Kind, set);
    }

    public MeshSelection Clear() => new(Kind, ImmutableHashSet<MeshItem>.Empty);

    /// <summary>The selection as another kind of element, converted through the vertices of each mesh.</summary>
    public MeshSelection As(MeshElement kind, Func<string, MeshData?> meshes)
    {
        if (kind == Kind)
        {
            return this;
        }
        var items = ImmutableHashSet.CreateBuilder<MeshItem>();
        foreach (var guid in Guids)
        {
            if (meshes(guid) is not { } mesh)
            {
                continue;
            }
            var vertices = VerticesOf(mesh, Of(guid));
            items.UnionWith(Select(mesh, kind, vertices).Select(i => new MeshItem(guid, i)));
        }
        return new MeshSelection(kind, items.ToImmutable());
    }

    /// <summary>The vertices of the selected elements of a mesh.</summary>
    public HashSet<int> VerticesOf(MeshData mesh, IEnumerable<int> indices)
    {
        var vertices = new HashSet<int>();
        foreach (var index in indices)
        {
            switch (Kind)
            {
                case MeshElement.Vertices when index < mesh.Vertices.Length:
                    vertices.Add(index);
                    break;
                case MeshElement.Edges when index < mesh.Edges.Length:
                    vertices.Add(mesh.Edges[index].A);
                    vertices.Add(mesh.Edges[index].B);
                    break;
                case MeshElement.Faces when index < mesh.Faces.Length:
                    vertices.UnionWith(mesh.Faces[index].Corners);
                    break;
            }
        }
        return vertices;
    }

    /// <summary>The elements of a kind whose every vertex is in a set.</summary>
    public static IEnumerable<int> Select(MeshData mesh, MeshElement kind, HashSet<int> vertices) => kind switch
    {
        MeshElement.Vertices => vertices.Where(v => v < mesh.Vertices.Length).Order(),
        MeshElement.Edges => Enumerable.Range(0, mesh.Edges.Length).Where(i => vertices.Contains(mesh.Edges[i].A) && vertices.Contains(mesh.Edges[i].B)),
        _ => Enumerable.Range(0, mesh.Faces.Length).Where(i => mesh.Faces[i].Corners.All(vertices.Contains)),
    };

    /// <summary>Every element of a kind of a mesh.</summary>
    public static IEnumerable<MeshItem> All(string guid, MeshData mesh, MeshElement kind)
    {
        var count = kind switch { MeshElement.Vertices => mesh.Vertices.Length, MeshElement.Edges => mesh.Edges.Length, _ => mesh.Faces.Length };
        return Enumerable.Range(0, count).Select(i => new MeshItem(guid, i));
    }

    /// <summary>The selection without the elements that a mesh no longer has, after an edit changed its indices.</summary>
    public MeshSelection Pruned(Func<string, MeshData?> meshes)
    {
        var kept = Items.Where(i => meshes(i.Guid) is { } mesh && i.Index < (Kind switch
        {
            MeshElement.Vertices => mesh.Vertices.Length,
            MeshElement.Edges => mesh.Edges.Length,
            _ => mesh.Faces.Length,
        }));
        return new MeshSelection(Kind, [.. kept]);
    }
}
