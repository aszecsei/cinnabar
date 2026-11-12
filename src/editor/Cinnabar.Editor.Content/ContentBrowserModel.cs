using Cinnabar.Editor.Link.Cook;

namespace Cinnabar.Editor.Content;

/// <summary>A folder of a content root, by the root's name and its path in the root, <c>""</c> for the root itself.</summary>
public sealed record ContentFolder(string Root, string Path)
{
    public string Name => Path == "" ? Root : AssetIndex.Name(Path);

    /// <summary>The folder as the root's name and its path, for a message.</summary>
    public string Display => Path == "" ? Root : $"{Root}/{Path}";

    /// <summary>The folder under this one with a name, trimmed.</summary>
    public ContentFolder Child(string name) => new(Root, Path == "" ? name.Trim() : $"{Path}/{name.Trim()}");

    /// <summary>The folder's directory on disk, or null when the index has no such root.</summary>
    public string? Directory(AssetIndex assets) =>
        assets.FindRoot(Root) is { } root ? System.IO.Path.Combine(root.Dir, Path) : null;
}

/// <summary>
/// Where the content browser is, as one value: a folder; a file of it, whose sub-assets show; or a prefab, a file of the
/// folder or a sub-asset of a file, whose entity's children show, with 0 for its root. The folder of a file or a prefab is
/// where it is, so it follows it when it moves.
/// </summary>
public abstract record ContentLocation(ContentFolder Folder)
{
    public sealed record InFolder(ContentFolder Folder) : ContentLocation(Folder);

    public sealed record InFile(ContentFolder Folder, string File) : ContentLocation(Folder);

    public sealed record InPrefab(ContentFolder Folder, string? File, string Prefab, ulong Node) : ContentLocation(Folder);

    /// <summary>The folder that an asset is in, or that a sub-asset's file is in.</summary>
    public static ContentFolder FolderOf(Asset asset) => new(asset.Root, AssetIndex.Parent(asset.Path));

    /// <summary>Inside an asset: a file's sub-assets, or a prefab's root, or null for a sub-asset that is not a prefab.</summary>
    public static ContentLocation? Into(Asset asset) => asset.Kind == AssetKind.Prefab
        ? new InPrefab(FolderOf(asset), AssetIndex.IsSubasset(asset) ? asset.Parent : null, asset.Guid, 0)
        : AssetIndex.IsSubasset(asset) ? null
        : new InFile(FolderOf(asset), asset.Guid);

    /// <summary>Where an asset shows: a sub-asset in its file, and a file in its folder.</summary>
    public static ContentLocation Around(Asset asset) =>
        AssetIndex.IsSubasset(asset) ? new InFile(FolderOf(asset), asset.Parent) : new InFolder(FolderOf(asset));
}

/// <summary>An asset, by its GUID, or a folder, which an operation such as Rename or Delete acts on.</summary>
public sealed record ContentItem(string? Guid, ContentFolder? Folder)
{
    public static ContentItem Of(Asset asset) => new(asset.Guid, null);

    public static ContentItem Of(ContentFolder folder) => new(null, folder);
}

/// <summary>A row of the content browser's folder list.</summary>
public sealed record FolderRow(string Root, string Path, string Name, int Depth, bool HasChildren, bool Expanded);

/// <summary>How the content browser shows its assets.</summary>
public enum ContentViewMode
{
    Grid,
    List,
}

/// <summary>What the content browser's filter offers: the asset kinds that a person looks for together.</summary>
public enum ContentKind
{
    Scenes,
    Prefabs,
    Models,
    Meshes,
    Materials,
    Textures,
    Audio,
    Effects,
    Animation,
    Interface,
    Scripts,
    Shaders,
}

/// <summary>A row of the content browser's tags: a tag, how many assets have it or a tag under it, and whether it filters.</summary>
public sealed record TagRow(string Tag, string Name, int Depth, int Count, bool HasChildren, bool Expanded, bool Filtering);

/// <summary>A part of the path that the content browser shows over its assets: a folder, a file or prefab that is open, or an entity of the prefab.</summary>
public sealed record ContentCrumb(string Name, ContentFolder? Folder, string? File, ulong? Node = null);

/// <summary>An entity of a prefab, which a tile shows and a drag takes as a part of the prefab.</summary>
public sealed record PrefabPart(string Prefab, ulong Id, string Name, int ChildCount, bool HasMesh);

/// <summary>What the content browser shows of a prefab's entity: the entities under it, the assets that it uses, and the entities above it, from the prefab's root's child.</summary>
public sealed record PrefabContents(IReadOnlyList<PrefabPart> Children, IReadOnlyList<string> Assets, IReadOnlyList<(ulong Id, string Name)> Trail);

/// <summary>What a tile of the content browser shows, by a key that the selection holds: an asset, by its GUID, or a part of a prefab.</summary>
public sealed record ContentTile(string Key, Asset? Asset, PrefabPart? Part)
{
    public static ContentTile Of(Asset asset) => new(asset.Guid, asset, null);

    public static ContentTile Of(PrefabPart part) => new(ContentBrowserModel.PartKey(part.Prefab, part.Id), null, part);

    public string Name => Part?.Name ?? (Asset is { } asset ? AssetIndex.DisplayName(asset) : "");
}

/// <summary>
/// What the content browser shows (see docs/editor/shell-and-panels.md#content-browser): the open folder or file, the
/// filter, the selection and how it shows them. Docking can rebuild the panel's view at any time, and the commands act on
/// the folder and the selection whether the panel shows or not, so all of it is here. Use it on one thread.
/// </summary>
public sealed class ContentBrowserModel
{
    public const double MinTileSize = 64;
    public const double MaxTileSize = 256;
    public const double DefaultTileSize = 72;

    readonly AssetIndex _index;
    // Roots start expanded, and other folders collapsed. The set holds the expanded ones, as "root/path".
    readonly HashSet<string> _expandedFolders = [];
    readonly HashSet<string> _seenRoots = [];
    readonly HashSet<ContentKind> _kinds = [];
    readonly HashSet<string> _filterTags = new(StringComparer.Ordinal);
    // Tags start expanded. The set holds the ones that the user collapsed.
    readonly HashSet<string> _collapsedTags = [];
    readonly ProjectTags _tags;
    List<string> _selection = [];
    List<ContentTile>? _tiles;
    string _search = "";
    string? _anchor;
    string? _cursor;
    ContentViewMode _viewMode = ContentViewMode.Grid;
    double _tileSize = DefaultTileSize;
    bool _inThisFolder;
    bool _showingTags;

    public ContentBrowserModel(AssetIndex index, ProjectTags tags)
    {
        _index = index;
        _tags = tags;
        _tags.Changed += OnTagsChanged;
        _tags.Reload();
        _index.Changed += OnIndexChanged;
        OnIndexChanged();
    }

    /// <summary>Whether the left of the panel shows the tags, and not the folders.</summary>
    public bool ShowingTags
    {
        get => _showingTags;
        set
        {
            if (_showingTags != value)
            {
                _showingTags = value;
                Changed?.Invoke();
            }
        }
    }

    /// <summary>The tags that an asset must have, each or one under it, for it to show.</summary>
    public IReadOnlyCollection<string> FilterTags => _filterTags;

    /// <summary>Shows or hides a tag's assets in the filter.</summary>
    public void ToggleTag(string tag)
    {
        if (!_filterTags.Remove(tag))
        {
            _filterTags.Add(tag);
        }
        ItemsMoved();
    }

    /// <summary>Whether an asset has a tag or one under it, or its file has: what is true of a file is true of what it makes.</summary>
    public bool HasTag(Asset asset, string tag) => _tags.Has(asset.Guid, tag) || (asset.Parent != "" && _tags.Has(asset.Parent, tag));

    /// <summary>Shows or hides the tags under a tag.</summary>
    public void ToggleTagExpanded(string tag)
    {
        if (!_collapsedTags.Remove(tag))
        {
            _collapsedTags.Add(tag);
        }
        Changed?.Invoke();
    }

    /// <summary>The rows of the tag list: each tag, under the tag above it, and not under one that is collapsed.</summary>
    public IReadOnlyList<TagRow> TagRows()
    {
        var all = _tags.All();
        // How many assets have each tag, counting a file's tags once for the file.
        var rows = new List<TagRow>();
        foreach (var tag in all)
        {
            var parts = tag.Split('/');
            var hidden = false;
            for (var i = 1; i < parts.Length && !hidden; i++)
            {
                hidden = _collapsedTags.Contains(string.Join('/', parts[..i]));
            }
            if (hidden)
            {
                continue;
            }
            var count = _tags.Assets.Count(g => _tags.Has(g, tag));
            rows.Add(new TagRow(tag, parts[^1], parts.Length - 1, count, all.Any(t => t.StartsWith(tag + "/", StringComparison.Ordinal)), !_collapsedTags.Contains(tag), _filterTags.Contains(tag)));
        }
        return rows;
    }

    /// <summary>Where the browser is: a folder, a file in it, or a prefab's entity, or null without a root. <see cref="Place"/> sets it.</summary>
    public ContentLocation? Location { get; private set; }

    /// <summary>The open folder, where new assets go: the location's, which follows its file when the file moves.</summary>
    public ContentFolder? Folder => Location?.Folder;

    /// <summary>The file whose sub-assets show in place of its folder's assets, by GUID, or null.</summary>
    public string? OpenFile => Location switch
    {
        ContentLocation.InFile f => f.File,
        ContentLocation.InPrefab p => p.File,
        _ => null,
    };

    /// <summary>The prefab whose entities show, by GUID, or null: a sub-asset of the open file, or a file of the open folder.</summary>
    public string? OpenPrefab => (Location as ContentLocation.InPrefab)?.Prefab;

    /// <summary>The entity of the open prefab whose children show, or 0 for its root.</summary>
    public ulong OpenNode => (Location as ContentLocation.InPrefab)?.Node ?? 0;

    /// <summary>Finds what a prefab's entity shows, with 0 for its root, or null for a prefab with no tree. The shell gives it.</summary>
    public Func<string, ulong, PrefabContents?>? PrefabViews { get; set; }

    /// <summary>A part's key in the selection and a drag.</summary>
    public static string PartKey(string prefab, ulong id) => $"{prefab}:{id:x16}";

    /// <summary>Reads a part's key, and returns null for an asset's.</summary>
    public static (string Prefab, ulong Id)? ParsePartKey(string key)
    {
        var colon = key.IndexOf(':');
        return colon > 0 && ulong.TryParse(key.AsSpan(colon + 1), System.Globalization.NumberStyles.HexNumber, null, out var id)
            ? (key[..colon], id) : null;
    }

    /// <summary>The selected assets, by GUID, without the selected parts, as the asset commands take.</summary>
    public IReadOnlyList<string> SelectedAssets => [.. _selection.Where(k => !k.Contains(':'))];

    /// <summary>The selected assets, by GUID, the one that was selected first first.</summary>
    public IReadOnlyList<string> Selection => _selection;

    /// <summary>What to search for, or <c>""</c>.</summary>
    public string Search
    {
        get => _search;
        set
        {
            if (_search != value)
            {
                _search = value;
                ItemsMoved();
            }
        }
    }

    public bool Searching => Search.Trim().Length > 0;

    /// <summary>The kinds that show. None means every kind.</summary>
    public IReadOnlyCollection<ContentKind> Kinds => _kinds;

    /// <summary>A search, a kind or a tag narrows what shows, so it comes from every folder, or those under the open one.</summary>
    public bool Filtering => Searching || _kinds.Count > 0 || _filterTags.Count > 0;

    /// <summary>Whether a filter looks only in the open folder and those under it.</summary>
    public bool InThisFolder
    {
        get => _inThisFolder;
        set
        {
            if (_inThisFolder != value)
            {
                _inThisFolder = value;
                ItemsMoved();
            }
        }
    }

    public ContentViewMode ViewMode
    {
        get => _viewMode;
        set
        {
            if (_viewMode != value)
            {
                _viewMode = value;
                ViewSettingsChanged?.Invoke();
                Changed?.Invoke();
            }
        }
    }

    /// <summary>The side of a tile's picture, in the grid.</summary>
    public double TileSize
    {
        get => _tileSize;
        set
        {
            var size = Math.Clamp(value, MinTileSize, MaxTileSize);
            if (_tileSize != size)
            {
                _tileSize = size;
                ViewSettingsChanged?.Invoke();
                Changed?.Invoke();
            }
        }
    }

    /// <summary>What the view shows changed: the folders, the assets or the filter. A cook raises it for each of its messages.</summary>
    public event Action? Changed;

    /// <summary>The open folder or the selection, which the commands act on, changed.</summary>
    public event Action? ContextChanged;

    /// <summary>An asset was revealed: it is selected in its folder, for the view to scroll to.</summary>
    public event Action<Asset>? Revealed;

    /// <summary>The view mode or the tile size changed, which each user keeps.</summary>
    public event Action? ViewSettingsChanged;

    /// <summary>
    /// What to show: the entities and assets of the open prefab, the assets of the open file or the open folder, or every
    /// asset that the filter matches, the open file's only when one is open. The selection keeps only what is among them.
    /// </summary>
    public IReadOnlyList<ContentTile> Tiles
    {
        get
        {
            if (_tiles == null)
            {
                _tiles = BuildTiles();
                var shown = _tiles.Select(t => t.Key).ToHashSet();
                var kept = _selection.Where(shown.Contains).ToList();
                if (kept.Count != _selection.Count)
                {
                    _selection = kept;
                    ContextChanged?.Invoke();
                }
            }
            return _tiles;
        }
    }

    /// <summary>The assets among <see cref="Tiles"/>.</summary>
    public IReadOnlyList<Asset> Items => [.. Tiles.Select(t => t.Asset).OfType<Asset>()];

    /// <summary>How many assets of each kind the filter's other parts leave, for the kinds that it offers.</summary>
    public IReadOnlyList<(ContentKind Kind, int Count)> KindCounts() =>
        [.. Scope().Where(a => MatchesSearchAndTags(a)).GroupBy(a => KindOf(a.Kind)).OrderBy(g => g.Key).Select(g => (g.Key, g.Count()))];

    /// <summary>The path over the assets: the root, each folder, and the open file.</summary>
    public IReadOnlyList<ContentCrumb> Crumbs()
    {
        if (Location?.Folder is not { } folder)
        {
            return [];
        }
        List<ContentCrumb> crumbs = [new ContentCrumb(folder.Root, new ContentFolder(folder.Root, ""), null)];
        var path = "";
        foreach (var part in folder.Path.Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            path = path == "" ? part : $"{path}/{part}";
            crumbs.Add(new ContentCrumb(part, new ContentFolder(folder.Root, path), null));
        }
        if (OpenFile != null && _index.Find(OpenFile) is { } file)
        {
            crumbs.Add(new ContentCrumb(AssetIndex.Name(file.Path), null, file.Guid));
        }
        if (OpenPrefab != null && _index.Find(OpenPrefab) is { } prefab)
        {
            crumbs.Add(new ContentCrumb(AssetIndex.Name(AssetIndex.DisplayName(prefab)), null, null, 0));
            if (PrefabViews?.Invoke(OpenPrefab, OpenNode) is { } view)
            {
                crumbs.AddRange(view.Trail.Select(t => new ContentCrumb(t.Name, null, null, t.Id)));
            }
        }
        return crumbs;
    }

    /// <summary>The kind that the filter offers an asset under.</summary>
    public static ContentKind KindOf(AssetKind kind) => kind switch
    {
        AssetKind.Scene or AssetKind.NavMesh => ContentKind.Scenes,
        AssetKind.Prefab => ContentKind.Prefabs,
        AssetKind.Model or AssetKind.Stage => ContentKind.Models,
        AssetKind.Mesh or AssetKind.InstanceSet => ContentKind.Meshes,
        AssetKind.Material or AssetKind.MaterialInstance or AssetKind.MaterialFunction => ContentKind.Materials,
        AssetKind.Texture or AssetKind.SpriteSheet => ContentKind.Textures,
        AssetKind.Audio => ContentKind.Audio,
        AssetKind.Effect => ContentKind.Effects,
        AssetKind.Font or AssetKind.Ui => ContentKind.Interface,
        AssetKind.Animation or AssetKind.AnimationGraph or AssetKind.Skin => ContentKind.Animation,
        AssetKind.Shader or AssetKind.ShadingModel => ContentKind.Shaders,
        _ => ContentKind.Scripts,
    };

    /// <summary>Shows or hides a kind in the filter.</summary>
    public void ToggleKind(ContentKind kind)
    {
        if (!_kinds.Remove(kind))
        {
            _kinds.Add(kind);
        }
        ItemsMoved();
    }

    /// <summary>Ends the filter: no search, every kind and no tag.</summary>
    public void ClearFilter()
    {
        _kinds.Clear();
        _filterTags.Clear();
        _search = "";
        ItemsMoved();
    }

    /// <summary>The rows of the folder list: each root, and the folders under the expanded ones.</summary>
    public IReadOnlyList<FolderRow> FolderRows()
    {
        var rows = new List<FolderRow>();
        void Add(string root, string path, string name, int depth)
        {
            var children = _index.ChildFolders(root, path).ToList();
            var expanded = _expandedFolders.Contains($"{root}/{path}");
            rows.Add(new FolderRow(root, path, name, depth, children.Count > 0, expanded));
            if (expanded)
            {
                foreach (var child in children)
                {
                    Add(root, path == "" ? child : $"{path}/{child}", child, depth + 1);
                }
            }
        }
        foreach (var root in _index.Roots)
        {
            Add(root.Name, "", root.Name, 0);
        }
        return rows;
    }

    /// <summary>Shows or hides the folders under a folder.</summary>
    public void ToggleFolder(string root, string path)
    {
        var key = $"{root}/{path}";
        if (!_expandedFolders.Remove(key))
        {
            _expandedFolders.Add(key);
        }
        Changed?.Invoke();
    }

    /// <summary>Opens a folder, and ends the search and any open file or prefab.</summary>
    public void Open(ContentFolder folder)
    {
        var to = new ContentLocation.InFolder(folder);
        if (Location == to && _search == "")
        {
            return;
        }
        GoTo(to, clearFilter: false);
    }

    /// <summary>
    /// Goes to a location, and ends the search, and with clearFilter the kinds and tags too. Every move that a person or a
    /// reveal makes comes here.
    /// </summary>
    void GoTo(ContentLocation? to, bool clearFilter)
    {
        Place(to);
        _search = "";
        if (clearFilter)
        {
            _kinds.Clear();
            _filterTags.Clear();
        }
        ItemsMoved();
        ContextChanged?.Invoke();
    }

    // The one writer of Location.
    void Place(ContentLocation? to) => Location = to;

    /// <summary>
    /// Shows what a file makes in place of its folder's assets, or a prefab's entities, whether it is a file or a sub-asset
    /// of one, and ends the search.
    /// </summary>
    public void Enter(string guid)
    {
        if (_index.Find(guid) is not { } asset)
        {
            return;
        }
        if (ContentLocation.Into(asset) is { } to)
        {
            GoTo(to, clearFilter: false);
        }
    }

    /// <summary>Shows what is under an entity of the open prefab, with 0 for its root.</summary>
    public void EnterNode(ulong id)
    {
        if (Location is ContentLocation.InPrefab prefab)
        {
            GoTo(prefab with { Node = id }, clearFilter: false);
        }
    }

    /// <summary>
    /// Goes back a level: from a prefab's entity to the one above it, from its root to the file that makes it or its folder,
    /// and from a file to its folder, with what it left selected. Leaving a file or a prefab ends the filter, which was its.
    /// </summary>
    public void Leave()
    {
        switch (Location)
        {
        case ContentLocation.InPrefab { Node: not 0 } at:
            var trail = PrefabViews?.Invoke(at.Prefab, at.Node)?.Trail ?? [];
            _selection = [PartKey(at.Prefab, at.Node)];
            _anchor = _cursor = _selection[0];
            GoTo(at with { Node = trail.Count >= 2 ? trail[^2].Id : 0 }, clearFilter: false);
            break;
        case ContentLocation.InPrefab at:
            _selection = [at.Prefab];
            _anchor = _cursor = at.Prefab;
            GoTo(at.File is { } file ? new ContentLocation.InFile(at.Folder, file) : new ContentLocation.InFolder(at.Folder), clearFilter: true);
            break;
        case ContentLocation.InFile at:
            _selection = [at.File];
            _anchor = _cursor = at.File;
            GoTo(new ContentLocation.InFolder(at.Folder), clearFilter: true);
            break;
        }
    }

    /// <summary>Selects assets, by GUID. Those that stay selected keep their order, so the first one's details stay.</summary>
    public void Select(IEnumerable<string> guids)
    {
        var selected = guids.ToList();
        Set([.. _selection.Where(selected.Contains), .. selected.Where(g => !_selection.Contains(g))]);
    }

    /// <summary>A click on an asset: it alone, or with Ctrl in or out of the selection, or with Shift the assets from the anchor to it.</summary>
    public void Press(string guid, bool add, bool range)
    {
        if (range && _anchor != null && Span(_anchor, guid) is { } span)
        {
            Select(add ? _selection.Union(span) : span);
        }
        else
        {
            if (add)
            {
                Select(_selection.Contains(guid) ? _selection.Where(g => g != guid) : _selection.Append(guid));
            }
            else
            {
                Select([guid]);
            }
            _anchor = guid;
        }
        _cursor = guid;
    }

    /// <summary>
    /// Moves the selection by assets, as the arrow keys do, stopping at the ends, or with Shift grows it from the anchor.
    /// It gives the asset that the cursor moved to.
    /// </summary>
    public ContentTile? Move(int by, bool range)
    {
        var items = Tiles;
        if (items.Count == 0)
        {
            return null;
        }
        var at = _cursor == null ? -1 : IndexOf(items, _cursor);
        var next = at < 0 ? (by < 0 ? items.Count - 1 : 0) : Math.Clamp(at + by, 0, items.Count - 1);
        Press(items[next].Key, false, range);
        return items[next];
    }

    public void SelectAll()
    {
        Select(Tiles.Select(t => t.Key));
        _anchor = Tiles.Count > 0 ? Tiles[0].Key : null;
    }

    /// <summary>Shows an asset selected in its folder, or opens a folder, showing where it is, and ends the search.</summary>
    public void Reveal(ContentItem item)
    {
        if (item.Guid is { } guid && _index.Find(guid) is { } asset)
        {
            Reveal(asset);
        }
        else if (item.Folder is { } folder)
        {
            for (var path = AssetIndex.Parent(folder.Path); path != ""; path = AssetIndex.Parent(path))
            {
                _expandedFolders.Add($"{folder.Root}/{path}");
            }
            _expandedFolders.Add(folder.Root + "/");
            GoTo(new ContentLocation.InFolder(folder), clearFilter: false);
        }
    }

    void Reveal(Asset asset)
    {
        var folder = AssetIndex.Parent(asset.Path);
        for (var path = folder; path != ""; path = AssetIndex.Parent(path))
        {
            _expandedFolders.Add($"{asset.Root}/{path}");
        }
        // A sub-asset shows in its file. What is revealed shows, whatever the filter hid.
        _selection = [asset.Guid];
        _anchor = _cursor = asset.Guid;
        GoTo(ContentLocation.Around(asset), clearFilter: true);
        Revealed?.Invoke(asset);
    }

    /// <summary>The selection as it is given, whether or not it shows, with the folder.</summary>
    public void SetContext(ContentFolder? folder, IReadOnlyList<string> selected)
    {
        if (Folder != folder)
        {
            Place(folder is { } f ? new ContentLocation.InFolder(f) : null);
            _tiles = null;
            Changed?.Invoke();
        }
        _ = Tiles;
        _selection = [.. selected];
        ContextChanged?.Invoke();
    }

    void OnIndexChanged()
    {
        foreach (var root in _index.Roots.Where(r => _seenRoots.Add(r.Name)))
        {
            _expandedFolders.Add(root.Name + "/");
        }
        // The open file and prefab can move, and the location follows them; they can go, with their folder, and so can the
        // open folder, with its root or by a delete or a move.
        var followed = Follow(Location);
        var context = followed != Location;
        Place(followed);
        var existing = _selection.Where(k => k.Contains(':') || _index.Find(k) != null).ToList();
        if (existing.Count != _selection.Count)
        {
            _selection = existing;
            context = true;
        }
        _tiles = null;
        Changed?.Invoke();
        if (context)
        {
            ContextChanged?.Invoke();
        }
    }

    // Where a location is once the index changed: an open file or prefab where it is now, so its folder follows it; what
    // is left when it went; and the first root's top when the folder went too.
    ContentLocation? Follow(ContentLocation? at)
    {
        switch (at)
        {
        case ContentLocation.InPrefab p:
            if (_index.Find(p.Prefab) is { } prefab && ContentLocation.Into(prefab) is ContentLocation.InPrefab moved)
            {
                return moved with { Node = p.Node };
            }
            return Follow(p.File is { } file ? new ContentLocation.InFile(p.Folder, file) : new ContentLocation.InFolder(p.Folder));
        case ContentLocation.InFile f:
            return _index.Find(f.File) is { } asset && ContentLocation.Into(asset) is { } into ? into : Follow(new ContentLocation.InFolder(f.Folder));
        case ContentLocation.InFolder { Folder: var folder } when _index.FindRoot(folder.Root) != null && (folder.Path == "" || _index.Folders.Contains(new(folder.Root, folder.Path))):
            return at;
        default:
            return _index.Roots.Count > 0 ? new ContentLocation.InFolder(new ContentFolder(_index.Roots[0].Name, "")) : null;
        }
    }

    // What a filter looks through, and what shows without one.
    IEnumerable<Asset> Scope()
    {
        if (OpenPrefab is { } prefab)
        {
            return (PrefabViews?.Invoke(prefab, OpenNode)?.Assets ?? []).Select(_index.Find).OfType<Asset>();
        }
        if (OpenFile is { } file)
        {
            return _index.SubassetsOf(file);
        }
        if (Folder is not { } folder)
        {
            return Filtering && !InThisFolder ? _index.Assets.Values : [];
        }
        return !Filtering ? _index.AssetsIn(folder.Root, folder.Path)
            : InThisFolder ? _index.AssetsUnder(folder.Root, folder.Path)
            : _index.Assets.Values;
    }

    List<ContentTile> BuildTiles()
    {
        if (OpenPrefab is { } prefab)
        {
            if (PrefabViews?.Invoke(prefab, OpenNode) is not { } view)
            {
                return [];
            }
            var query = Search.Trim();
            var parts = _kinds.Count > 0 ? [] : view.Children.Where(p => query.Length == 0 || query.Split(' ', StringSplitOptions.RemoveEmptyEntries).All(w => p.Name.Contains(w, StringComparison.OrdinalIgnoreCase)));
            var assets = view.Assets.Select(_index.Find).OfType<Asset>()
                .Where(a => MatchesSearchAndTags(a) && (_kinds.Count == 0 || _kinds.Contains(KindOf(a.Kind))));
            return [.. parts.Select(ContentTile.Of), .. assets.Select(ContentTile.Of)];
        }
        // A prefab comes first in what a file makes: it is the way into the file's whole hierarchy.
        return [.. (OpenFile != null ? BuildItems().OrderBy(a => a.Kind == AssetKind.Prefab ? 0 : 1) : BuildItems().AsEnumerable()).Select(ContentTile.Of)];
    }

    List<Asset> BuildItems()
    {
        var scope = Scope();
        if (!Filtering)
        {
            return [.. scope];
        }
        var matches = scope.Where(a => MatchesSearchAndTags(a) && (_kinds.Count == 0 || _kinds.Contains(KindOf(a.Kind))));
        return OpenFile != null
            ? [.. matches]
            : [.. matches.OrderBy(a => AssetIndex.Name(a.Path), StringComparer.OrdinalIgnoreCase)
                .ThenBy(a => a.Path, StringComparer.OrdinalIgnoreCase)
                .ThenBy(a => a.Subasset, StringComparer.OrdinalIgnoreCase)];
    }

    bool MatchesSearchAndTags(Asset asset) =>
        (!Searching || AssetIndex.MatchesSearch(asset, Search, HasTag)) && _filterTags.All(t => HasTag(asset, t));

    void OnTagsChanged()
    {
        // A tag that nothing has now can no longer be turned off, so it stops filtering.
        var all = _tags.All();
        _filterTags.RemoveWhere(t => !all.Contains(t));
        ItemsMoved();
    }

    static int IndexOf(IReadOnlyList<ContentTile> items, string guid)
    {
        for (var i = 0; i < items.Count; i++)
        {
            if (items[i].Key == guid)
            {
                return i;
            }
        }
        return -1;
    }

    // The assets from one to another, in the order that they show, or null when one of them does not show.
    List<string>? Span(string from, string to)
    {
        var items = Tiles;
        var a = IndexOf(items, from);
        var b = IndexOf(items, to);
        if (a < 0 || b < 0)
        {
            return null;
        }
        return [.. items.Skip(Math.Min(a, b)).Take(Math.Abs(a - b) + 1).Select(i => i.Key)];
    }

    void ItemsMoved()
    {
        _tiles = null;
        Changed?.Invoke();
    }

    void Set(List<string> selection)
    {
        if (!selection.SequenceEqual(_selection))
        {
            _selection = selection;
            ContextChanged?.Invoke();
        }
    }
}

/// <summary>
/// Where the content browser's assets are: rows of equal height, each a fixed number of tiles, so a tile's place follows
/// from its index, whatever is realized. A list is one column of short rows.
/// </summary>
public readonly record struct ContentGridLayout(int Columns, double TileWidth, double RowHeight)
{
    public const double Gap = 6;
    public const double LabelHeight = 34;
    public const double ListRowHeight = 22;

    public static ContentGridLayout Of(double width, ContentViewMode mode, double tileSize)
    {
        if (mode == ContentViewMode.List)
        {
            return new ContentGridLayout(1, Math.Max(width, 0), ListRowHeight);
        }
        var tile = tileSize + 2 * Gap;
        return new ContentGridLayout(Math.Max((int)Math.Floor((width + Gap) / (tile + Gap)), 1), tile, tileSize + LabelHeight + 2 * Gap);
    }

    public int RowCount(int items) => (items + Columns - 1) / Columns;

    public int RowOf(int index) => index / Columns;

    public double Top(int row) => row * RowHeight;

    /// <summary>The asset under a point in the rows' space, or null over the gaps and past the last.</summary>
    public int? IndexAt(double x, double y, int count)
    {
        if (x < 0 || y < 0)
        {
            return null;
        }
        var column = (int)Math.Floor(x / (TileWidth + Gap));
        if (column >= Columns || x - column * (TileWidth + Gap) > TileWidth)
        {
            return null;
        }
        var index = (int)Math.Floor(y / RowHeight) * Columns + column;
        return index < count ? index : null;
    }

    /// <summary>The assets that a rectangle in the rows' space touches, in order.</summary>
    public IEnumerable<int> InRect(double x0, double y0, double x1, double y1, int count)
    {
        var (left, right) = (Math.Min(x0, x1), Math.Max(x0, x1));
        var (top, bottom) = (Math.Min(y0, y1), Math.Max(y0, y1));
        var firstRow = Math.Max((int)Math.Floor(top / RowHeight), 0);
        var lastRow = (int)Math.Floor(bottom / RowHeight);
        for (var row = firstRow; row <= lastRow; row++)
        {
            for (var column = 0; column < Columns; column++)
            {
                var x = column * (TileWidth + Gap);
                var index = row * Columns + column;
                if (index < count && x < right && x + TileWidth > left)
                {
                    yield return index;
                }
            }
        }
    }
}
