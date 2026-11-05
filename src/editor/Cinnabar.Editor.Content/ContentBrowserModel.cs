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
    Scripts,
    Shaders,
}

/// <summary>A row of the content browser's tags: a tag, how many assets have it or a tag under it, and whether it filters.</summary>
public sealed record TagRow(string Tag, string Name, int Depth, int Count, bool HasChildren, bool Expanded, bool Filtering);

/// <summary>A part of the path that the content browser shows over its assets: a folder, or a file that is open.</summary>
public sealed record ContentCrumb(string Name, ContentFolder? Folder, string? File);

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
    List<Asset>? _items;
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

    /// <summary>The open folder, where new assets go.</summary>
    public ContentFolder? Folder { get; private set; }

    /// <summary>The file whose sub-assets show in place of its folder's assets, by GUID, or null.</summary>
    public string? OpenFile { get; private set; }

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
    /// The assets to show: those of the open file or the open folder, or every asset that the filter matches, the open
    /// file's only when one is open. The selection keeps only the assets that are among them.
    /// </summary>
    public IReadOnlyList<Asset> Items
    {
        get
        {
            if (_items == null)
            {
                _items = BuildItems();
                var shown = _items.Select(a => a.Guid).ToHashSet();
                var kept = _selection.Where(shown.Contains).ToList();
                if (kept.Count != _selection.Count)
                {
                    _selection = kept;
                    ContextChanged?.Invoke();
                }
            }
            return _items;
        }
    }

    /// <summary>How many assets of each kind the filter's other parts leave, for the kinds that it offers.</summary>
    public IReadOnlyList<(ContentKind Kind, int Count)> KindCounts() =>
        [.. Scope().Where(a => MatchesSearchAndTags(a)).GroupBy(a => KindOf(a.Kind)).OrderBy(g => g.Key).Select(g => (g.Key, g.Count()))];

    /// <summary>The path over the assets: the root, each folder, and the open file.</summary>
    public IReadOnlyList<ContentCrumb> Crumbs()
    {
        if (Folder is not { } folder)
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
        return crumbs;
    }

    /// <summary>The kind that the filter offers an asset under.</summary>
    public static ContentKind KindOf(AssetKind kind) => kind switch
    {
        AssetKind.Scene => ContentKind.Scenes,
        AssetKind.Prefab => ContentKind.Prefabs,
        AssetKind.Model or AssetKind.Stage => ContentKind.Models,
        AssetKind.Mesh or AssetKind.InstanceSet => ContentKind.Meshes,
        AssetKind.Material or AssetKind.MaterialInstance or AssetKind.MaterialFunction => ContentKind.Materials,
        AssetKind.Texture => ContentKind.Textures,
        AssetKind.Audio => ContentKind.Audio,
        AssetKind.Effect => ContentKind.Effects,
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

    /// <summary>Opens a folder, and ends the search and any open file.</summary>
    public void Open(ContentFolder folder)
    {
        if (Folder == folder && _search == "" && OpenFile == null)
        {
            return;
        }
        Folder = folder;
        OpenFile = null;
        _search = "";
        ItemsMoved();
        ContextChanged?.Invoke();
    }

    /// <summary>Shows a file's sub-assets in place of its folder's assets, and ends the search.</summary>
    public void Enter(string file)
    {
        if (_index.Find(file) is not { } asset || AssetIndex.IsSubasset(asset))
        {
            return;
        }
        Folder = new ContentFolder(asset.Root, AssetIndex.Parent(asset.Path));
        OpenFile = file;
        _search = "";
        ItemsMoved();
        ContextChanged?.Invoke();
    }

    /// <summary>Goes back from an open file to its folder, with the file selected, so the filter ends: it was the file's.</summary>
    public void Leave()
    {
        if (OpenFile is { } file)
        {
            OpenFile = null;
            _kinds.Clear();
            _filterTags.Clear();
            _search = "";
            _selection = [file];
            _anchor = _cursor = file;
            ItemsMoved();
            ContextChanged?.Invoke();
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
    public Asset? Move(int by, bool range)
    {
        var items = Items;
        if (items.Count == 0)
        {
            return null;
        }
        var at = _cursor == null ? -1 : IndexOf(items, _cursor);
        var next = at < 0 ? (by < 0 ? items.Count - 1 : 0) : Math.Clamp(at + by, 0, items.Count - 1);
        Press(items[next].Guid, false, range);
        return items[next];
    }

    public void SelectAll()
    {
        Select(Items.Select(a => a.Guid));
        _anchor = Items.Count > 0 ? Items[0].Guid : null;
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
            Folder = folder;
            OpenFile = null;
            _search = "";
            ItemsMoved();
            ContextChanged?.Invoke();
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
        OpenFile = AssetIndex.IsSubasset(asset) ? asset.Parent : null;
        Folder = new ContentFolder(asset.Root, folder);
        _search = "";
        _kinds.Clear();
        _filterTags.Clear();
        _selection = [asset.Guid];
        _anchor = _cursor = asset.Guid;
        ItemsMoved();
        ContextChanged?.Invoke();
        Revealed?.Invoke(asset);
    }

    /// <summary>The selection as it is given, whether or not it shows, with the folder.</summary>
    public void SetContext(ContentFolder? folder, IReadOnlyList<string> selected)
    {
        if (Folder != folder)
        {
            Folder = folder;
            OpenFile = null;
            _items = null;
            Changed?.Invoke();
        }
        _ = Items;
        _selection = [.. selected];
        ContextChanged?.Invoke();
    }

    void OnIndexChanged()
    {
        foreach (var root in _index.Roots.Where(r => _seenRoots.Add(r.Name)))
        {
            _expandedFolders.Add(root.Name + "/");
        }
        // The open folder can go, with its root or by a delete or a move, and so can the open file.
        var context = false;
        if (Folder is not { } folder || _index.FindRoot(folder.Root) == null || (folder.Path != "" && !_index.Folders.Contains(new(folder.Root, folder.Path))))
        {
            var fallback = _index.Roots.Count > 0 ? new ContentFolder(_index.Roots[0].Name, "") : null;
            context = Folder != fallback;
            Folder = fallback;
            OpenFile = null;
        }
        if (OpenFile != null && _index.Find(OpenFile) == null)
        {
            OpenFile = null;
        }
        var existing = _selection.Where(g => _index.Find(g) != null).ToList();
        if (existing.Count != _selection.Count)
        {
            _selection = existing;
            context = true;
        }
        _items = null;
        Changed?.Invoke();
        if (context)
        {
            ContextChanged?.Invoke();
        }
    }

    // What a filter looks through, and what shows without one.
    IEnumerable<Asset> Scope()
    {
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

    static int IndexOf(IReadOnlyList<Asset> items, string guid)
    {
        for (var i = 0; i < items.Count; i++)
        {
            if (items[i].Guid == guid)
            {
                return i;
            }
        }
        return -1;
    }

    // The assets from one to another, in the order that they show, or null when one of them does not show.
    List<string>? Span(string from, string to)
    {
        var items = Items;
        var a = IndexOf(items, from);
        var b = IndexOf(items, to);
        if (a < 0 || b < 0)
        {
            return null;
        }
        return [.. items.Skip(Math.Min(a, b)).Take(Math.Abs(a - b) + 1).Select(i => i.Guid)];
    }

    void ItemsMoved()
    {
        _items = null;
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
