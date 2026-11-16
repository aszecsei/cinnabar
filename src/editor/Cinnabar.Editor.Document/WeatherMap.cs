
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
    public byte[] EncodePng() => Png.Encode(new PngImage(Width, Height, 4, 8, [.. Rgba.Select(b => (ushort)b)]));

    /// <summary>
    /// A map from a PNG of 8-bit gray, RGB, gray with alpha or RGBA texels without interlacing, with an alpha of 255,
    /// or null for a PNG of another kind or bytes that are not a PNG. A PNG with a palette, 16-bit texels or interlacing
    /// is for an image library.
    /// </summary>
    public static WeatherMap? DecodePng(byte[] bytes)
    {
        if (Png.Decode(bytes) is not { Depth: 8 } image)
        {
            return null;
        }
        var map = new WeatherMap(image.Width, image.Height);
        var channels = image.Channels;
        for (var i = 0; i < image.Width * image.Height; i++)
        {
            var s = image.Samples;
            var (r, g, b) = channels switch
            {
                1 or 2 => (s[i * channels], s[i * channels], s[i * channels]),
                _ => (s[i * channels], s[i * channels + 1], s[i * channels + 2]),
            };
            map.Rgba[i * 4] = (byte)r;
            map.Rgba[i * 4 + 1] = (byte)g;
            map.Rgba[i * 4 + 2] = (byte)b;
        }
        return map;
    }
}
