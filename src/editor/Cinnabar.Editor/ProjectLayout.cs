using Cinnabar.Editor.Document;

namespace Cinnabar.Editor;

/// <summary>
/// The engine's checkout and a project's folder, and the paths that the editor runs a project with. They are the paths
/// that <c>cinnabar.exe</c> builds (see docs/overview/getting-started.md#a-project), so the editor and the tool agree on
/// every file.
/// </summary>
public static class ProjectLayout
{
    /// <summary>The variable that names the engine's checkout, as <c>cinnabar.exe</c> reads it.</summary>
    public const string EngineVariable = "CINNABAR_ROOT";

    public const string SettingsFileName = "project.settings";
    public const string NameKey = "game.name";
    public const string MainSceneKey = "game.main_scene";

    /// <summary>A folder is the engine's checkout when it has the engine's content root.</summary>
    public static bool IsEngine(string dir) => Directory.Exists(Path.Combine(dir, "lib", "engine", "content"));

    /// <summary>
    /// The engine's checkout: <c>CINNABAR_ROOT</c>, or the checkout above the editor's executable, which a built editor
    /// is in. Null when neither is one.
    /// </summary>
    public static string? EngineRoot()
    {
        if (Environment.GetEnvironmentVariable(EngineVariable) is { Length: > 0 } variable && IsEngine(variable))
        {
            return Path.GetFullPath(variable);
        }
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
        {
            if (IsEngine(dir.FullName))
            {
                return dir.FullName;
            }
        }
        return null;
    }

    /// <summary>The project's folder that a path names: the folder itself, or the folder of its settings file. Null when it is neither.</summary>
    public static string? ProjectDirectory(string path)
    {
        var full = Path.GetFullPath(path);
        if (File.Exists(full) && Path.GetFileName(full).Equals(SettingsFileName, StringComparison.OrdinalIgnoreCase))
        {
            return Path.GetDirectoryName(full);
        }
        return File.Exists(Path.Combine(full, SettingsFileName)) ? full : null;
    }

    /// <summary>Whether a project has Odin of its own: a .odin file in its game folder.</summary>
    public static bool HasOdin(string projectDir)
    {
        var code = Path.Combine(projectDir, "game");
        return Directory.Exists(code) && Directory.EnumerateFiles(code, "*.odin").Any();
    }

    /// <summary>The game's name: its settings' <c>game.name</c>, or its folder's name.</summary>
    public static string Name(string projectDir) =>
        ProjectSettings.Get(Path.Combine(projectDir, SettingsFileName), NameKey) is { Length: > 0 } name ? name : Path.GetFileName(projectDir.TrimEnd('\\', '/'));

    /// <summary>The DXC that the engine downloaded: <c>vendor/dxc/&lt;version&gt;/dxc.exe</c>, the newest when there are several.</summary>
    public static string? Dxc(string engineRoot)
    {
        var dir = Path.Combine(engineRoot, "vendor", "dxc");
        if (!Directory.Exists(dir))
        {
            return null;
        }
        return Directory.EnumerateDirectories(dir)
            .Select(d => Path.Combine(d, "dxc.exe"))
            .Where(File.Exists)
            .OrderByDescending(p => p, StringComparer.Ordinal)
            .FirstOrDefault();
    }

    /// <summary>The source file in a content root whose .meta file gives a GUID, or null. Hidden folders are skipped, as the cooker skips them.</summary>
    public static string? FindAsset(string contentDir, string guid)
    {
        if (!Directory.Exists(contentDir))
        {
            return null;
        }
        foreach (var meta in Directory.EnumerateFiles(contentDir, "*.meta"))
        {
            if (string.Equals(ProjectSettings.Get(meta, "guid"), guid, StringComparison.OrdinalIgnoreCase))
            {
                return meta[..^".meta".Length];
            }
        }
        foreach (var dir in Directory.EnumerateDirectories(contentDir))
        {
            if (!Path.GetFileName(dir).StartsWith('.') && FindAsset(dir, guid) is { } found)
            {
                return found;
            }
        }
        return null;
    }

    /// <summary><c>cinnabar.exe</c> in the engine's build.</summary>
    public static string Tool(string engineRoot) => Path.Combine(engineRoot, "build", "tools", "cinnabar.exe");

    /// <summary>The templates that a new project starts from, by their folders' names, the basic one first.</summary>
    public static IReadOnlyList<string> Templates(string engineRoot)
    {
        var dir = Path.Combine(engineRoot, "lib", "engine", "templates");
        if (!Directory.Exists(dir))
        {
            return [];
        }
        return [.. Directory.EnumerateDirectories(dir).Select(Path.GetFileName).OfType<string>().OrderBy(t => t == "basic" ? "" : t, StringComparer.Ordinal)];
    }
}
