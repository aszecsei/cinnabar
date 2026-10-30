namespace Cinnabar.Editor.Maths;

/// <summary>A unit quaternion, x, y, z and w, as the engine stores rotations.</summary>
public readonly record struct Quat(double X, double Y, double Z, double W)
{
    public static Quat Identity => new(0, 0, 0, 1);

    public double Length => Math.Sqrt(X * X + Y * Y + Z * Z + W * W);

    public Quat Normalized()
    {
        var l = Length;
        return new(X / l, Y / l, Z / l, W / l);
    }

    public Quat Conjugate => new(-X, -Y, -Z, W);

    public static Quat operator *(Quat a, Quat b) => new(
        a.W * b.X + a.X * b.W + a.Y * b.Z - a.Z * b.Y,
        a.W * b.Y - a.X * b.Z + a.Y * b.W + a.Z * b.X,
        a.W * b.Z + a.X * b.Y - a.Y * b.X + a.Z * b.W,
        a.W * b.W - a.X * b.X - a.Y * b.Y - a.Z * b.Z);

    public double[] Rotate(double[] v)
    {
        var r = this * new Quat(v[0], v[1], v[2], 0) * Conjugate;
        return [r.X, r.Y, r.Z];
    }
}

/// <summary>Rotations of vectors and the quaternions that make them.</summary>
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
