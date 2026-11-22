namespace Cinnabar.Editor.Shell;

/// <summary>
/// Where Undo and Redo go while no graph editor's tab is active (see docs/editor/cutscene-editor.md#keying): the scene,
/// or the cutscene that keys from the inspector or the viewport went into last.
/// </summary>
public abstract record UndoTarget
{
    public sealed record Scene : UndoTarget
    {
        public static readonly Scene Instance = new();
    }

    public sealed record Cutscene(CutsceneEditor Editor) : UndoTarget;
}

public sealed partial class EditorShell
{
    UndoTarget _undoTarget = UndoTarget.Scene.Instance;

    /// <summary>Keys from the inspector and the viewport, into the cutscene that holds the preview.</summary>
    public Keying Keying { get; }

    /// <summary>
    /// What was edited last outside a graph editor's tab: the scene, or a cutscene by its keys. A cutscene whose tab
    /// closes, or that gives the preview to another, is the scene again.
    /// </summary>
    public UndoTarget LastEdited => _undoTarget;

    /// <summary>
    /// The graph editor whose history Undo and Redo move: the active tab's, or with none, the cutscene that was keyed
    /// last, or null for the scene.
    /// </summary>
    public IGraphEditor? UndoEditor => ActiveGraphEditor ?? (LastEdited is UndoTarget.Cutscene c ? c.Editor : null);

    /// <summary>
    /// The file time, in nanoseconds since the Unix epoch as the game reads it, of an asset's blob in the cache's
    /// preview area, or 0 when it has none.
    /// </summary>
    internal long PreviewBlobTime(string guid) => PreviewBlobTime(_options.Cook.CachePath, guid);

    /// <summary>An asset's blob's file time in a cache's preview area, as the game's <c>file_modified</c> reads it, or 0 for none.</summary>
    public static long PreviewBlobTime(string cache, string guid)
    {
        var path = Path.Combine(cache, "preview", guid + ".blob");
        return File.Exists(path) ? (File.GetLastWriteTimeUtc(path) - DateTime.UnixEpoch).Ticks * 100 : 0;
    }

    // The one writer of what was edited last: each committed scene edit, and each key.
    internal void Edited(UndoTarget target)
    {
        if (target != _undoTarget)
        {
            _undoTarget = target;
            Commands.InvalidateAll();
        }
    }

    // A cutscene that leaves, by its tab closing or by giving the preview to another, is no longer what Undo follows.
    void ForgetKeyed()
    {
        if (_undoTarget is UndoTarget.Cutscene c && (c.Editor != CutscenePreview.Owner || !_cutscenes.Contains(c.Editor)))
        {
            Edited(UndoTarget.Scene.Instance);
        }
    }

    // What a key button shows follows the preview, its playhead and the selected entities' values.
    void WireKeying()
    {
        CutscenePreview.Changed += ForgetKeyed;
        CutscenePreview.Changed += Keying.Raise;
        CutscenePreview.PlayheadMoved += Keying.Raise;
        World.ValuesChanged += entity =>
        {
            if (Selection.Entities.Contains(entity))
            {
                Keying.Raise();
            }
        };
        Selection.Changed += (_, _) => Keying.Raise();
    }
}
