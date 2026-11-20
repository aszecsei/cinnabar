using System.Buffers.Binary;
using System.Globalization;
using Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// A camera's lens in words, which the Properties panel shows under its Camera (see
/// docs/editor/shell-and-panels.md#properties): its field of view and its focal length, whichever it sets, and its
/// depth of field (see docs/rendering/post-processing.md#depth-of-field).
/// </summary>
public static class CameraLensText
{
    /// <summary>render.CAMERA_ID.</summary>
    public const ulong CameraId = 32;
    // render.DEFAULT_VERTICAL_FOV and render.DEFAULT_SENSOR_HEIGHT.
    const double DefaultVerticalFov = Math.PI / 3;
    const double DefaultSensorHeight = 24;

    /// <summary>The lens of a Camera component's bytes, or null if they do not hold one.</summary>
    public static string? Describe(IReadOnlyList<FieldInfo> fields, ReadOnlySpan<byte> data)
    {
        var values = new Dictionary<string, double>();
        foreach (var field in fields)
        {
            if (field.Kind == FieldKind.F32 && field.Offset + 4 <= data.Length)
            {
                values[field.Name] = BinaryPrimitives.ReadSingleLittleEndian(data[(int)field.Offset..]);
            }
            else if (field.Name == "projection" && field.Offset < data.Length)
            {
                values[field.Name] = data[(int)field.Offset];
            }
            else if (field.Kind == FieldKind.Entity && field.Name == "focus" && field.Offset + 8 <= data.Length)
            {
                values[field.Name] = BinaryPrimitives.ReadUInt64LittleEndian(data[(int)field.Offset..]) != 0 ? 1 : 0;
            }
        }
        if (!values.ContainsKey("vertical_fov"))
        {
            return null;
        }
        if (values.GetValueOrDefault("projection") != 0)
        {
            return "Orthographic: no lens, and no depth of field.";
        }
        var focal = values.GetValueOrDefault("focal_length");
        var sensor = values.GetValueOrDefault("sensor_height") is > 0 and var s ? s : DefaultSensorHeight;
        string lens;
        if (focal > 0)
        {
            var fov = 2 * Math.Atan(sensor / (2 * focal));
            lens = $"A {Mm(focal)} lens on a {Mm(sensor)} sensor: {Degrees(fov)} vertical.";
        }
        else
        {
            var fov = values.GetValueOrDefault("vertical_fov") is > 0 and var v ? v : DefaultVerticalFov;
            lens = $"{Degrees(fov)} vertical: a {Mm(sensor / (2 * Math.Tan(fov / 2)))} lens on a {Mm(sensor)} sensor.";
        }
        var aperture = values.GetValueOrDefault("aperture");
        if (aperture <= 0)
        {
            return lens + " No depth of field: the aperture is 0.";
        }
        var focus = values.GetValueOrDefault("focus") != 0
            ? "on the focus entity"
            : $"at {Number(values.GetValueOrDefault("focus_distance") is > 0 and var d ? d : 10)} m";
        return lens + $" f/{Number(aperture)}, focused {focus}.";
    }

    static string Number(double v) => v.ToString("0.#", CultureInfo.InvariantCulture);
    static string Mm(double v) => Number(v) + " mm";
    static string Degrees(double radians) => Number(radians * 180 / Math.PI) + "°";
}
