
namespace Cinnabar.Editor.Document;

/// <summary>An error or a warning in a scene file, at a line from 1, or 0 for the whole file.</summary>
public sealed record SceneProblem(int Line, string Message, bool IsError)
{
    public override string ToString() => Line > 0 ? $"{Line}: {Message}" : Message;
}

/// <summary>
/// What a scene file is for, which its text alone does not say. A prefab's sublevel key is a warning, and the reader
/// drops it, because an instance can be in any sublevel. With the project's declared sublevels, a name that is not among
/// them is a warning; with null, no name is checked.
/// </summary>
public sealed record SceneParseOptions(bool IsPrefab = false, IReadOnlyCollection<string>? Sublevels = null);

/// <summary>
/// Reads and writes scene files (see docs/editor/document-and-scenes.md#scenes). The cooker reads the same format with
/// <c>asset_format.scene_parse</c>, and the two must agree. Writing sorts entities by scene ID, with an instance's
/// override blocks after it by path (see docs/editor/prefabs.md#instances-in-a-scene), and components by ID, so an edit
/// changes only the lines of the entity that it touches. A prefab is a scene file with one root. The reader takes
/// versions 1 to 3 too. Version 1 has no instances, version 2 no references to other scenes, and version 3 no sublevels.
/// The writer writes version 3 for a scene without a sublevel, so a file that has none stays as older editors wrote it.
/// </summary>
public static partial class SceneFile
{
    public const int Version = 4;
    /// <summary>The version of a file without a sublevel key.</summary>
    public const int VersionWithoutSublevels = 3;
    /// <summary>The longest name of a sublevel, which is letters, digits and _, as <c>asset_format.SUBLEVEL_MAX_NAME</c>.</summary>
    public const int MaxSublevelName = 31;

    /// <summary>Whether a name can be a sublevel's.</summary>
    public static bool IsSublevelName(string name) => name.Length is >= 1 and <= MaxSublevelName && name.All(c => c == '_' || char.IsAsciiLetterOrDigit(c));
    public const string Extension = ".scene";
    public const string PrefabExtension = ".prefab";

    /// <summary>Parses a file. The scene is null when a problem is an error.</summary>
    public static (Scene? Scene, IReadOnlyList<SceneProblem> Problems) Parse(string text, SceneParseOptions? options = null)
    {
        var parser = new Parser(options ?? new SceneParseOptions());
        parser.Run(text);
        return (parser.Problems.Any(p => p.IsError) ? null : parser.Scene, parser.Problems);
    }
}
