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

/// <summary>
/// What the content browser shows (see docs/editor/shell-and-panels.md#content-browser): the open folder, the search, the
/// selection and what is expanded. Docking can rebuild the panel's view at any time, and the commands act on the folder
/// and the selection whether the panel shows or not, so all of it is here. Use it on one thread.
/// </summary>
public sealed class ContentBrowserModel
{
    readonly AssetIndex _index;
    // Roots start expanded, and other folders collapsed. The set holds the expanded ones, as "root/path".
    readonly HashSet<string> _expandedFolders = [];
    readonly HashSet<string> _seenRoots = [];
    // The files whose sub-assets show under them, by GUID.
    readonly HashSet<string> _expandedFiles = [];
    List<string> _selection = [];
    List<Asset>? _items;
    string _search = "";

    public ContentBrowserModel(AssetIndex index)
    {
        _index = index;
        _index.Changed += OnIndexChanged;
        OnIndexChanged();
    }

    /// <summary>The open folder, where new assets go.</summary>
    public ContentFolder? Folder { get; private set; }

    /// <summary>The selected assets, by GUID, the one that was selected first first.</summary>
    public IReadOnlyList<string> Selection => _selection;

    /// <summary>What to search for, or <c>""</c> to show the open folder.</summary>
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

    /// <summary>What the view shows changed: the folders, the assets or the search. A cook raises it for each of its messages.</summary>
    public event Action? Changed;

    /// <summary>The open folder or the selection, which the commands act on, changed.</summary>
    public event Action? ContextChanged;

    /// <summary>An asset was revealed: it is selected in its folder, for the view to scroll to.</summary>
    public event Action<Asset>? Revealed;

    /// <summary>
    /// The assets to show: every asset that the search matches, or the open folder's, each expanded file with its
    /// sub-assets under it. The selection keeps only the assets that are among them.
    /// </summary>
    public IReadOnlyList<Asset> Items
    {
        get
        {
            if (_items == null)
            {
                _items = BuildItems();
                KeepSelected(g => _items.Any(a => a.Guid == g));
            }
            return _items;
        }
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

    public bool IsFileExpanded(string guid) => _expandedFiles.Contains(guid);

    /// <summary>Shows or hides a file's sub-assets.</summary>
    public void ToggleFile(string guid)
    {
        if (!_expandedFiles.Remove(guid))
        {
            _expandedFiles.Add(guid);
        }
        ItemsMoved();
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

    /// <summary>Opens a folder, and ends the search.</summary>
    public void Open(ContentFolder folder)
    {
        if (Folder == folder && _search == "")
        {
            return;
        }
        Folder = folder;
        _search = "";
        ItemsMoved();
        ContextChanged?.Invoke();
    }

    /// <summary>Selects assets, by GUID. Those that stay selected keep their order, so the first one's details stay.</summary>
    public void Select(IEnumerable<string> guids)
    {
        var selected = guids.ToList();
        Set([.. _selection.Where(selected.Contains), .. selected.Where(g => !_selection.Contains(g))]);
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
        // A sub-asset shows under its file.
        if (AssetIndex.IsSubasset(asset))
        {
            _expandedFiles.Add(asset.Parent);
        }
        Folder = new ContentFolder(asset.Root, folder);
        _search = "";
        _selection = [asset.Guid];
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
        // The open folder can go, with its root or by a delete or a move.
        var context = false;
        if (Folder is not { } folder || _index.FindRoot(folder.Root) == null || (folder.Path != "" && !_index.Folders.Contains(new(folder.Root, folder.Path))))
        {
            var fallback = _index.Roots.Count > 0 ? new ContentFolder(_index.Roots[0].Name, "") : null;
            context = Folder != fallback;
            Folder = fallback;
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

    List<Asset> BuildItems()
    {
        if (Searching)
        {
            return [.. _index.Search(Search.Trim())];
        }
        if (Folder is not { } folder)
        {
            return [];
        }
        List<Asset> assets = [];
        foreach (var asset in _index.AssetsIn(folder.Root, folder.Path))
        {
            assets.Add(asset);
            if (_expandedFiles.Contains(asset.Guid))
            {
                assets.AddRange(_index.SubassetsOf(asset.Guid));
            }
        }
        return assets;
    }

    void ItemsMoved()
    {
        _items = null;
        Changed?.Invoke();
    }

    void KeepSelected(Func<string, bool> keep)
    {
        var kept = _selection.Where(keep).ToList();
        if (kept.Count != _selection.Count)
        {
            _selection = kept;
            ContextChanged?.Invoke();
        }
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
