namespace Cinnabar.Editor.Document;

/// <summary>What a landscape brush does (see docs/editor/landscape.md#brushes).</summary>
public enum LandscapeBrush
{
    /// <summary>Raises the height map under the brush.</summary>
    Raise,
    /// <summary>Lowers it.</summary>
    Lower,
    /// <summary>Moves each texel toward the mean of its neighbours.</summary>
    Smooth,
    /// <summary>Moves each texel toward the height where the stroke started.</summary>
    Flatten,
    /// <summary>A straight slope from where the stroke started to where it is, as wide as the brush.</summary>
    Ramp,
    /// <summary>Adds value noise, the same at a place for every stroke.</summary>
    Noise,
    /// <summary>Paints holes into the hole mask.</summary>
    Hole,
    /// <summary>Paints the hole mask solid.</summary>
    Fill,
}

/// <summary>
/// One dab of a brush, in the texels of the grid it paints: its center, where texel i's middle is i + 0.5, its radius
/// along x and y, which differ when the grid's texels are not square on the surface, its strength from 0 to 1, and
/// how much of its radius, from the edge in, falls off.
/// </summary>
public readonly record struct BrushDab(double X, double Y, double RadiusX, double RadiusY, double Strength, double Falloff);

/// <summary>A tile's texels before and after an edit.</summary>
public sealed record TilePatch(TexelRect Rect, ushort[] Before, ushort[] After);

/// <summary>
/// A stroke of a brush on a grid, from the press to the release (see docs/editor/landscape.md#strokes): it keeps the
/// grid as it was, so that it can give each changed tile's texels before and after for undo, put them back for a
/// cancel, and redraw a ramp. Each <see cref="Apply"/> paints a dab and gives the rectangle that it changed.
/// </summary>
public sealed class LandscapeStroke
{
    /// <summary>What one dab at full strength raises or lowers, as a share of the height range.</summary>
    public const double Step = 0.01;

    /// <summary>The noise's cell, in texels.</summary>
    public const double NoiseCell = 8;

    readonly HashSet<(int X, int Y)> _tiles = [];
    readonly double _flatten;
    readonly (double X, double Y, double Height) _start;

    public LandscapeStroke(HeightGrid grid, LandscapeBrush brush, BrushDab first)
    {
        Grid = grid;
        Brush = brush;
        Original = grid.Copy();
        _flatten = Original.Sample(first.X / grid.Width, first.Y / grid.Height);
        _start = (first.X, first.Y, _flatten);
    }

    public HeightGrid Grid { get; }

    public LandscapeBrush Brush { get; }

    /// <summary>The grid as it was when the stroke began.</summary>
    public HeightGrid Original { get; }

    /// <summary>Paints a dab, and gives the rectangle of texels that it may have changed.</summary>
    public TexelRect Apply(BrushDab dab)
    {
        if (Brush == LandscapeBrush.Ramp)
        {
            return Ramp(dab);
        }
        var rect = Bounds(dab.X, dab.Y, dab.X, dab.Y, dab);
        if (rect.IsEmpty)
        {
            return rect;
        }
        Touch(rect);
        // Smoothing reads the texels as they were before this dab, one past the rectangle.
        var around = new TexelRect(rect.X - 1, rect.Y - 1, rect.Width + 2, rect.Height + 2).Clamp(Grid.Width, Grid.Height);
        var before = Brush == LandscapeBrush.Smooth ? new HeightGrid(around.Width, around.Height, Grid.Read(around)) : null;
        var amount = dab.Strength * Step * 65535;
        for (var y = rect.Y; y < rect.Bottom; y++)
        {
            for (var x = rect.X; x < rect.Right; x++)
            {
                var w = Weight((x + 0.5 - dab.X) / dab.RadiusX, (y + 0.5 - dab.Y) / dab.RadiusY, dab.Falloff);
                if (w <= 0)
                {
                    continue;
                }
                double h = Grid[x, y];
                h = Brush switch
                {
                    LandscapeBrush.Raise => h + amount * w,
                    LandscapeBrush.Lower => h - amount * w,
                    LandscapeBrush.Smooth => h + (Mean(before!, x - around.X, y - around.Y) - h) * w * dab.Strength,
                    LandscapeBrush.Flatten => h + (_flatten - h) * w * dab.Strength,
                    LandscapeBrush.Noise => h + (2 * ValueNoise(x / NoiseCell, y / NoiseCell) - 1) * amount * w,
                    LandscapeBrush.Hole => 0,
                    LandscapeBrush.Fill => 65535,
                    _ => h,
                };
                Grid[x, y] = (ushort)Math.Clamp(Math.Round(h), 0, 65535);
            }
        }
        return rect;
    }

    /// <summary>The tiles that the stroke changed, with their texels before and after it.</summary>
    public IReadOnlyList<TilePatch> Patches()
    {
        var patches = new List<TilePatch>();
        foreach (var (tx, ty) in _tiles.OrderBy(t => t.Y).ThenBy(t => t.X))
        {
            var rect = Grid.TileOf(tx, ty);
            var before = Original.Read(rect);
            var after = Grid.Read(rect);
            if (!before.AsSpan().SequenceEqual(after))
            {
                patches.Add(new TilePatch(rect, before, after));
            }
        }
        return patches;
    }

    /// <summary>Puts back every tile that the stroke changed, and gives the rectangle that holds them.</summary>
    public TexelRect Restore()
    {
        var changed = TexelRect.Empty;
        foreach (var (tx, ty) in _tiles)
        {
            var rect = Grid.TileOf(tx, ty);
            Grid.Write(rect, Original.Read(rect));
            changed = changed.Union(rect);
        }
        return changed;
    }

    // A ramp is drawn again from the stroke's start to the dab at each step, over what the grid was.
    TexelRect Ramp(BrushDab dab)
    {
        var restored = Restore();
        var rect = Bounds(_start.X, _start.Y, dab.X, dab.Y, dab);
        if (rect.IsEmpty)
        {
            return restored;
        }
        Touch(rect);
        var end = Original.Sample(dab.X / Grid.Width, dab.Y / Grid.Height);
        // Along the segment, in the brush's units, where the radius is 1 along both axes.
        double ax = _start.X / dab.RadiusX, ay = _start.Y / dab.RadiusY;
        double bx = dab.X / dab.RadiusX, by = dab.Y / dab.RadiusY;
        double ux = bx - ax, uy = by - ay;
        var lengthSquared = ux * ux + uy * uy;
        for (var y = rect.Y; y < rect.Bottom; y++)
        {
            for (var x = rect.X; x < rect.Right; x++)
            {
                double px = (x + 0.5) / dab.RadiusX - ax, py = (y + 0.5) / dab.RadiusY - ay;
                var t = lengthSquared > 1e-12 ? Math.Clamp((px * ux + py * uy) / lengthSquared, 0, 1) : 0;
                var w = Weight(px - ux * t, py - uy * t, dab.Falloff);
                if (w <= 0)
                {
                    continue;
                }
                double h = Grid[x, y];
                var target = _start.Height + (end - _start.Height) * t;
                Grid[x, y] = (ushort)Math.Clamp(Math.Round(h + (target - h) * w * dab.Strength), 0, 65535);
            }
        }
        return restored.Union(rect);
    }

    void Touch(TexelRect rect)
    {
        foreach (var tile in Grid.TilesIn(rect))
        {
            _tiles.Add(tile);
        }
    }

    // The texels within the brush's radius of a segment from (x0, y0) to (x1, y1), inside the grid.
    TexelRect Bounds(double x0, double y0, double x1, double y1, BrushDab dab)
    {
        var left = (int)Math.Floor(Math.Min(x0, x1) - dab.RadiusX);
        var top = (int)Math.Floor(Math.Min(y0, y1) - dab.RadiusY);
        var right = (int)Math.Ceiling(Math.Max(x0, x1) + dab.RadiusX);
        var bottom = (int)Math.Ceiling(Math.Max(y0, y1) + dab.RadiusY);
        return new TexelRect(left, top, right - left, bottom - top).Clamp(Grid.Width, Grid.Height);
    }

    /// <summary>
    /// A brush's weight at a distance from its center, in radii along each axis: 1 inside the part that does not fall
    /// off, 0 past the radius, and a smooth step between.
    /// </summary>
    public static double Weight(double dx, double dy, double falloff)
    {
        var d = Math.Sqrt(dx * dx + dy * dy);
        if (d >= 1)
        {
            return 0;
        }
        var inner = 1 - Math.Clamp(falloff, 0, 1);
        if (d <= inner)
        {
            return 1;
        }
        var t = (d - inner) / (1 - inner);
        return 1 - t * t * (3 - 2 * t);
    }

    static double Mean(HeightGrid g, int x, int y)
    {
        var sum = 0.0;
        for (var j = -1; j <= 1; j++)
        {
            for (var i = -1; i <= 1; i++)
            {
                sum += g.At(x + i, y + j);
            }
        }
        return sum / 9;
    }

    // Value noise from 0 to 1: a hash at each lattice point, blended smoothly between them.
    static double ValueNoise(double x, double y)
    {
        int ix = (int)Math.Floor(x), iy = (int)Math.Floor(y);
        double fx = x - ix, fy = y - iy;
        fx = fx * fx * (3 - 2 * fx);
        fy = fy * fy * (3 - 2 * fy);
        var top = Lerp(Hash(ix, iy), Hash(ix + 1, iy), fx);
        var bottom = Lerp(Hash(ix, iy + 1), Hash(ix + 1, iy + 1), fx);
        return Lerp(top, bottom, fy);
    }

    static double Lerp(double a, double b, double t) => a + (b - a) * t;

    static double Hash(int x, int y)
    {
        var h = 0x811c9dc5u;
        h = (h ^ (uint)x) * 0x01000193;
        h = (h ^ (uint)y) * 0x01000193;
        h ^= h >> 15;
        h *= 0x2c1b3c6d;
        h ^= h >> 12;
        return h / 4294967296.0;
    }
}
