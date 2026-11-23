using System.Buffers.Binary;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// A component field's value as a property track's channels key it (see docs/editor/cutscene-editor.md#keying): which
/// fields a property track can animate, and their numbers in the channels' order.
/// </summary>
public static class KeyValues
{
    /// <summary>How a property track keys a field, or null for one that it cannot animate, or that only a transform track keys.</summary>
    public static PropertyShape? Shape(FieldInfo field) => field.ReadOnly ? null : field.Kind switch
    {
        FieldKind.F32 => PropertyShape.Number,
        FieldKind.Bool or FieldKind.I8 or FieldKind.I16 or FieldKind.I32 or FieldKind.I64
            or FieldKind.U8 or FieldKind.U16 or FieldKind.U32 or FieldKind.U64 or FieldKind.Enum => PropertyShape.Stepped,
        FieldKind.Vector2 => PropertyShape.Vector2,
        FieldKind.Vector3 when field.Color => PropertyShape.Color,
        FieldKind.Vector3 => PropertyShape.Vector3,
        _ => null,
    };

    /// <summary>
    /// A field's numbers from its component's bytes, one for each channel: a bool is 0 or 1, and an enum is its number.
    /// Null when the bytes are too short, or for a kind that no channel holds.
    /// </summary>
    public static double[]? Numbers(FieldInfo field, ReadOnlySpan<byte> component)
    {
        var kind = field.Kind == FieldKind.Enum ? field.EnumBase : field.Kind;
        int size;
        try
        {
            size = FieldValues.Size(kind);
        }
        catch (ArgumentOutOfRangeException)
        {
            return null;
        }
        if (field.Offset + size > component.Length)
        {
            return null;
        }
        var data = component.Slice((int)field.Offset, size).ToArray();
        double F32(int i) => BinaryPrimitives.ReadSingleLittleEndian(data.AsSpan(i * 4));
        return kind switch
        {
            FieldKind.Bool => [data[0] != 0 ? 1 : 0],
            FieldKind.I8 => [(sbyte)data[0]],
            FieldKind.U8 => [data[0]],
            FieldKind.I16 => [BinaryPrimitives.ReadInt16LittleEndian(data)],
            FieldKind.U16 => [BinaryPrimitives.ReadUInt16LittleEndian(data)],
            FieldKind.I32 => [BinaryPrimitives.ReadInt32LittleEndian(data)],
            FieldKind.U32 => [BinaryPrimitives.ReadUInt32LittleEndian(data)],
            FieldKind.I64 => [BinaryPrimitives.ReadInt64LittleEndian(data)],
            FieldKind.U64 => [BinaryPrimitives.ReadUInt64LittleEndian(data)],
            FieldKind.F32 => [F32(0)],
            FieldKind.Vector2 => [F32(0), F32(1)],
            FieldKind.Vector3 => [F32(0), F32(1), F32(2)],
            FieldKind.Quaternion => [F32(0), F32(1), F32(2), F32(3)],
            _ => null,
        };
    }

    /// <summary>A Position field's three i64s in units of 2^-24 m, or null when the bytes are too short.</summary>
    public static long[]? Units(FieldInfo field, ReadOnlySpan<byte> component)
    {
        if (field.Kind != FieldKind.Position || field.Offset + 24 > component.Length)
        {
            return null;
        }
        var data = component[(int)field.Offset..];
        return [BinaryPrimitives.ReadInt64LittleEndian(data), BinaryPrimitives.ReadInt64LittleEndian(data[8..]), BinaryPrimitives.ReadInt64LittleEndian(data[16..])];
    }

    /// <summary>
    /// Writes a value into a field of its component's bytes, as the game does when it sets the field from a scene: an
    /// enum's name takes its number. False, with the bytes as they were, for a value that does not fit the field, or for
    /// a kind that no track keys, such as an entity or an asset.
    /// </summary>
    public static bool Write(FieldInfo field, Span<byte> component, Document.SceneValue value)
    {
        var kind = field.Kind == FieldKind.Enum ? field.EnumBase : field.Kind;
        int size;
        try
        {
            size = FieldValues.Size(kind);
        }
        catch (ArgumentOutOfRangeException)
        {
            return false;
        }
        if (field.Offset + size > component.Length)
        {
            return false;
        }
        var data = component.Slice((int)field.Offset, size);
        var numbers = value.Numbers;
        Int128? Integer()
        {
            if (field.Kind == FieldKind.Enum && value.Kind == Document.SceneValueKind.Name)
            {
                return field.EnumValues.FirstOrDefault(v => v.Name == value.Text) is { } e ? e.Value : null;
            }
            if (value.Kind == Document.SceneValueKind.Bool)
            {
                return value.Bool ? 1 : 0;
            }
            return numbers.Count == 1 ? numbers[0].Integer ?? (Int128)Math.Round(numbers[0].Float) : null;
        }
        static bool Floats(Span<byte> data, Document.SceneValue value, int count)
        {
            if (value.Kind != Document.SceneValueKind.Number || value.Numbers.Count != count)
            {
                return false;
            }
            for (var i = 0; i < count; i++)
            {
                BinaryPrimitives.WriteSingleLittleEndian(data[(i * 4)..], (float)value.Numbers[i].Float);
            }
            return true;
        }
        switch (field.Kind)
        {
            case FieldKind.F32:
                return Floats(data, value, 1);
            case FieldKind.Vector2:
                return Floats(data, value, 2);
            case FieldKind.Vector3:
                return Floats(data, value, 3);
            case FieldKind.Quaternion:
                return Floats(data, value, 4);
            case FieldKind.Position:
                if (value.Kind != Document.SceneValueKind.Number || numbers.Count != 3 || numbers.Any(n => n.Integer == null))
                {
                    return false;
                }
                for (var i = 0; i < 3; i++)
                {
                    BinaryPrimitives.WriteInt64LittleEndian(data[(i * 8)..], (long)numbers[i].Integer!.Value);
                }
                return true;
        }
        if (Integer() is not { } n)
        {
            return false;
        }
        switch (kind)
        {
            case FieldKind.Bool:
                data[0] = n != 0 ? (byte)1 : (byte)0;
                return true;
            case FieldKind.I8:
            case FieldKind.U8:
                data[0] = (byte)(long)n;
                return true;
            case FieldKind.I16:
            case FieldKind.U16:
                BinaryPrimitives.WriteUInt16LittleEndian(data, (ushort)(long)n);
                return true;
            case FieldKind.I32:
            case FieldKind.U32:
                BinaryPrimitives.WriteUInt32LittleEndian(data, (uint)(long)n);
                return true;
            case FieldKind.I64:
            case FieldKind.U64:
                BinaryPrimitives.WriteUInt64LittleEndian(data, (ulong)n);
                return true;
        }
        return false;
    }

    /// <summary>
    /// Whether a key's value is the field's: equal for a value that steps, and otherwise within the noise of the f32s
    /// that the game evaluates in.
    /// </summary>
    public static bool Same(double key, double value, bool stepped) =>
        stepped ? key == value : Math.Abs(key - value) <= 1e-4 + 1e-5 * Math.Abs(value);
}

/// <summary>
/// A pose as a transform track's channels key it, the inverse of <c>lib/engine/cutscene/transform.odin</c> (see
/// docs/cinematics/tracks.md#transform-tracks): in meters and in degrees, applied z, then x, then y.
/// </summary>
public static class PoseKeys
{
    /// <summary>World_Position units in a meter.</summary>
    public const double UnitsPerMeter = 1 << 24;

    /// <summary>
    /// A relative track's position keys: the offset from the binding's own position, in its own rotation's axes.
    /// <paramref name="offset"/> is the shown position less the own one, in meters.
    /// </summary>
    public static double[] RelativePosition(Vec3 offset, Quat own) => own.Normalized().Conjugate.Rotate(offset).ToArray();

    /// <summary>A relative track's rotation keys: the rotation after the binding's own one, as Euler angles.</summary>
    public static double[] RelativeRotation(Quat own, Quat shown) => Euler((own.Normalized().Conjugate * shown).Normalized());

    /// <summary>A rotation's Euler angles in degrees, as the engine's <c>euler_of</c> gives them.</summary>
    public static double[] Euler(Quat q) => FieldValues.Euler(q.X, q.Y, q.Z, q.W);

    /// <summary>
    /// An absolute track's position keys: the shown position from the track's origin, in meters, from the difference in
    /// units, so a place far from the world's origin keeps its precision.
    /// </summary>
    public static double[] AbsolutePosition(IReadOnlyList<long> shown, IReadOnlyList<long> origin) =>
        [.. Enumerable.Range(0, 3).Select(i => (shown[i] - origin[i]) / UnitsPerMeter)];

    /// <summary>An origin in whole meters, and in units, nearest a position in units.</summary>
    public static (long[] Meters, long[] Units) OriginNear(IReadOnlyList<long> position)
    {
        var meters = position.Select(u => (long)Math.Round(u / UnitsPerMeter)).ToArray();
        return (meters, [.. meters.Select(m => m * (1L << 24))]);
    }

    /// <summary>An origin in meters, in units, rounded as the cooker rounds it.</summary>
    public static long[] Units(IReadOnlyList<double> meters) => [.. meters.Select(m => (long)Math.Round(m * UnitsPerMeter))];

    /// <summary>
    /// Euler angles, each moved by whole turns to the nearest of its channel's key next to it, so the curve turns the
    /// short way from it. A channel with no key there keeps its angle.
    /// </summary>
    public static double[] Unwrap(IReadOnlyList<double> angles, IReadOnlyList<double?> near) =>
        [.. angles.Select((a, i) => i < near.Count && near[i] is { } n ? a + 360 * Math.Round((n - a) / 360) : a)];

    /// <summary>Whether rotation keys turn as the shown Euler angles do, compared as rotations, so whole turns are the same.</summary>
    public static bool SameRotation(IReadOnlyList<double?> keys, IReadOnlyList<double> angles)
    {
        if (keys.Count != 3 || angles.Count != 3)
        {
            return false;
        }
        if (keys.Any(k => k == null))
        {
            return keys.Select((k, i) => k == null || Math.Abs(Angles.Wrap180(k.Value - angles[i])) <= 1e-3).All(same => same);
        }
        var a = FieldValues.Quaternion(keys[0]!.Value, keys[1]!.Value, keys[2]!.Value);
        var b = FieldValues.Quaternion(angles[0], angles[1], angles[2]);
        return Math.Abs(a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3]) > 1 - 1e-6;
    }
}
