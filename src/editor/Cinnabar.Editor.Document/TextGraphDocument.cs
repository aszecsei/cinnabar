namespace Cinnabar.Editor.Document;

/// <summary>A graph document whose file another program can also change, which a save then asks before it replaces.</summary>
public interface ITextGraphDocument : IGraphDocument
{
    /// <summary>Another program changed the file since the document last read or wrote it, or took it away.</summary>
    bool ChangedOnDisk { get; }
}

/// <summary>
/// An open text file that an editor keeps as whole lines, and its edits. Its first state is the file's text as it is, so
/// opening a file changes nothing, and the first save changes only the lines of its edits.
/// </summary>
public abstract class TextGraphDocument<TGraph> : GraphDocument<TGraph>, ITextGraphDocument
{
    // The file's text when the document last read or wrote it.
    string _onDisk;

    protected TextGraphDocument(string path, string guid, TGraph graph, string text) : base(path, guid, graph, text) => _onDisk = text;

    public bool ChangedOnDisk
    {
        get
        {
            try
            {
                return AnimationGraphFile.Decode(File.ReadAllBytes(Path)) != _onDisk;
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

    /// <summary>A file's full path and its text, or a problem when it cannot be read or is not UTF-8.</summary>
    protected static (string Path, string? Text, MaterialProblem? Problem) Read(string path)
    {
        var full = System.IO.Path.GetFullPath(path);
        byte[] bytes;
        try
        {
            bytes = File.ReadAllBytes(full);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return (full, null, new MaterialProblem(0, e.Message));
        }
        return AnimationGraphFile.Decode(bytes) is { } text ? (full, text, null) : (full, null, new MaterialProblem(0, "its text is not UTF-8"));
    }
}
