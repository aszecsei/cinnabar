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

    static (string Key, string Value)? Parse(string line)
    {
        var trimmed = line.Trim();
        var equals = trimmed.IndexOf('=');
        if (trimmed.Length == 0 || trimmed[0] == '#' || equals <= 0)
        {
            return null;
        }
        return (trimmed[..equals].Trim(), trimmed[(equals + 1)..].Trim());
    }
}
