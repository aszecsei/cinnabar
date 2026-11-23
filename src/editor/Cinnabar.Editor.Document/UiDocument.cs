namespace Cinnabar.Editor.Document;

/// <summary>
/// An open UI document and its edits. Its first state is the file's text as it is, so opening a file changes nothing,
/// and the first save changes only the text of its edits.
/// </summary>
public sealed class UiDocument : TextGraphDocument<UiFile>
{
    UiDocument(string path, string guid, UiFile file, string text) : base(path, guid, file, text)
    {
    }

    /// <summary>Reads a file. The document is null, with a problem, when it cannot be read or does not start as a UI document does.</summary>
    public static (UiDocument? Document, MaterialProblem? Problem) Open(string path, string guid) =>
        Open(path, (full, file, text) => new UiDocument(full, guid, file, text));
}
