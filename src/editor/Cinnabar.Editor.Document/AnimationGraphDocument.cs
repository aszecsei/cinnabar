namespace Cinnabar.Editor.Document;

/// <summary>
/// An open animation graph and its edits. Its first state is the file's text as it is, so opening a file changes nothing,
/// and the first save changes only the lines of its edits.
/// </summary>
public sealed class AnimationGraphDocument : TextGraphDocument<AnimationGraphFile>
{
    AnimationGraphDocument(string path, string guid, AnimationGraphFile graph, string text) : base(path, guid, graph, text)
    {
    }

    /// <summary>Reads a file. The document is null, with a problem, when it cannot be read or does not start as a graph does.</summary>
    public static (AnimationGraphDocument? Document, MaterialProblem? Problem) Open(string path, string guid)
    {
        var (full, text, problem) = Read(path);
        if (text == null)
        {
            return (null, problem);
        }
        var (graph, refused) = AnimationGraphFile.Parse(text);
        return (graph == null ? null : new AnimationGraphDocument(full, guid, graph, text), refused);
    }

    /// <summary>The node whose lines of <see cref="GraphDocument{TGraph}.Text"/> hold a line, or null for a line of no node.</summary>
    public int? NodeAt(int line) => Graph.NodeAt(line);

    protected override string WriteGraph() => Graph.Text;

    protected override AnimationGraphFile ReadGraph(string text) => AnimationGraphFile.Parse(text).File!;
}
