using Cinnabar.Editor.Content;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Model;
using AssetStatus = Cinnabar.Editor.Link.Cook.AssetStatus;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// What the sessions that edit snapshot assets do alike (see docs/editor/document-and-scenes.md#document-model): save
/// the dirty ones, and find the live ones that the host can draw from their cooked blobs again.
/// </summary>
static class SnapshotSaves
{
    /// <summary>
    /// Saves each asset, through <see cref="SnapshotAsset{TSnapshot}.Save"/>, with a console line under a label, such as
    /// <c>mesh</c>, for each. A failure goes to the console, and the rest are still saved. False when one failed.
    /// </summary>
    public static bool SaveDirty(IEnumerable<ISnapshotAsset> assets, string label, ConsoleLog console)
    {
        var ok = true;
        foreach (var asset in assets.Where(a => a.IsDirty).ToList())
        {
            try
            {
                asset.Save();
                console.Add(LogLevel.Info, $"{label}: saved {asset.Path}");
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                console.Add(LogLevel.Error, $"{label}: cannot save {asset.Path}: {e.Message}");
                ok = false;
            }
        }
        return ok;
    }

    /// <summary>The live assets that are saved and whose cooked blobs are current, for the session to release.</summary>
    public static List<T> Cooked<T>(IEnumerable<T> assets, AssetIndex index) where T : ILiveAsset =>
        [.. assets.Where(a => a.IsLive && !a.IsDirty && index.Find(a.Guid) is { Status: AssetStatus.Current })];
}
