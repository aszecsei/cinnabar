using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;
using Wire = Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Tools;

/// <summary>
/// A line of sight through a point of a frame, relative to the camera's position: from the camera itself along the
/// pixel's direction in perspective, and from the pixel's own point of the camera's plane along the view in
/// orthographic, where every pixel looks the same way.
/// </summary>
public readonly record struct ViewRay(Vec3 Origin, Vec3 Direction)
{
    public Vec3 At(double distance) => Origin + Direction * distance;
}

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
    public const double MaxPitch = 89 * Math.PI / 180;
    // Each wheel notch of a dolly takes the camera this much of the way to the pivot.
    const double DollyStep = 0.15;
    const double MinPivotDistance = 0.01;
    const double MinOrthographicHeight = 0.001;
    // An orthographic camera is at least this far from its pivot, in meters, and sees this far.
    public const double OrthographicStandoff = 50;
    public const double OrthographicFar = 10000;

    /// <summary>A raw World_Position, in units of 2^-24 m.</summary>
    public long[] Position { get; private set; } = [0, 0, 0];

    /// <summary>The heading: a turn about the world's +y, in radians.</summary>
    public double Yaw { get; private set; }

    /// <summary>A turn about the camera's +x, in radians. Positive looks down.</summary>
    public double Pitch { get; private set; }

    public double VerticalFov { get; init; } = DefaultFov;
    public double Near { get; init; } = DefaultNear;

    /// <summary>
    /// Perspective, or orthographic, without perspective (see docs/editor/viewport.md#projection). Only
    /// <see cref="SetProjection"/> changes it.
    /// </summary>
    public Wire.CameraProjection Projection { get; private set; } = Wire.CameraProjection.Perspective;

    public bool IsOrthographic => Projection == Wire.CameraProjection.Orthographic;

    /// <summary>What an orthographic camera shows from its bottom to its top, in meters. Zooming changes it.</summary>
    public double OrthographicHeight { get; private set; } = 10;

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

    /// <summary>
    /// How far a perspective camera would stand from the pivot to show what this one shows there: its pivot's distance,
    /// or for an orthographic camera, the distance that shows its height.
    /// </summary>
    public double ViewDistance => IsOrthographic ? OrthographicHeight / (2 * Math.Tan(VerticalFov / 2)) : PivotDistance;

    /// <summary>Where the camera is and how it looks, to tell whether anything moved it.</summary>
    public CameraPose Pose => new(Position[0], Position[1], Position[2], Yaw, Pitch, Projection, OrthographicHeight, PivotDistance);

    public EditorCamera Clone() => (EditorCamera)MemberwiseClone();

    /// <summary>
    /// Changes the projection, so that what is at the pivot stays as large on screen: an orthographic camera shows the
    /// height that the perspective one showed at the pivot, and a perspective one stands back to where it shows the
    /// orthographic one's height. An orthographic camera stands at least <see cref="OrthographicStandoff"/> from its
    /// pivot, since it clips what is behind it.
    /// </summary>
    public void SetProjection(Wire.CameraProjection projection)
    {
        if (projection == Projection)
        {
            return;
        }
        var pivot = Pivot;
        if (projection == Wire.CameraProjection.Orthographic)
        {
            OrthographicHeight = Math.Max(2 * PivotDistance * Math.Tan(VerticalFov / 2), MinOrthographicHeight);
            PivotDistance = Math.Max(PivotDistance, OrthographicStandoff);
        }
        else
        {
            PivotDistance = Math.Max(OrthographicHeight / (2 * Math.Tan(VerticalFov / 2)), MinPivotDistance);
        }
        Projection = projection;
        Position = (-Forward * PivotDistance).Offset(pivot);
        Changed?.Invoke();
    }

    /// <summary>Sets what an orthographic camera shows from its bottom to its top, for a restored view or a test.</summary>
    public void SetOrthographicHeight(double height)
    {
        OrthographicHeight = Math.Max(height, MinOrthographicHeight);
        Changed?.Invoke();
    }

    /// <summary>Turns the camera in place, by pixels of mouse movement. A camera that turns freely has perspective.</summary>
    public void Look(double dx, double dy)
    {
        SetProjection(Wire.CameraProjection.Perspective);
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

    /// <summary>
    /// Turns about the pivot, by pixels of mouse movement, so the pivot stays where it is on screen. An orthographic
    /// camera that orbits becomes a perspective one.
    /// </summary>
    public void Orbit(double dx, double dy)
    {
        SetProjection(Wire.CameraProjection.Perspective);
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
        SetProjection(Wire.CameraProjection.Perspective);
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

    /// <summary>
    /// Moves toward the pivot, or away from it with a negative count, by wheel notches. An orthographic camera zooms in
    /// its place: it shows less, or more.
    /// </summary>
    public void Dolly(double notches)
    {
        if (IsOrthographic)
        {
            OrthographicHeight = Math.Max(OrthographicHeight * Math.Pow(1 - DollyStep, notches), MinOrthographicHeight);
            Changed?.Invoke();
            return;
        }
        var pivot = Pivot;
        PivotDistance = Math.Max(PivotDistance * Math.Pow(1 - DollyStep, notches), MinPivotDistance);
        Position = (-Forward * PivotDistance).Offset(pivot);
        Changed?.Invoke();
    }

    /// <summary>Keeps the heading, and moves so a sphere around a point fills the view, with the point as the pivot.</summary>
    public void Frame(long[] center, double radius)
    {
        if (IsOrthographic)
        {
            OrthographicHeight = Math.Max(radius * 2.2, MinOrthographicHeight);
            PivotDistance = Math.Max(radius * 2, OrthographicStandoff);
            Position = (-Forward * PivotDistance).Offset(center);
            Changed?.Invoke();
            return;
        }
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

    /// <summary>Looks along a heading and a pitch at a pivot, from a distance in front of it: the camera moves back from the pivot, which stays where it is.</summary>
    public void LookAt(long[] pivot, double distance, double yaw, double pitch)
    {
        Yaw = yaw;
        Pitch = Math.Clamp(pitch, -MaxPitch, MaxPitch);
        PivotDistance = Math.Max(distance, MinPivotDistance);
        Position = (-Forward * PivotDistance).Offset(pivot);
        Changed?.Invoke();
    }

    /// <summary>
    /// Looks along a heading and a pitch at a pivot with a projection, as a view starts: what is at the pivot shows as
    /// large as a perspective camera shows it from that distance.
    /// </summary>
    public void LookAt(long[] pivot, double distance, double yaw, double pitch, Wire.CameraProjection projection)
    {
        Yaw = yaw;
        Pitch = Math.Clamp(pitch, -MaxPitch, MaxPitch);
        PivotDistance = Math.Max(distance, MinPivotDistance);
        Projection = projection;
        if (IsOrthographic)
        {
            OrthographicHeight = Math.Max(2 * PivotDistance * Math.Tan(VerticalFov / 2), MinOrthographicHeight);
            PivotDistance = Math.Max(PivotDistance, OrthographicStandoff);
        }
        Position = (-Forward * PivotDistance).Offset(pivot);
        Changed?.Invoke();
    }

    void Turn(double yaw, double pitch)
    {
        Yaw = Math.IEEERemainder(Yaw + yaw, 2 * Math.PI);
        Pitch = Math.Clamp(Pitch + pitch, -MaxPitch, MaxPitch);
    }

    /// <summary>
    /// The meters that a pixel covers at a distance along the view's axis, in a frame this tall: the same at every
    /// distance for an orthographic camera.
    /// </summary>
    public double PixelSize(double distance, double height) =>
        (IsOrthographic ? OrthographicHeight : 2 * distance * Math.Tan(VerticalFov / 2)) / Math.Max(height, 1);

    /// <summary>The direction in which the camera sees a point relative to it: from itself, or along its view.</summary>
    public Vec3 ViewDirection(Vec3 relative) => IsOrthographic ? Forward : relative.Normalized();

    /// <summary>A raw World_Position relative to the camera, in meters.</summary>
    public Vec3 RelativeTo(long[] position) => Vec3.Between(Position, position);

    /// <summary>The line of sight through a point of a frame of this size, in the world, from the camera's position.</summary>
    public ViewRay Ray(Vec2 pixel, double width, double height)
    {
        // Half of what the frame shows at a distance of 1, or at every distance.
        var half = IsOrthographic ? OrthographicHeight / 2 : Math.Tan(VerticalFov / 2);
        var x = (2 * pixel.X / width - 1) * half * width / height;
        var y = (1 - 2 * pixel.Y / height) * half;
        return IsOrthographic
            ? new ViewRay(Right * x + Up * y, Forward)
            : new ViewRay(Vec3.Zero, (Forward + Right * x + Up * y).Normalized());
    }

    /// <summary>Where a point relative to the camera shows in a frame of this size, or null for one behind the camera.</summary>
    public Vec2? Project(Vec3 relative, double width, double height)
    {
        var z = Vec3.Dot(relative, Forward);
        if (z <= Near * 0.5)
        {
            return null;
        }
        var half = IsOrthographic ? OrthographicHeight / 2 : z * Math.Tan(VerticalFov / 2);
        var x = Vec3.Dot(relative, Right) / (half * width / height);
        var y = Vec3.Dot(relative, Up) / half;
        return new Vec2((x + 1) * width / 2, (1 - y) * height / 2);
    }

    /// <summary>The camera as the game takes it, for one of the editor's viewports.</summary>
    public Wire.EditorCamera ToMessage(uint viewport = 0)
    {
        var q = Rotation;
        return new Wire.EditorCamera(viewport, [.. Position], [(float)q.X, (float)q.Y, (float)q.Z, (float)q.W], (float)VerticalFov, (float)Near, Projection, (float)OrthographicHeight, (float)OrthographicFar);
    }
}
