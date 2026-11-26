using Cinnabar.Editor.Maths;

namespace Cinnabar.Editor.Mesh;

/// <summary>
/// Maps a cut's result back to its source, so that mesh mode can draw and pick the result while it edits the source
/// (see docs/editor/mesh-editing.md#editing-a-cut-wall). A result face is a fragment of a source face, or a face that a
/// cutter made. A result vertex is a source vertex when it is at the same point, since the cut welds its fragments to
/// the source's vertices first. A result edge is a source edge, or a fragment of one, when it lies on it.
/// </summary>
public sealed class CutMap
{
    readonly int[] _sourceFace;
    readonly IReadOnlyList<string> _cutters;
    readonly int?[] _vertex;
    readonly int?[] _edge;

    /// <summary>
    /// A map of a result onto the source it was cut from. <paramref name="sourceFace"/> gives each result face's source
    /// face, or <c>~i</c> for a face that cutter i made, whose label is <paramref name="cutters"/>[i].
    /// </summary>
    public CutMap(MeshData source, MeshData result, int[] sourceFace, IReadOnlyList<string> cutters)
    {
        Source = source;
        Result = result;
        _sourceFace = sourceFace;
        _cutters = cutters;
        var points = new Dictionary<Vec3, int>();
        for (var i = 0; i < source.Vertices.Length; i++)
        {
            points.TryAdd(source.Vertices[i], i);
        }
        _vertex = [.. result.Vertices.Select(v => points.TryGetValue(v, out var i) ? i : (int?)null)];
        _edge = [.. result.Edges.Select(e => EdgeOf(source, result, e))];
    }

    /// <summary>The source that the map was made from. A newer source is not mapped by it.</summary>
    public MeshData Source { get; }

    /// <summary>The result that the map was made from.</summary>
    public MeshData Result { get; }

    /// <summary>The source face of a result face, or null for one that a cutter made.</summary>
    public int? SourceFace(int resultFace) =>
        resultFace >= 0 && resultFace < _sourceFace.Length && _sourceFace[resultFace] >= 0 ? _sourceFace[resultFace] : null;

    /// <summary>The label of the cutter that made a result face, or null for a fragment of a source face.</summary>
    public string? Cutter(int resultFace) =>
        resultFace >= 0 && resultFace < _sourceFace.Length && _sourceFace[resultFace] < 0 && ~_sourceFace[resultFace] < _cutters.Count
            ? _cutters[~_sourceFace[resultFace]] : null;

    /// <summary>The source vertex at a result vertex's point, or null for a vertex that the cut made.</summary>
    public int? SourceVertex(int resultVertex) => resultVertex >= 0 && resultVertex < _vertex.Length ? _vertex[resultVertex] : null;

    /// <summary>The source edge that a result edge is, or lies on, or null for an edge that the cut made.</summary>
    public int? SourceEdge(int resultEdge) => resultEdge >= 0 && resultEdge < _edge.Length ? _edge[resultEdge] : null;

    /// <summary>The source index of a result element of a kind, or null for one that the cut made.</summary>
    public int? SourceOf(MeshElement kind, int resultIndex) => kind switch
    {
        MeshElement.Vertices => SourceVertex(resultIndex),
        MeshElement.Edges => SourceEdge(resultIndex),
        _ => SourceFace(resultIndex),
    };

    /// <summary>The result elements of a kind that a source element became.</summary>
    public IEnumerable<int> ResultsOf(MeshElement kind, int sourceIndex)
    {
        var count = kind switch
        {
            MeshElement.Vertices => _vertex.Length,
            MeshElement.Edges => _edge.Length,
            _ => _sourceFace.Length,
        };
        return Enumerable.Range(0, count).Where(i => SourceOf(kind, i) == sourceIndex);
    }

    // The source edge that a result edge lies on: the one between its ends' source vertices, else one whose segment
    // holds both its ends, as a fragment of an edge that the cut split does.
    static int? EdgeOf(MeshData source, MeshData result, MeshEdge edge)
    {
        var a = result.Vertices[edge.A];
        var b = result.Vertices[edge.B];
        var edges = source.Edges;
        for (var i = 0; i < edges.Length; i++)
        {
            var p = source.Vertices[edges[i].A];
            var q = source.Vertices[edges[i].B];
            if (OnSegment(a, p, q) && OnSegment(b, p, q))
            {
                return i;
            }
        }
        return null;
    }

    static bool OnSegment(Vec3 x, Vec3 p, Vec3 q)
    {
        var d = q - p;
        var lengthSquared = Vec3.Dot(d, d);
        if (lengthSquared < 1e-18)
        {
            return false;
        }
        var t = Math.Clamp(Vec3.Dot(x - p, d) / lengthSquared, 0, 1);
        return (p + d * t - x).Length <= MeshBoolean.PlaneEpsilon;
    }
}
