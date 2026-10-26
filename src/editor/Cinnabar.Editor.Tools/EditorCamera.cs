using Cinnabar.Editor.Document;
using Wire = Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Tools;

/// <summary>
/// The editor's camera in edit mode (see docs/editor/viewport.md#viewport): a position, a heading and a pitch, and a pivot ahead
/// of it, which orbiting turns around and dollying approaches. The camera looks down its +z, with +y up and +x right,
/// as the engine's views do. The editor sends it to the game whenever it changes, so a host restart keeps the view.
/// </summary>
public sealed class EditorCamera
{
    public const double DefaultFov = 60 * Math.PI / 180;
    public const double DefaultNear = 0.05;
    // Radians per pixel of mouse movement, for looking and orbiting.
    const double TurnRate = 0.005;
    // Pitch stops short of straight up and down, where the heading is undefined.
    const double MaxPitch = 89 * Math.PI / 180;
    // Each wheel notch of a dolly takes the camera this much of the way to the pivot.
    const double DollyStep = 0.15;
    const double MinPivotDistance = 0.01;

    /// <summary>A raw World_Position, in units of 2^-24 m.</summary>
    public long[] Position { get; private set; } = [0, 0, 0];

    /// <summary>The heading: a turn about the world's +y, in radians.</summary>
    public double Yaw { get; private set; }

    /// <summary>A turn about the camera's +x, in radians. Positive looks down.</summary>
    public double Pitch { get; private set; }

    public double VerticalFov { get; init; } = DefaultFov;
    public double Near { get; init; } = DefaultNear;

    /// <summary>How far ahead the pivot is, in meters.</summary>
    public double PivotDistance { get; private set; } = 5;

    /// <summary>Flying speed in meters per second.</summary>
    public double Speed { get; private set; } = 4;

    public event Action? Changed;

    public Quat Rotation => (Rotations.AxisAngle(Vec3.UnitY, Yaw) * Rotations.AxisAngle(Vec3.UnitX, Pitch)).Normalized();

    public Vec3 Forward => Rotation.Rotate(Vec3.UnitZ);
    public Vec3 Right => Rotation.Rotate(Vec3.UnitX);
    public Vec3 Up => Rotation.Rotate(Vec3.UnitY);

    /// <summary>The point that orbiting turns around, as a raw World_Position.</summary>
    public long[] Pivot => (Forward * PivotDistance).Offset(Position);

    public EditorCamera Clone() => (EditorCamera)MemberwiseClone();

    /// <summary>Turns the camera in place, by pixels of mouse movement.</summary>
    public void Look(double dx, double dy)
    {
        Turn(dx * TurnRate, dy * TurnRate);
        Changed?.Invoke();
    }

    /// <summary>Moves along the camera's own axes: x right, y up and z forward, each from -1 to 1, at the flying speed.</summary>
    public void Fly(Vec3 direction, double seconds, double boost = 1)
    {
        if (direction == Vec3.Zero)
        {
            return;
        }
        var world = Right * direction.X + Up * direction.Y + Forward * direction.Z;
        Position = (world.Normalized() * (Speed * boost * seconds)).Offset(Position);
        Changed?.Invoke();
    }

    /// <summary>Scales the flying speed, as the wheel does while flying.</summary>
    public void ChangeSpeed(double notches)
    {
        Speed = Math.Clamp(Speed * Math.Pow(1.25, notches), 0.05, 1e7);
        Changed?.Invoke();
    }

    /// <summary>Turns about the pivot, by pixels of mouse movement, so the pivot stays where it is on screen.</summary>
    public void Orbit(double dx, double dy)
    {
        var pivot = Pivot;
        Turn(dx * TurnRate, dy * TurnRate);
        Position = (-Forward * PivotDistance).Offset(pivot);
        Changed?.Invoke();
    }

    /// <summary>
    /// Turns about a point, by pixels of mouse movement, so the point stays where it is on screen, as orbiting about
    /// the selection does. The pivot ahead goes to the point's distance along the view's axis.
    /// </summary>
    public void OrbitAround(long[] point, double dx, double dy)
    {
        var offset = Vec3.Between(point, Position);
        var (yaw, pitch) = (Yaw, Pitch);
        var right = Right;
        Turn(dx * TurnRate, dy * TurnRate);
        // The heading turns about the world's +y and the pitch about the camera's right axis, so the camera's
        // offset from the point turns by the same rotation, pitch first.
        var turn = Rotations.AxisAngle(Vec3.UnitY, Yaw - yaw) * Rotations.AxisAngle(right, Pitch - pitch);
        Position = turn.Rotate(offset).Offset(point);
        PivotDistance = Math.Max(Vec3.Dot(Vec3.Between(Position, point), Forward), MinPivotDistance);
        Changed?.Invoke();
    }

    /// <summary>Moves in the view's plane so the pivot's plane follows the mouse, by pixels of a frame this tall.</summary>
    public void Pan(double dx, double dy, double height)
    {
        var meters = PixelSize(PivotDistance, height);
        Position = (Right * (-dx * meters) + Up * (dy * meters)).Offset(Position);
        Changed?.Invoke();
    }

    /// <summary>Moves toward the pivot, or away from it with a negative count, by wheel notches.</summary>
    public void Dolly(double notches)
    {
        var pivot = Pivot;
        PivotDistance = Math.Max(PivotDistance * Math.Pow(1 - DollyStep, notches), MinPivotDistance);
        Position = (-Forward * PivotDistance).Offset(pivot);
        Changed?.Invoke();
    }

    /// <summary>Keeps the heading, and moves so a sphere around a point fills the view, with the point as the pivot.</summary>
    public void Frame(long[] center, double radius)
    {
        PivotDistance = Math.Max(radius, MinPivotDistance) / Math.Sin(VerticalFov / 2) * 1.1;
        Position = (-Forward * PivotDistance).Offset(center);
        Changed?.Invoke();
    }

    /// <summary>Places the camera, for a restored view or a test.</summary>
    public void Place(long[] position, double yaw, double pitch)
    {
        Position = [.. position];
        Yaw = yaw;
        Pitch = Math.Clamp(pitch, -MaxPitch, MaxPitch);
        Changed?.Invoke();
    }

    void Turn(double yaw, double pitch)
    {
        Yaw = Math.IEEERemainder(Yaw + yaw, 2 * Math.PI);
        Pitch = Math.Clamp(Pitch + pitch, -MaxPitch, MaxPitch);
    }

    /// <summary>The meters that a pixel covers at a distance along the view's axis, in a frame this tall.</summary>
    public double PixelSize(double distance, double height) => 2 * distance * Math.Tan(VerticalFov / 2) / Math.Max(height, 1);

    /// <summary>A raw World_Position relative to the camera, in meters.</summary>
    public Vec3 RelativeTo(long[] position) => Vec3.Between(Position, position);

    /// <summary>The direction through a point of a frame of this size, in the world.</summary>
    public Vec3 Ray(Vec2 pixel, double width, double height)
    {
        var tan = Math.Tan(VerticalFov / 2);
        var x = (2 * pixel.X / width - 1) * tan * width / height;
        var y = (1 - 2 * pixel.Y / height) * tan;
        return (Forward + Right * x + Up * y).Normalized();
    }

    /// <summary>Where a point relative to the camera shows in a frame of this size, or null for one behind the camera.</summary>
    public Vec2? Project(Vec3 relative, double width, double height)
    {
        var z = Vec3.Dot(relative, Forward);
        if (z <= Near * 0.5)
        {
            return null;
        }
        var tan = Math.Tan(VerticalFov / 2);
        var x = Vec3.Dot(relative, Right) / (z * tan * width / height);
        var y = Vec3.Dot(relative, Up) / (z * tan);
        return new Vec2((x + 1) * width / 2, (1 - y) * height / 2);
    }

    public Wire.EditorCamera ToMessage()
    {
        var q = Rotation;
        return new Wire.EditorCamera([.. Position], [(float)q.X, (float)q.Y, (float)q.Z, (float)q.W], (float)VerticalFov, (float)Near);
    }
}
