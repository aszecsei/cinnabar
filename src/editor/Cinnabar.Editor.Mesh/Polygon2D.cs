using Cinnabar.Editor.Maths;

namespace Cinnabar.Editor.Mesh;

/// <summary>Tests on a polygon of 3D points in the plane of its dominant axes.</summary>
public static class Polygon2D
{
    /// <summary>Whether a polygon's edges cross each other, tested in the plane of its two largest extents.</summary>
    public static bool Crosses(IReadOnlyList<Vec3> points)
    {
        var normal = MeshData.FaceNormal([.. points], [.. Enumerable.Range(0, points.Count)]);
        var (u, v) = Axes(normal);
        var n = points.Count;
        for (var i = 0; i < n; i++)
        {
            for (var j = i + 1; j < n; j++)
            {
                // Edges that share a corner do not count.
                if (j == i + 1 || (i == 0 && j == n - 1))
                {
                    continue;
                }
                var (a, b) = (points[i], points[(i + 1) % n]);
                var (c, d) = (points[j], points[(j + 1) % n]);
                if (Intersect((a[u], a[v]), (b[u], b[v]), (c[u], c[v]), (d[u], d[v])))
                {
                    return true;
                }
            }
        }
        return false;
    }

    static bool Intersect((double X, double Y) a, (double X, double Y) b, (double X, double Y) c, (double X, double Y) d)
    {
        static double Cross((double X, double Y) p, (double X, double Y) q, (double X, double Y) r) => (q.X - p.X) * (r.Y - p.Y) - (q.Y - p.Y) * (r.X - p.X);
        var (d1, d2, d3, d4) = (Cross(c, d, a), Cross(c, d, b), Cross(a, b, c), Cross(a, b, d));
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
    }

    /// <summary>The two axes, as indexes, of the plane of a polygon with this normal: the axes other than its largest.</summary>
    public static (int, int) Axes(Vec3 normal)
    {
        var (ax, ay, az) = (Math.Abs(normal.X), Math.Abs(normal.Y), Math.Abs(normal.Z));
        return ax >= ay && ax >= az ? (1, 2) : ay >= az ? (0, 2) : (0, 1);
    }

    /// <summary>
    /// Whether a point in a polygon's plane is inside it: an even-odd crossing test in the plane's dominant axes, which
    /// takes concave polygons.
    /// </summary>
    public static bool Inside(Vec3[] points, Vec3 normal, Vec3 point)
    {
        var (u, v) = Axes(normal);
        var inside = false;
        for (int i = 0, j = points.Length - 1; i < points.Length; j = i++)
        {
            var (pi, pj) = (points[i], points[j]);
            if (pi[v] > point[v] != pj[v] > point[v])
            {
                var x = (pj[u] - pi[u]) * (point[v] - pi[v]) / (pj[v] - pi[v]) + pi[u];
                if (point[u] < x)
                {
                    inside = !inside;
                }
            }
        }
        return inside;
    }
}
