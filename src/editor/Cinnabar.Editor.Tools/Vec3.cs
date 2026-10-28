using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Tools;

/// <summary>A vector in meters, in doubles. Positions relative to the camera are small, so doubles hold them exactly enough.</summary>
public readonly record struct Vec3(double X, double Y, double Z)
{
    public static Vec3 Zero => new(0, 0, 0);
    public static Vec3 UnitX => new(1, 0, 0);
    public static Vec3 UnitY => new(0, 1, 0);
    public static Vec3 UnitZ => new(0, 0, 1);

    public static Vec3 operator +(Vec3 a, Vec3 b) => new(a.X + b.X, a.Y + b.Y, a.Z + b.Z);
    public static Vec3 operator -(Vec3 a, Vec3 b) => new(a.X - b.X, a.Y - b.Y, a.Z - b.Z);
    public static Vec3 operator -(Vec3 a) => new(-a.X, -a.Y, -a.Z);
    public static Vec3 operator *(Vec3 a, double s) => new(a.X * s, a.Y * s, a.Z * s);
    public static Vec3 operator *(double s, Vec3 a) => a * s;
    public static Vec3 operator /(Vec3 a, double s) => new(a.X / s, a.Y / s, a.Z / s);

    public double this[int axis] => axis switch { 0 => X, 1 => Y, _ => Z };

    public double Length => Math.Sqrt(Dot(this, this));

    public Vec3 Normalized() => Length is var l and > 1e-12 ? this / l : Zero;

    public static double Dot(Vec3 a, Vec3 b) => a.X * b.X + a.Y * b.Y + a.Z * b.Z;

    public static Vec3 Cross(Vec3 a, Vec3 b) => new(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X);

    /// <summary>Each component times the other's: a scale applied to a vector.</summary>
    public static Vec3 Scale(Vec3 a, Vec3 b) => new(a.X * b.X, a.Y * b.Y, a.Z * b.Z);

    public static Vec3 From(double[] v) => new(v[0], v[1], v[2]);

    public double[] ToArray() => [X, Y, Z];

    /// <summary>The meters from one raw World_Position to another.</summary>
    public static Vec3 Between(long[] from, long[] to) =>
        new((to[0] - from[0]) / Pose.Unit, (to[1] - from[1]) / Pose.Unit, (to[2] - from[2]) / Pose.Unit);

    /// <summary>A raw World_Position moved by this many meters.</summary>
    public long[] Offset(long[] position) =>
        [position[0] + (long)Math.Round(X * Pose.Unit), position[1] + (long)Math.Round(Y * Pose.Unit), position[2] + (long)Math.Round(Z * Pose.Unit)];
}

/// <summary>A point on the viewport in pixels of the frame, from its top left.</summary>
public readonly record struct Vec2(double X, double Y)
{
    public static Vec2 operator +(Vec2 a, Vec2 b) => new(a.X + b.X, a.Y + b.Y);
    public static Vec2 operator -(Vec2 a, Vec2 b) => new(a.X - b.X, a.Y - b.Y);
    public static Vec2 operator *(Vec2 a, double s) => new(a.X * s, a.Y * s);

    public double Length => Math.Sqrt(X * X + Y * Y);

    /// <summary>The distance from a point to the segment from a to b.</summary>
    public static double DistanceToSegment(Vec2 p, Vec2 a, Vec2 b)
    {
        var ab = b - a;
        var lengthSquared = ab.X * ab.X + ab.Y * ab.Y;
        var t = lengthSquared < 1e-12 ? 0 : Math.Clamp(((p.X - a.X) * ab.X + (p.Y - a.Y) * ab.Y) / lengthSquared, 0, 1);
        return (p - (a + ab * t)).Length;
    }
}

public static class Rotations
{
    /// <summary>A turn about a unit axis by an angle in radians, counterclockwise as the axis points at the viewer.</summary>
    public static Quat AxisAngle(Vec3 axis, double angle)
    {
        var s = Math.Sin(angle / 2);
        return new Quat(axis.X * s, axis.Y * s, axis.Z * s, Math.Cos(angle / 2));
    }

    public static Vec3 Rotate(this Quat q, Vec3 v) => Vec3.From(q.Rotate(v.ToArray()));

    /// <summary>The rotation that takes the world's axes to an orthonormal, right-handed frame.</summary>
    public static Quat FromAxes(Vec3 x, Vec3 y, Vec3 z)
    {
        // Shepperd's method: the largest diagonal term picks the component to divide by.
        var trace = x.X + y.Y + z.Z;
        if (trace > 0)
        {
            var s = Math.Sqrt(trace + 1) * 2;
            return new Quat((y.Z - z.Y) / s, (z.X - x.Z) / s, (x.Y - y.X) / s, s / 4).Normalized();
        }
        if (x.X > y.Y && x.X > z.Z)
        {
            var s = Math.Sqrt(1 + x.X - y.Y - z.Z) * 2;
            return new Quat(s / 4, (x.Y + y.X) / s, (z.X + x.Z) / s, (y.Z - z.Y) / s).Normalized();
        }
        if (y.Y > z.Z)
        {
            var s = Math.Sqrt(1 + y.Y - x.X - z.Z) * 2;
            return new Quat((x.Y + y.X) / s, s / 4, (y.Z + z.Y) / s, (z.X - x.Z) / s).Normalized();
        }
        var t = Math.Sqrt(1 + z.Z - x.X - y.Y) * 2;
        return new Quat((z.X + x.Z) / t, (y.Z + z.Y) / t, t / 4, (x.Y - y.X) / t).Normalized();
    }
}
