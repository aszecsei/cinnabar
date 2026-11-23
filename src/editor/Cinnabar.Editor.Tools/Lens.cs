namespace Cinnabar.Editor.Tools;

/// <summary>
/// A cinematic camera's lens (see docs/rendering/assets.md#components): its focal length and its sensor's height set its
/// vertical field of view, as the runtime's <c>render.cinematic_vertical_fov</c> does, with its defaults for values of 0
/// or less.
/// </summary>
public static class Lens
{
    public const double DefaultFocalLength = 35;
    public const double DefaultSensorWidth = 36;
    public const double DefaultSensorHeight = 24;
    public const double DefaultFocusDistance = 10;

    /// <summary>The vertical field of view in radians: 2 × atan(sensor height / (2 × focal length)).</summary>
    public static double VerticalFov(double focalLength, double sensorHeight)
    {
        var focal = focalLength > 0 ? focalLength : DefaultFocalLength;
        var sensor = sensorHeight > 0 ? sensorHeight : DefaultSensorHeight;
        return 2 * Math.Atan(sensor / (2 * focal));
    }

    /// <summary>The focal length in millimeters that gives a vertical field of view on a sensor: the inverse of <see cref="VerticalFov"/>.</summary>
    public static double FocalLength(double verticalFov, double sensorHeight)
    {
        var sensor = sensorHeight > 0 ? sensorHeight : DefaultSensorHeight;
        return sensor / (2 * Math.Tan(Math.Clamp(verticalFov, 1e-4, Math.PI - 1e-4) / 2));
    }
}
