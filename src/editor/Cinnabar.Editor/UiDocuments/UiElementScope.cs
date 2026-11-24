using Avalonia.Controls;
using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.UiDocuments;

/// <summary>
/// The UI editor's canvas and tree while one has the keyboard (see docs/editor/ui-editor.md#the-tree): Delete and
/// Duplicate act on the selected element, not on the entities, and do nothing with none selected. Cancel, Esc in the
/// canvas, selects nothing.
/// </summary>
sealed class UiElementScope(UiEditor editor) : ICommandScope
{
    /// <summary>
    /// Makes a view's scope the focused one while it has the keyboard, and asks the commands again when the selection
    /// changes while it is on screen.
    /// </summary>
    public static void Follow(Control view, CommandRegistry commands, UiEditor editor)
    {
        var scope = new UiElementScope(editor);
        FocusFollower.Scope(view, commands, scope);
        void Refresh() => commands.Refresh(scope);
        new ViewSubscriptions(view).Add(() => editor.SelectionChanged += Refresh, () => editor.SelectionChanged -= Refresh);
    }

    public ScopedCommand? Handler(string commandId) => commandId switch
    {
        EditorCommands.DeleteEntity => new(() => Run(editor.Delete), () => editor.SelectedNode != null),
        EditorCommands.DuplicateEntity => new(() => Run(editor.Duplicate), () => editor.SelectedNode != null),
        // F fits the document in the canvas, as it frames a graph.
        EditorCommands.FrameSelected => new(editor.Fit),
        // Esc in the canvas selects nothing.
        EditorCommands.Cancel => new(() => editor.Select(null), () => editor.SelectedNode != null),
        _ => null,
    };

    void Run(Action<int> action)
    {
        if (editor.SelectedNode is { } node)
        {
            action(node);
        }
    }
}
