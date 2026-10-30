using Cinnabar.Editor.Content;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Model;
using LogLevel = Cinnabar.Editor.Model.LogLevel;
using ConsoleLog = Cinnabar.Editor.Model.ConsoleLog;
using CookFolder = Cinnabar.Editor.Link.Cook.Folder;

namespace Cinnabar.Editor.Shell;

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

/// <summary>
/// The asset operations (see docs/editor/shell-and-panels.md#content-browser): each asks the cook daemon, which is the only program
/// that writes .meta files, and awaits its answer. They change the project, not the scene, so they are not on the undo
/// stack. The commands act on the content browser's folder and selection.
/// </summary>
public sealed class ContentBrowser(
    AssetIndex assets,
    CookSession cook,
    ConsoleLog console,
    Func<Func<Task<OperationResult?>>, Task<bool>> movingScene,
    Action changed)
{
    /// <summary>The content browser's folder, where new assets go.</summary>
    public ContentFolder? Folder { get; private set; }

    /// <summary>The GUIDs of the content browser's selected assets.</summary>
    public IReadOnlyList<string> SelectedAssets { get; private set; } = [];

    /// <summary>
    /// Whether the selection holds a sub-asset. A sub-asset changes only with its file, so the file operations do not
    /// take it (see docs/content/daemon-and-operations.md#asset-operations).
    /// </summary>
    public bool SelectionHasSubassets => SelectedAssets.Any(g => assets.Find(g) is { } a && AssetIndex.IsSubasset(a));

    /// <summary>The cook daemon is linked, so the content can change.</summary>
    public bool CanChangeContent => cook.State == CookState.Linked;

    /// <summary>The user asked for a new asset from a template, or a folder for null. The window asks for its name.</summary>
    public event Action<AssetTemplate?>? NewAssetRequested;

    /// <summary>The user asked to rename an asset or a folder. The window asks for the new name.</summary>
    public event Action<ContentItem>? RenameRequested;

    /// <summary>The user asked to delete assets and folders. The window shows what uses them, and confirms.</summary>
    public event Action<IReadOnlyList<ContentItem>>? DeleteRequested;

    /// <summary>An operation made or moved an asset or a folder, which the content browser shows and selects.</summary>
    public event Action<ContentItem>? ContentRevealed;

    /// <summary>The cook daemon refused an operation, with its reason. The window shows it.</summary>
    public event Action<string>? OperationFailed;

    /// <summary>Shows an asset in the content browser, selected in its folder.</summary>
    public void RevealAsset(string guid) => ContentRevealed?.Invoke(new ContentItem(guid, null));

    /// <summary>The content browser's folder or selection changed.</summary>
    public void SelectContent(ContentFolder? folder, IReadOnlyList<string> selected)
    {
        Folder = folder;
        SelectedAssets = selected;
        changed();
    }

    public void RequestNewAsset(AssetTemplate? template) => NewAssetRequested?.Invoke(template);

    public void RequestRename(ContentItem item) => RenameRequested?.Invoke(item);

    /// <summary>Renames the one selected asset.</summary>
    public void RequestRenameSelected()
    {
        if (SelectedAssets is [var guid])
        {
            RequestRename(new ContentItem(guid, null));
        }
    }

    public void RequestDelete(IReadOnlyList<ContentItem> items)
    {
        if (items.Count > 0)
        {
            DeleteRequested?.Invoke(items);
        }
    }

    public void RequestDeleteSelected() => RequestDelete([.. SelectedAssets.Select(g => new ContentItem(g, null))]);

    /// <summary>The name that a new asset or folder starts with in the content browser's folder, which no file has yet.</summary>
    public string NewName(AssetTemplate? template)
    {
        var stem = template switch
        {
            AssetTemplate.Script => "new_script",
            AssetTemplate.Behaviour => "new_behaviour",
            AssetTemplate.Scene => "new_scene",
            AssetTemplate.Material => "new_material",
            AssetTemplate.MaterialFunction => "new_function",
            AssetTemplate.Mesh => "new_mesh",
            AssetTemplate.Prefab => "new_prefab",
            AssetTemplate.Effect => "new_effect",
            _ => "new_folder",
        };
        if (Folder?.Directory(assets) is not { } dir)
        {
            return stem;
        }
        var extension = template switch
        {
            AssetTemplate.Scene => assets.ExtensionOf(AssetKind.Scene),
            AssetTemplate.Material => assets.ExtensionOf(AssetKind.Material),
            AssetTemplate.MaterialFunction => assets.ExtensionOf(AssetKind.MaterialFunction),
            AssetTemplate.Mesh => assets.ExtensionOf(AssetKind.Mesh),
            AssetTemplate.Prefab => assets.ExtensionOf(AssetKind.Prefab),
            AssetTemplate.Effect => assets.ExtensionOf(AssetKind.Effect),
            null => "",
            _ => assets.ExtensionOf(AssetKind.Script),
        };
        for (var n = 1; ; n++)
        {
            var name = n == 1 ? stem : $"{stem}_{n}";
            var path = Path.Combine(dir, name + extension);
            if (!File.Exists(path) && !Directory.Exists(path))
            {
                return name;
            }
        }
    }

    /// <summary>Makes an asset from a template, or a folder for null, in the content browser's folder.</summary>
    public async Task<bool> Create(AssetTemplate? template, string name)
    {
        if (Folder is not { } folder)
        {
            return false;
        }
        if (template is { } t)
        {
            var result = await Operate(new CreateAsset(t, folder.Root, folder.Path, name));
            if (result is { Guids: [var guid, ..] })
            {
                ContentRevealed?.Invoke(new ContentItem(guid, null));
            }
            return result != null;
        }
        var created = folder.Child(name);
        if (await Operate(new CreateFolder(created.Root, created.Path)) == null)
        {
            return false;
        }
        ContentRevealed?.Invoke(ContentItem.Of(created));
        return true;
    }

    public async Task<bool> Rename(ContentItem item, string name)
    {
        if (item.Guid is { } guid)
        {
            var moved = await movingScene(() => Operate(new RenameAsset(guid, name)));
            if (moved)
            {
                ContentRevealed?.Invoke(item);
            }
            return moved;
        }
        if (item.Folder is not { } folder)
        {
            return false;
        }
        if (!await movingScene(() => Operate(new RenameFolder(folder.Root, folder.Path, name))))
        {
            return false;
        }
        ContentRevealed?.Invoke(ContentItem.Of(new ContentFolder(folder.Root, AssetIndex.Parent(folder.Path)).Child(name)));
        return true;
    }

    /// <summary>Moves assets, each with its .meta file, into a folder.</summary>
    public async Task<bool> MoveAssets(IReadOnlyList<string> guids, ContentFolder to)
    {
        if (guids.Count == 0 || !await movingScene(() => Operate(new MoveAssets([.. guids], to.Root, to.Path))))
        {
            return false;
        }
        ContentRevealed?.Invoke(new ContentItem(guids[0], null));
        return true;
    }

    /// <summary>Whether assets can move into a folder: some of them are elsewhere.</summary>
    public bool CanMoveAssets(IReadOnlyList<string> guids, ContentFolder to) =>
        CanChangeContent && guids.Select(assets.Find).OfType<Asset>().Any(a => a.Root != to.Root || AssetIndex.Parent(a.Path) != to.Path);

    public async Task<bool> DuplicateSelectedAssets()
    {
        if (SelectedAssets.Count == 0 || await Operate(new DuplicateAssets([.. SelectedAssets])) is not { } result)
        {
            return false;
        }
        if (result.Guids is [var first, ..])
        {
            ContentRevealed?.Invoke(new ContentItem(first, null));
        }
        return true;
    }

    /// <summary>Sends assets and folders to the Recycle Bin. The window has confirmed.</summary>
    public async Task<bool> Delete(IReadOnlyList<ContentItem> items)
    {
        var guids = items.Select(i => i.Guid).OfType<string>().ToArray();
        var folders = items.Select(i => i.Folder).OfType<ContentFolder>().Select(f => new CookFolder(f.Root, f.Path)).ToArray();
        return await Operate(new DeleteAssets(guids, folders)) != null;
    }

    /// <summary>
    /// The assets that a delete takes, the folders' included, and the assets that use them and stay, whose cooks it
    /// breaks.
    /// </summary>
    public (IReadOnlyList<Asset> Deleted, IReadOnlyList<Asset> Users) DeleteEffects(IReadOnlyList<ContentItem> items)
    {
        var deleted = items.Select(i => i.Guid).OfType<string>().Select(assets.Find).OfType<Asset>()
            .Concat(items.Select(i => i.Folder).OfType<ContentFolder>().SelectMany(f => assets.AssetsUnder(f.Root, f.Path)))
            .DistinctBy(a => a.Guid).ToList();
        return (deleted, assets.DependentsOutside([.. deleted.Select(a => a.Guid)]));
    }

    /// <summary>
    /// Sets one of an asset's import settings. A setting at its default leaves the .meta file, and the others stay as
    /// they are.
    /// </summary>
    public async Task<bool> SetImportSetting(string guid, string key, string value)
    {
        if (assets.Find(guid) is not { } asset)
        {
            return false;
        }
        return await Operate(new SetImportSettings(guid, WithSetting(asset.Settings, assets.SettingsOf(asset.Kind), key, value))) != null;
    }

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

    public async Task<bool> ReimportSelectedAssets() =>
        SelectedAssets.Count > 0 && await Operate(new Reimport([.. SelectedAssets])) != null;

    /// <summary>Asks the daemon for an operation, and returns its answer, or null when it failed, which it reports.</summary>
    async Task<OperationResult?> Operate(ILinkMessage operation)
    {
        var result = await cook.Request(operation);
        if (result.Error != "")
        {
            console.Add(LogLevel.Warning, $"content: {result.Error}");
            OperationFailed?.Invoke(result.Error);
            return null;
        }
        return result;
    }
}
