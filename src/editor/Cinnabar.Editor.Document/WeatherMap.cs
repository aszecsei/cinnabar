using System.Buffers.Binary;
using System.IO.Compression;

namespace Cinnabar.Editor.Document;

/// <summary>The weather map's channels: its red, green and blue (see docs/rendering/clouds.md#weather).</summary>
public enum WeatherChannel
{
    Coverage = 0,
    Precipitation = 1,
    Type = 2,
}

/// <summary>
/// What a generated weather map is made of: its size on a side, the seed of its noise, how many cells of noise go
/// across it, the octaves of the coverage's noise, and a bias added to each channel.
/// </summary>
public sealed record WeatherGeneration(int Size = 512, int Seed = 1, double Scale = 6, int Octaves = 4, double CoverageBias = 0, double PrecipitationBias = 0, double TypeBias = 0);

/// <summary>
/// A weather map (see docs/editor/shell-and-panels.md#weather-map): the texels of the texture whose red, green and blue
/// are the clouds' coverage, precipitation and type, as RGBA bytes with an alpha of 255. It paints, generates from
/// noise, and reads and writes a PNG, so the editor needs no image library to edit the asset.
/// </summary>
public sealed class WeatherMap
{
    public int Width { get; }

    public int Height { get; }

    /// <summary>The texels, row by row from the top, four bytes each: red, green, blue and an alpha of 255.</summary>
    public byte[] Rgba { get; }

    public WeatherMap(int width, int height)
    {
        if (width <= 0 || height <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(width), "a weather map needs a width and a height above 0");
        }
        Width = width;
        Height = height;
        Rgba = new byte[width * height * 4];
        for (var i = 3; i < Rgba.Length; i += 4)
        {
            Rgba[i] = 255;
        }
    }

    WeatherMap(int width, int height, byte[] rgba)
    {
        Width = width;
        Height = height;
        Rgba = rgba;
    }

    /// <summary>A copy, for a stroke's history.</summary>
    public WeatherMap Clone() => new(Width, Height, (byte[])Rgba.Clone());

    /// <summary>A channel's value at a texel, from 0 to 1.</summary>
    public double Get(WeatherChannel channel, int x, int y) => Rgba[(y * Width + x) * 4 + (int)channel] / 255.0;

    public void Set(WeatherChannel channel, int x, int y, double value) =>
        Rgba[(y * Width + x) * 4 + (int)channel] = (byte)Math.Round(Math.Clamp(value, 0, 1) * 255);

    /// <summary>
    /// Paints a channel toward a value with a round brush at a texel: within <paramref name="hardness"/> of the radius
    /// the brush is full, and it falls off to nothing at the radius. <paramref name="strength"/> is how far each texel
    /// moves toward the value, from 0 to 1. The other channels do not change.
    /// </summary>
    public void Paint(WeatherChannel channel, double x, double y, double radius, double strength, double hardness, double value)
    {
        radius = Math.Max(radius, 0.5);
        strength = Math.Clamp(strength, 0, 1);
        hardness = Math.Clamp(hardness, 0, 1);
        value = Math.Clamp(value, 0, 1);
        var x0 = Math.Max((int)Math.Floor(x - radius), 0);
        var x1 = Math.Min((int)Math.Ceiling(x + radius), Width - 1);
        var y0 = Math.Max((int)Math.Floor(y - radius), 0);
        var y1 = Math.Min((int)Math.Ceiling(y + radius), Height - 1);
        for (var ty = y0; ty <= y1; ty++)
        {
            for (var tx = x0; tx <= x1; tx++)
            {
                var distance = Math.Sqrt((tx + 0.5 - x) * (tx + 0.5 - x) + (ty + 0.5 - y) * (ty + 0.5 - y)) / radius;
                if (distance >= 1)
                {
                    continue;
                }
                // Full inside the hard part, then a smooth step down to the edge.
                var edge = hardness >= 1 ? 1 : Math.Clamp((1 - distance) / (1 - hardness), 0, 1);
                var weight = edge * edge * (3 - 2 * edge) * strength;
                var old = Get(channel, tx, ty);
                Set(channel, tx, ty, old + (value - old) * weight);
            }
        }
    }

    /// <summary>
    /// Fills the map from noise, the same for the same generation: the coverage is a tiling Perlin fbm, and the
    /// precipitation and the type come from tiling Worley cells, so a few cells rain and lean toward cumulonimbus. The
    /// map repeats beyond its edges, as the clouds read it.
    /// </summary>
    public void Generate(WeatherGeneration g)
    {
        var cells = Math.Max(1, (int)Math.Round(g.Scale));
        var octaves = Math.Clamp(g.Octaves, 1, 8);
        var seed = (uint)g.Seed;
        for (var y = 0; y < Height; y++)
        {
            for (var x = 0; x < Width; x++)
            {
                var u = (x + 0.5) / Width;
                var v = (y + 0.5) / Height;
                var coverage = Fbm(u, v, cells, octaves, seed);
                var (f1, cell) = Worley(u, v, cells, seed ^ 0x9e3779b9);
                var cellValue = Hash01(cell.X, cell.Y, 0, seed ^ 0x7f4a7c15);
                // The nearer the middle of a stormy cell, the more it rains.
                var stormy = cellValue > 0.72 ? 1.0 : cellValue > 0.5 ? 0.25 : 0.0;
                var core = Math.Clamp(1 - f1 * 1.6, 0, 1);
                var precipitation = core * core * stormy;
                var type = 0.5 + (cellValue - 0.5) * 0.5;
                type = type + (1 - type) * precipitation;
                Set(WeatherChannel.Coverage, x, y, coverage + g.CoverageBias);
                Set(WeatherChannel.Precipitation, x, y, precipitation + g.PrecipitationBias);
                Set(WeatherChannel.Type, x, y, type + g.TypeBias);
            }
        }
    }

    // Perlin fbm over the unit square that tiles, from 0 to 1.
    static double Fbm(double u, double v, int cells, int octaves, uint seed)
    {
        var sum = 0.0;
        var amplitude = 0.5;
        var norm = 0.0;
        var period = cells;
        for (var o = 0; o < octaves; o++)
        {
            sum += amplitude * Perlin(u * period, v * period, period, seed + (uint)o * 131);
            norm += amplitude;
            amplitude *= 0.5;
            period *= 2;
        }
        return Math.Clamp(sum / norm * 0.5 + 0.5, 0, 1);
    }

    // Tiling 2D Perlin noise with a lattice of `period` cells, from about -1 to 1.
    static double Perlin(double x, double y, int period, uint seed)
    {
        var x0 = (int)Math.Floor(x);
        var y0 = (int)Math.Floor(y);
        var fx = x - x0;
        var fy = y - y0;
        double Grad(int ix, int iy, double dx, double dy)
        {
            var angle = Hash01(Mod(ix, period), Mod(iy, period), 0, seed) * Math.PI * 2;
            return Math.Cos(angle) * dx + Math.Sin(angle) * dy;
        }
        var sx = Fade(fx);
        var sy = Fade(fy);
        var a = Lerp(Grad(x0, y0, fx, fy), Grad(x0 + 1, y0, fx - 1, fy), sx);
        var b = Lerp(Grad(x0, y0 + 1, fx, fy - 1), Grad(x0 + 1, y0 + 1, fx - 1, fy - 1), sx);
        return Lerp(a, b, sy) * 1.414;
    }

    // Tiling Worley noise: the distance to the nearest of `cells` cells' points, in cells, and that cell.
    static (double F1, (int X, int Y) Cell) Worley(double u, double v, int cells, uint seed)
    {
        var x = u * cells;
        var y = v * cells;
        var x0 = (int)Math.Floor(x);
        var y0 = (int)Math.Floor(y);
        var best = double.MaxValue;
        var bestCell = (0, 0);
        for (var dy = -1; dy <= 1; dy++)
        {
            for (var dx = -1; dx <= 1; dx++)
            {
                var cx = Mod(x0 + dx, cells);
                var cy = Mod(y0 + dy, cells);
                var px = x0 + dx + Hash01(cx, cy, 1, seed);
                var py = y0 + dy + Hash01(cx, cy, 2, seed);
                var d = (px - x) * (px - x) + (py - y) * (py - y);
                if (d < best)
                {
                    best = d;
                    bestCell = (cx, cy);
                }
            }
        }
        return (Math.Sqrt(best), bestCell);
    }

    static int Mod(int a, int n) => ((a % n) + n) % n;

    static double Fade(double t) => t * t * t * (t * (t * 6 - 15) + 10);

    static double Lerp(double a, double b, double t) => a + (b - a) * t;

    // A hash of lattice coordinates and a seed, from 0 to 1, the same on every platform.
    static double Hash01(int x, int y, int k, uint seed)
    {
        var h = seed ^ 0x811c9dc5;
        h = (h ^ (uint)x) * 0x01000193;
        h = (h ^ (uint)y) * 0x01000193;
        h = (h ^ (uint)k) * 0x01000193;
        h ^= h >> 15;
        h *= 0x2c1b3c6d;
        h ^= h >> 12;
        h *= 0x297a2d39;
        h ^= h >> 15;
        return h / 4294967296.0;
    }

    /// <summary>The map as an 8-bit RGBA PNG without interlacing.</summary>
    public byte[] EncodePng()
    {
        var raw = new byte[(Width * 4 + 1) * Height];
        for (var y = 0; y < Height; y++)
        {
            // Each row starts with its filter, None.
            Buffer.BlockCopy(Rgba, y * Width * 4, raw, y * (Width * 4 + 1) + 1, Width * 4);
        }
        using var compressed = new MemoryStream();
        using (var zlib = new ZLibStream(compressed, CompressionLevel.Optimal, leaveOpen: true))
        {
            zlib.Write(raw);
        }
        var header = new byte[13];
        BinaryPrimitives.WriteInt32BigEndian(header, Width);
        BinaryPrimitives.WriteInt32BigEndian(header.AsSpan(4), Height);
        header[8] = 8; // bit depth
        header[9] = 6; // RGBA
        using var png = new MemoryStream();
        png.Write(PngSignature);
        WriteChunk(png, "IHDR", header);
        WriteChunk(png, "IDAT", compressed.ToArray());
        WriteChunk(png, "IEND", []);
        return png.ToArray();
    }

    /// <summary>
    /// A map from a PNG of 8-bit gray, RGB, gray with alpha or RGBA texels without interlacing, with an alpha of 255,
    /// or null for a PNG of another kind or bytes that are not a PNG. A PNG with a palette, 16-bit texels or interlacing
    /// is for an image library.
    /// </summary>
    public static WeatherMap? DecodePng(byte[] bytes)
    {
        if (bytes.Length < PngSignature.Length + 12 || !bytes.AsSpan(0, PngSignature.Length).SequenceEqual(PngSignature))
        {
            return null;
        }
        var at = PngSignature.Length;
        int width = 0, height = 0, channels = 0;
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
                    var (depth, color, interlace) = (chunk[8], chunk[9], chunk[12]);
                    channels = color switch { 0 => 1, 2 => 3, 4 => 2, 6 => 4, _ => 0 };
                    if (depth != 8 || channels == 0 || interlace != 0 || width <= 0 || height <= 0)
                    {
                        return null;
                    }
                    break;
                case "IDAT":
                    data.Write(chunk);
                    break;
                case "IEND":
                    return channels == 0 ? null : Unfilter(data.ToArray(), width, height, channels);
            }
            at += 12 + length;
        }
        return null;
    }

    // Inflates the rows, undoes each row's filter, and widens the texels to RGBA.
    static WeatherMap? Unfilter(byte[] compressed, int width, int height, int channels)
    {
        var stride = width * channels;
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
                int left = i >= channels ? output[i - channels] : 0;
                int up = y > 0 ? previous[i] : 0;
                int upLeft = y > 0 && i >= channels ? previous[i - channels] : 0;
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
        var map = new WeatherMap(width, height);
        for (var i = 0; i < width * height; i++)
        {
            var (r, g, b) = channels switch
            {
                1 or 2 => (rows[i * channels], rows[i * channels], rows[i * channels]),
                _ => (rows[i * channels], rows[i * channels + 1], rows[i * channels + 2]),
            };
            map.Rgba[i * 4] = r;
            map.Rgba[i * 4 + 1] = g;
            map.Rgba[i * 4 + 2] = b;
        }
        return map;
    }

    static int Paeth(int a, int b, int c)
    {
        var p = a + b - c;
        var pa = Math.Abs(p - a);
        var pb = Math.Abs(p - b);
        var pc = Math.Abs(p - c);
        return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
    }

    static readonly byte[] PngSignature = [137, 80, 78, 71, 13, 10, 26, 10];

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
