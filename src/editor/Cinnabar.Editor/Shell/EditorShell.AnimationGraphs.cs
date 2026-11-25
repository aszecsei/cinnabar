using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Shell;

/// <summary>The animation graph editor's documents (see docs/editor/animation-graph-editor.md#animation-graph-editor).</summary>
public sealed partial class EditorShell
{
    public IReadOnlyList<AnimationGraphEditor> AnimationGraphs => [.. _graphEditors.OfType<AnimationGraphEditor>()];

    /// <summary>The animation graph editor whose document is active, or null when the viewport or another document is.</summary>
    public AnimationGraphEditor? ActiveAnimationGraph => ActiveGraphEditor as AnimationGraphEditor;

    /// <summary>
    /// Opens an animation graph in its editor, or shows its open editor. A file that does not start as a graph does
    /// opens in the script editor instead, with the reason in the console.
    /// </summary>
    public AnimationGraphEditor? OpenAnimationGraph(Link.Cook.Asset asset) => OpenEditor(asset) as AnimationGraphEditor;

    // Each graph file's clip events, by GUID, as its file had them when it was last written: read again when it changes.
    readonly Dictionary<string, (DateTime Modified, AnimationGraphFile? Graph)> _graphFiles = [];

    /// <summary>
    /// A clip's events in an animation graph, in the clip's ticks, with their names and arguments as the graph writes
    /// them (see docs/editor/cutscene-editor.md#events). An open graph's are what its editor has, saved or not. Empty
    /// for a graph that is not there or does not name the clip.
    /// </summary>
    public IReadOnlyList<CutsceneClipEvent> ClipEvents(string graph, string clip)
    {
        AnimationGraphFile? file;
        if (_graphEditors.Find(e => e.Guid == graph) is AnimationGraphEditor open)
        {
            file = open.Document.Graph;
        }
        else if (!TryFileOf(graph, AssetKind.AnimationGraph, out var path))
        {
            return [];
        }
        else
        {
            var modified = File.Exists(path) ? File.GetLastWriteTimeUtc(path) : default;
            if (!_graphFiles.TryGetValue(graph, out var cached) || cached.Modified != modified)
            {
                file = null;
                try
                {
                    file = AnimationGraphFile.Parse(File.ReadAllText(path)).File;
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                }
                cached = (modified, file);
                _graphFiles[graph] = cached;
            }
            file = cached.Graph;
        }
        var named = file?.Clips.FirstOrDefault(c => string.Equals(c.Guid, clip, StringComparison.OrdinalIgnoreCase));
        return named == null ? [] : [.. named.Events.Select(ParseEvent).OfType<CutsceneClipEvent>()];
    }

    // An event line, "event <seconds> <name> [<argument>]...", as the clip's ticks and the rest of the line. Null for
    // a line that is not one, which the cooker reports.
    static CutsceneClipEvent? ParseEvent(string code)
    {
        var parts = code.Trim().Split((char[]?)null, 3, StringSplitOptions.RemoveEmptyEntries);
        if (parts is not ["event", var time, var rest]
            || !double.TryParse(time, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var seconds)
            || !double.IsFinite(seconds) || seconds < 0)
        {
            return null;
        }
        return new CutsceneClipEvent((int)Math.Round(Math.Min(seconds * CutsceneFile.TicksPerSecond, int.MaxValue)), rest.Trim());
    }

    // The game says what an animation graph's preview plays.
    void OnPreviewView(Link.Protocol.AnimatorView view)
    {
        var guid = Convert.ToHexStringLower(view.Graph);
        (_graphEditors.Find(g => g.Guid == guid) as AnimationGraphEditor)?.OnPreviewView(view);
    }
}
