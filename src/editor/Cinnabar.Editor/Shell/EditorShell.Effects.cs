using Cinnabar.Editor.Docking;
using Cinnabar.Editor.Panels;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The effect previews (see docs/rendering/particles.md#previews): opening an effect from the content browser as a
/// document beside the viewport, which shows it playing, and its preview's link to the game. The effect's text opens in
/// the script editor, and the preview shows each save once the daemon cooks it.
/// </summary>
public sealed partial class EditorShell
{
    readonly List<EffectPreview> _effects = [];

    public IReadOnlyList<EffectPreview> Effects => _effects;

    /// <summary>Opens an effect's preview, or shows its open one.</summary>
    public EffectPreview? OpenEffect(Link.Cook.Asset asset)
    {
        if (_effects.Find(e => e.Guid == asset.Guid) is { } open)
        {
            Layout.ShowDocument(open);
            return open;
        }
        if (Assets.FullPath(asset) is not { } path)
        {
            return null;
        }
        var previewId = _previewSlots.Free();
        if (previewId == null)
        {
            Console.Add(LogLevel.Warning, $"effect: {MaxPreviews} previews are open, so {Path.GetFileName(path)} has none");
        }
        var preview = new EffectPreview(this, asset, path, previewId);
        _effects.Add(preview);
        if (Host.Linked)
        {
            preview.SendPreview();
        }
        Layout.OpenDocument(new EffectPreviewDocument(preview, () => new EffectPreviewView(this, preview)));
        return preview;
    }

    void OnEffectClosed(EffectPreview preview)
    {
        if (_effects.Remove(preview))
        {
            preview.ClosePreview();
            preview.Dispose();
        }
    }
}
