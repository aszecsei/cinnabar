namespace Cinnabar.Editor.Document;

/// <summary>
/// A project's settings file (see docs/overview/architecture.md#project-settings): <c>key = value</c> lines, with blank lines
/// and <c>#</c> comments, which the game reads. The user file beside it, <c>project.user.settings</c> for
/// <c>project.settings</c>, replaces its values on one machine. An edit changes a key's line in place, so the file keeps
/// its comments and order.
/// </summary>
public static class ProjectSettings
{
    /// <summary>The user file beside a project file: the project file's name with <c>.user</c> before its extension.</summary>
    public static string UserPath(string path)
    {
        var extension = Path.GetExtension(path);
        return extension == "" ? path + ".user" : path[..^extension.Length] + ".user" + extension;
    }

    /// <summary>A key's value in a file, or null when the file or the key is not there. The last line with it wins.</summary>
    public static string? Get(string path, string key)
    {
        if (!File.Exists(path))
        {
            return null;
        }
        string? value = null;
        foreach (var line in File.ReadAllLines(path))
        {
            if (Parse(line) is { } entry && entry.Key == key)
            {
                value = entry.Value;
            }
        }
        return value;
    }

    /// <summary>The keys that a file gives, in the order of their last lines, or none when the file is not there.</summary>
    public static IReadOnlyList<string> Keys(string path)
    {
        if (!File.Exists(path))
        {
            return [];
        }
        var keys = new List<string>();
        foreach (var line in File.ReadAllLines(path))
        {
            if (Parse(line) is { } entry)
            {
                keys.Remove(entry.Key);
                keys.Add(entry.Key);
            }
        }
        return keys;
    }

    /// <summary>
    /// Sets a key in a file, replacing its line or adding one, or removes it with a null value. A user file left with
    /// nothing but comments goes, so the game has nothing to replace.
    /// </summary>
    public static void Set(string path, string key, string? value, bool removeWhenEmpty = false)
    {
        var lines = File.Exists(path) ? File.ReadAllLines(path).ToList() : [];
        // Only the last line with the key counts, so the earlier ones go.
        var index = lines.FindLastIndex(l => Parse(l)?.Key == key);
        for (var i = index - 1; i >= 0; i--)
        {
            if (Parse(lines[i])?.Key == key)
            {
                lines.RemoveAt(i);
                index--;
            }
        }
        if (value == null)
        {
            if (index >= 0)
            {
                lines.RemoveAt(index);
            }
        }
        else if (index >= 0)
        {
            lines[index] = $"{key} = {value}";
        }
        else
        {
            lines.Add($"{key} = {value}");
        }
        if (removeWhenEmpty && lines.All(l => Parse(l) == null))
        {
            File.Delete(path);
            return;
        }
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        File.WriteAllText(path, string.Join("\n", lines) + "\n");
    }

    /// <summary>The prefix of the keys that declare sublevels, <c>sublevel.&lt;name&gt; = active</c> or <c>= inactive</c>.</summary>
    public const string SublevelPrefix = "sublevel.";

    /// <summary>
    /// The sublevels that a project file and its user file declare, in the order that their names first appear, and
    /// whether each one starts active: the last line for a name wins. A line with a name or a value that does not fit is
    /// skipped, as the game warns about it.
    /// </summary>
    public static IReadOnlyList<(string Name, bool Active)> Sublevels(string path)
    {
        var sublevels = new List<(string Name, bool Active)>();
        foreach (var file in new[] { path, UserPath(path) })
        {
            if (!File.Exists(file))
            {
                continue;
            }
            foreach (var line in File.ReadAllLines(file))
            {
                if (!TryParseLine(line, out var key, out var value) || !TryParseSublevel(key, value, out var name, out var active))
                {
                    continue;
                }
                var at = sublevels.FindIndex(s => s.Name == name);
                if (at < 0)
                {
                    sublevels.Add((name, active));
                }
                else
                {
                    sublevels[at] = (name, active);
                }
            }
        }
        return sublevels;
    }

    /// <summary>
    /// Splits a <c>key = value</c> line as the engine's <c>format.settings_line</c> does, and is false for a blank line or
    /// a comment. A line without <c>=</c> is a key with an empty value. <c>lib/engine/asset/format/testdata/lexemes.json</c>
    /// pins the two together.
    /// </summary>
    public static bool TryParseLine(string line, out string key, out string value)
    {
        var trimmed = line.Trim();
        if (trimmed.Length == 0 || trimmed[0] == '#')
        {
            key = value = "";
            return false;
        }
        var equals = trimmed.IndexOf('=');
        (key, value) = equals < 0 ? (trimmed, "") : (trimmed[..equals].Trim(), trimmed[(equals + 1)..].Trim());
        return true;
    }

    /// <summary>
    /// Reads a line <c>sublevel.&lt;name&gt; = active|inactive</c> as the engine's <c>format.sublevel_parse_setting</c>
    /// does, and is false for another key, a name that <see cref="SceneFile.IsSublevelName"/> refuses or another value.
    /// </summary>
    public static bool TryParseSublevel(string key, string value, out string name, out bool active)
    {
        name = key.StartsWith(SublevelPrefix, StringComparison.Ordinal) ? key[SublevelPrefix.Length..] : "";
        active = value == "active";
        return name != "" && SceneFile.IsSublevelName(name) && value is "active" or "inactive";
    }

    static (string Key, string Value)? Parse(string line) =>
        TryParseLine(line, out var key, out var value) ? (key, value) : null;
}
