namespace Cinnabar.Editor.Document;

/// <summary>An open scene: its file and its contents. Saving comes with editing.</summary>
public sealed class SceneDocument(string path, Scene scene)
{
    /// <summary>The file's full path.</summary>
    public string Path { get; } = path;

    public Scene Scene { get; } = scene;

    public string Title => System.IO.Path.GetFileName(Path);

    /// <summary>Reads and parses a scene file. The document is null when the file cannot be read or has an error.</summary>
    public static (SceneDocument? Document, IReadOnlyList<SceneProblem> Problems) Open(string path)
    {
        var full = System.IO.Path.GetFullPath(path);
        string text;
        try
        {
            text = File.ReadAllText(full);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return (null, [new SceneProblem(0, e.Message, true)]);
        }
        var (scene, problems) = SceneFile.Parse(text);
        return (scene == null ? null : new SceneDocument(full, scene), problems);
    }
}
