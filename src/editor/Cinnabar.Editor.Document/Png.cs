using System.Buffers.Binary;
using System.IO.Compression;

namespace Cinnabar.Editor.Document;

/// <summary>
/// An image as a PNG holds it without a palette: <see cref="Channels"/> samples a texel (1 gray, 2 gray and alpha, 3 RGB,
/// 4 RGBA) of <see cref="Depth"/> bits, 8 or 16, row-major, each widened to a ushort.
/// </summary>
public sealed record PngImage(int Width, int Height, int Channels, int Depth, ushort[] Samples)
{
    /// <summary>The largest sample of the depth.</summary>
    public int Max => Depth == 16 ? 65535 : 255;

    /// <summary>The first channel of each texel, gray or red, widened to 16 bits: an 8-bit 255 is 65535.</summary>
    public ushort[] FirstChannel16()
    {
        var out16 = new ushort[Width * Height];
        for (var i = 0; i < out16.Length; i++)
        {
            var s = Samples[i * Channels];
            out16[i] = Depth == 16 ? s : (ushort)(s * 257);
        }
        return out16;
    }
}

/// <summary>
/// The PNG reader and writer that the editor's own images use, the weather map's and the landscape's (see
/// docs/editor/landscape.md#saving): 8- and 16-bit gray, gray with alpha, RGB and RGBA, without interlacing. A PNG
/// with a palette or interlacing is for an image library.
/// </summary>
public static class Png
{
    static readonly byte[] Signature = [137, 80, 78, 71, 13, 10, 26, 10];

    /// <summary>An image as a PNG, with each row's filter None.</summary>
    public static byte[] Encode(PngImage image)
    {
        var bytesPerSample = image.Depth / 8;
        var stride = image.Width * image.Channels * bytesPerSample;
        var raw = new byte[(stride + 1) * image.Height];
        for (var y = 0; y < image.Height; y++)
        {
            var row = raw.AsSpan(y * (stride + 1) + 1, stride);
            for (var i = 0; i < image.Width * image.Channels; i++)
            {
                var s = image.Samples[y * image.Width * image.Channels + i];
                if (bytesPerSample == 2)
                {
                    BinaryPrimitives.WriteUInt16BigEndian(row[(i * 2)..], s);
                }
                else
                {
                    row[i] = (byte)s;
                }
            }
        }
        using var compressed = new MemoryStream();
        using (var zlib = new ZLibStream(compressed, CompressionLevel.Optimal, leaveOpen: true))
        {
            zlib.Write(raw);
        }
        var header = new byte[13];
        BinaryPrimitives.WriteInt32BigEndian(header, image.Width);
        BinaryPrimitives.WriteInt32BigEndian(header.AsSpan(4), image.Height);
        header[8] = (byte)image.Depth;
        header[9] = image.Channels switch { 1 => 0, 2 => 4, 3 => 2, _ => 6 };
        using var png = new MemoryStream();
        png.Write(Signature);
        WriteChunk(png, "IHDR", header);
        WriteChunk(png, "IDAT", compressed.ToArray());
        WriteChunk(png, "IEND", []);
        return png.ToArray();
    }

    /// <summary>A PNG's image, or null for a PNG of another kind or bytes that are not a PNG.</summary>
    public static PngImage? Decode(byte[] bytes)
    {
        if (bytes.Length < Signature.Length + 12 || !bytes.AsSpan(0, Signature.Length).SequenceEqual(Signature))
        {
            return null;
        }
        var at = Signature.Length;
        int width = 0, height = 0, channels = 0, depth = 0;
        using var data = new MemoryStream();
        while (at + 12 <= bytes.Length)
        {
            var length = BinaryPrimitives.ReadInt32BigEndian(bytes.AsSpan(at));
            var type = System.Text.Encoding.ASCII.GetString(bytes, at + 4, 4);
            if (length < 0 || at + 12 + length > bytes.Length)
            {
                return null;
            }
            var chunk = bytes.AsSpan(at + 8, length);
            switch (type)
            {
                case "IHDR":
                    if (length != 13)
                    {
                        return null;
                    }
                    width = BinaryPrimitives.ReadInt32BigEndian(chunk);
                    height = BinaryPrimitives.ReadInt32BigEndian(chunk[4..]);
                    var (bits, color, interlace) = (chunk[8], chunk[9], chunk[12]);
                    channels = color switch { 0 => 1, 2 => 3, 4 => 2, 6 => 4, _ => 0 };
                    depth = bits;
                    if (depth is not (8 or 16) || channels == 0 || interlace != 0 || width <= 0 || height <= 0)
                    {
                        return null;
                    }
                    break;
                case "IDAT":
                    data.Write(chunk);
                    break;
                case "IEND":
                    return channels == 0 ? null : Unfilter(data.ToArray(), width, height, channels, depth);
            }
            at += 12 + length;
        }
        return null;
    }

    // Inflates the rows, undoes each row's filter, and reads the samples.
    static PngImage? Unfilter(byte[] compressed, int width, int height, int channels, int depth)
    {
        var bytesPerSample = depth / 8;
        var texel = channels * bytesPerSample;
        var stride = width * texel;
        var raw = new byte[(stride + 1) * height];
        try
        {
            using var zlib = new ZLibStream(new MemoryStream(compressed), CompressionMode.Decompress);
            var read = 0;
            while (read < raw.Length)
            {
                var n = zlib.Read(raw, read, raw.Length - read);
                if (n == 0)
                {
                    return null;
                }
                read += n;
            }
        }
        catch (InvalidDataException)
        {
            return null;
        }
        var rows = new byte[stride * height];
        for (var y = 0; y < height; y++)
        {
            var filter = raw[y * (stride + 1)];
            var line = raw.AsSpan(y * (stride + 1) + 1, stride);
            var output = rows.AsSpan(y * stride, stride);
            var previous = y > 0 ? rows.AsSpan((y - 1) * stride, stride) : Span<byte>.Empty;
            for (var i = 0; i < stride; i++)
            {
                int left = i >= texel ? output[i - texel] : 0;
                int up = y > 0 ? previous[i] : 0;
                int upLeft = y > 0 && i >= texel ? previous[i - texel] : 0;
                var predicted = filter switch
                {
                    0 => 0,
                    1 => left,
                    2 => up,
                    3 => (left + up) / 2,
                    4 => Paeth(left, up, upLeft),
                    _ => -1,
                };
                if (predicted < 0)
                {
                    return null;
                }
                output[i] = (byte)(line[i] + predicted);
            }
        }
        var samples = new ushort[width * height * channels];
        for (var i = 0; i < samples.Length; i++)
        {
            samples[i] = bytesPerSample == 2 ? BinaryPrimitives.ReadUInt16BigEndian(rows.AsSpan(i * 2)) : rows[i];
        }
        return new PngImage(width, height, channels, depth, samples);
    }

    static int Paeth(int a, int b, int c)
    {
        var p = a + b - c;
        var pa = Math.Abs(p - a);
        var pb = Math.Abs(p - b);
        var pc = Math.Abs(p - c);
        return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
    }

    static void WriteChunk(Stream png, string type, byte[] data)
    {
        var length = new byte[4];
        BinaryPrimitives.WriteInt32BigEndian(length, data.Length);
        png.Write(length);
        var typeBytes = System.Text.Encoding.ASCII.GetBytes(type);
        png.Write(typeBytes);
        png.Write(data);
        var crc = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(crc, Crc32(typeBytes, data));
        png.Write(crc);
    }

    static readonly uint[] CrcTable = MakeCrcTable();

    static uint[] MakeCrcTable()
    {
        var table = new uint[256];
        for (uint n = 0; n < 256; n++)
        {
            var c = n;
            for (var k = 0; k < 8; k++)
            {
                c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
            }
            table[n] = c;
        }
        return table;
    }

    static uint Crc32(byte[] type, byte[] data)
    {
        var c = 0xffffffff;
        foreach (var b in type)
        {
            c = CrcTable[(c ^ b) & 0xff] ^ (c >> 8);
        }
        foreach (var b in data)
        {
            c = CrcTable[(c ^ b) & 0xff] ^ (c >> 8);
        }
        return c ^ 0xffffffff;
    }
}
