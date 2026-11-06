using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Cook;

namespace Cinnabar.Editor.Content;

/// <summary>
/// The editor's mirror of the cook daemon's index (see docs/editor/shell-and-panels.md#content-browser): the roots, their folders and
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
    readonly List<NodeInfo> _nodes = [];
    readonly List<UiAttributeInfo> _uiAttributes = [];
    readonly List<ShadingModelInfo> _shadingModels = [];
    // The files of each folder and the sub-assets of each file, by name, built when next asked for after a change, since
    // the content browser asks for them for each row and a cook changes the assets many times.
    Dictionary<(string Root, string Folder), List<Asset>>? _filesByFolder;
    Dictionary<string, List<Asset>>? _subassetsByFile;

    public IReadOnlyList<Root> Roots => _roots;

    /// <summary>What the daemon cooks: each kind's extension and import settings.</summary>
    public IReadOnlyList<Importer> Importers => _importers;

    /// <summary>By GUID.</summary>
    public IReadOnlyDictionary<string, Asset> Assets => _assets;

    public IReadOnlyCollection<Folder> Folders => _folders;

    /// <summary>The kinds of node of material graphs, which the daemon's cooker knows (see docs/content/kinds/materials.md#material-graphs).</summary>
    public IReadOnlyList<NodeInfo> Nodes => _nodes;

    /// <summary>The attributes of UI documents, from the daemon's Welcome, which the UI editor's properties show.</summary>
    public IReadOnlyList<UiAttributeInfo> UiAttributes => _uiAttributes;

    /// <summary>The shading models that cook, by name.</summary>
    public IReadOnlyList<ShadingModelInfo> ShadingModels => _shadingModels;

    /// <summary>The cook link is up, so the index is the daemon's latest.</summary>
    public bool Linked { get; private set; }

    /// <summary>The roots, the assets, the folders, the problems or <see cref="Linked"/> changed.</summary>
    public event Action? Changed;

    /// <summary>
    /// An asset's picture is ready, by its GUID. It is not <see cref="Changed"/>, as a screen of tiles makes many of these,
    /// and what shows need not be built again for each.
    /// </summary>
    public event Action<string>? ThumbnailChanged;

    /// <summary>The host wrote an asset's picture at a path, if that is still the asset's.</summary>
    public void MarkThumbnailReady(string guid, string path)
    {
        if (_assets.TryGetValue(guid, out var asset) && asset.Thumbnail == path && !asset.ThumbnailReady)
        {
            _assets[guid] = asset with { ThumbnailReady = true };
            ForgetLists();
            ThumbnailChanged?.Invoke(guid);
        }
    }

    /// <summary>
    /// The asset whose picture a tile of this one shows: its own, or for a file with none, such as a stage or a model, what
    /// it makes: its prefab, or its first mesh. Null when there is none.
    /// </summary>
    public Asset? PictureOf(Asset shown)
    {
        var asset = Find(shown.Guid) ?? shown;
        if (asset.Thumbnail != "")
        {
            return asset;
        }
        if (IsSubasset(asset))
        {
            return null;
        }
        var made = SubassetsOf(asset.Guid).ToList();
        return made.Find(a => a.Kind == AssetKind.Prefab && a.Thumbnail != "") ?? made.Find(a => a.Kind == AssetKind.Mesh && a.Thumbnail != "");
    }

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
                _nodes.Clear();
                _nodes.AddRange(welcome.Nodes);
                _uiAttributes.Clear();
                _uiAttributes.AddRange(welcome.UiAttributes);
                break;
            case ShadingModels models:
                _shadingModels.Clear();
                _shadingModels.AddRange(models.Models);
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
                ForgetLists();
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
                ForgetLists();
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
    public IEnumerable<Asset> AssetsIn(string root, string folder)
    {
        _filesByFolder ??= _assets.Values.Where(a => a.Parent == "")
            .GroupBy(a => (a.Root, Parent(a.Path)))
            .ToDictionary(g => g.Key, g => g.OrderBy(a => Name(a.Path), StringComparer.OrdinalIgnoreCase).ToList());
        return _filesByFolder.GetValueOrDefault((root, folder)) ?? [];
    }

    /// <summary>The sub-assets that a file makes, such as a model's meshes, by name (see docs/content/identity-and-cooking.md#identity).</summary>
    public IEnumerable<Asset> SubassetsOf(string guid)
    {
        _subassetsByFile ??= _assets.Values.Where(a => a.Parent != "")
            .GroupBy(a => a.Parent)
            .ToDictionary(g => g.Key, g => g.OrderBy(a => a.Subasset, StringComparer.OrdinalIgnoreCase).ToList());
        return _subassetsByFile.GetValueOrDefault(guid) ?? [];
    }

    void ForgetLists()
    {
        _filesByFolder = null;
        _subassetsByFile = null;
    }

    /// <summary>Whether an asset is a sub-asset, which changes only with its file.</summary>
    public static bool IsSubasset(Asset asset) => asset.Parent != "";

    /// <summary>What the content browser calls an asset: a file's name, or a sub-asset's name in its file.</summary>
    public static string DisplayName(Asset asset) => IsSubasset(asset) ? asset.Subasset : Name(asset.Path);

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
    public IEnumerable<Asset> Search(string query) =>
        _assets.Values.Where(a => MatchesSearch(a, query))
            .OrderBy(a => Name(a.Path), StringComparer.OrdinalIgnoreCase)
            .ThenBy(a => a.Path, StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Whether an asset has every word of a search (see <see cref="Search"/>). A <c>tag:</c> word asks the given function,
    /// and without one matches nothing.
    /// </summary>
    public static bool MatchesSearch(Asset asset, string query, Func<Asset, string, bool>? tagged = null) =>
        query.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).All(w =>
            w.StartsWith("tag:", StringComparison.OrdinalIgnoreCase) ? tagged?.Invoke(asset, w["tag:".Length..]) ?? false : Matches(asset, w));

    static bool Matches(Asset asset, string word)
    {
        if (word.StartsWith("kind:", StringComparison.OrdinalIgnoreCase))
        {
            return string.Equals(word["kind:".Length..], asset.Kind.ToString(), StringComparison.OrdinalIgnoreCase);
        }
        return DisplayName(asset).Contains(word, StringComparison.OrdinalIgnoreCase)
            || asset.Behaviour.Contains(word, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>The last part of a path in a root, such as <c>door.luau</c> for <c>scripts/door.luau</c>.</summary>
    public static string Name(string path) => path[(path.LastIndexOf('/') + 1)..];

    /// <summary>The folder of a path in a root, or <c>""</c> for the root.</summary>
    public static string Parent(string path) => path.LastIndexOf('/') is var slash and >= 0 ? path[..slash] : "";
}
