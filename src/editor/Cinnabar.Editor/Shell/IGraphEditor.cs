using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Shell;

/// <summary>An open graph in a document beside the viewport: what the shell's commands and the window ask of it.</summary>
public interface IGraphEditor : IDisposable
{
    /// <summary>The asset's GUID, which stays when its file moves.</summary>
    string Guid { get; }

    IGraphDocument Document { get; }

    /// <summary>
    /// Every document that the tab holds, which its Save writes and its dirty mark reads: its own, and for a cutscene,
    /// each sub-sequence it shows or showed in context with changes (see docs/editor/cutscene-editor.md#sub-sequences).
    /// </summary>
    IEnumerable<IGraphDocument> Documents => [Document];

    /// <summary>The document whose history Undo and Redo move: the one that the tab shows.</summary>
    IGraphDocument UndoDocument => Document;

    /// <summary>Whether closing the tab would lose changes that no other tab holds, so the close asks first.</summary>
    bool LosesChangesOnClose => Document.IsDirty;

    /// <summary>Whether any of the tab's documents has changes, which its title marks.</summary>
    bool IsDirty => Documents.Any(d => d.IsDirty);

    /// <summary>What the console calls it, such as <c>material</c>.</summary>
    string Noun { get; }

    /// <summary>Sends the unsaved text to the cook daemon now, and shows the answer's problems.</summary>
    Task CookNow();

    /// <summary>The checks of the unsaved text.</summary>
    ICookChecks Checks { get; }

    /// <summary>The editor's document or its own state changed, which the shell's commands may read.</summary>
    event Action? Changed;
}
