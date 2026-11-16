namespace Cinnabar.Editor.Document;

/// <summary>A rectangle of texels: its least corner and its size. An empty one has no texels.</summary>
public readonly record struct TexelRect(int X, int Y, int Width, int Height)
{
    public static TexelRect Empty => default;

    public bool IsEmpty => Width <= 0 || Height <= 0;

    public int Right => X + Width;

    public int Bottom => Y + Height;

    /// <summary>The least rectangle that holds both.</summary>
    public TexelRect Union(TexelRect other)
    {
        if (IsEmpty)
        {
            return other;
        }
        if (other.IsEmpty)
        {
            return this;
        }
        int x = Math.Min(X, other.X), y = Math.Min(Y, other.Y);
        return new TexelRect(x, y, Math.Max(Right, other.Right) - x, Math.Max(Bottom, other.Bottom) - y);
    }

    /// <summary>The part of the rectangle inside a grid of this size.</summary>
    public TexelRect Clamp(int width, int height)
    {
        int x = Math.Max(X, 0), y = Math.Max(Y, 0);
        int right = Math.Min(Right, width), bottom = Math.Min(Bottom, height);
        return right <= x || bottom <= y ? Empty : new TexelRect(x, y, right - x, bottom - y);
    }
}

/// <summary>
/// One channel of an image as the landscape tools paint it (see docs/editor/landscape.md#height-maps-and-masks):
/// <see cref="Width"/> by <see cref="Height"/> texels from 0 to 65535, row-major from the top, which is the least v of
/// <c>uv0</c> and the least z of the surface. A height map's texel is its height between the surface's
/// <c>height_range</c>, and a hole mask's is 0 for a hole. Undo keeps it in tiles of <see cref="Tile"/> texels.
/// </summary>
public sealed class HeightGrid
{
    /// <summary>A side of the tiles that a stroke's undo keeps.</summary>
    public const int Tile = 32;

    public HeightGrid(int width, int height, ushort[] texels)
    {
        if (width <= 0 || height <= 0 || texels.Length != width * height)
        {
            throw new ArgumentException($"a grid of {width} by {height} has {width * height} texels, not {texels.Length}");
        }
        Width = width;
        Height = height;
        Texels = texels;
    }

    public HeightGrid(int width, int height, ushort fill) : this(width, height, Filled(width * height, fill))
    {
    }

    public int Width { get; }

    public int Height { get; }

    public ushort[] Texels { get; }

    public ushort this[int x, int y]
    {
        get => Texels[y * Width + x];
        set => Texels[y * Width + x] = value;
    }

    /// <summary>The texel at a place, clamped to the edges.</summary>
    public ushort At(int x, int y) => Texels[Math.Clamp(y, 0, Height - 1) * Width + Math.Clamp(x, 0, Width - 1)];

    /// <summary>The grid at a point of <c>uv0</c>, from 0 to 1, as a linear, clamped sampler reads mip 0.</summary>
    public double Sample(double u, double v)
    {
        var px = u * Width - 0.5;
        var py = v * Height - 0.5;
        var x = (int)Math.Floor(px);
        var y = (int)Math.Floor(py);
        double fx = px - x, fy = py - y;
        var top = At(x, y) + (At(x + 1, y) - At(x, y)) * fx;
        var bottom = At(x, y + 1) + (At(x + 1, y + 1) - At(x, y + 1)) * fx;
        return top + (bottom - top) * fy;
    }

    /// <summary>The texel at a point of <c>uv0</c>, as a Load of its floor does.</summary>
    public ushort Nearest(double u, double v) => At((int)Math.Floor(u * Width), (int)Math.Floor(v * Height));

    public HeightGrid Copy() => new(Width, Height, (ushort[])Texels.Clone());

    /// <summary>The texels of a rectangle inside the grid, row-major.</summary>
    public ushort[] Read(TexelRect rect)
    {
        var out16 = new ushort[rect.Width * rect.Height];
        for (var y = 0; y < rect.Height; y++)
        {
            Array.Copy(Texels, (rect.Y + y) * Width + rect.X, out16, y * rect.Width, rect.Width);
        }
        return out16;
    }

    /// <summary>Writes the texels of a rectangle inside the grid, row-major.</summary>
    public void Write(TexelRect rect, ushort[] texels)
    {
        for (var y = 0; y < rect.Height; y++)
        {
            Array.Copy(texels, y * rect.Width, Texels, (rect.Y + y) * Width + rect.X, rect.Width);
        }
    }

    /// <summary>The tile that holds a texel, as its rectangle, clamped to the grid.</summary>
    public TexelRect TileOf(int tx, int ty) => new TexelRect(tx * Tile, ty * Tile, Tile, Tile).Clamp(Width, Height);

    /// <summary>The tiles, by their indices, that a rectangle touches.</summary>
    public IEnumerable<(int X, int Y)> TilesIn(TexelRect rect)
    {
        rect = rect.Clamp(Width, Height);
        if (rect.IsEmpty)
        {
            yield break;
        }
        for (var ty = rect.Y / Tile; ty <= (rect.Bottom - 1) / Tile; ty++)
        {
            for (var tx = rect.X / Tile; tx <= (rect.Right - 1) / Tile; tx++)
            {
                yield return (tx, ty);
            }
        }
    }

    static ushort[] Filled(int count, ushort fill)
    {
        var texels = new ushort[count];
        Array.Fill(texels, fill);
        return texels;
    }
}
