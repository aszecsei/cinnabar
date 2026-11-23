using System.Buffers.Binary;
using System.Globalization;
using Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// A cinematic camera's lens in words, which the Properties panel shows under its Cinematic Camera (see
/// docs/editor/shell-and-panels.md#properties): the field of view that its focal length gives on its sensor, the
/// sensor's aspect, and its depth of field (see docs/rendering/post-processing.md#depth-of-field). Also the sensor
/// presets that the panel offers.
/// </summary>
public static class CinematicCameraText
{
    /// <summary>render.CINEMATIC_CAMERA_ID.</summary>
    public const ulong CinematicCameraId = 160;
    // render.DEFAULT_FOCAL_LENGTH, DEFAULT_SENSOR_WIDTH, DEFAULT_SENSOR_HEIGHT and DEFAULT_FOCUS_DISTANCE.
    const double DefaultFocalLength = 35;
    const double DefaultSensorWidth = 36;
    const double DefaultSensorHeight = 24;
    const double DefaultFocusDistance = 10;

    /// <summary>Sensors by name, in millimeters.</summary>
    public static readonly IReadOnlyList<(string Name, double Width, double Height)> SensorPresets =
    [
        ("Full frame", 36, 24),
        ("Super 35", 24.89, 18.66),
        ("Super 16", 12.52, 7.41),
        ("IMAX 70 mm", 70.41, 52.63),
    ];

    /// <summary>The name of the preset that a sensor's size is, or null.</summary>
    public static string? SensorName(double width, double height)
    {
        width = width > 0 ? width : DefaultSensorWidth;
        height = height > 0 ? height : DefaultSensorHeight;
        foreach (var (name, w, h) in SensorPresets)
        {
            if (Math.Abs(w - width) < 0.005 && Math.Abs(h - height) < 0.005)
            {
                return name;
            }
        }
        return null;
    }

    /// <summary>The lens of a Cinematic_Camera component's bytes, or null if they do not hold one.</summary>
    public static string? Describe(IReadOnlyList<FieldInfo> fields, ReadOnlySpan<byte> data)
    {
        var values = Values(fields, data);
        if (!values.ContainsKey("focal_length"))
        {
            return null;
        }
        var focal = values.GetValueOrDefault("focal_length") is > 0 and var f ? f : DefaultFocalLength;
        var width = values.GetValueOrDefault("sensor_width") is > 0 and var w ? w : DefaultSensorWidth;
        var height = values.GetValueOrDefault("sensor_height") is > 0 and var h ? h : DefaultSensorHeight;
        var fov = Tools.Lens.VerticalFov(focal, height);
        var preset = SensorName(width, height) is { } name ? $" ({name})" : "";
        var lens = $"A {Mm(focal)} lens on a {Number(width, "0.##")} × {Mm(height)} sensor{preset}: {Degrees(fov)} vertical, {Number(width / height, "0.##")}:1.";
        var aperture = values.GetValueOrDefault("aperture");
        if (aperture <= 0)
        {
            return lens + " No depth of field: the aperture is 0.";
        }
        var focus = values.GetValueOrDefault("focus") != 0
            ? "on the focus entity"
            : $"at {Number(values.GetValueOrDefault("focus_distance") is > 0 and var d ? d : DefaultFocusDistance)} m";
        return lens + $" f/{Number(aperture)}, focused {focus}.";
    }

    /// <summary>The sensor's width and height in a Cinematic_Camera component's bytes, 0 for a field that is not there.</summary>
    public static (double Width, double Height) Sensor(IReadOnlyList<FieldInfo> fields, ReadOnlySpan<byte> data)
    {
        var values = Values(fields, data);
        return (values.GetValueOrDefault("sensor_width"), values.GetValueOrDefault("sensor_height"));
    }

    static Dictionary<string, double> Values(IReadOnlyList<FieldInfo> fields, ReadOnlySpan<byte> data)
    {
        var values = new Dictionary<string, double>();
        foreach (var field in fields)
        {
            if (field.Kind == FieldKind.F32 && field.Offset + 4 <= data.Length)
            {
                values[field.Name] = BinaryPrimitives.ReadSingleLittleEndian(data[(int)field.Offset..]);
            }
            else if (field.Kind == FieldKind.Entity && field.Name == "focus" && field.Offset + 8 <= data.Length)
            {
                values[field.Name] = BinaryPrimitives.ReadUInt64LittleEndian(data[(int)field.Offset..]) != 0 ? 1 : 0;
            }
        }
        return values;
    }

    static string Number(double v, string format = "0.#") => v.ToString(format, CultureInfo.InvariantCulture);
    static string Mm(double v) => Number(v, "0.##") + " mm";
    static string Degrees(double radians) => Number(radians * 180 / Math.PI) + "°";
}
