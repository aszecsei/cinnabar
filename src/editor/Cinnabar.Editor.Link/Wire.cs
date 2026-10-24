using System.Buffers;
using System.Buffers.Binary;
using System.Text;

namespace Cinnabar.Editor.Link;

/// <summary>
/// A message of a link. The generated records in <c>Cinnabar.Editor.Link.Protocol</c> (the editor link) and
/// <c>Cinnabar.Editor.Link.Cook</c> (the cook link) implement it.
/// </summary>
public interface ILinkMessage
{
    ushort MessageKind { get; }

    void Write(LinkWriter writer);
}

/// <summary>The peer sent bytes that are not a message of this protocol.</summary>
public sealed class LinkProtocolException(string message) : Exception(message);

public delegate T ElementReader<T>(ref LinkReader reader);

/// <summary>Reads a message of one link by its kind: <c>LinkMessages.Read</c> or <c>CookMessages.Read</c>.</summary>
public delegate ILinkMessage MessageReader(ushort kind, ref LinkReader reader);

/// <summary>
/// Reads the wire format of <c>lib/engine/wire</c>: little-endian numbers, bools as one byte, and strings and
/// slices as a <c>u32</c> count followed by their bytes or elements. A fixed array has no count.
/// </summary>
public ref struct LinkReader(ReadOnlySpan<byte> data)
{
    readonly ReadOnlySpan<byte> _data = data;
    int _pos;

    public readonly bool AtEnd => _pos == _data.Length;

    ReadOnlySpan<byte> Take(int count)
    {
        if (count < 0 || count > _data.Length - _pos)
        {
            throw new LinkProtocolException("a message is shorter than its fields");
        }
        var span = _data.Slice(_pos, count);
        _pos += count;
        return span;
    }

    public byte ReadU8() => Take(1)[0];
    public sbyte ReadI8() => (sbyte)Take(1)[0];
    public ushort ReadU16() => BinaryPrimitives.ReadUInt16LittleEndian(Take(2));
    public short ReadI16() => BinaryPrimitives.ReadInt16LittleEndian(Take(2));
    public uint ReadU32() => BinaryPrimitives.ReadUInt32LittleEndian(Take(4));
    public int ReadI32() => BinaryPrimitives.ReadInt32LittleEndian(Take(4));
    public ulong ReadU64() => BinaryPrimitives.ReadUInt64LittleEndian(Take(8));
    public long ReadI64() => BinaryPrimitives.ReadInt64LittleEndian(Take(8));
    public float ReadF32() => BinaryPrimitives.ReadSingleLittleEndian(Take(4));
    public double ReadF64() => BinaryPrimitives.ReadDoubleLittleEndian(Take(8));

    public bool ReadBool() => ReadU8() switch
    {
        0 => false,
        1 => true,
        var b => throw new LinkProtocolException($"{b} is not a bool"),
    };

    public string ReadString() => Encoding.UTF8.GetString(Take(ReadCount()));

    public byte[] ReadBytes() => Take(ReadCount()).ToArray();

    public T[] ReadSlice<T>(ElementReader<T> read)
    {
        var count = ReadCount();
        // Every element takes at least one byte, so a count beyond the rest of the payload is a lie.
        if (count > _data.Length - _pos)
        {
            throw new LinkProtocolException($"a slice of {count} elements is longer than its message");
        }
        return ReadFixed(count, read);
    }

    public T[] ReadFixed<T>(int count, ElementReader<T> read)
    {
        var items = new T[count];
        for (var i = 0; i < count; i++)
        {
            items[i] = read(ref this);
        }
        return items;
    }

    int ReadCount()
    {
        var count = ReadU32();
        return count <= int.MaxValue ? (int)count : throw new LinkProtocolException($"a count of {count} is too large");
    }
}

/// <summary>Writes the wire format that <see cref="LinkReader"/> reads.</summary>
public sealed class LinkWriter
{
    readonly ArrayBufferWriter<byte> _buffer = new();

    public int Length => _buffer.WrittenCount;

    public ReadOnlySpan<byte> Written => _buffer.WrittenSpan;

    Span<byte> Next(int count)
    {
        var span = _buffer.GetSpan(count)[..count];
        _buffer.Advance(count);
        return span;
    }

    public void WriteU8(byte value) => Next(1)[0] = value;
    public void WriteI8(sbyte value) => Next(1)[0] = (byte)value;
    public void WriteU16(ushort value) => BinaryPrimitives.WriteUInt16LittleEndian(Next(2), value);
    public void WriteI16(short value) => BinaryPrimitives.WriteInt16LittleEndian(Next(2), value);
    public void WriteU32(uint value) => BinaryPrimitives.WriteUInt32LittleEndian(Next(4), value);
    public void WriteI32(int value) => BinaryPrimitives.WriteInt32LittleEndian(Next(4), value);
    public void WriteU64(ulong value) => BinaryPrimitives.WriteUInt64LittleEndian(Next(8), value);
    public void WriteI64(long value) => BinaryPrimitives.WriteInt64LittleEndian(Next(8), value);
    public void WriteF32(float value) => BinaryPrimitives.WriteSingleLittleEndian(Next(4), value);
    public void WriteF64(double value) => BinaryPrimitives.WriteDoubleLittleEndian(Next(8), value);
    public void WriteBool(bool value) => WriteU8(value ? (byte)1 : (byte)0);

    public void WriteString(string value)
    {
        var count = Encoding.UTF8.GetByteCount(value);
        WriteU32((uint)count);
        Encoding.UTF8.GetBytes(value, Next(count));
    }

    public void WriteBytes(byte[] bytes)
    {
        WriteU32((uint)bytes.Length);
        bytes.CopyTo(Next(bytes.Length));
    }

    public void WriteSlice<T>(T[] items, Action<LinkWriter, T> write)
    {
        WriteU32((uint)items.Length);
        foreach (var item in items)
        {
            write(this, item);
        }
    }

    public void WriteFixed<T>(T[] items, int count, Action<LinkWriter, T> write)
    {
        if (items.Length != count)
        {
            throw new ArgumentException($"a fixed array of {count} has {items.Length} elements", nameof(items));
        }
        foreach (var item in items)
        {
            write(this, item);
        }
    }
}

/// <summary>
/// A message on the wire: a 12-byte little-endian header (payload length, kind, flags, request ID) and the payload.
/// A response has its request's ID, and an event has ID 0.
/// </summary>
public static class LinkFrame
{
    public const int HeaderSize = 12;
    public const int MaxPayload = 64 * 1024 * 1024;

    public readonly record struct Header(uint Length, ushort Kind, ushort Flags, uint Request);

    public static byte[] Encode(ILinkMessage message, uint request = 0)
    {
        var payload = new LinkWriter();
        message.Write(payload);
        var frame = new byte[HeaderSize + payload.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(frame.AsSpan(0), (uint)payload.Length);
        BinaryPrimitives.WriteUInt16LittleEndian(frame.AsSpan(4), message.MessageKind);
        BinaryPrimitives.WriteUInt16LittleEndian(frame.AsSpan(6), 0);
        BinaryPrimitives.WriteUInt32LittleEndian(frame.AsSpan(8), request);
        payload.Written.CopyTo(frame.AsSpan(HeaderSize));
        return frame;
    }

    public static Header ReadHeader(ReadOnlySpan<byte> bytes)
    {
        var header = new Header(
            BinaryPrimitives.ReadUInt32LittleEndian(bytes),
            BinaryPrimitives.ReadUInt16LittleEndian(bytes[4..]),
            BinaryPrimitives.ReadUInt16LittleEndian(bytes[6..]),
            BinaryPrimitives.ReadUInt32LittleEndian(bytes[8..]));
        return header.Length <= MaxPayload ? header : throw new LinkProtocolException($"a message of {header.Length} bytes is too long");
    }

    /// <summary>Decodes a payload of a link's message, which must hold exactly one message of its kind.</summary>
    public static ILinkMessage Decode(ushort kind, ReadOnlySpan<byte> payload, MessageReader read)
    {
        var reader = new LinkReader(payload);
        var message = read(kind, ref reader);
        return reader.AtEnd ? message : throw new LinkProtocolException($"a message of kind {kind} has bytes after its fields");
    }
}
