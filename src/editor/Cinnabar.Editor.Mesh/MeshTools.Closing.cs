using System.Collections.Immutable;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Mesh;

/// <summary>Bridge and Cap, which close open edges (see docs/editor/mesh-editing.md#mesh-tools).</summary>
public static partial class MeshTools
{
    /// <summary>Bridge and Cap mark an edge of their new faces sharp beyond this angle, in degrees, as Recalculate Normals does.</summary>
    public const double ClosingSharpDegrees = 30;

    /// <summary>
    /// Joins two loops of selected open edges with a strip of quads, one quad for each pair of edges, and selects the
    /// strip. The loops must have the same number of edges. Each loop's vertices pair with the other's that are
    /// nearest about their centers. A quad takes the material and the mapping of its neighbor whose plane is nearest
    /// its own, or a world-aligned mapping at that neighbor's scale when the neighbor's mapping lies edge-on to it.
    /// </summary>
    public static (ToolResult Result, string? Reason) Bridge(MeshData mesh, IEnumerable<int> edges)
    {
        var unchanged = new ToolResult(mesh, MeshElement.Edges, [.. edges]);
        var (loops, reason) = OpenLoops(mesh, edges);
        if (loops == null)
        {
            return (unchanged, reason);
        }
        if (loops.Count != 2)
        {
            return (unchanged, $"bridge needs two loops of open edges, and the selected edges make {loops.Count}");
        }
        var (a, b) = (loops[0], loops[1]);
        if (a.Vertices.Count != b.Vertices.Count)
        {
            return (unchanged, $"bridge needs two loops of the same number of edges, and these have {a.Vertices.Count} and {b.Vertices.Count}");
        }
        var n = a.Vertices.Count;
        var (ca, cb) = (Centroid(mesh, a.Vertices), Centroid(mesh, b.Vertices));
        // B runs against A, so a quad goes along each loop's edge the other way round from the face beside it. The
        // offset pairs each vertex of A with the vertex of B nearest it about the loops' centers.
        int B(int m, int i) => b.Vertices[(((m - i) % n) + n) % n];
        var best = 0;
        var bestCost = double.MaxValue;
        for (var m = 0; m < n; m++)
        {
            var cost = 0.0;
            for (var i = 0; i < n; i++)
            {
                var d = (mesh.Vertices[a.Vertices[i]] - ca) - (mesh.Vertices[B(m, i)] - cb);
                cost += Vec3.Dot(d, d);
            }
            if (cost < bestCost)
            {
                (best, bestCost) = (m, cost);
            }
        }
        var faces = mesh.Faces.ToBuilder();
        var added = new List<int>();
        for (var i = 0; i < n; i++)
        {
            ImmutableArray<int> quad = [a.Vertices[(i + 1) % n], a.Vertices[i], B(best, i), B(best, i + 1)];
            var normal = MeshData.FaceNormal(mesh.Vertices, quad);
            var (fa, fb) = (a.Faces[i], b.Faces[(((best - i - 1) % n) + n) % n]);
            var near = Vec3.Dot(mesh.FaceNormal(fa), normal) >= Vec3.Dot(mesh.FaceNormal(fb), normal) ? mesh.Faces[fa] : mesh.Faces[fb];
            var mapping = EdgeOn(near.Mapping, normal) ? Mapping.WorldAligned(normal, near.Mapping.ScaleU) : near.Mapping;
            added.Add(faces.Count);
            faces.Add(new MeshFace(near.Slot, quad, mapping));
        }
        var result = RecalculateNormals(mesh.With(faces: faces), ClosingSharpDegrees, added);
        return (new ToolResult(result, MeshElement.Faces, added), null);
    }

    /// <summary>
    /// Fills one loop of selected open edges and selects the fill: one face for a convex loop, or the bake's triangles
    /// for a concave one. The fill takes the material of the face beside the loop's first edge and a world-aligned
    /// mapping at a scale. A loop that is not planar within <see cref="MeshData.PlanarTolerance"/>, or that crosses
    /// itself, is refused with the reason.
    /// </summary>
    public static (ToolResult Result, string? Reason) Cap(MeshData mesh, IEnumerable<int> edges, double mappingScale = Mapping.DefaultScale)
    {
        var unchanged = new ToolResult(mesh, MeshElement.Edges, [.. edges]);
        var (loops, reason) = OpenLoops(mesh, edges);
        if (loops == null)
        {
            return (unchanged, reason);
        }
        if (loops.Count != 1)
        {
            return (unchanged, $"cap needs one loop of open edges, and the selected edges make {loops.Count}");
        }
        var loop = loops[0];
        // The fill goes round the other way from the faces beside it.
        var cap = loop.Vertices.AsEnumerable().Reverse().ToImmutableArray();
        var normal = MeshData.FaceNormal(mesh.Vertices, cap);
        if (normal == Vec3.Zero)
        {
            return (unchanged, "the loop has no area");
        }
        var distance = cap.Average(c => Vec3.Dot(normal, mesh.Vertices[c]));
        var bend = cap.Max(c => Math.Abs(Vec3.Dot(normal, mesh.Vertices[c]) - distance));
        if (bend > MeshData.PlanarTolerance)
        {
            return (unchanged, $"the loop is not planar: it bends by {bend * 1000:0.##} mm, and a cap allows {MeshData.PlanarTolerance * 1000:0.##}");
        }
        var points = cap.Select(c => mesh.Vertices[c]).ToList();
        if (Polygon2D.Crosses(points) || Polygon2D.Triangulate(points, normal, out var convex) is not { } triangles)
        {
            return (unchanged, "the loop crosses itself");
        }
        var slot = mesh.Faces[loop.Faces[0]].Slot;
        var mapping = Mapping.WorldAligned(normal, mappingScale);
        var faces = mesh.Faces.ToBuilder();
        var added = new List<int>();
        IEnumerable<ImmutableArray<int>> fill = convex ? [cap] : triangles.Select(t => ImmutableArray.Create(cap[t.A], cap[t.B], cap[t.C]));
        foreach (var corners in fill)
        {
            added.Add(faces.Count);
            faces.Add(new MeshFace(slot, corners, mapping));
        }
        var result = RecalculateNormals(mesh.With(faces: faces), ClosingSharpDegrees, added);
        return (new ToolResult(result, MeshElement.Faces, added), null);
    }

    // A loop of open edges: its vertices in the winding of the faces beside it, and the face beside each edge, the
    // edge from vertex i to vertex i + 1.
    sealed record OpenLoop(List<int> Vertices, List<int> Faces);

    // The selected edges chained into loops, each edge going the way its one face goes along it. An edge that is not
    // open, a vertex where the edges branch, and edges that do not close are each a reason.
    static (List<OpenLoop>? Loops, string? Reason) OpenLoops(MeshData mesh, IEnumerable<int> edges)
    {
        var next = new Dictionary<int, (int To, int Face)>();
        var order = new List<int>();
        foreach (var e in edges.Where(e => e >= 0 && e < mesh.Edges.Length).Distinct().Order())
        {
            var edge = mesh.Edges[e];
            var beside = mesh.FacesOfEdge(edge);
            if (beside.Count != 1)
            {
                return (null, $"the edge {edge.A} {edge.B} is not open: it has {beside.Count} faces");
            }
            var corners = mesh.Faces[beside[0]].Corners;
            var k = corners.IndexOf(edge.A);
            var (from, to) = corners[(k + 1) % corners.Length] == edge.B ? (edge.A, edge.B) : (edge.B, edge.A);
            if (!next.TryAdd(from, (to, beside[0])))
            {
                return (null, $"the selected edges branch at vertex {from}");
            }
            order.Add(from);
        }
        if (next.Count == 0)
        {
            return (null, "no open edges are selected");
        }
        var loops = new List<OpenLoop>();
        var seen = new HashSet<int>();
        foreach (var start in order)
        {
            if (seen.Contains(start))
            {
                continue;
            }
            var loop = new OpenLoop([], []);
            var at = start;
            while (seen.Add(at))
            {
                if (!next.TryGetValue(at, out var step))
                {
                    return (null, "the selected edges do not close into a loop");
                }
                loop.Vertices.Add(at);
                loop.Faces.Add(step.Face);
                at = step.To;
            }
            if (at != start)
            {
                return (null, $"the selected edges branch at vertex {at}");
            }
            loops.Add(loop);
        }
        return (loops, null);
    }

    // Whether a mapping's plane is nearly edge-on to a face, so its texture would smear along the face.
    static bool EdgeOn(Mapping mapping, Vec3 normal)
    {
        var plane = Vec3.Cross(mapping.UAxis, mapping.VAxis).Normalized();
        return Math.Abs(Vec3.Dot(plane, normal)) < 0.1;
    }
}
