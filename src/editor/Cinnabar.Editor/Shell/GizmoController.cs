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

    /// <summary>After the drag's edit commits or cancels, by the drag or by another, and the gizmo is sent.</summary>
    void Ended(bool committed) { }
}

/// <summary>
/// A gizmo drag from press to release (see docs/editor/viewport.md#viewport): the drag's math and its target, the undo entry it
/// previews its steps in, and the commit or cancel at its end. The drag lasts as long as its edit: one that another ends
/// ends the drag too.
/// </summary>
sealed class GizmoController(Func<string, SceneEdit?> begin, Action sent)
{
    sealed record Active(GizmoDrag Drag, IGizmoTarget Target, SceneEdit Edit);

    Active? _active;

    public IGizmoTarget? Target => _active?.Target;

    public bool IsDragging => _active != null;

    /// <summary>Starts a drag in a new undo entry. False when another edit is open.</summary>
    public bool Start(GizmoDrag drag, IGizmoTarget target, string label) => begin(label) is { } edit && Start(drag, target, edit);

    /// <summary>Starts a drag in an entry that is open already, as a pending distance's. False for a stale one.</summary>
    public bool Start(GizmoDrag drag, IGizmoTarget target, SceneEdit edit)
    {
        if (!edit.IsOpen || _active != null)
        {
            return false;
        }
        _active = new Active(drag, target, edit);
        edit.Ended += committed => OnEnded(edit, committed);
        sent();
        return true;
    }

    public void Drag(Vec2 pixel, bool snap)
    {
        if (_active is not { } active)
        {
            return;
        }
        var ops = active.Target.Drag(active.Drag, pixel, snap);
        if (ops.Count > 0 && active.Edit.Preview(ops))
        {
            active.Target.Previewed();
        }
    }

    public void Release() => _active?.Edit.Commit();

    /// <summary>Ends the drag and puts what it edited back.</summary>
    public void Cancel() => _active?.Edit.Cancel();

    void OnEnded(SceneEdit edit, bool committed)
    {
        if (_active is not { } active || active.Edit != edit)
        {
            return;
        }
        _active = null;
        sent();
        active.Target.Ended(committed);
    }
}
