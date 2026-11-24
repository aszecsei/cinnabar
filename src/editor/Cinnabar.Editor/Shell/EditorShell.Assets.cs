using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Cook;

namespace Cinnabar.Editor.Shell;

public sealed partial class EditorShell
{
    /// <summary>The content browser's folder and selection, and the asset operations (see <see cref="ContentBrowser"/>).</summary>
    public ContentBrowser Content { get; }

    /// <summary>The source file of the asset of a GUID, when it is of a kind and its root is known.</summary>
    public bool TryFileOf(string guid, AssetKind kind, out string path)
    {
        if (Assets.Find(guid) is { } asset && asset.Kind == kind && Assets.FullPath(asset) is { } full)
        {
            path = full;
            return true;
        }
        path = "";
        return false;
    }

    /// <summary>The GUID of an asset file, from the index or from its .meta file, or null when it has none yet.</summary>
    string? AssetGuidOf(string path)
    {
        if (Assets.FindByPath(path) is { } asset)
        {
            return asset.Guid;
        }
        return MetaFile.TryRead(path + MetaFile.Extension)?.Guid;
    }

    /// <summary>
    /// The GUID of a file's sub-asset by its name, such as <c>sublevel.night</c>, from the index or from the file's .meta
    /// file, or null when it has none yet (see docs/content/identity-and-cooking.md#identity).
    /// </summary>
    string? SubassetGuidOf(string path, string name)
    {
        if (AssetGuidOf(path) is { } parent && Assets.SubassetsOf(parent).FirstOrDefault(a => a.Subasset == name) is { } asset)
        {
            return asset.Guid;
        }
        return MetaFile.TryRead(path + MetaFile.Extension)?.SubassetGuid(name);
    }

    // An operation that may move the open scene's file, which the document then follows, with its autosave.
    async Task<bool> MovingScene(Func<Task<OperationResult?>> operation)
    {
        var open = Scene is { } scene ? AssetGuidOf(scene.Path) : null;
        if (await operation() == null)
        {
            return false;
        }
        if (Scene is { } document && open != null && Assets.Find(open) is { } moved && Assets.FullPath(moved) is { } path
            && !string.Equals(path, document.Path, StringComparison.OrdinalIgnoreCase))
        {
            var old = document.Path;
            document.Move(path);
            Autosave.Delete(old);
            if (document.IsDirty)
            {
                Autosave.Write(document);
            }
        }
        return true;
    }
}
