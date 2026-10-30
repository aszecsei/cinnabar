namespace Cinnabar.Editor.Maths;

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
