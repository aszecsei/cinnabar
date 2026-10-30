using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Maths;

namespace Cinnabar.Editor.Tools;

/// <summary>What the viewport's left button does: select, or move, turn or scale the selection with a gizmo.</summary>
public enum Tool
{
    Select,
    Move,
    Rotate,
    Scale,
}

/// <summary>Whether the gizmo's axes are the world's or the entity's. Scaling always uses the entity's.</summary>
public enum Space
{
    World,
    Local,
}

/// <summary>
/// The gizmo's shape and its hit test (see docs/editor/viewport.md#viewport). The game draws the gizmo from a Gizmo_State, with
/// the same proportions as here (see lib/engine/editor/viewport.odin): an axis's length is <see cref="Size"/>, and the
/// other parts are fractions of it.
/// </summary>
public static class Gizmo
{
    /// <summary>An axis's length on screen, in pixels of the frame.</summary>
    public const double ScreenLength = 110;
    /// <summary>How near the mouse must be to a part, in pixels.</summary>
    public const double HitPixels = 8;
    // A plane handle smaller than this on screen, in square pixels, takes no clicks.
    const double MinPlaneArea = 40;

    // Fractions of an axis's length, as viewport.odin draws them.
    public const double PlaneNear = 0.25;
    public const double PlaneFar = 0.5;
    public const double Center = 0.08;
    public const double ViewRing = 1.2;

    public static GizmoKind KindOf(Tool tool) => tool switch
    {
        Tool.Move => GizmoKind.Translate,
        Tool.Rotate => GizmoKind.Rotate,
        Tool.Scale => GizmoKind.Scale,
        _ => GizmoKind.None,
    };

    /// <summary>The axes' length in meters, so they are <see cref="ScreenLength"/> pixels long at the gizmo's distance.</summary>
    public static double Size(EditorCamera camera, Vec3 center, double height) =>
        camera.PixelSize(Math.Max(Vec3.Dot(center, camera.Forward), camera.Near), height) * ScreenLength;

    public static Vec3 Axis(Quat axes, int i) => axes.Rotate(i switch { 0 => Vec3.UnitX, 1 => Vec3.UnitY, _ => Vec3.UnitZ });

    public static GizmoPart AxisPart(int i) => i switch { 0 => GizmoPart.X, 1 => GizmoPart.Y, _ => GizmoPart.Z };

    /// <summary>
    /// The part under a point of the frame, or None. The parts in the middle win over the planes, and the planes over
    /// the axes, as they are drawn on top. <paramref name="center"/> is relative to the camera.
    /// </summary>
    public static GizmoPart HitTest(GizmoKind kind, EditorCamera camera, Vec3 center, Quat axes, Vec2 mouse, double width, double height)
    {
        if (kind == GizmoKind.None || camera.Project(center, width, height) is not { } c)
        {
            return GizmoPart.None;
        }
        var size = Size(camera, center, height);
        Vec2? Screen(Vec3 p) => camera.Project(p, width, height);
        var best = GizmoPart.None;
        var bestDistance = HitPixels;
        void Consider(GizmoPart part, double distance)
        {
            if (distance < bestDistance)
            {
                best = part;
                bestDistance = distance;
            }
        }

        switch (kind)
        {
            case GizmoKind.Translate or GizmoKind.Scale:
                if ((mouse - c).Length <= Center * ScreenLength + 2)
                {
                    return GizmoPart.View;
                }
                if (kind == GizmoKind.Translate)
                {
                    for (var i = 0; i < 3; i++)
                    {
                        var (u, w) = (Axis(axes, i), Axis(axes, (i + 1) % 3));
                        Vec3[] corners =
                        [
                            center + (u + w) * (PlaneNear * size), center + u * (PlaneFar * size) + w * (PlaneNear * size),
                            center + (u + w) * (PlaneFar * size), center + u * (PlaneNear * size) + w * (PlaneFar * size),
                        ];
                        var projected = corners.Select(Screen).ToArray();
                        if (projected.All(p => p != null) && InsideQuad(mouse, [.. projected.Select(p => p!.Value)]))
                        {
                            return i switch { 0 => GizmoPart.XY, 1 => GizmoPart.YZ, _ => GizmoPart.ZX };
                        }
                    }
                }
                for (var i = 0; i < 3; i++)
                {
                    if (Screen(center + Axis(axes, i) * size) is { } end)
                    {
                        Consider(AxisPart(i), Vec2.DistanceToSegment(mouse, c, end));
                    }
                }
                return best;
            case GizmoKind.Rotate:
                // Only each ring's near half takes the mouse: the far half is behind the others.
                var toCamera = (-center).Normalized();
                for (var i = 0; i < 3; i++)
                {
                    var (u, w) = (Axis(axes, (i + 1) % 3), Axis(axes, (i + 2) % 3));
                    const int Segments = 64;
                    for (var k = 0; k < Segments; k++)
                    {
                        var a = Ring(center, u, w, size, k * 2 * Math.PI / Segments);
                        var b = Ring(center, u, w, size, (k + 1) * 2 * Math.PI / Segments);
                        if (Vec3.Dot(a - center, toCamera) < 0 && Vec3.Dot(b - center, toCamera) < 0)
                        {
                            continue;
                        }
                        if (Screen(a) is { } sa && Screen(b) is { } sb)
                        {
                            Consider(AxisPart(i), Vec2.DistanceToSegment(mouse, sa, sb));
                        }
                    }
                }
                Consider(GizmoPart.View, Math.Abs((mouse - c).Length - ViewRing * ScreenLength));
                return best;
            default:
                return GizmoPart.None;
        }
    }

    static Vec3 Ring(Vec3 center, Vec3 u, Vec3 w, double radius, double angle) => center + (u * Math.Cos(angle) + w * Math.Sin(angle)) * radius;

    // The quad's corners go around it in order, so the point is inside when it is on the same side of every edge. A
    // plane seen nearly edge on is a sliver, which takes no clicks.
    static bool InsideQuad(Vec2 p, Vec2[] q)
    {
        var area = 0.0;
        for (var i = 0; i < 4; i++)
        {
            area += q[i].X * q[(i + 1) % 4].Y - q[(i + 1) % 4].X * q[i].Y;
        }
        if (Math.Abs(area) / 2 < MinPlaneArea)
        {
            return false;
        }
        var sign = 0;
        for (var i = 0; i < 4; i++)
        {
            var (a, b) = (q[i], q[(i + 1) % 4]);
            var cross = (b.X - a.X) * (p.Y - a.Y) - (b.Y - a.Y) * (p.X - a.X);
            var s = Math.Sign(cross);
            if (s != 0 && sign != 0 && s != sign)
            {
                return false;
            }
            sign = s != 0 ? s : sign;
        }
        return true;
    }
}

/// <summary>The steps that snapping rounds to: meters, degrees, and a scale factor.</summary>
public readonly record struct Snapping(double Meters, double Degrees, double Factor)
{
    public static Snapping Default => new(0.25, 15, 0.1);

    public static double Round(double value, double step) => step > 0 ? Math.Round(value / step) * step : value;
}

/// <summary>
/// A drag of a gizmo part, from the press to the release (see docs/editor/viewport.md#viewport). Each mouse position gives the
/// change from where the drag started. The camera is the one at the press, so flying during a drag does not move the
/// selection.
/// </summary>
public sealed class GizmoDrag
{
    readonly GizmoKind _kind;
    readonly EditorCamera _camera;
    readonly Vec3 _center;
    readonly Quat _axes;
    readonly double _size;
    readonly double _width;
    readonly double _height;
    readonly Vec2 _start;
    readonly Vec3? _grab;
    readonly double _grabAlong;
    double _angle;
    double _lastAngle;

    public GizmoPart Part { get; }

    public GizmoDrag(GizmoKind kind, GizmoPart part, EditorCamera camera, Vec3 center, Quat axes, Vec2 mouse, double width, double height)
    {
        (_kind, Part, _camera, _center, _axes, _width, _height, _start) = (kind, part, camera.Clone(), center, axes, width, height, mouse);
        _size = Gizmo.Size(camera, center, height);
        var ray = Ray(mouse);
        if (AxisIndex(part) is { } i)
        {
            _grabAlong = Along(Gizmo.Axis(axes, i), ray) ?? 0;
        }
        _grab = Plane(PlaneNormal(), ray);
        _lastAngle = Angle(mouse) ?? 0;
    }

    /// <summary>The change from the press to this point, rounded to the steps when snapping is on.</summary>
    public GizmoChange Update(Vec2 mouse, Snapping? snap)
    {
        var ray = Ray(mouse);
        switch (_kind)
        {
            case GizmoKind.Translate:
                return GizmoChange.None with { Translation = Translation(ray, snap) };
            case GizmoKind.Rotate:
                if (Angle(mouse) is { } angle)
                {
                    // The angle grows past half a turn, so a drag can turn the selection more than once around.
                    _angle += Math.IEEERemainder(angle - _lastAngle, 2 * Math.PI);
                    _lastAngle = angle;
                }
                var turned = snap is { } s ? Snapping.Round(_angle, s.Degrees * Math.PI / 180) : _angle;
                return GizmoChange.None with { Rotation = Rotations.AxisAngle(RotationAxis(), turned) };
            case GizmoKind.Scale:
                double factor;
                if (Part == GizmoPart.View)
                {
                    factor = 1 + (mouse.X - _start.X) / Gizmo.ScreenLength;
                }
                else
                {
                    var along = Along(Gizmo.Axis(_axes, AxisIndex(Part)!.Value), ray) ?? _grabAlong;
                    factor = Math.Abs(_grabAlong) > 0.2 * _size ? along / _grabAlong : 1 + (along - _grabAlong) / _size;
                }
                if (snap is { } step)
                {
                    factor = Snapping.Round(factor, step.Factor);
                }
                // A factor of 0 would lose the entity's size for good.
                factor = Math.Abs(factor) < 1e-3 ? 1e-3 : factor;
                var scale = Part switch
                {
                    GizmoPart.X => new Vec3(factor, 1, 1),
                    GizmoPart.Y => new Vec3(1, factor, 1),
                    GizmoPart.Z => new Vec3(1, 1, factor),
                    _ => new Vec3(factor, factor, factor),
                };
                return GizmoChange.None with { Scale = scale };
            default:
                return GizmoChange.None;
        }
    }

    Vec3 Translation(Vec3 ray, Snapping? snap)
    {
        if (AxisIndex(Part) is { } i)
        {
            var axis = Gizmo.Axis(_axes, i);
            var along = (Along(axis, ray) ?? _grabAlong) - _grabAlong;
            return axis * (snap is { } s ? Snapping.Round(along, s.Meters) : along);
        }
        if (_grab is not { } grab || Plane(PlaneNormal(), ray) is not { } hit)
        {
            return Vec3.Zero;
        }
        var moved = hit - grab;
        if (snap is not { } step)
        {
            return moved;
        }
        // A plane snaps along its two axes, and the view's plane along the world's.
        if (Part == GizmoPart.View)
        {
            return new Vec3(Snapping.Round(moved.X, step.Meters), Snapping.Round(moved.Y, step.Meters), Snapping.Round(moved.Z, step.Meters));
        }
        var (a, b) = PlaneAxes();
        return a * Snapping.Round(Vec3.Dot(moved, a), step.Meters) + b * Snapping.Round(Vec3.Dot(moved, b), step.Meters);
    }

    Vec3 Ray(Vec2 mouse) => _camera.Ray(mouse, _width, _height);

    static int? AxisIndex(GizmoPart part) => part switch { GizmoPart.X => 0, GizmoPart.Y => 1, GizmoPart.Z => 2, _ => null };

    (Vec3, Vec3) PlaneAxes() => Part switch
    {
        GizmoPart.XY => (Gizmo.Axis(_axes, 0), Gizmo.Axis(_axes, 1)),
        GizmoPart.YZ => (Gizmo.Axis(_axes, 1), Gizmo.Axis(_axes, 2)),
        _ => (Gizmo.Axis(_axes, 2), Gizmo.Axis(_axes, 0)),
    };

    Vec3 PlaneNormal() => Part switch
    {
        GizmoPart.XY => Gizmo.Axis(_axes, 2),
        GizmoPart.YZ => Gizmo.Axis(_axes, 0),
        GizmoPart.ZX => Gizmo.Axis(_axes, 1),
        _ => _camera.Forward,
    };

    Vec3 RotationAxis() => AxisIndex(Part) is { } i ? Gizmo.Axis(_axes, i) : _camera.Forward;

    // How far along an axis through the center the ray passes closest, in meters, or null when they are parallel.
    double? Along(Vec3 axis, Vec3 ray)
    {
        var b = Vec3.Dot(axis, ray);
        var denominator = 1 - b * b;
        if (denominator < 1e-6)
        {
            return null;
        }
        // The ray starts at the camera, which is the origin here.
        var d = Vec3.Dot(axis, _center);
        var e = Vec3.Dot(ray, _center);
        return (b * e - d) / denominator;
    }

    // Where the ray meets the plane through the center, or null when it runs along it or away from it.
    Vec3? Plane(Vec3 normal, Vec3 ray)
    {
        var facing = Vec3.Dot(normal, ray);
        if (Math.Abs(facing) < 1e-6)
        {
            return null;
        }
        var t = Vec3.Dot(normal, _center) / facing;
        return t > 0 ? ray * t : null;
    }

    // The angle of the mouse about the rotation axis, in radians, counterclockwise as the axis points at the viewer. A
    // ring seen nearly edge on, and the view's ring, use the angle on screen about the center, with the sign that a
    // small turn about the axis has there.
    double? Angle(Vec2 mouse)
    {
        var axis = RotationAxis();
        var (u, w) = Basis(axis);
        if (Part != GizmoPart.View && Math.Abs(Vec3.Dot(axis, _center.Normalized())) > 0.15 && Plane(axis, Ray(mouse)) is { } hit)
        {
            var v = hit - _center;
            return Math.Atan2(Vec3.Dot(v, w), Vec3.Dot(v, u));
        }
        if (_camera.Project(_center, _width, _height) is not { } c
            || _camera.Project(_center + u * _size, _width, _height) is not { } a
            || _camera.Project(_center + Rotations.AxisAngle(axis, 0.1).Rotate(u) * _size, _width, _height) is not { } b)
        {
            return null;
        }
        double ScreenAngle(Vec2 p) => Math.Atan2(p.Y - c.Y, p.X - c.X);
        var sign = Math.Sign(Math.IEEERemainder(ScreenAngle(b) - ScreenAngle(a), 2 * Math.PI));
        return sign == 0 ? null : sign * ScreenAngle(mouse);
    }

    // Two unit vectors that span the plane normal to an axis, with u × w = axis.
    static (Vec3 U, Vec3 W) Basis(Vec3 axis)
    {
        var helper = Math.Abs(axis.Y) < 0.9 ? Vec3.UnitY : Vec3.UnitX;
        var u = Vec3.Cross(helper, axis).Normalized();
        return (u, Vec3.Cross(axis, u));
    }
}
