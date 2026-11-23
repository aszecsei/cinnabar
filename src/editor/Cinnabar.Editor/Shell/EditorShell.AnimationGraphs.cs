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

    // The game says what an animation graph's preview plays.
    void OnPreviewView(Link.Protocol.AnimatorView view)
    {
        var guid = Convert.ToHexStringLower(view.Graph);
        (_graphEditors.Find(g => g.Guid == guid) as AnimationGraphEditor)?.OnPreviewView(view);
    }
}
