namespace Cinnabar.Editor.Document;

/// <summary>
/// An open decision and its edits. Its first state is the file's text as it is, so opening a file changes nothing, and
/// the first save changes only the lines of its edits.
/// </summary>
public sealed class DecisionDocument : TextGraphDocument<DecisionFile>
{
    DecisionDocument(string path, string guid, DecisionFile file, string text) : base(path, guid, file, text)
    {
    }

    /// <summary>Reads a file. The document is null, with a problem, when it cannot be read or does not start as a decision does.</summary>
    public static (DecisionDocument? Document, MaterialProblem? Problem) Open(string path, string guid)
    {
        var (full, text, problem) = Read(path);
        if (text == null)
        {
            return (null, problem);
        }
        var (file, refused) = DecisionFile.Parse(text);
        return (file == null ? null : new DecisionDocument(full, guid, file, text), refused);
    }

    protected override string WriteGraph() => Graph.Text;

    protected override DecisionFile ReadGraph(string text) => DecisionFile.Parse(text).File!;
}
