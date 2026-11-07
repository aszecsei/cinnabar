using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The scene's open undo entry, as <see cref="EditorShell.TryBeginEdit"/> gives it to the one that opened it (see
/// docs/editor/document-and-scenes.md#document-model). Previews, the commit and the cancel go through it. Once the entry
/// ends, by its owner or by the shell, the token is stale and does nothing, and <see cref="Ended"/> tells the owner.
/// </summary>
public sealed class SceneEdit
{
    readonly EditorShell _shell;
    readonly SceneDocument _document;

    internal SceneEdit(EditorShell shell, SceneDocument document, string label, string owner, bool commitIfInterrupted)
    {
        (_shell, _document) = (shell, document);
        (Label, Owner, CommitIfInterrupted) = (label, owner, commitIfInterrupted);
    }

    /// <summary>The undo entry's label.</summary>
    public string Label { get; }

    /// <summary>Who opened the entry, as the console names it: "the gizmo", "a mesh tool", "a field drag".</summary>
    public string Owner { get; }

    /// <summary>Whether the shell keeps the entry when it ends it for its owner, as Play does, or puts it back.</summary>
    public bool CommitIfInterrupted { get; }

    /// <summary>Whether the entry is still the scene's open one.</summary>
    public bool IsOpen => _shell.OpenEdit == this;

    /// <summary>The entry ended, committed or not, by whoever ended it. It is raised once.</summary>
    public event Action<bool>? Ended;

    public bool Preview(Operation op) => Preview([op]);

    /// <summary>Applies operations in the entry. A stale token does nothing; an operation that does not fit goes to the console. Both are false.</summary>
    public bool Preview(IReadOnlyList<Operation> ops)
    {
        if (!IsOpen)
        {
            return false;
        }
        try
        {
            _document.Preview(ops);
            return true;
        }
        catch (InvalidOperationException e)
        {
            _shell.Console.Add(Model.LogLevel.Error, $"edit: {e.Message}");
            return false;
        }
    }

    /// <summary>Ends the entry as an undo step. A stale token does nothing.</summary>
    public void Commit() => _shell.EndEdit(this, commit: true);

    /// <summary>Ends the entry and puts back what it changed. A stale token does nothing.</summary>
    public void Cancel() => _shell.EndEdit(this, commit: false);

    internal void End(bool commit)
    {
        if (commit)
        {
            _document.Commit();
        }
        else
        {
            _document.Cancel();
        }
    }

    internal void RaiseEnded(bool committed) => Ended?.Invoke(committed);
}
