using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Mesh;

/// <summary>A directed edge of a face's boundary: from one corner to the next, in the face's winding.</summary>
public readonly record struct HalfEdge(int From, int To, int Face);

/// <summary>
/// A set of faces as the region tools see it (see docs/editor/mesh-editing.md#mesh-tools): its boundary, the half-edges
/// of its faces whose other side is not in the region, chained into loops in the faces' winding, and the vertices on
/// it. Faces that share an edge act as one region, so a wall or a ring goes around them, not between them.
/// </summary>
public sealed class MeshRegion
{
    public MeshRegion(MeshData mesh, IEnumerable<int> faces)
    {
        Mesh = mesh;
        Faces = faces.Where(f => f >= 0 && f < mesh.Faces.Length).ToHashSet();
        var boundary = new List<HalfEdge>();
        foreach (var f in Faces.Order())
        {
            var corners = mesh.Faces[f].Corners;
            for (var k = 0; k < corners.Length; k++)
            {
                var (a, b) = (corners[k], corners[(k + 1) % corners.Length]);
                if (a == b)
                {
                    continue;
                }
                var others = mesh.FacesOfEdge(new MeshEdge(a, b));
                if (others.Count < 2 || others.Any(o => !Faces.Contains(o)))
                {
                    boundary.Add(new HalfEdge(a, b, f));
                }
            }
        }
        Boundary = boundary;
        BoundaryVertices = boundary.SelectMany(h => new[] { h.From, h.To }).ToHashSet();
        Vertices = Faces.SelectMany(f => mesh.Faces[f].Corners).ToHashSet();
    }

    public MeshData Mesh { get; }

    public HashSet<int> Faces { get; }

    /// <summary>The boundary's half-edges, in the faces' winding: the region is on their left seen from the front.</summary>
    public IReadOnlyList<HalfEdge> Boundary { get; }

    public HashSet<int> BoundaryVertices { get; }

    /// <summary>Every vertex that a face of the region uses.</summary>
    public HashSet<int> Vertices { get; }

    /// <summary>The vertices of the region that no boundary edge touches: inside it.</summary>
    public IEnumerable<int> InteriorVertices => Vertices.Where(v => !BoundaryVertices.Contains(v));

    /// <summary>The average of the faces' normals, unit, or the first face's when they cancel.</summary>
    public Vec3 Normal
    {
        get
        {
            var sum = Vec3.Zero;
            foreach (var f in Faces)
            {
                sum += Mesh.FaceNormal(f);
            }
            if (sum.Length > 1e-9)
            {
                return sum.Normalized();
            }
            return Faces.Count > 0 ? Mesh.FaceNormal(Faces.Min()) : Vec3.UnitY;
        }
    }

    /// <summary>
    /// The boundary chained into loops, each a list of vertices in winding order, or null when a boundary vertex has
    /// more than one way on, as at a pinch, which the tools refuse.
    /// </summary>
    public List<List<int>>? Loops()
    {
        var next = new Dictionary<int, int>();
        foreach (var h in Boundary)
        {
            if (!next.TryAdd(h.From, h.To))
            {
                return null;
            }
        }
        var loops = new List<List<int>>();
        var seen = new HashSet<int>();
        foreach (var start in Boundary.Select(h => h.From))
        {
            if (!seen.Add(start))
            {
                continue;
            }
            var loop = new List<int> { start };
            var at = start;
            while (next.TryGetValue(at, out var to) && to != start)
            {
                if (!seen.Add(to))
                {
                    return null;
                }
                loop.Add(to);
                at = to;
            }
            if (!next.ContainsKey(at) || next[at] != start)
            {
                return null;
            }
            loops.Add(loop);
        }
        return loops;
    }

    /// <summary>The selected faces grouped into regions of faces that share an edge.</summary>
    public static List<HashSet<int>> Connected(MeshData mesh, IEnumerable<int> faces)
    {
        var chosen = faces.Where(f => f >= 0 && f < mesh.Faces.Length).ToHashSet();
        var groups = new List<HashSet<int>>();
        var seen = new HashSet<int>();
        foreach (var start in chosen.Order())
        {
            if (!seen.Add(start))
            {
                continue;
            }
            var group = new HashSet<int> { start };
            var queue = new Queue<int>([start]);
            while (queue.Count > 0)
            {
                var f = queue.Dequeue();
                var corners = mesh.Faces[f].Corners;
                for (var k = 0; k < corners.Length; k++)
                {
                    foreach (var other in mesh.FacesOfEdge(new MeshEdge(corners[k], corners[(k + 1) % corners.Length])))
                    {
                        if (chosen.Contains(other) && seen.Add(other))
                        {
                            group.Add(other);
                            queue.Enqueue(other);
                        }
                    }
                }
            }
            groups.Add(group);
        }
        return groups;
    }

    /// <summary>
    /// The inward direction of a boundary half-edge within its face's plane: unit, perpendicular to the edge, toward
    /// the face's inside.
    /// </summary>
    public Vec3 Inward(HalfEdge h)
    {
        var direction = (Mesh.Vertices[h.To] - Mesh.Vertices[h.From]).Normalized();
        return Vec3.Cross(Mesh.FaceNormal(h.Face), direction).Normalized();
    }

    /// <summary>
    /// The move that offsets each boundary vertex inward by a distance along the bisector of its two boundary edges,
    /// so the inset edges stay parallel to the old ones at the distance.
    /// </summary>
    public Dictionary<int, Vec3> InsetOffsets(double distance)
    {
        var offsets = new Dictionary<int, Vec3>();
        var inwards = new Dictionary<int, List<Vec3>>();
        foreach (var h in Boundary)
        {
            var m = Inward(h);
            foreach (var v in new[] { h.From, h.To })
            {
                if (!inwards.TryGetValue(v, out var list))
                {
                    inwards[v] = list = [];
                }
                list.Add(m);
            }
        }
        foreach (var (v, list) in inwards)
        {
            offsets[v] = Bisector(list) * distance;
        }
        return offsets;
    }

    /// <summary>
    /// The shortest move that takes a point a unit distance along each of some directions at once: the direction for
    /// one, the bisector scaled by the angle for two, and the least-norm solution for more, or their average when they
    /// do not agree.
    /// </summary>
    public static Vec3 Bisector(IReadOnlyList<Vec3> normals)
    {
        if (normals.Count == 0)
        {
            return Vec3.Zero;
        }
        if (normals.Count == 1)
        {
            return normals[0];
        }
        if (normals.Count == 2)
        {
            var d = Vec3.Dot(normals[0], normals[1]);
            return d < -0.999 ? normals[0] : (normals[0] + normals[1]) / (1 + d);
        }
        // Minimum-norm x with Nx = 1: x = Nᵀ (N Nᵀ)⁻¹ 1, for the first three directions that span.
        var n = normals.Take(3).ToArray();
        var g = new double[3, 3];
        for (var i = 0; i < 3; i++)
        {
            for (var j = 0; j < 3; j++)
            {
                g[i, j] = Vec3.Dot(n[i], n[j]);
            }
        }
        if (Solve(g, [1, 1, 1]) is { } y)
        {
            return n[0] * y[0] + n[1] * y[1] + n[2] * y[2];
        }
        var sum = normals.Aggregate(Vec3.Zero, (s, v) => s + v);
        return sum.Length < 1e-9 ? normals[0] : sum.Normalized();
    }

    // Gaussian elimination for a 3 by 3 system, or null when it is singular.
    static double[]? Solve(double[,] a, double[] b)
    {
        var m = (double[,])a.Clone();
        var r = (double[])b.Clone();
        for (var col = 0; col < 3; col++)
        {
            var pivot = col;
            for (var row = col + 1; row < 3; row++)
            {
                if (Math.Abs(m[row, col]) > Math.Abs(m[pivot, col]))
                {
                    pivot = row;
                }
            }
            if (Math.Abs(m[pivot, col]) < 1e-9)
            {
                return null;
            }
            for (var k = 0; k < 3; k++)
            {
                (m[col, k], m[pivot, k]) = (m[pivot, k], m[col, k]);
            }
            (r[col], r[pivot]) = (r[pivot], r[col]);
            for (var row = 0; row < 3; row++)
            {
                if (row == col)
                {
                    continue;
                }
                var factor = m[row, col] / m[col, col];
                for (var k = 0; k < 3; k++)
                {
                    m[row, k] -= factor * m[col, k];
                }
                r[row] -= factor * r[col];
            }
        }
        return [r[0] / m[0, 0], r[1] / m[1, 1], r[2] / m[2, 2]];
    }
}
