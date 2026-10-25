using System.Text.Json;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// Each user's editor settings, in <c>%LOCALAPPDATA%\cinnabar\editor</c>: <c>layout.json</c>, which the editor
/// writes when it closes, <c>keybindings.json</c>, an object from command ID to key gesture that the user writes, and
/// <c>settings.json</c>, the user's other settings, and <c>viewport.json</c>, how the viewport draws.
/// </summary>
public sealed class EditorSettings(string directory)
{
    public const string LayoutFileName = "layout.json";
    public const string KeyBindingsFileName = "keybindings.json";
    public const string SettingsFileName = "settings.json";
    /// <summary>The viewport's debug view, features and helpers, which the editor writes when they change.</summary>
    public const string ViewportFileName = "viewport.json";

    /// <summary>VS Code, at the file's line.</summary>
    public static readonly string[] DefaultScriptEditor = ["code", "-g", "{file}:{line}"];

    public string Directory { get; } = directory;

    public static EditorSettings ForUser() =>
        new(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "cinnabar", "editor"));

    public string? Read(string name)
    {
        var path = Path.Combine(Directory, name);
        return File.Exists(path) ? File.ReadAllText(path) : null;
    }

    public void Write(string name, string text)
    {
        System.IO.Directory.CreateDirectory(Directory);
        // Through a temporary file, so a crash while writing never leaves half a file.
        var path = Path.Combine(Directory, name);
        File.WriteAllText(path + ".tmp", text);
        File.Move(path + ".tmp", path, overwrite: true);
    }

    /// <summary>
    /// The command that opens a script, as <c>"scriptEditor"</c> in <c>settings.json</c>: an array of the program and
    /// its arguments, in which <c>{file}</c> and <c>{line}</c> stand for the script's path and a line.
    /// </summary>
    public string[] ScriptEditor()
    {
        if (Read(SettingsFileName) is not { } text)
        {
            return DefaultScriptEditor;
        }
        try
        {
            using var json = JsonDocument.Parse(text);
            return json.RootElement.TryGetProperty("scriptEditor", out var command) && command.ValueKind == JsonValueKind.Array
                ? [.. command.EnumerateArray().Select(a => a.GetString() ?? "")]
                : DefaultScriptEditor;
        }
        catch (JsonException)
        {
            return DefaultScriptEditor;
        }
    }

    /// <summary>The user's key bindings, and a warning if the file cannot be read.</summary>
    public (IReadOnlyDictionary<string, string> Bindings, string? Warning) ReadKeyBindings()
    {
        var text = Read(KeyBindingsFileName);
        if (text == null)
        {
            return (new Dictionary<string, string>(), null);
        }
        try
        {
            return (JsonSerializer.Deserialize<Dictionary<string, string>>(text) ?? [], null);
        }
        catch (JsonException e)
        {
            return (new Dictionary<string, string>(), $"key bindings: {Path.Combine(Directory, KeyBindingsFileName)}: {e.Message}");
        }
    }
}
