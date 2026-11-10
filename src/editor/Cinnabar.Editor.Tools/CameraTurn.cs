using Wire = Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Tools;

/// <summary>Where a camera is and how it looks, to tell whether anything moved it.</summary>
public readonly record struct CameraPose(long X, long Y, long Z, double Yaw, double Pitch, Wire.CameraProjection Projection, double OrthographicHeight, double PivotDistance);

/// <summary>
/// A camera's turn about its pivot to look along an axis, over a short time, as the view gizmo starts it (see
/// docs/editor/viewport.md#view-gizmo). The heading takes the short way round. A turn to a perspective camera has
/// perspective from its first step, and a turn to an orthographic one keeps the camera's projection until its last.
/// </summary>
/// <param name="Pivot">The pivot, as a raw World_Position, which stays where it is.</param>
/// <param name="Distance">How far a perspective camera stands from the pivot, which keeps what is there as large.</param>
/// <param name="Last">The camera's pose when the turn started, then the one that the turn last gave it: a camera whose pose differs has been moved by something else.</param>
/// <param name="Elapsed">The milliseconds that the turn has run.</param>
public sealed record CameraTurn(
    long[] Pivot,
    double Distance,
    double FromYaw,
    double FromPitch,
    double ToYaw,
    double ToPitch,
    Wire.CameraProjection Projection,
    CameraPose Last,
    double Elapsed = 0)
{
    /// <summary>How long a turn takes, in milliseconds.</summary>
    public const double Duration = 200;

    /// <summary>A turn of a camera from where it looks now, about its pivot.</summary>
    public static CameraTurn Of(EditorCamera camera, double toYaw, double toPitch, Wire.CameraProjection projection) =>
        new(camera.Pivot, camera.ViewDistance, camera.Yaw, camera.Pitch, toYaw, toPitch, projection, camera.Pose);

    /// <summary>How far the turn has gone, from 0 to 1.</summary>
    public double Progress => Math.Clamp(Elapsed / Duration, 0, 1);

    /// <summary>The heading and the pitch at a point of the turn, eased in and out.</summary>
    public (double Yaw, double Pitch) At(double t)
    {
        t = Math.Clamp(t, 0, 1);
        if (t >= 1)
        {
            return (ToYaw, ToPitch);
        }
        var s = t * t * (3 - 2 * t);
        return (Math.IEEERemainder(FromYaw + Math.IEEERemainder(ToYaw - FromYaw, 2 * Math.PI) * s, 2 * Math.PI), FromPitch + (ToPitch - FromPitch) * s);
    }

    /// <summary>Puts the camera where the turn is after some more milliseconds, and gives the turn with the pose that it set.</summary>
    public CameraTurn Step(EditorCamera camera, double milliseconds)
    {
        var turn = this with { Elapsed = Elapsed + Math.Max(milliseconds, 0) };
        var t = turn.Progress;
        var (yaw, pitch) = turn.At(t);
        var projection = t >= 1 || Projection == Wire.CameraProjection.Perspective ? Projection : camera.Projection;
        camera.LookAt(Pivot, Distance, yaw, pitch, projection);
        return turn with { Last = camera.Pose };
    }

    /// <summary>Whether the turn has reached its end.</summary>
    public bool Done => Progress >= 1;

    /// <summary>Whether something other than the turn has moved the camera since the turn last did.</summary>
    public bool Moved(EditorCamera camera) => camera.Pose != Last;
}
