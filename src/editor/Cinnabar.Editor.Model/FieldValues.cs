using System.Buffers.Binary;
using System.Globalization;
using Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Model;

/// <summary>Reads a field out of a component's bytes, as the game laid them out (see <see cref="FieldInfo"/>).</summary>
public static class FieldValues
{
    // World_Position is in units of 2^-24 m.
    const double PositionUnit = 1.0 / (1 << 24);

    /// <summary>The value as text for the properties panel, or null if the bytes are too short for the field.</summary>
    public static string? Format(FieldInfo field, ReadOnlySpan<byte> component)
    {
        var size = Size(field.Kind == FieldKind.Enum ? field.EnumBase : field.Kind);
        if (field.Offset + size > component.Length)
        {
            return null;
        }
        var data = component.Slice((int)field.Offset, size);
        return field.Kind switch
        {
            FieldKind.Bool => data[0] != 0 ? "true" : "false",
            FieldKind.F32 => Number(BinaryPrimitives.ReadSingleLittleEndian(data)),
            FieldKind.F64 => Number(BinaryPrimitives.ReadDoubleLittleEndian(data)),
            FieldKind.Enum => EnumName(field, ReadInteger(field.EnumBase, data)),
            FieldKind.Vector3 => $"({Number(F32(data, 0))}, {Number(F32(data, 1))}, {Number(F32(data, 2))})",
            FieldKind.Quaternion => $"({Number(F32(data, 0))}, {Number(F32(data, 1))}, {Number(F32(data, 2))}, {Number(F32(data, 3))})",
            FieldKind.Position => $"({Meters(data, 0)}, {Meters(data, 1)}, {Meters(data, 2)}) m",
            FieldKind.Entity => EntityNode.Format(BinaryPrimitives.ReadUInt64LittleEndian(data)),
            FieldKind.U64 => BinaryPrimitives.ReadUInt64LittleEndian(data).ToString(CultureInfo.InvariantCulture),
            _ => ReadInteger(field.Kind, data).ToString(CultureInfo.InvariantCulture),
        };
    }

    /// <summary>The entity that an Entity field refers to, or 0.</summary>
    public static ulong Entity(FieldInfo field, ReadOnlySpan<byte> component) =>
        field.Kind == FieldKind.Entity && field.Offset + 8 <= component.Length
            ? BinaryPrimitives.ReadUInt64LittleEndian(component[(int)field.Offset..])
            : 0;

    public static int Size(FieldKind kind) => kind switch
    {
        FieldKind.Bool or FieldKind.I8 or FieldKind.U8 => 1,
        FieldKind.I16 or FieldKind.U16 => 2,
        FieldKind.I32 or FieldKind.U32 or FieldKind.F32 => 4,
        FieldKind.I64 or FieldKind.U64 or FieldKind.F64 or FieldKind.Entity => 8,
        FieldKind.Vector3 => 12,
        FieldKind.Quaternion => 16,
        FieldKind.Position => 24,
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, "not a field of fixed size"),
    };

    static long ReadInteger(FieldKind kind, ReadOnlySpan<byte> data) => kind switch
    {
        FieldKind.I8 => (sbyte)data[0],
        FieldKind.U8 => data[0],
        FieldKind.I16 => BinaryPrimitives.ReadInt16LittleEndian(data),
        FieldKind.U16 => BinaryPrimitives.ReadUInt16LittleEndian(data),
        FieldKind.I32 => BinaryPrimitives.ReadInt32LittleEndian(data),
        FieldKind.U32 => BinaryPrimitives.ReadUInt32LittleEndian(data),
        FieldKind.I64 => BinaryPrimitives.ReadInt64LittleEndian(data),
        // Past long.MaxValue a u64 shows as negative here. Format reads U64 fields separately.
        FieldKind.U64 => (long)BinaryPrimitives.ReadUInt64LittleEndian(data),
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, "not an integer"),
    };

    static string EnumName(FieldInfo field, long value)
    {
        foreach (var v in field.EnumValues)
        {
            if (v.Value == value)
            {
                return v.Name;
            }
        }
        return value.ToString(CultureInfo.InvariantCulture);
    }

    static float F32(ReadOnlySpan<byte> data, int index) => BinaryPrimitives.ReadSingleLittleEndian(data[(index * 4)..]);

    static string Meters(ReadOnlySpan<byte> data, int index) =>
        Number(BinaryPrimitives.ReadInt64LittleEndian(data[(index * 8)..]) * PositionUnit);

    /// <summary>Up to six significant digits, and no exponent for ordinary sizes.</summary>
    public static string Number(double value) => value.ToString("0.######", CultureInfo.InvariantCulture);

    /// <summary>A behaviour field's value as text.</summary>
    public static string Format(BehaviourField field) => field.Kind switch
    {
        BehaviourFieldKind.Number => Number(field.Number),
        BehaviourFieldKind.Boolean => field.Boolean ? "true" : "false",
        BehaviourFieldKind.String => $"\"{field.Text}\"",
        BehaviourFieldKind.Vector => $"({Number(field.Vector[0])}, {Number(field.Vector[1])}, {Number(field.Vector[2])})",
        BehaviourFieldKind.Entity => EntityNode.Format(field.Entity),
        _ => "nil",
    };
}
