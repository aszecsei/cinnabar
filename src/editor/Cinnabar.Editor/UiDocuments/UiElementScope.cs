using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.UiDocuments;

/// <summary>
/// The UI editor's canvas and tree while one has the keyboard (see docs/editor/ui-editor.md#the-tree): Delete and
/// Duplicate act on the selected element, not on the entities, and do nothing with none selected.
/// </summary>
sealed class UiElementScope(UiEditor editor) : ICommandScope
{
    public ScopedCommand? Handler(string commandId) => commandId switch
    {
        EditorCommands.DeleteEntity => new(() => Run(editor.Delete), () => editor.SelectedNode != null),
        EditorCommands.DuplicateEntity => new(() => Run(editor.Duplicate), () => editor.SelectedNode != null),
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
