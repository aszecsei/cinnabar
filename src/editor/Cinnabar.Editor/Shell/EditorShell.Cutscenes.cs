using Cinnabar.Editor.Docking;
using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Shell;

/// <summary>The cutscene editor's documents (see docs/editor/cutscene-editor.md).</summary>
public sealed partial class EditorShell
{
    readonly List<CutsceneEditor> _cutscenes = [];

    public IReadOnlyList<CutsceneEditor> Cutscenes => _cutscenes;

    /// <summary>The cutscene editor whose document is active, or null when the viewport or another document is.</summary>
    public CutsceneEditor? ActiveCutscene => ActiveGraphEditor as CutsceneEditor;

    /// <summary>
    /// Opens a cutscene in its editor, or shows its open editor. A file that does not start with <c>cutscene 1</c>
    /// opens in the script editor instead, with the reason in the console.
    /// </summary>
    public CutsceneEditor? OpenCutscene(Link.Cook.Asset asset)
    {
        if (_cutscenes.Find(c => c.Guid == asset.Guid) is { } open)
        {
            Layout.ShowDocument(open);
            return open;
        }
        if (Assets.FullPath(asset) is not { } path)
        {
            return null;
        }
        var (document, problem) = CutsceneDocument.Open(path, asset.Guid);
        if (document == null)
        {
            Report("cutscene", path, [(problem!.Line, problem.Message, true)]);
            OpenScript(path, (uint)problem.Line);
            return null;
        }
        var editor = new CutsceneEditor(this, document);
        _cutscenes.Add(editor);
        _ = editor.CookNow();
        Layout.OpenDocument(new CutsceneEditorDocument(editor, () => new Cutscenes.CutsceneEditorView(this, editor)));
        GraphEditorsChanged?.Invoke();
        return editor;
    }
}
