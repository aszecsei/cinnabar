using Cinnabar.Editor.Link.Cook;

namespace Cinnabar.Editor.Content;

/// <summary>An import setting as the content browser edits it: its value, or null while the assets differ, and whether the draft changed it.</summary>
public sealed record ImportSettingRow(SettingInfo Info, string? Value, bool Changed);

/// <summary>Import settings of one section, as the content browser shows them under its header: Section is "" for the top-level settings.</summary>
public sealed record ImportSettingGroup(string Section, IReadOnlyList<(string Label, ImportSettingRow Row)> Rows);

/// <summary>
/// The import settings that the selected files will have (see docs/editor/shell-and-panels.md#content-browser), until Apply
/// sends them to the daemon, as a change can mean a long cook. It shows the settings that all of the files take, each with
/// the same values, and sends only what changed, so a value that differs among the files stays as each has it.
/// </summary>
public sealed class ImportSettingsDraft(AssetIndex index)
{
    readonly Dictionary<string, string> _changes = [];
    string[] _guids = [];

    /// <summary>The files that it edits, by GUID.</summary>
    public IReadOnlyList<string> Assets => _guids;

    /// <summary>Whether it has changes that are not applied.</summary>
    public bool Dirty => _changes.Count > 0;

    /// <summary>A change was made or dropped.</summary>
    public event Action? Changed;

    /// <summary>The files among a selection: a sub-asset's settings are its file's, which it does not edit by itself.</summary>
    public static string[] Files(AssetIndex index, IEnumerable<string> selection) =>
        [.. selection.Where(g => index.Find(g) is { } a && !AssetIndex.IsSubasset(a))];

    /// <summary>Edits the files among a selection, and drops what it had, unless they are the same files.</summary>
    public void Load(IEnumerable<string> selection)
    {
        var files = Files(index, selection);
        if (!files.SequenceEqual(_guids))
        {
            _guids = files;
            _changes.Clear();
        }
    }

    /// <summary>Whether a selection's files are the ones that it edits, in any order.</summary>
    public bool Holds(IEnumerable<string> selection) =>
        Files(index, selection).Order(StringComparer.Ordinal).SequenceEqual(_guids.Order(StringComparer.Ordinal));

    /// <summary>The settings that all of the files take, in the first file's order.</summary>
    public IReadOnlyList<ImportSettingRow> Rows()
    {
        var assets = _guids.Select(index.Find).OfType<Asset>().ToList();
        if (assets.Count == 0)
        {
            return [];
        }
        var rows = new List<ImportSettingRow>();
        foreach (var info in index.SettingsOf(assets[0].Kind))
        {
            if (!assets.All(a => index.SettingsOf(a.Kind).Any(i => i.Key == info.Key && i.Values.SequenceEqual(info.Values))))
            {
                continue;
            }
            if (_changes.TryGetValue(info.Key, out var changed))
            {
                rows.Add(new ImportSettingRow(info, changed, true));
                continue;
            }
            var values = assets.Select(a => ValueOf(a, info.Key)).Distinct().ToList();
            rows.Add(new ImportSettingRow(info, values.Count == 1 ? values[0] : null, false));
        }
        return rows;
    }

    /// <summary>
    /// Groups settings by the section in their key, as in "mip_map.border": the top-level settings come first, then each
    /// section in the order that it first shows. A label is the key without its section.
    /// </summary>
    public static IReadOnlyList<ImportSettingGroup> Group(IEnumerable<ImportSettingRow> rows)
    {
        var top = new List<(string, ImportSettingRow)>();
        var sections = new List<(string Name, List<(string, ImportSettingRow)> Rows)>();
        foreach (var row in rows)
        {
            var key = row.Info.Key;
            var dot = key.IndexOf('.');
            if (dot < 0)
            {
                top.Add((key, row));
                continue;
            }
            var name = key[..dot];
            var at = sections.FindIndex(s => s.Name == name);
            if (at < 0)
            {
                sections.Add((name, []));
                at = sections.Count - 1;
            }
            sections[at].Rows.Add((key[(dot + 1)..], row));
        }
        var groups = new List<ImportSettingGroup>();
        if (top.Count > 0)
        {
            groups.Add(new ImportSettingGroup("", top));
        }
        groups.AddRange(sections.Select(s => new ImportSettingGroup(s.Name, s.Rows)));
        return groups;
    }

    /// <summary>Sets a value for all of the files. A value that each has already is no change.</summary>
    public void Set(string key, string value)
    {
        var same = _guids.Select(index.Find).OfType<Asset>().All(a => ValueOf(a, key) == value);
        var changed = same ? _changes.Remove(key) : !_changes.TryGetValue(key, out var old) | old != value;
        if (!same)
        {
            _changes[key] = value;
        }
        if (changed)
        {
            Changed?.Invoke();
        }
    }

    /// <summary>Drops the changes.</summary>
    public void Revert()
    {
        if (_changes.Count > 0)
        {
            _changes.Clear();
            Changed?.Invoke();
        }
    }

    /// <summary>What Apply sends: each file that a change touches, with all of its settings as they will be.</summary>
    public AssetSettings[] Request()
    {
        var request = new List<AssetSettings>();
        foreach (var asset in _guids.Select(index.Find).OfType<Asset>())
        {
            var infos = index.SettingsOf(asset.Kind);
            var settings = asset.Settings;
            foreach (var (key, value) in _changes.Where(c => ValueOf(asset, c.Key) != c.Value))
            {
                settings = WithSetting(settings, infos, key, value);
            }
            if (settings != asset.Settings)
            {
                request.Add(new AssetSettings(asset.Guid, settings));
            }
        }
        return [.. request];
    }

    string ValueOf(Asset asset, string key) =>
        asset.Settings.FirstOrDefault(s => s.Key == key)?.Value
        ?? index.SettingsOf(asset.Kind).FirstOrDefault(i => i.Key == key)?.Default
        ?? "";

    /// <summary>
    /// An asset's import settings with one set: in its place, or last if it is new, and left out at its default.
    /// </summary>
    public static Setting[] WithSetting(IReadOnlyList<Setting> settings, IReadOnlyList<SettingInfo> infos, string key, string value)
    {
        var info = infos.FirstOrDefault(s => s.Key == key);
        var result = settings.Where(s => s.Key != key).ToList();
        if (info == null || value != info.Default)
        {
            var at = settings.ToList().FindIndex(s => s.Key == key);
            result.Insert(at < 0 ? result.Count : at, new Setting(key, value));
        }
        return [.. result];
    }
}
