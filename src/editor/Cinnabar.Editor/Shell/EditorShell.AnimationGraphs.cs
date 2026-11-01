using Cinnabar.Editor.Docking;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Shell;

/// <summary>The animation graph editor's documents (see docs/editor/animation-graph-editor.md#animation-graph-editor).</summary>
public sealed partial class EditorShell
{
    readonly List<AnimationGraphEditor> _animationGraphs = [];

    public IReadOnlyList<AnimationGraphEditor> AnimationGraphs => _animationGraphs;

    /// <summary>The animation graph editor whose document is active, or null when the viewport or another document is.</summary>
    public AnimationGraphEditor? ActiveAnimationGraph => ActiveGraphEditor as AnimationGraphEditor;

    /// <summary>
    /// Opens an animation graph in its editor, or shows its open editor. A file that does not start as a graph does
    /// opens in the script editor instead, with the reason in the console.
    /// </summary>
    public AnimationGraphEditor? OpenAnimationGraph(Link.Cook.Asset asset)
    {
        if (_animationGraphs.Find(g => g.Guid == asset.Guid) is { } open)
        {
            Layout.ShowDocument(open);
            return open;
        }
        if (Assets.FullPath(asset) is not { } path)
        {
            return null;
        }
        var (document, problem) = AnimationGraphDocument.Open(path, asset.Guid);
        if (document == null)
        {
            Report("animation graph", path, [(problem!.Line, problem.Message, true)]);
            OpenScript(path, (uint)problem.Line);
            return null;
        }
        var editor = new AnimationGraphEditor(this, document);
        _animationGraphs.Add(editor);
        _ = editor.CookNow();
        Layout.OpenDocument(new AnimationGraphEditorDocument(editor, () => new AnimationGraphs.AnimationGraphEditorView(this, editor)));
        GraphEditorsChanged?.Invoke();
        return editor;
    }
}
