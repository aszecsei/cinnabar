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

    // An operation that may move the open scene's file, which the document then follows, with its autosave.
    async Task<bool> MovingScene(Func<Task<OperationResult?>> operation)
    {
        var open = Scene is { } scene ? Assets.FindByPath(scene.Path)?.Guid : null;
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
