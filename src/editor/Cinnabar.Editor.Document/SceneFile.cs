
namespace Cinnabar.Editor.Document;

/// <summary>An error or a warning in a scene file, at a line from 1, or 0 for the whole file.</summary>
public sealed record SceneProblem(int Line, string Message, bool IsError)
{
    public override string ToString() => Line > 0 ? $"{Line}: {Message}" : Message;
}

/// <summary>
/// Reads and writes scene files (see docs/editor/document-and-scenes.md#scenes). The cooker reads the same format with
/// <c>asset_format.scene_parse</c>, and the two must agree. Writing sorts entities by scene ID, with an instance's
/// override blocks after it by path (see docs/editor/prefabs.md#instances-in-a-scene), and components by ID, so an edit
/// changes only the lines of the entity that it touches. A prefab is a scene file with one root. The reader takes
/// versions 1 and 2 too. Version 1 has no instances, and version 2 no references to other scenes.
/// </summary>
public static partial class SceneFile
{
    public const int Version = 3;
    public const string Extension = ".scene";
    public const string PrefabExtension = ".prefab";

    /// <summary>Parses a file. The scene is null when a problem is an error.</summary>
    public static (Scene? Scene, IReadOnlyList<SceneProblem> Problems) Parse(string text)
    {
        var parser = new Parser();
        parser.Run(text);
        return (parser.Problems.Any(p => p.IsError) ? null : parser.Scene, parser.Problems);
    }
}
