using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Mesh;

/// <summary>
/// Hammer's grid, in meters (see docs/editor/mesh-editing.md#grid): sizes from 1/64 m to 16 m in powers of two, which
/// snapping rounds vertices' world positions to, and the plane that the game draws it on: through a point, facing the
/// camera's nearest world axis.
/// </summary>
public static class MeshGrid
{
    public const double MinSize = 1.0 / 64;
    public const double MaxSize = 16;
    public const double DefaultSize = 0.25;

    public static double Finer(double size) => Math.Max(size / 2, MinSize);

    public static double Coarser(double size) => Math.Min(size * 2, MaxSize);

    /// <summary>A size as the viewport shows it: "0.25 m", or "1/64 m" below an eighth, where the decimals get long.</summary>
    public static string Format(double size) => size >= 0.125 ? $"{size:0.###} m" : $"1/{Math.Round(1 / size):0} m";

    /// <summary>A position with each coordinate rounded to the grid.</summary>
    public static Vec3 Snap(Vec3 position, double size) =>
        new(Math.Round(position.X / size) * size, Math.Round(position.Y / size) * size, Math.Round(position.Z / size) * size);

    /// <summary>The world axis that a direction is nearest: 0 for x, 1 for y, 2 for z.</summary>
    public static int NearestAxis(Vec3 direction)
    {
        var (ax, ay, az) = (Math.Abs(direction.X), Math.Abs(direction.Y), Math.Abs(direction.Z));
        return ax >= ay && ax >= az ? 0 : ay >= az ? 1 : 2;
    }

    public static Vec3 AxisVector(int axis) => axis switch { 0 => Vec3.UnitX, 1 => Vec3.UnitY, _ => Vec3.UnitZ };

    /// <summary>Where a ray from the camera meets the plane through a point with a normal, both relative to the camera, or null.</summary>
    public static Vec3? HitPlane(Vec3 point, Vec3 normal, Vec3 ray)
    {
        var facing = Vec3.Dot(normal, ray);
        if (Math.Abs(facing) < 1e-9)
        {
            return null;
        }
        var t = Vec3.Dot(normal, point) / facing;
        return t > 0 ? ray * t : null;
    }
}
