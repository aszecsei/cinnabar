using System.Collections.Immutable;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;

namespace Cinnabar.Editor.Mesh;

/// <summary>
/// What a boolean operation gives: the new mesh, in the target's space, and for each of its faces the target face it
/// came from, or -1 for a face that the cutter made. With a reason, the operation was refused and the mesh is the
/// target as it was.
/// </summary>
public sealed record BooleanResult(MeshData Mesh, int[] SourceFace, string? Reason);

/// <summary>
/// Subtract, Union and Intersect of two solid meshes (see docs/editor/mesh-editing.md#booleans), by BSP clipping of
/// planar polygons in doubles, in the target's space. Each side's faces are clipped by the other side's tree, never
/// by their own, so a target face that the cutter does not cross comes through as it was. The fragments are then
/// welded, joined at their T-junctions, merged back per source face and cleaned of the vertices the splits left on
/// straight edges.
/// </summary>
public static class MeshBoolean
{
    /// <summary>A point is on a plane within this, in meters: Clean's weld distance.</summary>
    public const double PlaneEpsilon = MeshTools.WeldDistance;

    enum Op { Subtract, Union, Intersect }


    /// <summary>The target without the cutter's volume. The faces that the cutter makes take <paramref name="capSlot"/>.</summary>
    public static BooleanResult Subtract(MeshData target, Pose targetPose, MeshData cutter, Pose cutterPose, int capSlot) =>
        Run(Op.Subtract, target, MeshPlacement.Between(cutterPose, targetPose), cutter, capSlot);

    /// <summary>The volume of either mesh, as one mesh in the target's space.</summary>
    public static BooleanResult Union(MeshData target, Pose targetPose, MeshData cutter, Pose cutterPose, int capSlot) =>
        Run(Op.Union, target, MeshPlacement.Between(cutterPose, targetPose), cutter, capSlot);

    /// <summary>The volume that both meshes have.</summary>
    public static BooleanResult Intersect(MeshData target, Pose targetPose, MeshData cutter, Pose cutterPose, int capSlot) =>
        Run(Op.Intersect, target, MeshPlacement.Between(cutterPose, targetPose), cutter, capSlot);

    // A convex planar polygon of one side, with the face of that side it is a fragment of.
    sealed record Poly(List<Vec3> Points, Vec3 Normal, double W, int Source);

    sealed class Node(Vec3 normal, double w)
    {
        public Vec3 Normal { get; } = normal;
        public double W { get; } = w;
        public Node? Front { get; set; }
        public Node? Back { get; set; }
    }

    static BooleanResult Run(Op op, MeshData target, MeshAffine toTarget, MeshData cutter, int capSlot)
    {
        BooleanResult Refuse(string reason) => new(target, [.. Enumerable.Range(0, target.Faces.Length)], reason);
        if (!target.IsSolid)
        {
            return Refuse("the target is not solid");
        }
        if (!cutter.IsSolid)
        {
            return Refuse("the cutter is not solid");
        }
        if (capSlot < 0 || capSlot >= MeshData.MaxSlots)
        {
            return Refuse($"the slot {capSlot} is not one of the mesh's {MeshData.MaxSlots}");
        }
        if (Moved(cutter, toTarget) is not { } moved)
        {
            return Refuse("the cutter's scale is zero on an axis");
        }
        var (targetMin, targetMax) = Bounds(target.Vertices);
        var (cutterMin, cutterMax) = Bounds(moved.Vertices);
        var pad = new Vec3(PlaneEpsilon, PlaneEpsilon, PlaneEpsilon);
        (cutterMin, cutterMax) = (cutterMin - pad, cutterMax + pad);
        if (!Overlap(targetMin, targetMax, cutterMin, cutterMax))
        {
            return op switch
            {
                Op.Subtract => new BooleanResult(target, [.. Enumerable.Range(0, target.Faces.Length)], null),
                Op.Union => Appended(target, moved, capSlot),
                _ => Refuse("the meshes do not meet"),
            };
        }

        // A target face that misses the cutter's bounds is wholly outside the cutter, and stays as it is.
        var near = new bool[target.Faces.Length];
        for (var i = 0; i < target.Faces.Length; i++)
        {
            var (min, max) = Bounds(target.Faces[i].Corners.Select(c => target.Vertices[c]));
            near[i] = Overlap(min, max, cutterMin, cutterMax);
        }
        var targetTree = Build(Polygons(target, Enumerable.Range(0, target.Faces.Length)));
        var cutterTree = Build(Polygons(moved, Enumerable.Range(0, moved.Faces.Length)));

        // The coplanar rules: a fragment on one of the other side's planes counts as inside it or outside it by
        // whether it faces the same way. They are csg.js's, without its inversions.
        var (keptTarget, droppedTarget) = Clip(Polygons(target, Enumerable.Range(0, target.Faces.Length).Where(i => near[i])), cutterTree,
            keepInside: op == Op.Intersect, sameInside: op != Op.Union, oppositeInside: op == Op.Union);
        var (keptCutter, _) = Clip(Polygons(moved, Enumerable.Range(0, moved.Faces.Length)), targetTree,
            keepInside: op != Op.Union, sameInside: op == Op.Union, oppositeInside: op == Op.Union);
        // A subtraction or a union that drops no target fragment and keeps no cutter fragment is the target as it was:
        // the cutter only touches it, or a union's cutter is inside it.
        if (op != Op.Intersect && droppedTarget.Count == 0 && keptCutter.Count == 0)
        {
            return new BooleanResult(target, [.. Enumerable.Range(0, target.Faces.Length)], null);
        }
        return Assemble(op, target, moved, near, keptTarget, droppedTarget, keptCutter, capSlot, Refuse);
    }

    // The cutter in the target's space, its faces reversed when the map mirrors, with its mappings moved along.
    static MeshData? Moved(MeshData cutter, MeshAffine toTarget)
    {
        var mirrors = toTarget.Determinant < 0;
        var faces = new List<MeshFace>();
        foreach (var f in cutter.Faces)
        {
            if (toTarget.MoveMapping(f.Mapping) is not { } mapping)
            {
                return null;
            }
            faces.Add(new MeshFace(f.Slot, mirrors ? [.. f.Corners.Reverse()] : f.Corners, mapping));
        }
        return cutter.With(vertices: cutter.Vertices.Select(toTarget.Apply), faces: faces, sharpEdges: []);
    }

    internal static (Vec3 Min, Vec3 Max) Bounds(IEnumerable<Vec3> points)
    {
        var (min, max) = (new Vec3(double.MaxValue, double.MaxValue, double.MaxValue), new Vec3(double.MinValue, double.MinValue, double.MinValue));
        foreach (var p in points)
        {
            min = new Vec3(Math.Min(min.X, p.X), Math.Min(min.Y, p.Y), Math.Min(min.Z, p.Z));
            max = new Vec3(Math.Max(max.X, p.X), Math.Max(max.Y, p.Y), Math.Max(max.Z, p.Z));
        }
        return (min, max);
    }

    internal static bool Overlap(Vec3 aMin, Vec3 aMax, Vec3 bMin, Vec3 bMax) =>
        aMin.X <= bMax.X && aMax.X >= bMin.X && aMin.Y <= bMax.Y && aMax.Y >= bMin.Y && aMin.Z <= bMax.Z && aMax.Z >= bMin.Z;

    // The target with the cutter's faces after it, as a union of meshes that do not meet is.
    static BooleanResult Appended(MeshData target, MeshData moved, int capSlot)
    {
        var offset = target.Vertices.Length;
        var faces = target.Faces.AddRange(moved.Faces.Select(f => new MeshFace(capSlot, [.. f.Corners.Select(c => c + offset)], f.Mapping)));
        var mesh = target.With(vertices: target.Vertices.AddRange(moved.Vertices), faces: faces);
        return new BooleanResult(mesh, [.. Enumerable.Range(0, target.Faces.Length), .. Enumerable.Repeat(-1, moved.Faces.Length)], null);
    }

    // The faces as convex polygons: a convex face as it is, a concave one as the bake's triangles.
    static List<Poly> Polygons(MeshData mesh, IEnumerable<int> faces)
    {
        var result = new List<Poly>();
        foreach (var f in faces)
        {
            var corners = mesh.Faces[f].Corners;
            var normal = mesh.FaceNormal(f);
            if (normal == Vec3.Zero)
            {
                continue;
            }
            var points = corners.Select(c => mesh.Vertices[c]).ToList();
            var w = points.Average(p => Vec3.Dot(normal, p));
            var triangles = Polygon2D.Triangulate(points, normal, out var convex);
            if (convex || triangles == null)
            {
                result.Add(new Poly(points, normal, w, f));
                continue;
            }
            foreach (var (a, b, c) in triangles)
            {
                result.Add(new Poly([points[a], points[b], points[c]], normal, w, f));
            }
        }
        return result;
    }

    const int Coplanar = 0, Front = 1, Back = 2, Spanning = 3;

    // Splits a convex polygon by a plane into the parts in front and behind, or reports it coplanar.
    static int Split(Poly poly, Vec3 normal, double w, List<Poly>? front, List<Poly>? back)
    {
        var n = poly.Points.Count;
        var side = Side(poly, normal, w);
        if (side != Spanning || front == null || back == null)
        {
            if (side == Front)
            {
                front?.Add(poly);
            }
            else if (side == Back)
            {
                back?.Add(poly);
            }
            return side;
        }
        var types = new int[n];
        for (var i = 0; i < n; i++)
        {
            var d = Vec3.Dot(normal, poly.Points[i]) - w;
            types[i] = d < -PlaneEpsilon ? Back : d > PlaneEpsilon ? Front : Coplanar;
        }
        var (f, b) = (new List<Vec3>(), new List<Vec3>());
        for (var i = 0; i < n; i++)
        {
            var j = (i + 1) % n;
            var (ti, tj) = (types[i], types[j]);
            var (vi, vj) = (poly.Points[i], poly.Points[j]);
            if (ti != Back)
            {
                f.Add(vi);
            }
            if (ti != Front)
            {
                b.Add(vi);
            }
            if ((ti | tj) == Spanning)
            {
                var t = (w - Vec3.Dot(normal, vi)) / Vec3.Dot(normal, vj - vi);
                var v = vi + (vj - vi) * t;
                f.Add(v);
                b.Add(v);
            }
        }
        if (f.Count >= 3)
        {
            front.Add(poly with { Points = f });
        }
        if (b.Count >= 3)
        {
            back.Add(poly with { Points = b });
        }
        return Spanning;
    }

    // Which side of a plane a polygon is on, without splitting it.
    static int Side(Poly poly, Vec3 normal, double w)
    {
        var all = 0;
        foreach (var p in poly.Points)
        {
            var d = Vec3.Dot(normal, p) - w;
            all |= d < -PlaneEpsilon ? Back : d > PlaneEpsilon ? Front : Coplanar;
        }
        return all;
    }

    // A tree of a closed solid's planes, built without recursion, since a convex mesh makes a chain as deep as its
    // faces. Each node's plane is the one of a few sampled polygons that splits the fewest of the rest, or the first
    // that splits none, as every face of a convex mesh does.
    static Node? Build(List<Poly> polys)
    {
        if (polys.Count == 0)
        {
            return null;
        }
        var root = NewNode(polys);
        var stack = new Stack<(Node Node, List<Poly> Polys)>();
        stack.Push((root, polys));
        while (stack.Count > 0)
        {
            var (node, list) = stack.Pop();
            var (front, back) = (new List<Poly>(), new List<Poly>());
            foreach (var p in list)
            {
                Split(p, node.Normal, node.W, front, back);
            }
            if (front.Count > 0)
            {
                node.Front = NewNode(front);
                stack.Push((node.Front, front));
            }
            if (back.Count > 0)
            {
                node.Back = NewNode(back);
                stack.Push((node.Back, back));
            }
        }
        return root;
    }

    static Node NewNode(List<Poly> list)
    {
        var splitter = Splitter(list);
        return new Node(splitter.Normal, splitter.W);
    }

    static Poly Splitter(List<Poly> list)
    {
        const int Samples = 6;
        if (list.Count <= 2)
        {
            return list[0];
        }
        var best = list[0];
        var bestCost = int.MaxValue;
        var step = Math.Max(1, list.Count / Samples);
        for (var s = 0; s < list.Count && s / step < Samples; s += step)
        {
            var candidate = list[s];
            var (spans, fronts, backs) = (0, 0, 0);
            foreach (var p in list)
            {
                switch (Split(p, candidate.Normal, candidate.W, null, null))
                {
                    case Spanning:
                        spans++;
                        break;
                    case Front:
                        fronts++;
                        break;
                    case Back:
                        backs++;
                        break;
                }
            }
            var cost = spans * 8 + Math.Abs(fronts - backs);
            if (cost < bestCost)
            {
                (best, bestCost) = (candidate, cost);
            }
            if (spans == 0)
            {
                break;
            }
        }
        return best;
    }

    // The polygons cut by a tree into the fragments to keep and the sources of those dropped. A fragment ends
    // outside at a missing front child and inside at a missing back child; one on a node's plane goes inside or
    // outside by whether it faces the plane's way.
    static (List<Poly> Kept, HashSet<int> Dropped) Clip(List<Poly> polys, Node? tree, bool keepInside, bool sameInside, bool oppositeInside)
    {
        var kept = new List<Poly>();
        var dropped = new HashSet<int>();
        void End(Poly p, bool inside)
        {
            if (inside == keepInside)
            {
                kept.Add(p);
            }
            else
            {
                dropped.Add(p.Source);
            }
        }
        if (tree == null)
        {
            polys.ForEach(p => End(p, false));
            return (kept, dropped);
        }
        var stack = new Stack<(Node Node, List<Poly> Polys)>();
        stack.Push((tree, polys));
        while (stack.Count > 0)
        {
            var (node, list) = stack.Pop();
            var (front, back) = (new List<Poly>(), new List<Poly>());
            foreach (var p in list)
            {
                if (Split(p, node.Normal, node.W, front, back) == Coplanar)
                {
                    var inside = Vec3.Dot(p.Normal, node.Normal) > 0 ? sameInside : oppositeInside;
                    (inside ? back : front).Add(p);
                }
            }
            if (front.Count > 0)
            {
                if (node.Front == null)
                {
                    front.ForEach(p => End(p, false));
                }
                else
                {
                    stack.Push((node.Front, front));
                }
            }
            if (back.Count > 0)
            {
                if (node.Back == null)
                {
                    back.ForEach(p => End(p, true));
                }
                else
                {
                    stack.Push((node.Back, back));
                }
            }
        }
        return (kept, dropped);
    }

    // One face of the result before it is a MeshFace: its corners, slot and mapping, the target face it came from or
    // -1, and the group whose fragments merge: a target face's index, or a cutter face's as ~index.
    sealed record Piece(List<int> Corners, int Slot, Mapping Mapping, int Source, int Group, bool Far);

    static BooleanResult Assemble(Op op, MeshData target, MeshData moved, bool[] near, List<Poly> keptTarget, HashSet<int> droppedTarget,
        List<Poly> keptCutter, int capSlot, Func<string, BooleanResult> refuse)
    {
        var vertices = target.Vertices.ToBuilder();
        var weld = new Welder(vertices);
        var pieces = new List<Piece>();
        var fragments = keptTarget.GroupBy(p => p.Source).ToDictionary(g => g.Key, g => g.ToList());
        for (var i = 0; i < target.Faces.Length; i++)
        {
            var face = target.Faces[i];
            if (!near[i])
            {
                // A far face is outside the cutter: an intersection drops it, and the others keep it as it is.
                if (op != Op.Intersect)
                {
                    pieces.Add(new Piece([.. face.Corners], face.Slot, face.Mapping, i, i, true));
                }
                continue;
            }
            if (!droppedTarget.Contains(i))
            {
                // A face whose fragments the cut all keeps stays whole.
                pieces.Add(new Piece([.. face.Corners], face.Slot, face.Mapping, i, i, false));
                continue;
            }
            foreach (var p in fragments.GetValueOrDefault(i) ?? [])
            {
                pieces.Add(new Piece(weld.Indices(p.Points), face.Slot, face.Mapping, i, i, false));
            }
        }
        var reverse = op == Op.Subtract;
        foreach (var p in keptCutter)
        {
            var mapping = moved.Faces[p.Source].Mapping;
            var corners = weld.Indices(p.Points);
            if (reverse)
            {
                corners.Reverse();
                mapping = mapping with { VAxis = -mapping.VAxis };
            }
            pieces.Add(new Piece(corners, capSlot, mapping, -1, ~p.Source, false));
        }
        pieces = [.. pieces.Select(p => p with { Corners = Dedupe(p.Corners) }).Where(p => p.Corners.Distinct().Count() >= 3)];
        if (pieces.Count == 0)
        {
            return refuse(op == Op.Subtract ? "the cutter contains the target, so nothing is left" : "the meshes do not meet");
        }

        JoinTJunctions(pieces, vertices);
        pieces = Merge(pieces);

        var mesh = target.With(vertices: vertices, faces: pieces.Select(p => new MeshFace(p.Slot, [.. p.Corners], p.Mapping)), sharpEdges: []);
        // The split points that only straight edges need go, as Clean dissolves them.
        var dissolve = MeshTools.Collinear(mesh, v => v >= target.Vertices.Length);
        if (dissolve.Count > 0)
        {
            mesh = mesh.With(faces: mesh.Faces.Select(f => f with { Corners = [.. f.Corners.Where(c => !dissolve.Contains(c))] }));
        }
        mesh = mesh.With(sharpEdges: SharpEdges(target, mesh));
        var used = mesh.Faces.SelectMany(f => f.Corners).ToHashSet();
        mesh = MeshTools.Compact(mesh, [.. Enumerable.Range(0, mesh.Vertices.Length).Where(v => !used.Contains(v))], []);
        var cut = Enumerable.Range(0, pieces.Count).Where(i => pieces[i].Source < 0).ToList();
        mesh = MeshTools.RecalculateNormals(mesh, MeshTools.ClosingSharpDegrees, cut);

        if (mesh.Validate() is { Count: > 0 } problems)
        {
            return refuse($"the result is not valid: {string.Join("; ", problems)}");
        }
        if (!mesh.IsSolid)
        {
            return refuse(mesh.OpenEdges.Length is var open and > 0
                ? $"the result is not solid: {open} {(open == 1 ? "edge is" : "edges are")} open"
                : "the result is not solid");
        }
        return new BooleanResult(mesh, [.. pieces.Select(p => p.Source)], null);
    }

    // Positions to vertex indices, joining a position to an earlier vertex within the weld distance, through cells.
    sealed class Welder
    {
        readonly ImmutableArray<Vec3>.Builder _vertices;
        readonly Dictionary<(long, long, long), List<int>> _cells = [];

        public Welder(ImmutableArray<Vec3>.Builder vertices)
        {
            _vertices = vertices;
            for (var i = 0; i < vertices.Count; i++)
            {
                Cell(vertices[i]).Add(i);
            }
        }

        static (long, long, long) Key(Vec3 p) =>
            ((long)Math.Floor(p.X / MeshTools.WeldDistance), (long)Math.Floor(p.Y / MeshTools.WeldDistance), (long)Math.Floor(p.Z / MeshTools.WeldDistance));

        List<int> Cell(Vec3 p)
        {
            var key = Key(p);
            if (!_cells.TryGetValue(key, out var list))
            {
                _cells[key] = list = [];
            }
            return list;
        }

        public int Index(Vec3 p)
        {
            var (x, y, z) = Key(p);
            for (var dx = -1L; dx <= 1; dx++)
            {
                for (var dy = -1L; dy <= 1; dy++)
                {
                    for (var dz = -1L; dz <= 1; dz++)
                    {
                        if (_cells.TryGetValue((x + dx, y + dy, z + dz), out var near))
                        {
                            foreach (var j in near)
                            {
                                if ((_vertices[j] - p).Length <= MeshTools.WeldDistance)
                                {
                                    return j;
                                }
                            }
                        }
                    }
                }
            }
            _vertices.Add(p);
            Cell(p).Add(_vertices.Count - 1);
            return _vertices.Count - 1;
        }

        public List<int> Indices(IEnumerable<Vec3> points) => [.. points.Select(Index)];
    }

    // Corners without a repeat of the one before, around the face.
    static List<int> Dedupe(List<int> corners)
    {
        var result = new List<int>();
        foreach (var c in corners)
        {
            if (result.Count == 0 || result[^1] != c)
            {
                result.Add(c);
            }
        }
        while (result.Count > 1 && result[0] == result[^1])
        {
            result.RemoveAt(result.Count - 1);
        }
        return result;
    }

    // Puts each vertex that lies on an edge of a piece, between its ends, into that edge, so the pieces meet edge to
    // edge. The vertices are those of the pieces near the cut, but a split plane goes on past the cutter, so a far
    // piece's edge can take one too.
    static void JoinTJunctions(List<Piece> pieces, ImmutableArray<Vec3>.Builder vertices)
    {
        var candidates = pieces.Where(p => !p.Far).SelectMany(p => p.Corners).Distinct().OrderBy(v => vertices[v].X).ToArray();
        var xs = candidates.Select(v => vertices[v].X).ToArray();
        for (var i = 0; i < pieces.Count; i++)
        {
            var corners = pieces[i].Corners;
            var result = new List<int>();
            for (var k = 0; k < corners.Count; k++)
            {
                var (a, b) = (corners[k], corners[(k + 1) % corners.Count]);
                result.Add(a);
                var (pa, pb) = (vertices[a], vertices[b]);
                var d = pb - pa;
                var lengthSquared = Vec3.Dot(d, d);
                if (lengthSquared < 1e-18)
                {
                    continue;
                }
                var (lo, hi) = (Math.Min(pa.X, pb.X) - PlaneEpsilon, Math.Max(pa.X, pb.X) + PlaneEpsilon);
                var start = Array.BinarySearch(xs, lo);
                start = start < 0 ? ~start : start;
                while (start > 0 && xs[start - 1] >= lo)
                {
                    start--;
                }
                var on = new List<(double T, int V)>();
                for (var j = start; j < xs.Length && xs[j] <= hi; j++)
                {
                    var v = candidates[j];
                    if (v == a || v == b)
                    {
                        continue;
                    }
                    var t = Vec3.Dot(vertices[v] - pa, d) / lengthSquared;
                    if (t <= 0 || t >= 1)
                    {
                        continue;
                    }
                    if ((pa + d * t - vertices[v]).Length <= PlaneEpsilon)
                    {
                        on.Add((t, v));
                    }
                }
                if (on.Count == 0)
                {
                    continue;
                }
                on.Sort((x, y) => x.T.CompareTo(y.T));
                result.AddRange(on.Select(o => o.V));
            }
            if (result.Count != corners.Count)
            {
                pieces[i] = pieces[i] with { Corners = Dedupe(result) };
            }
        }
    }

    // Merges the fragments of each source face, two at a time, where they share an edge and the union's boundary is
    // one loop. A merge that would leave a hole is not made, so a face with a hole through it stays a ring of faces.
    static List<Piece> Merge(List<Piece> pieces)
    {
        var result = new List<Piece>();
        foreach (var group in pieces.GroupBy(p => p.Group))
        {
            var list = group.ToList();
            if (list.Count == 1 || list[0].Far)
            {
                result.AddRange(list);
                continue;
            }
            var merged = true;
            while (merged)
            {
                merged = false;
                for (var i = 0; i < list.Count && !merged; i++)
                {
                    for (var j = i + 1; j < list.Count && !merged; j++)
                    {
                        if (Joined(list[i].Corners, list[j].Corners) is { } loop)
                        {
                            list[i] = list[i] with { Corners = loop };
                            list.RemoveAt(j);
                            merged = true;
                        }
                    }
                }
            }
            result.AddRange(list);
        }
        return result;
    }

    // The boundary of two polygons that share edges, when it is one simple loop, or null.
    static List<int>? Joined(List<int> a, List<int> b)
    {
        var halves = new List<(int From, int To)>();
        foreach (var corners in new[] { a, b })
        {
            for (var k = 0; k < corners.Count; k++)
            {
                halves.Add((corners[k], corners[(k + 1) % corners.Count]));
            }
        }
        var set = halves.ToHashSet();
        var boundary = halves.Where(h => !set.Contains((h.To, h.From))).ToList();
        if (boundary.Count == halves.Count || boundary.Count < 3)
        {
            return null;
        }
        var next = new Dictionary<int, int>();
        foreach (var (from, to) in boundary)
        {
            if (!next.TryAdd(from, to))
            {
                return null;
            }
        }
        var loop = new List<int> { boundary[0].From };
        var at = next[boundary[0].From];
        while (at != boundary[0].From)
        {
            if (loop.Count > boundary.Count)
            {
                return null;
            }
            loop.Add(at);
            if (!next.TryGetValue(at, out at))
            {
                return null;
            }
        }
        return loop.Count == boundary.Count ? loop : null;
    }

    // The target's sharp edges in the result: each kept where it is still an edge, or else by the parts of it between
    // the new vertices that lie along it, where those are edges.
    static List<MeshEdge> SharpEdges(MeshData target, MeshData mesh)
    {
        var added = Enumerable.Range(target.Vertices.Length, mesh.Vertices.Length - target.Vertices.Length).Where(v => mesh.FacesOfVertex(v).Count > 0).ToList();
        var sharp = new List<MeshEdge>();
        foreach (var e in target.SharpEdges)
        {
            if (mesh.EdgeIndex(e.A, e.B) >= 0)
            {
                sharp.Add(e);
                continue;
            }
            var (pa, pb) = (mesh.Vertices[e.A], mesh.Vertices[e.B]);
            var d = pb - pa;
            var lengthSquared = Vec3.Dot(d, d);
            if (lengthSquared < 1e-18)
            {
                continue;
            }
            var chain = added
                .Select(v => (V: v, T: Vec3.Dot(mesh.Vertices[v] - pa, d) / lengthSquared))
                .Where(x => x.T > 0 && x.T < 1 && (pa + d * x.T - mesh.Vertices[x.V]).Length <= PlaneEpsilon)
                .OrderBy(x => x.T).Select(x => x.V).Prepend(e.A).Append(e.B).ToList();
            for (var k = 0; k + 1 < chain.Count; k++)
            {
                if (mesh.EdgeIndex(chain[k], chain[k + 1]) >= 0)
                {
                    sharp.Add(new MeshEdge(chain[k], chain[k + 1]));
                }
            }
        }
        return sharp;
    }
}
