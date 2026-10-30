using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Shell;

/// <summary>What a gizmo drag edits: entities, mesh elements, textures, a mesh's pivot, or a pending distance.</summary>
interface IGizmoTarget
{
    /// <summary>The operations for the drag at a pixel. The target updates the drag itself, since targets snap differently.</summary>
    IReadOnlyList<Operation> Drag(GizmoDrag drag, Vec2 pixel, bool snap);

    /// <summary>After a step's operations previewed.</summary>
    void Previewed() { }

    /// <summary>After the drag stops and before its edit commits or cancels.</summary>
    void Ending() { }

    /// <summary>After the drag's edit commits or cancels and the gizmo is sent.</summary>
    void Ended(bool committed) { }
}

/// <summary>
/// A gizmo drag from press to release (see docs/editor/viewport.md#viewport): the drag's math and its target, the undo entry it
/// opens, the steps it previews in it, and the commit or cancel at its end.
/// </summary>
sealed class GizmoController(Action<string> begin, Func<IReadOnlyList<Operation>, bool> preview, Action commit, Action cancel, Action sent)
{
    GizmoDrag? _drag;

    public IGizmoTarget? Target { get; private set; }

    public bool IsDragging => _drag != null;

    /// <summary>Starts a drag. With no label, the undo entry is already open, as a pending distance's is.</summary>
    public void Start(GizmoDrag drag, IGizmoTarget target, string? label)
    {
        (_drag, Target) = (drag, target);
        if (label != null)
        {
            begin(label);
        }
        sent();
    }

    public void Drag(Vec2 pixel, bool snap)
    {
        if (_drag == null || Target == null)
        {
            return;
        }
        var ops = Target.Drag(_drag, pixel, snap);
        if (ops.Count > 0 && preview(ops))
        {
            Target.Previewed();
        }
    }

    public void Release() => End(committed: true);

    /// <summary>Ends the drag and puts what it edited back.</summary>
    public void Cancel() => End(committed: false);

    /// <summary>Forgets the drag and leaves its undo entry to the caller.</summary>
    public void Drop() => (_drag, Target) = (null, null);

    void End(bool committed)
    {
        if (_drag == null || Target is not { } target)
        {
            return;
        }
        Drop();
        target.Ending();
        if (committed)
        {
            commit();
        }
        else
        {
            cancel();
        }
        sent();
        target.Ended(committed);
    }
}
