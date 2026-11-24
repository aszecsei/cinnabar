using Cinnabar.Editor.Commands;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The commands that the active editor's tab takes after the focused scope (see
/// docs/editor/shell-and-panels.md#commands): the editor's own, such as a cutscene's Delete while its timeline has the
/// keyboard, then Save, Undo and Redo of its document. Undo and Redo also take the cutscene keyed after the scene's last
/// edit. A command that none takes acts on the active scene.
/// </summary>
sealed class EditorScope(EditorShell shell) : ICommandScope
{
    public ScopedCommand? Handler(string commandId)
    {
        if (shell.ActiveGraphEditor is ICommandScope editor && editor.Handler(commandId) is { } own)
        {
            return own;
        }
        return commandId switch
        {
            EditorCommands.Save when shell.ActiveGraphEditor is { } graph =>
                new(() => _ = shell.SaveGraph(graph), () => !graph.Document.InTransaction),
            EditorCommands.Undo when shell.UndoEditor is { } graph => new(graph.Document.Undo, () => graph.Document.CanUndo),
            EditorCommands.Redo when shell.UndoEditor is { } graph => new(graph.Document.Redo, () => graph.Document.CanRedo),
            _ => null,
        };
    }
}
