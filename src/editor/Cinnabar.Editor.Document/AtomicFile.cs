namespace Cinnabar.Editor.Document;

/// <summary>
/// The editor's one way to write a file whole: to a temporary file beside it, then moved over it, so a crash, the cook
/// daemon or the host never sees half a file.
/// </summary>
public static class AtomicFile
{
    /// <summary>Writes text as UTF-8 without a byte order mark.</summary>
    public static void Write(string path, string text) => Write(path, Utf8Text.Encode(text));

    public static void Write(string path, byte[] bytes)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + ".tmp";
        File.WriteAllBytes(temporary, bytes);
        File.Move(temporary, path, overwrite: true);
    }
}
