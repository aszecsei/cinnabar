using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Cutscenes;

/// <summary>
/// A cutscene editor's tab while the keyboard is anywhere in it (see docs/editor/cutscene-editor.md#the-tab): Cancel,
/// which Esc runs, cancels in this order:
/// <list type="number">
/// <item>a drag on the timeline, then one on the curves;</item>
/// <item>a field's drag, as of a time's name;</item>
/// <item>an armed pick of a binding's entity;</item>
/// <item>in the pane that has the keyboard, a box, or else the selection.</item>
/// </list>
/// So a drag ends before a pick, and a pick before the selection. A text box keeps its own Esc.
/// </summary>
sealed class CutsceneCancelScope(CutsceneEditor editor, CutsceneTimelineInput timeline, CutsceneCurveInput curves) : ICommandScope
{
    /// <summary>
    /// Whether a drag is under way in the tab, which the first rungs cancel: a text box that has the keyboard then does
    /// not keep Esc, since a scrub's handle takes no keyboard.
    /// </summary>
    public bool DragUnderWay => timeline.Dragging || curves.Dragging || editor.Document.InTransaction;

    public ScopedCommand? Handler(string commandId) => commandId switch
    {
        EditorCommands.Cancel => ScopedCommand.FirstOf(
            (() => timeline.Dragging, () => timeline.Escape()),
            (() => curves.Dragging, () => curves.Escape()),
            // A field's drag, or a held drag such as a lens scrub, which puts back the selection that it began with.
            (() => editor.Document.InTransaction, () => editor.EndDrag(cancel: true)),
            (() => editor.Picking != null, () => editor.CancelPick()),
            (() => editor.KeyboardPane == CutscenePane.Timeline && timeline.CanEscape, () => timeline.Escape()),
            (() => editor.KeyboardPane == CutscenePane.Curves && curves.CanEscape, () => curves.Escape())),
        _ => null,
    };
}
