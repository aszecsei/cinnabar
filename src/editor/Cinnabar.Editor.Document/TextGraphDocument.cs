namespace Cinnabar.Editor.Document;

/// <summary>A graph document whose file another program can also change, which a save then asks before it replaces.</summary>
public interface ITextGraphDocument : IGraphDocument
{
    /// <summary>Another program changed the file since the document last read or wrote it, or took it away.</summary>
    bool ChangedOnDisk { get; }
}

/// <summary>A file format that keeps its text as it is, so writing it gives back the text that it read.</summary>
public interface ITextFile<TSelf> where TSelf : class, ITextFile<TSelf>
{
    /// <summary>Reads a file's text. The file is null, with a problem, when the text does not start as the format does.</summary>
    static abstract (TSelf? File, MaterialProblem? Problem) Parse(string text);

    /// <summary>The file's text, with its edits.</summary>
    string Text { get; }
}

/// <summary>
/// An open text file that an editor keeps as whole lines, and its edits. Its first state is the file's text as it is, so
/// opening a file changes nothing, and the first save changes only the lines of its edits.
/// </summary>
public abstract class TextGraphDocument<TFile> : GraphDocument<TFile>, ITextGraphDocument
    where TFile : class, ITextFile<TFile>
{
    // The file's text when the document last read or wrote it.
    string _onDisk;

    protected TextGraphDocument(string path, string guid, TFile file, string text) : base(path, guid, file, text) => _onDisk = text;

    public bool ChangedOnDisk
    {
        get
        {
            try
            {
                return Utf8Text.Decode(File.ReadAllBytes(Path)) != _onDisk;
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

    protected sealed override string WriteGraph() => Graph.Text;

    protected sealed override TFile ReadGraph(string text) => TFile.Parse(text).File!;

    /// <summary>
    /// Reads a file into a document that <paramref name="make"/> builds from the file's full path, its parsed file and
    /// its text. The document is null, with a problem, when the file cannot be read, is not UTF-8, or does not start as
    /// the format does.
    /// </summary>
    protected static (TDoc? Document, MaterialProblem? Problem) Open<TDoc>(string path, Func<string, TFile, string, TDoc> make)
        where TDoc : TextGraphDocument<TFile>
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
        if (Utf8Text.Decode(bytes) is not { } text)
        {
            return (null, new MaterialProblem(0, "its text is not UTF-8"));
        }
        var (file, problem) = TFile.Parse(text);
        return (file == null ? null : make(full, file, text), problem);
    }
}
