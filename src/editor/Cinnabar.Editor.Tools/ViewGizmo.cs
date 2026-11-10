using Cinnabar.Editor.Maths;

namespace Cinnabar.Editor.Tools;

/// <summary>A view along one of the world's axes, named by the side that it looks from (see docs/editor/viewport.md#view-gizmo).</summary>
public enum ViewAxis
{
    /// <summary>From +y, looking down.</summary>
    Top,
    /// <summary>From -y, looking up.</summary>
    Bottom,
    /// <summary>From +z, looking along -z, with +x to the left.</summary>
    Front,
    /// <summary>From -z, looking along +z, with +x to the right, as the 2D view looks.</summary>
    Back,
    /// <summary>From +x, looking along -x, with +z to the right.</summary>
    Right,
    /// <summary>From -x, looking along +x.</summary>
    Left,
}

/// <summary>A part of the view gizmo: its middle, which switches the projection, or the handle at one end of an axis.</summary>
public enum ViewGizmoPart
{
    None,
    Center,
    PositiveX,
    NegativeX,
    PositiveY,
    NegativeY,
    PositiveZ,
    NegativeZ,
}

/// <summary>
/// Where the handle of one end of an axis shows on the view gizmo: its offset from the gizmo's middle in pixels, with +y
/// down the screen, and how far it points away from the viewer, from -1 at the viewer to 1 away.
/// </summary>
public readonly record struct ViewGizmoHandle(ViewGizmoPart Part, Vec2 Offset, double Depth)
{
    public bool Positive => Part is ViewGizmoPart.PositiveX or ViewGizmoPart.PositiveY or ViewGizmoPart.PositiveZ;

    /// <summary>The axis, 0 to 2 for x to z.</summary>
    public int Axis => ((int)Part - (int)ViewGizmoPart.PositiveX) / 2;
}

/// <summary>
/// The view gizmo in a scene view's corner (see docs/editor/viewport.md#view-gizmo): the world's axes as the camera
/// sees them, a handle at each end. A handle looks along its axis from its side, and the middle switches the projection.
/// </summary>
public static class ViewGizmo
{
    /// <summary>A handle's radius, as a fraction of the gizmo's: the positive ends are larger, and carry the axis's letter.</summary>
    public const double PositiveHandle = 0.24;
    public const double NegativeHandle = 0.17;
    /// <summary>Half the middle square's side, as a fraction of the gizmo's radius.</summary>
    public const double CenterHalf = 0.16;
    // A camera that looks within this of an axis is along it: Top and Bottom are a degree short of straight.
    static readonly double AlignedCos = Math.Cos(1.5 * Math.PI / 180);

    static readonly Vec3[] Axes = [Vec3.UnitX, Vec3.UnitY, Vec3.UnitZ];

    /// <summary>The heading and the pitch of a camera that looks along an axis (see <see cref="EditorCamera.Rotation"/>).</summary>
    public static (double Yaw, double Pitch) Angles(ViewAxis axis) => axis switch
    {
        ViewAxis.Top => (0, EditorCamera.MaxPitch),
        ViewAxis.Bottom => (0, -EditorCamera.MaxPitch),
        ViewAxis.Front => (Math.PI, 0),
        ViewAxis.Back => (0, 0),
        ViewAxis.Right => (-Math.PI / 2, 0),
        ViewAxis.Left => (Math.PI / 2, 0),
        _ => throw new ArgumentOutOfRangeException(nameof(axis)),
    };

    /// <summary>The way that a camera along an axis looks.</summary>
    public static Vec3 Direction(ViewAxis axis) => axis switch
    {
        ViewAxis.Top => -Vec3.UnitY,
        ViewAxis.Bottom => Vec3.UnitY,
        ViewAxis.Front => -Vec3.UnitZ,
        ViewAxis.Back => Vec3.UnitZ,
        ViewAxis.Right => -Vec3.UnitX,
        ViewAxis.Left => Vec3.UnitX,
        _ => throw new ArgumentOutOfRangeException(nameof(axis)),
    };

    /// <summary>The axis that a camera looks along, or null for one that looks along none.</summary>
    public static ViewAxis? Aligned(EditorCamera camera)
    {
        var forward = camera.Forward;
        foreach (var axis in Enum.GetValues<ViewAxis>())
        {
            if (Vec3.Dot(forward, Direction(axis)) >= AlignedCos)
            {
                return axis;
            }
        }
        return null;
    }

    /// <summary>The view's name: the axis's, or Free for a camera along none.</summary>
    public static string Name(ViewAxis? axis) => axis?.ToString() ?? "Free";

    /// <summary>What a view is, as the gizmo and the view's menu name it: its axis and its projection.</summary>
    public static string Label(EditorCamera camera) => $"{Name(Aligned(camera))} · {(camera.IsOrthographic ? "Ortho" : "Persp")}";

    /// <summary>The view that a handle gives: the one from its end of the axis. The middle gives none.</summary>
    public static ViewAxis? AxisOf(ViewGizmoPart part) => part switch
    {
        ViewGizmoPart.PositiveX => ViewAxis.Right,
        ViewGizmoPart.NegativeX => ViewAxis.Left,
        ViewGizmoPart.PositiveY => ViewAxis.Top,
        ViewGizmoPart.NegativeY => ViewAxis.Bottom,
        ViewGizmoPart.PositiveZ => ViewAxis.Front,
        ViewGizmoPart.NegativeZ => ViewAxis.Back,
        _ => null,
    };

    /// <summary>The handles of a gizmo of this radius in pixels, as a camera with this rotation sees them, the farthest first, in the order to draw them.</summary>
    public static IReadOnlyList<ViewGizmoHandle> Layout(Quat rotation, double radius)
    {
        var right = rotation.Rotate(Vec3.UnitX);
        var up = rotation.Rotate(Vec3.UnitY);
        var forward = rotation.Rotate(Vec3.UnitZ);
        var handles = new List<ViewGizmoHandle>(6);
        for (var i = 0; i < 3; i++)
        {
            foreach (var sign in (ReadOnlySpan<int>)[1, -1])
            {
                var axis = Axes[i] * sign;
                var part = (ViewGizmoPart)((int)ViewGizmoPart.PositiveX + 2 * i + (sign > 0 ? 0 : 1));
                handles.Add(new ViewGizmoHandle(part, new Vec2(Vec3.Dot(axis, right), -Vec3.Dot(axis, up)) * radius, Vec3.Dot(axis, forward)));
            }
        }
        handles.Sort((a, b) => b.Depth.CompareTo(a.Depth));
        return handles;
    }

    /// <summary>
    /// The part under a point, as an offset from the gizmo's middle in pixels: the middle first, as it is drawn over
    /// every handle, then the handles from the nearest to the viewer.
    /// </summary>
    public static ViewGizmoPart Hit(IReadOnlyList<ViewGizmoHandle> handles, Vec2 point, double radius)
    {
        var half = CenterHalf * radius;
        if (Math.Abs(point.X) <= half && Math.Abs(point.Y) <= half)
        {
            return ViewGizmoPart.Center;
        }
        for (var i = handles.Count - 1; i >= 0; i--)
        {
            var handle = handles[i];
            if ((point - handle.Offset).Length <= (handle.Positive ? PositiveHandle : NegativeHandle) * radius)
            {
                return handle.Part;
            }
        }
        return ViewGizmoPart.None;
    }
}
