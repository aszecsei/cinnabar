using Cinnabar.Editor.Maths;

namespace Cinnabar.Editor.Document;

/// <summary>
/// A terrain as the landscape tools see it (see docs/editor/landscape.md#the-terrain): a <c>Surface_Renderer</c>'s
/// entity, its rectangle, its finest cell, its height range, and its height map's and hole mask's GUIDs ("" for none).
/// A height map texel of 0 is <see cref="Low"/> and 65535 is <see cref="High"/>, which is how a <c>Height_Field</c>
/// collider reads it.
/// </summary>
public sealed record LandscapeSurface(ulong Entity, double SizeX, double SizeZ, double Cell, double Low, double High, string HeightMap, string HoleMask)
{
    /// <summary>The <c>Surface_Renderer</c>'s stable ID.</summary>
    public const ulong ComponentId = 51;

    /// <summary>The finest cell's size when the component leaves <c>cell</c> at 0, the engine's <c>DEFAULT_SURFACE_CELL</c>.</summary>
    public const double DefaultCell = 1;

    /// <summary>The surface of an entity of the scene, or null when it has no <c>Surface_Renderer</c>.</summary>
    public static LandscapeSurface? Of(SceneEntity entity)
    {
        if (entity.Components.FirstOrDefault(c => c.Id == ComponentId) is not { } component)
        {
            return null;
        }
        SceneValue? Field(string name) => component.Fields.FirstOrDefault(f => f.Name == name)?.Value;
        double Number(string name, int i, double otherwise) =>
            Field(name) is { Kind: SceneValueKind.Number } v && v.Numbers.Count > i ? v.Numbers[i].Float : otherwise;
        string Asset(string name) => Field(name) is { Kind: SceneValueKind.Asset } v ? v.Asset : "";
        var cell = Number("cell", 0, 0);
        return new LandscapeSurface(entity.Id, Number("size", 0, 0), Number("size", 1, 0), cell > 0 ? cell : DefaultCell,
            Number("height_range", 0, 0), Number("height_range", 1, 0), Asset("height_map"), Asset("hole_mask"));
    }

    /// <summary>The finest cells along x and z: the size of a new hole mask, one texel each.</summary>
    public (int X, int Z) Cells => (Math.Max(1, (int)Math.Ceiling(SizeX / Cell)), Math.Max(1, (int)Math.Ceiling(SizeZ / Cell)));

    /// <summary>The height in meters above the surface's plane of a height map's value from 0 to 65535.</summary>
    public double HeightOf(double texel) => Low + texel / 65535 * (High - Low);

    /// <summary>A point on the plane, in the surface's space, as <c>uv0</c>.</summary>
    public (double U, double V) UvOf(double x, double z) => (x / SizeX + 0.5, z / SizeZ + 0.5);

    /// <summary>A place of <c>uv0</c> on the plane, in the surface's space.</summary>
    public (double X, double Z) PointOf(double u, double v) => ((u - 0.5) * SizeX, (v - 0.5) * SizeZ);
}

/// <summary>Where a ray hit a terrain: the point in the surface's space, its <c>uv0</c>, and the distance along the ray.</summary>
public readonly record struct LandscapeHit(Vec3 Local, double U, double V, double Distance);

/// <summary>
/// The editor's own pick of a terrain (see docs/editor/landscape.md#strokes), at once, as mesh mode picks its meshes: a
/// ray against the height map, as the vertex shader displaces the surface at its finest level, where the mask has no
/// hole.
/// </summary>
public static class LandscapePick
{
    /// <summary>The steps of the march along a cell, before the hit is refined.</summary>
    const double StepsPerCell = 2;

    /// <summary>
    /// The first hit of a ray, both relative to the surface's entity: from a point <paramref name="origin"/> along
    /// <paramref name="direction"/>, in the entity's space, scale and all, or null for none.
    /// </summary>
    public static LandscapeHit? Ray(LandscapeSurface surface, HeightGrid height, HeightGrid? mask, Vec3 origin, Vec3 direction)
    {
        if (surface.SizeX <= 0 || surface.SizeZ <= 0)
        {
            return null;
        }
        // Where the ray is inside the box of the rectangle and its heights.
        double low = Math.Min(surface.Low, surface.High), high = Math.Max(surface.Low, surface.High);
        var min = new Vec3(-surface.SizeX / 2, low - 1e-3, -surface.SizeZ / 2);
        var max = new Vec3(surface.SizeX / 2, high + 1e-3, surface.SizeZ / 2);
        double enter = 0, leave = double.MaxValue;
        for (var axis = 0; axis < 3; axis++)
        {
            if (Math.Abs(direction[axis]) < 1e-12)
            {
                if (origin[axis] < min[axis] || origin[axis] > max[axis])
                {
                    return null;
                }
                continue;
            }
            var a = (min[axis] - origin[axis]) / direction[axis];
            var b = (max[axis] - origin[axis]) / direction[axis];
            enter = Math.Max(enter, Math.Min(a, b));
            leave = Math.Min(leave, Math.Max(a, b));
        }
        if (enter > leave)
        {
            return null;
        }
        double Above(double t)
        {
            var p = origin + direction * t;
            var (u, v) = surface.UvOf(p.X, p.Z);
            return p.Y - surface.HeightOf(height.Sample(u, v));
        }
        // Steps of half a cell across, or of a 64th of the heights down a ray that falls straight.
        var across = Math.Sqrt(direction.X * direction.X + direction.Z * direction.Z);
        var cell = Math.Min(surface.SizeX / height.Width, surface.SizeZ / height.Height);
        var step = across > 1e-12 ? cell / StepsPerCell / across : double.MaxValue;
        if (Math.Abs(direction.Y) > 1e-12)
        {
            step = Math.Min(step, Math.Max(high - low, 1e-3) / 64 / Math.Abs(direction.Y));
        }
        var t0 = enter;
        var above0 = Above(t0);
        while (t0 < leave)
        {
            var t1 = Math.Min(t0 + step, leave);
            var above1 = Above(t1);
            if (above0 > 0 && above1 <= 0)
            {
                // Halve the step until the hit is a thousandth of a cell from the surface.
                double a = t0, b = t1;
                for (var i = 0; i < 24; i++)
                {
                    var m = (a + b) / 2;
                    if (Above(m) > 0)
                    {
                        a = m;
                    }
                    else
                    {
                        b = m;
                    }
                }
                var p = origin + direction * b;
                var (u, v) = surface.UvOf(p.X, p.Z);
                if (mask == null || mask.Nearest(u, v) > 0)
                {
                    return new LandscapeHit(p, u, v, b);
                }
            }
            (t0, above0) = (t1, above1);
            if (t1 >= leave)
            {
                break;
            }
        }
        return null;
    }
}
