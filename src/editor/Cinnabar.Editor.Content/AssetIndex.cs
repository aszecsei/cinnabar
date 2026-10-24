using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Cook;

namespace Cinnabar.Editor.Content;

/// <summary>
/// The editor's mirror of the cook daemon's index (see docs/editor.md#content-browser): the roots, their folders and
/// assets, and each asset's problems. It changes only through the daemon's messages, and keeps what it has while the
/// cook link is down. Use it on one thread.
/// </summary>
public sealed class AssetIndex
{
    readonly List<Root> _roots = [];
    readonly List<Importer> _importers = [];
    readonly Dictionary<string, Asset> _assets = [];
    readonly HashSet<Folder> _folders = [];
    readonly Dictionary<string, Problem[]> _problems = [];

    public IReadOnlyList<Root> Roots => _roots;

    /// <summary>What the daemon cooks: each kind's extension and import settings.</summary>
    public IReadOnlyList<Importer> Importers => _importers;

    /// <summary>By GUID.</summary>
    public IReadOnlyDictionary<string, Asset> Assets => _assets;

    public IReadOnlyCollection<Folder> Folders => _folders;

    /// <summary>The cook link is up, so the index is the daemon's latest.</summary>
    public bool Linked { get; private set; }

    /// <summary>The roots, the assets, the folders, the problems or <see cref="Linked"/> changed.</summary>
    public event Action? Changed;

    /// <summary>Applies one of the daemon's messages, and returns false for a message that is not about the index.</summary>
    public bool Apply(ILinkMessage message)
    {
        switch (message)
        {
            case Welcome welcome:
                _roots.Clear();
                _roots.AddRange(welcome.Roots);
                _importers.Clear();
                _importers.AddRange(welcome.Importers);
                break;
            case AssetSnapshot snapshot:
                _assets.Clear();
                _folders.Clear();
                _problems.Clear();
                foreach (var asset in snapshot.Assets)
                {
                    _assets[asset.Guid] = asset;
                }
                _folders.UnionWith(snapshot.Folders);
                Linked = true;
                break;
            case AssetDelta delta:
                foreach (var asset in delta.Changed)
                {
                    _assets[asset.Guid] = asset;
                }
                foreach (var guid in delta.Removed)
                {
                    _assets.Remove(guid);
                    _problems.Remove(guid);
                }
                _folders.ExceptWith(delta.RemovedFolders);
                _folders.UnionWith(delta.AddedFolders);
                break;
            case AssetProblems problems:
                if (problems.Problems.Length == 0)
                {
                    _problems.Remove(problems.Guid);
                }
                else
                {
                    _problems[problems.Guid] = problems.Problems;
                }
                break;
            default:
                return false;
        }
        Changed?.Invoke();
        return true;
    }

    /// <summary>The cook link closed. The index keeps what it has.</summary>
    public void Unlink()
    {
        if (Linked)
        {
            Linked = false;
            Changed?.Invoke();
        }
    }

    public Asset? Find(string guid) => _assets.GetValueOrDefault(guid);

    /// <summary>The import settings that an asset's kind takes.</summary>
    public IReadOnlyList<SettingInfo> SettingsOf(AssetKind kind) => _importers.Find(i => i.Kind == kind)?.Settings ?? [];

    /// <summary>The extension of a kind's sources, such as <c>.luau</c>.</summary>
    public string ExtensionOf(AssetKind kind) => _importers.Find(i => i.Kind == kind)?.Extension ?? "";

    /// <summary>The assets in a folder of a root and the folders under it, as a delete of the folder takes them.</summary>
    public IEnumerable<Asset> AssetsUnder(string root, string folder) =>
        _assets.Values.Where(a => a.Root == root && (folder == "" || a.Path.StartsWith(folder + "/", StringComparison.Ordinal)));

    /// <summary>
    /// The assets outside a set that depend on one in it: what a delete of the set breaks. Each comes once, by path.
    /// </summary>
    public IReadOnlyList<Asset> DependentsOutside(IReadOnlyCollection<string> guids) =>
        [.. _assets.Values.Where(a => !guids.Contains(a.Guid) && a.Dependencies.Any(guids.Contains))
            .OrderBy(a => a.Root, StringComparer.Ordinal).ThenBy(a => a.Path, StringComparer.OrdinalIgnoreCase)];

    /// <summary>The problems of an asset, or with <c>""</c>, those that belong to no asset.</summary>
    public IReadOnlyList<Problem> ProblemsOf(string guid) => _problems.GetValueOrDefault(guid) ?? [];

    public Root? FindRoot(string name) => _roots.Find(r => r.Name == name);

    /// <summary>The asset's source file: its root's directory and its path, with the platform's separators.</summary>
    public string? FullPath(Asset asset) =>
        FindRoot(asset.Root) is { } root ? Path.GetFullPath(Path.Combine(root.Dir, asset.Path)) : null;

    /// <summary>The asset whose source file is at a path, if any.</summary>
    public Asset? FindByPath(string path)
    {
        var full = Path.GetFullPath(path);
        return _assets.Values.FirstOrDefault(a => string.Equals(FullPath(a), full, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>The folders directly in a folder of a root, by name. The root itself is the folder <c>""</c>.</summary>
    public IEnumerable<string> ChildFolders(string root, string folder) =>
        _folders.Where(f => f.Root == root && Parent(f.Path) == folder).Select(f => Name(f.Path)).Order(StringComparer.OrdinalIgnoreCase);

    /// <summary>The assets directly in a folder of a root, by name.</summary>
    public IEnumerable<Asset> AssetsIn(string root, string folder) =>
        _assets.Values.Where(a => a.Root == root && Parent(a.Path) == folder).OrderBy(a => Name(a.Path), StringComparer.OrdinalIgnoreCase);

    /// <summary>The assets that depend on an asset.</summary>
    public IEnumerable<Asset> Dependents(string guid) =>
        _assets.Values.Where(a => a.Dependencies.Contains(guid)).OrderBy(a => a.Path, StringComparer.OrdinalIgnoreCase);

    /// <summary>The scripts that define a behaviour, by class name.</summary>
    public IEnumerable<Asset> Behaviours =>
        _assets.Values.Where(a => a.Kind == AssetKind.Script && a.Behaviour != "").OrderBy(a => a.Behaviour, StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// The assets of every folder that a search matches. Each word must match: <c>kind:script</c> or <c>kind:scene</c>
    /// matches the kind, and any other word a part of the file's name or the behaviour's class, ignoring case.
    /// </summary>
    public IEnumerable<Asset> Search(string query)
    {
        var words = query.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        return _assets.Values.Where(a => words.All(w => Matches(a, w)))
            .OrderBy(a => Name(a.Path), StringComparer.OrdinalIgnoreCase)
            .ThenBy(a => a.Path, StringComparer.OrdinalIgnoreCase);
    }

    static bool Matches(Asset asset, string word)
    {
        if (word.StartsWith("kind:", StringComparison.OrdinalIgnoreCase))
        {
            return string.Equals(word["kind:".Length..], asset.Kind.ToString(), StringComparison.OrdinalIgnoreCase);
        }
        return Name(asset.Path).Contains(word, StringComparison.OrdinalIgnoreCase)
            || asset.Behaviour.Contains(word, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>The last part of a path in a root, such as <c>door.luau</c> for <c>scripts/door.luau</c>.</summary>
    public static string Name(string path) => path[(path.LastIndexOf('/') + 1)..];

    /// <summary>The folder of a path in a root, or <c>""</c> for the root.</summary>
    public static string Parent(string path) => path.LastIndexOf('/') is var slash and >= 0 ? path[..slash] : "";
}
