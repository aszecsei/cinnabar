using System.Buffers.Binary;
using System.Globalization;
using Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Model;

/// <summary>How a field shows in the properties panel. A field's kind of display never changes with its value.</summary>
public enum DisplayKind
{
    Text,
    Number,
    /// <summary>Three values, x, y and z: vectors, positions and rotations.</summary>
    Axes,
    Bool,
    Entity,
    /// <summary>An asset reference: <see cref="FieldDisplay.Text"/> holds its GUID, or "" for none.</summary>
    Asset,
}

/// <summary>
/// A field's value, ready to show. <see cref="Text"/> is the whole value on one line, <see cref="Axes"/> holds the three
/// parts of an Axes value, and <see cref="Tooltip"/> what the display leaves out, such as a rotation's quaternion.
/// </summary>
public sealed record FieldDisplay(DisplayKind Kind, string Text, string[] Axes, bool Flag, ulong Entity, string? Tooltip)
{
    public static FieldDisplay Missing { get; } = new(DisplayKind.Text, "?", ["?", "?", "?"], false, 0, "The value is shorter than its type says.");
}

/// <summary>Reads a field out of a component's bytes, as the game laid them out (see <see cref="FieldInfo"/>).</summary>
public static class FieldValues
{
    // World_Position is in units of 2^-24 m.
    const double PositionUnit = 1.0 / (1 << 24);

    public static DisplayKind DisplayKindOf(FieldKind kind) => kind switch
    {
        FieldKind.Bool => DisplayKind.Bool,
        FieldKind.Entity => DisplayKind.Entity,
        FieldKind.Asset => DisplayKind.Asset,
        FieldKind.Vector3 or FieldKind.Quaternion or FieldKind.Position => DisplayKind.Axes,
        FieldKind.Enum => DisplayKind.Text,
        _ => DisplayKind.Number,
    };

    public static DisplayKind DisplayKindOf(BehaviourFieldKind kind) => kind switch
    {
        BehaviourFieldKind.Number => DisplayKind.Number,
        BehaviourFieldKind.Boolean => DisplayKind.Bool,
        BehaviourFieldKind.Vector => DisplayKind.Axes,
        BehaviourFieldKind.Entity => DisplayKind.Entity,
        _ => DisplayKind.Text,
    };

    /// <summary>A field's value from its component's bytes, or <see cref="FieldDisplay.Missing"/> if they are too short.</summary>
    public static FieldDisplay Display(FieldInfo field, ReadOnlySpan<byte> component)
    {
        var size = Size(field.Kind == FieldKind.Enum ? field.EnumBase : field.Kind);
        if (field.Offset + size > component.Length)
        {
            return FieldDisplay.Missing;
        }
        var data = component.Slice((int)field.Offset, size);
        switch (field.Kind)
        {
            case FieldKind.Bool:
                return Flag(data[0] != 0);
            case FieldKind.Entity:
                return Entity(BinaryPrimitives.ReadUInt64LittleEndian(data));
            case FieldKind.Asset:
                var guid = AssetGuid(data);
                return new FieldDisplay(DisplayKind.Asset, guid, [], false, 0, null);
            case FieldKind.Vector3:
                return Axes(F32(data, 0), F32(data, 1), F32(data, 2), "", null);
            case FieldKind.Position:
                double[] meters = [Meters(data, 0), Meters(data, 1), Meters(data, 2)];
                string[] parts = [Distance(meters[0]), Distance(meters[1]), Distance(meters[2])];
                return new FieldDisplay(DisplayKind.Axes, $"({string.Join(", ", parts)})", parts, false, 0,
                    $"In meters: ({string.Join(", ", meters.Select(Number))})");
            case FieldKind.Quaternion:
                var (x, y, z, w) = (F32(data, 0), F32(data, 1), F32(data, 2), F32(data, 3));
                var euler = Euler(x, y, z, w);
                return Axes(euler[0], euler[1], euler[2], "°",
                    $"Euler angles in degrees, applied z, then x, then y.\nQuaternion: ({Number(x)}, {Number(y)}, {Number(z)}, {Number(w)})");
            case FieldKind.Enum:
                var value = ReadInteger(field.EnumBase, data);
                return Text(EnumName(field, value), value.ToString(CultureInfo.InvariantCulture));
            case FieldKind.F32:
                return Text(Number(BinaryPrimitives.ReadSingleLittleEndian(data)), kind: DisplayKind.Number);
            case FieldKind.F64:
                return Text(Number(BinaryPrimitives.ReadDoubleLittleEndian(data)), kind: DisplayKind.Number);
            case FieldKind.U64:
                return Text(BinaryPrimitives.ReadUInt64LittleEndian(data).ToString("#,0", CultureInfo.InvariantCulture), kind: DisplayKind.Number);
            default:
                return Text(ReadInteger(field.Kind, data).ToString("#,0", CultureInfo.InvariantCulture), kind: DisplayKind.Number);
        }
    }

    /// <summary>A behaviour field's value.</summary>
    public static FieldDisplay Display(BehaviourField field) => field.Kind switch
    {
        BehaviourFieldKind.Number => Text(Number(field.Number), kind: DisplayKind.Number),
        BehaviourFieldKind.Boolean => Flag(field.Boolean),
        BehaviourFieldKind.String => Text($"\"{field.Text}\""),
        BehaviourFieldKind.Vector => Axes(field.Vector[0], field.Vector[1], field.Vector[2], "", null),
        BehaviourFieldKind.Entity => Entity(field.Entity),
        _ => Text("nil"),
    };

    /// <summary>The value on one line.</summary>
    public static string? Format(FieldInfo field, ReadOnlySpan<byte> component)
    {
        var display = Display(field, component);
        return display == FieldDisplay.Missing ? null : display.Text;
    }

    public static string Format(BehaviourField field) => Display(field).Text;

    /// <summary>The entity that an Entity field refers to, or 0.</summary>
    public static ulong Entity(FieldInfo field, ReadOnlySpan<byte> component) =>
        field.Kind == FieldKind.Entity && field.Offset + 8 <= component.Length
            ? BinaryPrimitives.ReadUInt64LittleEndian(component[(int)field.Offset..])
            : 0;

    /// <summary>An asset reference's 16 bytes as 32 lowercase hex digits, or "" for the zero GUID, which is none.</summary>
    public static string AssetGuid(ReadOnlySpan<byte> data) => data.IndexOfAnyExcept((byte)0) < 0 ? "" : Convert.ToHexStringLower(data);

    public static int Size(FieldKind kind) => kind switch
    {
        FieldKind.Bool or FieldKind.I8 or FieldKind.U8 => 1,
        FieldKind.I16 or FieldKind.U16 => 2,
        FieldKind.I32 or FieldKind.U32 or FieldKind.F32 => 4,
        FieldKind.I64 or FieldKind.U64 or FieldKind.F64 or FieldKind.Entity => 8,
        FieldKind.Vector3 => 12,
        FieldKind.Quaternion or FieldKind.Asset => 16,
        FieldKind.Position => 24,
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, "not a field of fixed size"),
    };

    /// <summary>
    /// The Euler angles of a rotation, in degrees, as the engine's <c>euler_of</c> gives them: applied z, then x, then
    /// y, as in Unity. Each is in (-180, 180], and x is in [-90, 90]. At gimbal lock, z is 0.
    /// </summary>
    public static double[] Euler(double x, double y, double z, double w)
    {
        // The rotation matrix's entries that the angles need, with m[row, column] as in the engine.
        var m02 = 2 * (x * z + y * w);
        var m10 = 2 * (x * y + z * w);
        var m11 = 1 - 2 * (x * x + z * z);
        var m12 = 2 * (y * z - x * w);
        var m22 = 1 - 2 * (x * x + y * y);
        // For Ry * Rx * Rz, m[1, 2] = -sin(x).
        var sx = Math.Clamp(-m12, -1, 1);
        double ex = Math.Asin(sx), ey, ez = 0;
        if (Math.Abs(sx) < 0.99999)
        {
            ey = Math.Atan2(m02, m22);
            ez = Math.Atan2(m10, m11);
        }
        else
        {
            var m00 = 1 - 2 * (y * y + z * z);
            var m20 = 2 * (x * z - y * w);
            ey = Math.Atan2(-m20, m00);
        }
        return [Degrees(ex), Degrees(ey), Degrees(ez)];
    }

    /// <summary>The rotation that Euler angles in degrees give, as the engine's <c>quaternion_euler</c> makes it: x, y, z, w.</summary>
    public static double[] Quaternion(double ex, double ey, double ez)
    {
        double Half(double degrees) => degrees * Math.PI / 360;
        var (sx, cx) = Math.SinCos(Half(ex));
        var (sy, cy) = Math.SinCos(Half(ey));
        var (sz, cz) = Math.SinCos(Half(ez));
        // qy * qx * qz, with qx about +X, qy about +Y and qz about +Z.
        return
        [
            cy * sx * cz + sy * cx * sz,
            sy * cx * cz - cy * sx * sz,
            cy * cx * sz - sy * sx * cz,
            cy * cx * cz + sy * sx * sz,
        ];
    }

    static double Degrees(double radians)
    {
        var degrees = radians * 180 / Math.PI;
        // (-180, 180], as the engine gives it.
        return degrees <= -180 ? degrees + 360 : degrees;
    }

    /// <summary>
    /// A number for people: grouped thousands, at most three decimals, and no negative zero, so float noise such as
    /// 0.700034 reads as 0.7.
    /// </summary>
    public static string Number(double value)
    {
        var text = value.ToString("#,0.###", CultureInfo.InvariantCulture);
        return text == "-0" ? "0" : text;
    }

    /// <summary>
    /// A distance in meters, in the largest of m, km, Mm and Gm that keeps the integer part under 10,000, so a
    /// position far from the origin still fits its box. The tooltip gives the exact meters.
    /// </summary>
    public static string Distance(double meters)
    {
        string[] units = ["m", "km", "Mm", "Gm"];
        var unit = 0;
        var value = meters;
        while (Math.Abs(value) >= 10_000 && unit < units.Length - 1)
        {
            value /= 1000;
            unit++;
        }
        return $"{Number(value)} {units[unit]}";
    }

    /// <summary><c>Previous_Transform</c> is "Previous Transform", and <c>inner.amount</c> is "Inner › Amount".</summary>
    public static string Humanize(string name) =>
        string.Join(" › ", name.Split('.').Select(part =>
            string.Join(" ", part.Split('_', StringSplitOptions.RemoveEmptyEntries)
                .Select(word => char.ToUpperInvariant(word[0]) + word[1..]))));

    static FieldDisplay Text(string text, string? tooltip = null, DisplayKind kind = DisplayKind.Text) =>
        new(kind, text, [], false, 0, tooltip);

    static FieldDisplay Flag(bool value) => new(DisplayKind.Bool, value ? "true" : "false", [], value, 0, null);

    static FieldDisplay Entity(ulong entity) => new(DisplayKind.Entity, EntityNode.Format(entity), [], false, entity, null);

    static FieldDisplay Axes(double x, double y, double z, string unit, string? tooltip)
    {
        string[] parts = [Number(x) + unit, Number(y) + unit, Number(z) + unit];
        return new(DisplayKind.Axes, $"({string.Join(", ", parts)})", parts, false, 0, tooltip);
    }

    static long ReadInteger(FieldKind kind, ReadOnlySpan<byte> data) => kind switch
    {
        FieldKind.I8 => (sbyte)data[0],
        FieldKind.U8 => data[0],
        FieldKind.I16 => BinaryPrimitives.ReadInt16LittleEndian(data),
        FieldKind.U16 => BinaryPrimitives.ReadUInt16LittleEndian(data),
        FieldKind.I32 => BinaryPrimitives.ReadInt32LittleEndian(data),
        FieldKind.U32 => BinaryPrimitives.ReadUInt32LittleEndian(data),
        FieldKind.I64 => BinaryPrimitives.ReadInt64LittleEndian(data),
        // Display reads U64 fields separately, so this is only an enum's base.
        FieldKind.U64 => (long)BinaryPrimitives.ReadUInt64LittleEndian(data),
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, "not an integer"),
    };

    static string EnumName(FieldInfo field, long value)
    {
        foreach (var v in field.EnumValues)
        {
            if (v.Value == value)
            {
                return Humanize(v.Name);
            }
        }
        return value.ToString(CultureInfo.InvariantCulture);
    }

    static float F32(ReadOnlySpan<byte> data, int index) => BinaryPrimitives.ReadSingleLittleEndian(data[(index * 4)..]);

    static double Meters(ReadOnlySpan<byte> data, int index) => BinaryPrimitives.ReadInt64LittleEndian(data[(index * 8)..]) * PositionUnit;
}
