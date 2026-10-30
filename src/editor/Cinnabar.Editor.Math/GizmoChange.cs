namespace Cinnabar.Editor.Maths;

/// <summary>How a gizmo drag changes the selection, about the gizmo's center: a move, a turn and a scale.</summary>
public readonly record struct GizmoChange(Vec3 Translation, Quat Rotation, Vec3 Scale)
{
    public static GizmoChange None => new(Vec3.Zero, Quat.Identity, new Vec3(1, 1, 1));
}
