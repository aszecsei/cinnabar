namespace Cinnabar.Editor.Document;

/// <summary>
/// An open material or material function and its edits (see docs/editor/material-editor.md#material-editor). The
/// writer gives each node its lines, which a problem's line finds the node by.
/// </summary>
public sealed class MaterialDocument : GraphDocument<MaterialGraph>
{
    Dictionary<int, int> _nodeLines = [];

    MaterialDocument(string path, string guid, MaterialGraph graph) : base(path, guid, graph)
    {
    }

    public MaterialFileKind Kind => Graph.Kind;

    /// <summary>Reads and parses a material file. The document is null when the file cannot be read, does not parse, or is HLSL.</summary>
    public static (MaterialDocument? Document, IReadOnlyList<MaterialProblem> Problems) Open(string path, string guid)
    {
        var full = System.IO.Path.GetFullPath(path);
        string text;
        try
        {
            text = File.ReadAllText(full);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return (null, [new MaterialProblem(0, e.Message)]);
        }
        var (graph, problems) = MaterialFile.Parse(text, MaterialFile.KindOf(full));
        if (graph is { Hlsl: not null })
        {
            return (null, [new MaterialProblem(0, "its evaluate is HLSL after a --- line, which the script editor edits")]);
        }
        return (graph == null ? null : new MaterialDocument(full, guid, graph), problems);
    }

    /// <summary>A document of a graph, as a test or a new material makes it, at a path that it has not written.</summary>
    public static MaterialDocument Of(string path, string guid, MaterialGraph graph) => new(System.IO.Path.GetFullPath(path), guid, graph);

    /// <summary>The node whose lines of <see cref="GraphDocument{TGraph}.Text"/> hold a line, or null for a line of the settings.</summary>
    public int? NodeAt(int line)
    {
        int? found = null;
        var start = 0;
        foreach (var (id, first) in _nodeLines)
        {
            if (first <= line && first >= start)
            {
                (found, start) = (id, first);
            }
        }
        return found;
    }

    protected override MaterialGraph ReadGraph(string text) => MaterialFile.Parse(text, Graph.Kind).Graph!;

    protected override string WriteGraph()
    {
        var lines = new Dictionary<int, int>();
        var text = MaterialFile.Write(Graph, lines);
        _nodeLines = lines;
        return text;
    }
}
