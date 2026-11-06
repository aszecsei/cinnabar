namespace Cinnabar.Editor.Document;

/// <summary>
/// An open UI document and its edits. Its first state is the file's text as it is, so opening a file changes nothing,
/// and the first save changes only the text of its edits.
/// </summary>
public sealed class UiDocument : GraphDocument<UiFile>
{
    // The file's text when the document last read or wrote it.
    string _onDisk;

    UiDocument(string path, string guid, UiFile file, string text) : base(path, guid, file, text) => _onDisk = text;

    /// <summary>Another program changed the file since the document last read or wrote it, or took it away.</summary>
    public bool ChangedOnDisk
    {
        get
        {
            try
            {
                return UiFile.Decode(File.ReadAllBytes(Path)) != _onDisk;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                return true;
            }
        }
    }

    public override void Save()
    {
        var text = Text;
        base.Save();
        _onDisk = text;
    }

    /// <summary>Reads a file. The document is null, with a problem, when it cannot be read or does not start as a UI document does.</summary>
    public static (UiDocument? Document, MaterialProblem? Problem) Open(string path, string guid)
    {
        var full = System.IO.Path.GetFullPath(path);
        byte[] bytes;
        try
        {
            bytes = File.ReadAllBytes(full);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return (null, new MaterialProblem(0, e.Message));
        }
        if (UiFile.Decode(bytes) is not { } text)
        {
            return (null, new MaterialProblem(0, "its text is not UTF-8"));
        }
        var (file, problem) = UiFile.Parse(text);
        return (file == null ? null : new UiDocument(full, guid, file, text), problem);
    }

    protected override string WriteGraph() => Graph.Text;

    protected override UiFile ReadGraph(string text) => UiFile.Parse(text).File!;
}
