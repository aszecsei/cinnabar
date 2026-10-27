using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Mesh;

/// <summary>The primitives of the Create group (see docs/editor/mesh-editing.md#primitives-and-draw).</summary>
public enum PrimitiveKind
{
    Block,
    Wedge,
    Cylinder,
    Cone,
    Sphere,
    Arch,
    Stairs,
    Torus,
    Plane,
}

/// <summary>The parameters of the primitives, which stay editable after a drag until the next edit.</summary>
public sealed record PrimitiveParameters(int Sides = 16, int Segments = 16, int Rings = 8, double Thickness = 0.25, double Arc = 180, int Steps = 8, double TubeRadius = 0.25)
{
    public static PrimitiveParameters Default => new();
}

/// <summary>
/// The generators that new geometry starts as (see docs/editor/mesh-editing.md#primitives-and-draw): each fills a box
/// between two corners, standing along a world axis, and gives a mesh closed and fronting out, except Plane and Arch,
/// with a mapping on every face: world-aligned, or around a round side with u continuous.
/// </summary>
public static class Primitives
{
    /// <summary>
    /// A box between two corners, in the mesh's space, as the cooker's mesh template is: six quads, clockwise seen from
    /// their fronts, world-aligned mappings at a scale, every edge sharp, and the material in slot 0.
    /// </summary>
    public static MeshData Block(Vec3 min, Vec3 max, double mappingScale = Mapping.DefaultScale, string material = "") =>
        Make(PrimitiveKind.Block, min, max, 1, PrimitiveParameters.Default, mappingScale, material);

    /// <summary>
    /// A primitive filling the box between two corners, standing along an axis (0 x, 1 y, 2 z), with its parameters.
    /// A box with no extent along an axis is given a little, so every face has area.
    /// </summary>
    public static MeshData Make(PrimitiveKind kind, Vec3 min, Vec3 max, int axis, PrimitiveParameters p, double mappingScale = Mapping.DefaultScale, string material = "")
    {
        var lo = new Vec3(Math.Min(min.X, max.X), Math.Min(min.Y, max.Y), Math.Min(min.Z, max.Z));
        var hi = new Vec3(Math.Max(min.X, max.X), Math.Max(min.Y, max.Y), Math.Max(min.Z, max.Z));
        var frame = new Frame(lo, hi, axis);
        var b = new Builder(frame, mappingScale);
        switch (kind)
        {
            case PrimitiveKind.Block:
                Box(b, 0, frame.Width, 0, frame.Height, 0, frame.Depth);
                break;
            case PrimitiveKind.Wedge:
                Wedge(b);
                break;
            case PrimitiveKind.Cylinder:
                Cylinder(b, Math.Clamp(p.Sides, 3, 64), cone: false);
                break;
            case PrimitiveKind.Cone:
                Cylinder(b, Math.Clamp(p.Sides, 3, 64), cone: true);
                break;
            case PrimitiveKind.Sphere:
                Sphere(b, Math.Clamp(p.Segments, 8, 64), Math.Clamp(p.Rings, 4, 32));
                break;
            case PrimitiveKind.Arch:
                Arch(b, Math.Clamp(p.Sides, 3, 64), Math.Max(p.Thickness, 0.01), Math.Clamp(p.Arc, 10, 360));
                break;
            case PrimitiveKind.Stairs:
                Stairs(b, Math.Clamp(p.Steps, 1, 64));
                break;
            case PrimitiveKind.Torus:
                Torus(b, Math.Clamp(p.Segments, 8, 64), Math.Clamp(p.Sides, 3, 32), Math.Max(p.TubeRadius, 0.01));
                break;
            case PrimitiveKind.Plane:
                b.Face([b.At(0, 0, 0), b.At(0, 0, frame.Depth), b.At(frame.Width, 0, frame.Depth), b.At(frame.Width, 0, 0)]);
                break;
        }
        return b.Build(material);
    }

    /// <summary>Whether a primitive is closed: every edge has two faces.</summary>
    public static bool IsClosed(PrimitiveKind kind) => kind is not (PrimitiveKind.Plane or PrimitiveKind.Arch);

    // A box of the frame, from x0 to x1 and so on, as the template's faces are.
    static void Box(Builder b, double x0, double x1, double y0, double y1, double z0, double z1)
    {
        int[] v =
        [
            b.At(x0, y0, z0), b.At(x1, y0, z0), b.At(x1, y0, z1), b.At(x0, y0, z1),
            b.At(x0, y1, z0), b.At(x1, y1, z0), b.At(x1, y1, z1), b.At(x0, y1, z1),
        ];
        foreach (var f in new[] { new[] { 0, 1, 2, 3 }, [4, 7, 6, 5], [0, 4, 5, 1], [2, 6, 7, 3], [3, 7, 4, 0], [1, 5, 6, 2] })
        {
            b.Face([.. f.Select(i => v[i])], sharp: true);
        }
    }

    static void Wedge(Builder b)
    {
        var (w, h, d) = (b.Frame.Width, b.Frame.Height, b.Frame.Depth);
        int[] v = [b.At(0, 0, 0), b.At(w, 0, 0), b.At(w, 0, d), b.At(0, 0, d), b.At(0, h, d), b.At(w, h, d)];
        b.Face([v[0], v[1], v[2], v[3]], sharp: true);
        b.Face([v[2], v[5], v[4], v[3]], sharp: true);
        b.Face([v[0], v[4], v[5], v[1]], sharp: true);
        b.Face([v[3], v[4], v[0]], sharp: true);
        b.Face([v[1], v[5], v[2]], sharp: true);
    }

    // A cylinder, or a cone with the top ring a point. The sides are mapped around, with u continuous.
    static void Cylinder(Builder b, int sides, bool cone)
    {
        var (w, h, d) = (b.Frame.Width, b.Frame.Height, b.Frame.Depth);
        var bottom = new int[sides];
        var top = new int[sides];
        for (var i = 0; i < sides; i++)
        {
            var angle = 2 * Math.PI * i / sides;
            var (x, z) = (w / 2 + w / 2 * Math.Cos(angle), d / 2 + d / 2 * Math.Sin(angle));
            bottom[i] = b.At(x, 0, z);
            if (!cone)
            {
                top[i] = b.At(x, h, z);
            }
        }
        b.Face(bottom, sharp: true);
        var tip = cone ? b.At(w / 2, h, d / 2) : -1;
        if (!cone)
        {
            b.Face([.. top.Reverse()], sharp: true);
        }
        var around = 0.0;
        for (var i = 0; i < sides; i++)
        {
            var next = (i + 1) % sides;
            var face = cone ? b.Face([bottom[i], tip, bottom[next]]) : b.Face([bottom[i], top[i], top[next], bottom[next]]);
            b.MapAround(face, bottom[i], bottom[next], around);
            around += (b.Position(bottom[next]) - b.Position(bottom[i])).Length;
        }
    }

    static void Sphere(Builder b, int segments, int rings)
    {
        var (w, h, d) = (b.Frame.Width, b.Frame.Height, b.Frame.Depth);
        var center = (w / 2, h / 2, d / 2);
        var top = b.At(w / 2, h, d / 2);
        var bottom = b.At(w / 2, 0, d / 2);
        var ring = new int[rings - 1, segments];
        for (var r = 1; r < rings; r++)
        {
            var phi = Math.PI * r / rings;
            for (var i = 0; i < segments; i++)
            {
                var theta = 2 * Math.PI * i / segments;
                ring[r - 1, i] = b.At(center.Item1 + w / 2 * Math.Sin(phi) * Math.Cos(theta), center.Item2 + h / 2 * Math.Cos(phi), center.Item3 + d / 2 * Math.Sin(phi) * Math.Sin(theta));
            }
        }
        for (var i = 0; i < segments; i++)
        {
            var next = (i + 1) % segments;
            var around = 2 * Math.PI * i / segments * (w / 2);
            var cap = b.Face([ring[0, i], top, ring[0, next]]);
            b.MapAround(cap, ring[0, i], ring[0, next], around);
            for (var r = 0; r + 1 < rings - 1; r++)
            {
                var face = b.Face([ring[r + 1, i], ring[r, i], ring[r, next], ring[r + 1, next]]);
                b.MapAround(face, ring[r + 1, i], ring[r + 1, next], around);
            }
            var floor = b.Face([bottom, ring[rings - 2, i], ring[rings - 2, next]]);
            b.MapAround(floor, ring[rings - 2, i], ring[rings - 2, next], around);
        }
    }

    // A bent wall around the box's middle: an arc of its outer radii, a thickness in, with quads outside, inside, on
    // top and underneath, open at its ends.
    static void Arch(Builder b, int sides, double thickness, double arcDegrees)
    {
        var (w, h, d) = (b.Frame.Width, b.Frame.Height, b.Frame.Depth);
        var inner = (Math.Max(w / 2 - thickness, 0.01), Math.Max(d / 2 - thickness, 0.01));
        var arc = arcDegrees * Math.PI / 180;
        var count = arcDegrees >= 360 ? sides : sides + 1;
        var outerBottom = new int[count];
        var outerTop = new int[count];
        var innerBottom = new int[count];
        var innerTop = new int[count];
        for (var i = 0; i < count; i++)
        {
            var angle = arc * i / sides;
            var (c, s) = (Math.Cos(angle), Math.Sin(angle));
            outerBottom[i] = b.At(w / 2 + w / 2 * c, 0, d / 2 + d / 2 * s);
            outerTop[i] = b.At(w / 2 + w / 2 * c, h, d / 2 + d / 2 * s);
            innerBottom[i] = b.At(w / 2 + inner.Item1 * c, 0, d / 2 + inner.Item2 * s);
            innerTop[i] = b.At(w / 2 + inner.Item1 * c, h, d / 2 + inner.Item2 * s);
        }
        var around = 0.0;
        for (var i = 0; i < sides; i++)
        {
            var next = (i + 1) % count;
            var outside = b.Face([outerBottom[i], outerTop[i], outerTop[next], outerBottom[next]]);
            b.MapAround(outside, outerBottom[i], outerBottom[next], around);
            var inside = b.Face([innerBottom[next], innerTop[next], innerTop[i], innerBottom[i]]);
            b.MapAround(inside, innerBottom[next], innerBottom[i], around);
            b.Face([outerTop[i], innerTop[i], innerTop[next], outerTop[next]], sharp: true);
            b.Face([outerBottom[next], innerBottom[next], innerBottom[i], outerBottom[i]], sharp: true);
            around += (b.Position(outerBottom[next]) - b.Position(outerBottom[i])).Length;
        }
    }

    // Steps rising along y as they go along z, solid underneath: each step's tread and riser, the bottom, the back and
    // the two side profiles.
    static void Stairs(Builder b, int steps)
    {
        var (w, h, d) = (b.Frame.Width, b.Frame.Height, b.Frame.Depth);
        var (rise, run) = (h / steps, d / steps);
        var (frontLeft, frontRight) = (b.At(0, 0, 0), b.At(w, 0, 0));
        var left = new List<int> { frontLeft };
        var right = new List<int> { frontRight };
        for (var k = 0; k < steps; k++)
        {
            var (z0, z1, y) = (k * run, (k + 1) * run, (k + 1) * rise);
            var (l0, l1, r0, r1) = (b.At(0, y, z0), b.At(0, y, z1), b.At(w, y, z0), b.At(w, y, z1));
            // The riser, facing -z, from the step below's height to this one's.
            b.Face([left[^1], l0, r0, right[^1]], sharp: true);
            // The tread, facing up.
            b.Face([l0, l1, r1, r0], sharp: true);
            left.AddRange([l0, l1]);
            right.AddRange([r0, r1]);
        }
        var (backLeft, backRight) = (b.At(0, 0, d), b.At(w, 0, d));
        left.Add(backLeft);
        right.Add(backRight);
        b.Face([frontLeft, frontRight, backRight, backLeft], sharp: true);
        b.Face([backRight, right[^2], left[^2], backLeft], sharp: true);
        // The left profile faces -x: the loop goes up the stairs and back along the bottom, seen from -x it is clockwise.
        b.Face([.. left], sharp: true);
        b.Face([.. Enumerable.Reverse(right)], sharp: true);
    }

    static void Torus(Builder b, int segments, int sides, double tube)
    {
        var (w, h, d) = (b.Frame.Width, b.Frame.Height, b.Frame.Depth);
        var major = (Math.Max(w / 2 - tube, 0.01), Math.Max(d / 2 - tube, 0.01));
        var radius = Math.Min(tube, h / 2);
        var ring = new int[segments, sides];
        for (var i = 0; i < segments; i++)
        {
            var theta = 2 * Math.PI * i / segments;
            var (c, s) = (Math.Cos(theta), Math.Sin(theta));
            for (var j = 0; j < sides; j++)
            {
                var phi = 2 * Math.PI * j / sides;
                var outward = radius * Math.Cos(phi);
                ring[i, j] = b.At(w / 2 + (major.Item1 + outward) * c, h / 2 + radius * Math.Sin(phi), d / 2 + (major.Item2 + outward) * s);
            }
        }
        for (var i = 0; i < segments; i++)
        {
            var next = (i + 1) % segments;
            var around = 2 * Math.PI * i / segments * major.Item1;
            for (var j = 0; j < sides; j++)
            {
                var up = (j + 1) % sides;
                var face = b.Face([ring[i, j], ring[i, up], ring[next, up], ring[next, j]]);
                b.MapAround(face, ring[i, j], ring[next, j], around);
            }
        }
    }

    /// <summary>The box's frame: its corner and the extents along its right, up and forward axes, which follow the standing axis.</summary>
    sealed class Frame
    {
        public Frame(Vec3 lo, Vec3 hi, int axis)
        {
            axis = ((axis % 3) + 3) % 3;
            // Right, up and forward are a cyclic turn of x, y and z, so the frame keeps the world's handedness and
            // faces built clockwise from their fronts stay so.
            (Up, Right, Forward) = (MeshGrid.AxisVector(axis), MeshGrid.AxisVector((axis + 2) % 3), MeshGrid.AxisVector((axis + 1) % 3));
            Origin = lo;
            var size = hi - lo;
            // No extent is a sliver, not nothing.
            double Extent(Vec3 along) => Math.Max(Vec3.Dot(size, along), 0.001);
            (Width, Height, Depth) = (Extent(Right), Extent(Up), Extent(Forward));
        }

        public Vec3 Origin { get; }
        public Vec3 Right { get; }
        public Vec3 Up { get; }
        public Vec3 Forward { get; }
        public double Width { get; }
        public double Height { get; }
        public double Depth { get; }

        public Vec3 At(double x, double y, double z) => Origin + Right * x + Up * y + Forward * z;
    }

    sealed class Builder(Frame frame, double mappingScale)
    {
        readonly List<Vec3> _vertices = [];
        readonly List<(List<int> Corners, Mapping? Mapping)> _faces = [];
        readonly HashSet<MeshEdge> _sharp = [];

        public Frame Frame { get; } = frame;

        public int At(double x, double y, double z)
        {
            _vertices.Add(Frame.At(x, y, z));
            return _vertices.Count - 1;
        }

        public Vec3 Position(int vertex) => _vertices[vertex];

        /// <summary>Adds a face of corners, clockwise seen from its front, and returns its index. Its mapping is world-aligned unless set.</summary>
        public int Face(int[] corners, bool sharp = false)
        {
            _faces.Add((corners.ToList(), null));
            if (sharp)
            {
                for (var i = 0; i < corners.Length; i++)
                {
                    _sharp.Add(new MeshEdge(corners[i], corners[(i + 1) % corners.Length]));
                }
            }
            return _faces.Count - 1;
        }

        /// <summary>
        /// Maps a face around a round side: u along the edge from one vertex to the next, continuing from a distance
        /// around so far, and v down the standing axis, so one repeat goes once round.
        /// </summary>
        public void MapAround(int face, int from, int to, double around)
        {
            var u = (_vertices[to] - _vertices[from]).Normalized();
            if (u == Vec3.Zero)
            {
                return;
            }
            var shift = around / mappingScale - Vec3.Dot(_vertices[from], u) / mappingScale;
            _faces[face] = (_faces[face].Corners, new Mapping(u, -Frame.Up, mappingScale, mappingScale, shift, 0, 0));
        }

        public MeshData Build(string material)
        {
            var vertices = _vertices.ToArray();
            var faces = _faces.Select(f => new MeshFace(0, [.. f.Corners],
                f.Mapping ?? Mapping.WorldAligned(MeshData.FaceNormal([.. vertices], [.. f.Corners]), mappingScale)));
            return new MeshData([material], vertices, faces, _sharp);
        }
    }
}
