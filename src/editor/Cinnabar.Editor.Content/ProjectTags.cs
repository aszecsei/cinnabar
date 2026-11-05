using System.Text.RegularExpressions;

namespace Cinnabar.Editor.Content;

/// <summary>
/// A project's tags for its assets (see docs/editor/shell-and-panels.md#content-browser), in <c>project.tags</c> beside
/// <c>project.settings</c>: a line of <c>guid = env/stone/trim, review/todo</c> for each tagged asset, with blank lines and
/// <c>#</c> comments. A <c>/</c> nests a tag, and a tag matches the tags under it. The file is keyed by GUID, so a move keeps
/// an asset's tags, and it is not content, so a change cooks nothing. An edit changes its asset's line in place, and a new
/// line goes in GUID order, so two people who tag different assets merge cleanly. An asset that is gone keeps its line,
/// because the Recycle Bin can bring it back with its GUID.
/// </summary>
public sealed partial class ProjectTags(string path)
{
    /// <summary>The file beside a project's settings.</summary>
    public static string PathFor(string projectPath) => Path.Combine(Path.GetDirectoryName(Path.GetFullPath(projectPath)) ?? "", "project.tags");

    readonly Dictionary<string, string[]> _tags = [];
    List<string> _lines = [];
    DateTime _stamp;
    long _size = -1;

    public string FilePath { get; } = path;

    /// <summary>The file's tags changed, by an edit here or from outside.</summary>
    public event Action? Changed;

    [GeneratedRegex(@"^[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)*$")]
    private static partial Regex Valid();

    /// <summary>A tag as the file spells it, without the slashes and spaces around it, or null when it has other characters.</summary>
    public static string? Normalize(string text)
    {
        var tag = text.Trim().Trim('/');
        return Valid().IsMatch(tag) ? tag : null;
    }

    /// <summary>Reads the file if it changed since the last read, as a pull or another program can change it.</summary>
    public void Reload()
    {
        var info = new FileInfo(FilePath);
        var (stamp, size) = info.Exists ? (info.LastWriteTimeUtc, info.Length) : (default, 0L);
        if (stamp == _stamp && size == _size)
        {
            return;
        }
        _stamp = stamp;
        _size = size;
        _lines = info.Exists ? [.. File.ReadAllLines(FilePath)] : [];
        _tags.Clear();
        foreach (var line in _lines)
        {
            if (Parse(line) is var (guid, tags))
            {
                _tags[guid] = tags;
            }
        }
        Changed?.Invoke();
    }

    /// <summary>The assets that have tags, by GUID.</summary>
    public IEnumerable<string> Assets => _tags.Keys;

    /// <summary>An asset's own tags.</summary>
    public IReadOnlyList<string> Of(string guid) => _tags.GetValueOrDefault(guid) ?? [];

    /// <summary>Whether an asset has a tag or one under it.</summary>
    public bool Has(string guid, string tag) =>
        _tags.TryGetValue(guid, out var tags) && tags.Any(t => t == tag || t.StartsWith(tag + "/", StringComparison.Ordinal));

    /// <summary>Every tag that an asset has, and each tag above one, in order.</summary>
    public IReadOnlyList<string> All()
    {
        var all = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var tag in _tags.Values.SelectMany(t => t))
        {
            for (var at = tag; ; at = at[..at.LastIndexOf('/')])
            {
                all.Add(at);
                if (!at.Contains('/'))
                {
                    break;
                }
            }
        }
        return [.. all];
    }

    /// <summary>Adds a tag to assets, and makes no new tag of one that is there.</summary>
    public void Add(IEnumerable<string> guids, string tag) =>
        Edit(guids.Select(g => (g, Of(g).Union([tag]).ToArray())));

    /// <summary>Takes a tag from assets, and those under it.</summary>
    public void Remove(IEnumerable<string> guids, string tag) =>
        Edit(guids.Select(g => (g, Of(g).Where(t => !Under(t, tag)).ToArray())));

    /// <summary>Renames a tag and those under it on every asset, which can move it under another.</summary>
    public void Rename(string from, string to) =>
        Edit(_tags.Keys.ToList().Where(g => Has(g, from)).Select(g => (g, Of(g).Select(t => Under(t, from) ? to + t[from.Length..] : t).Distinct().ToArray())));

    /// <summary>Gives a new asset the tags of another, as a duplicate has.</summary>
    public void Copy(string from, string to)
    {
        if (Of(from) is { Count: > 0 } tags)
        {
            Edit([(to, [.. tags])]);
        }
    }

    static bool Under(string tag, string above) => tag == above || tag.StartsWith(above + "/", StringComparison.Ordinal);

    void Edit(IEnumerable<(string Guid, string[] Tags)> edits)
    {
        // What another program wrote first stays.
        Reload();
        var changed = false;
        foreach (var (guid, tags) in edits.ToList())
        {
            if (tags.SequenceEqual(Of(guid)))
            {
                continue;
            }
            changed = true;
            var at = _lines.FindIndex(l => Parse(l)?.Guid == guid);
            if (tags.Length == 0)
            {
                _lines.RemoveAt(at);
                _tags.Remove(guid);
                continue;
            }
            var line = $"{guid} = {string.Join(", ", tags)}";
            if (at >= 0)
            {
                _lines[at] = line;
            }
            else
            {
                var after = _lines.FindIndex(l => Parse(l) is { } entry && string.CompareOrdinal(entry.Guid, guid) > 0);
                _lines.Insert(after < 0 ? _lines.Count : after, line);
            }
            _tags[guid] = tags;
        }
        if (!changed)
        {
            return;
        }
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(FilePath))!);
        var temporary = FilePath + ".tmp";
        File.WriteAllText(temporary, string.Join("\n", _lines) + "\n");
        File.Move(temporary, FilePath, overwrite: true);
        var info = new FileInfo(FilePath);
        _stamp = info.LastWriteTimeUtc;
        _size = info.Length;
        Changed?.Invoke();
    }

    static (string Guid, string[] Tags)? Parse(string line)
    {
        var trimmed = line.Trim();
        var equals = trimmed.IndexOf('=');
        if (trimmed.Length == 0 || trimmed[0] == '#' || equals <= 0)
        {
            return null;
        }
        var tags = trimmed[(equals + 1)..].Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(Normalize).OfType<string>().Distinct().ToArray();
        return (trimmed[..equals].Trim(), tags);
    }
}
