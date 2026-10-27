using System.Collections.Immutable;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Mesh;

/// <summary>
/// How a face's texture lies on it (see docs/editor/mesh-editing.md#mesh-assets): two axes in the mesh's space, the
/// scale in meters per texture repeat, the shift in repeats and the rotation in degrees. A face stores this, not UVs,
/// so the texture tools are exact and reversible; the bake derives the UVs, in the editor and the cooker alike.
/// </summary>
public readonly record struct Mapping(Vec3 UAxis, Vec3 VAxis, double ScaleU, double ScaleV, double ShiftU, double ShiftV, double Rotation)
{
    /// <summary>The scale of a new face's mapping: one texture repeat per meter, as <c>format.MESH_DEFAULT_SCALE</c>.</summary>
    public const double DefaultScale = 1;

    /// <summary>
    /// The mapping of a face by its normal's nearest world axis, as Hammer gives new faces and as
    /// <c>format.mesh_world_mapping</c> does: a floor's u runs along +x and its v along -z, a side wall's along +z and
    /// -y, and a front wall's along +x and -y, so neighbors across a right angle share a seam.
    /// </summary>
    public static Mapping WorldAligned(Vec3 normal, double scale = DefaultScale)
    {
        var (ax, ay, az) = (Math.Abs(normal.X), Math.Abs(normal.Y), Math.Abs(normal.Z));
        var (u, v) = ay >= ax && ay >= az ? (Vec3.UnitX, new Vec3(0, 0, -1))
            : ax >= az ? (Vec3.UnitZ, new Vec3(0, -1, 0))
            : (Vec3.UnitX, new Vec3(0, -1, 0));
        return new Mapping(u, v, scale, scale, 0, 0, 0);
    }

    /// <summary>
    /// A position's UV: the position along each axis in repeats, turned by the rotation about the mapping's origin,
    /// then shifted. This is the bake's formula, so the Face panel can show what the cooker will write.
    /// </summary>
    public (double U, double V) Uv(Vec3 p)
    {
        var a = Vec3.Dot(p, UAxis) / ScaleU;
        var b = Vec3.Dot(p, VAxis) / ScaleV;
        var (sin, cos) = Math.SinCos(Rotation * Math.PI / 180);
        return (a * cos - b * sin + ShiftU, a * sin + b * cos + ShiftV);
    }
}

/// <summary>A polygon of three or more vertex indices, clockwise seen from its front, in one material slot.</summary>
public sealed record MeshFace(int Slot, ImmutableArray<int> Corners, Mapping Mapping)
{
    public bool Equals(MeshFace? other) =>
        other != null && Slot == other.Slot && Corners.SequenceEqual(other.Corners) && Mapping == other.Mapping;

    public override int GetHashCode() => HashCode.Combine(Slot, Corners.Length, Mapping);
}

/// <summary>An edge between two vertices, as the file writes it. Two edges are the same whichever way round they are.</summary>
public readonly record struct MeshEdge(int A, int B)
{
    public bool Equals(MeshEdge other) => (A == other.A && B == other.B) || (A == other.B && B == other.A);

    public override int GetHashCode() => Math.Min(A, B) * 31 + Math.Max(A, B);
}

/// <summary>A problem that a mesh has, at a face by index, or -1 for the whole mesh.</summary>
public sealed record MeshProblem(int Face, string Message)
{
    public override string ToString() => Face >= 0 ? $"face {Face}: {Message}" : Message;
}

/// <summary>
/// A mesh as its file has it (see docs/editor/mesh-editing.md#the-mesh-model): the material slots, the vertices in
/// meters in the mesh's space, the faces with their mappings, and the sharp edges. It is immutable: a tool takes one
/// and returns a new one, so an undo is a swap. Vertices and faces are dense indices, not IDs, since nothing outside
/// the file refers to them.
/// </summary>
public sealed class MeshData
{
    /// <summary>A mesh has at most this many material slots: <c>render.MAX_MATERIAL_SLOTS</c>.</summary>
    public const int MaxSlots = 8;

    /// <summary>Faces must be planar within this, in meters.</summary>
    public const double PlanarTolerance = 0.001;

    public static readonly MeshData Empty = new([], [], [], [], []);

    /// <summary>The material of each slot, as 32 lowercase hex digits, or <c>""</c> for a slot that names none.</summary>
    public ImmutableArray<string> Materials { get; }
    public ImmutableArray<Vec3> Vertices { get; }
    public ImmutableArray<MeshFace> Faces { get; }
    public ImmutableArray<MeshEdge> SharpEdges { get; }
    /// <summary>The comment lines before the file's <c>mesh 1</c> line, with their <c>#</c>, which a save keeps.</summary>
    public ImmutableArray<string> HeaderComments { get; }

    public MeshData(
        IEnumerable<string> materials,
        IEnumerable<Vec3> vertices,
        IEnumerable<MeshFace> faces,
        IEnumerable<MeshEdge> sharpEdges,
        IEnumerable<string>? headerComments = null)
    {
        // An array that is given as it is stays the same array, so a change that keeps the faces keeps their array,
        // which is how the live path tells a move from an edit of the topology.
        if (materials is ImmutableArray<string> { Length: MaxSlots } sameMaterials)
        {
            Materials = sameMaterials;
        }
        else
        {
            var slots = materials.Take(MaxSlots).ToList();
            while (slots.Count < MaxSlots)
            {
                slots.Add("");
            }
            Materials = [.. slots];
        }
        Vertices = vertices as ImmutableArray<Vec3>? ?? [.. vertices];
        Faces = faces as ImmutableArray<MeshFace>? ?? [.. faces];
        SharpEdges = sharpEdges as ImmutableArray<MeshEdge>? ?? [.. sharpEdges];
        HeaderComments = [.. headerComments ?? []];
    }

    public MeshData With(
        IEnumerable<string>? materials = null,
        IEnumerable<Vec3>? vertices = null,
        IEnumerable<MeshFace>? faces = null,
        IEnumerable<MeshEdge>? sharpEdges = null) =>
        new(materials ?? Materials, vertices ?? Vertices, faces ?? Faces, sharpEdges ?? SharpEdges, HeaderComments);

    public bool IsSharp(int a, int b) => SharpEdges.Contains(new MeshEdge(a, b));

    // The connectivity that the tools need, built once per snapshot, the first time it is asked for.
    Lazy<Connectivity> Links => _links ??= new Lazy<Connectivity>(() => new Connectivity(this));
    Lazy<Connectivity>? _links;

    /// <summary>Every edge of the mesh once, in the order the faces first use them, with the lower vertex first.</summary>
    public ImmutableArray<MeshEdge> Edges => Links.Value.Edges;

    /// <summary>An edge's index in <see cref="Edges"/>, or -1 for two vertices that no face joins.</summary>
    public int EdgeIndex(int a, int b) => Links.Value.EdgeIndices.GetValueOrDefault(new MeshEdge(a, b), -1);

    /// <summary>The faces that use a vertex, in face order.</summary>
    public IReadOnlyList<int> FacesOfVertex(int vertex) => Links.Value.VertexFaces.GetValueOrDefault(vertex) ?? [];

    /// <summary>The faces on each side of an edge: one or two, or more for an edge the Clean tool reports.</summary>
    public IReadOnlyList<int> FacesOfEdge(MeshEdge edge) => Links.Value.EdgeFaces.GetValueOrDefault(edge) ?? [];

    sealed class Connectivity
    {
        public ImmutableArray<MeshEdge> Edges { get; }
        public Dictionary<MeshEdge, int> EdgeIndices { get; } = [];
        public Dictionary<MeshEdge, List<int>> EdgeFaces { get; } = [];
        public Dictionary<int, List<int>> VertexFaces { get; } = [];

        public Connectivity(MeshData mesh)
        {
            var edges = new List<MeshEdge>();
            for (var i = 0; i < mesh.Faces.Length; i++)
            {
                var corners = mesh.Faces[i].Corners;
                for (var k = 0; k < corners.Length; k++)
                {
                    var (a, b) = (corners[k], corners[(k + 1) % corners.Length]);
                    if (!VertexFaces.TryGetValue(a, out var faces))
                    {
                        VertexFaces[a] = faces = [];
                    }
                    if (!faces.Contains(i))
                    {
                        faces.Add(i);
                    }
                    if (a == b)
                    {
                        continue;
                    }
                    var edge = new MeshEdge(Math.Min(a, b), Math.Max(a, b));
                    if (!EdgeIndices.ContainsKey(edge))
                    {
                        EdgeIndices[edge] = edges.Count;
                        edges.Add(edge);
                        EdgeFaces[edge] = [];
                    }
                    if (!EdgeFaces[edge].Contains(i))
                    {
                        EdgeFaces[edge].Add(i);
                    }
                }
            }
            Edges = [.. edges];
        }
    }

    /// <summary>
    /// A face's plane normal by Newell's method, which gives a bent n-gon its average plane: unit, or zero for a face
    /// without area. Faces are clockwise seen from their front, so the normal is the cross product of the first
    /// edges' way round, as <c>format.mesh_face_normal</c> has it.
    /// </summary>
    public Vec3 FaceNormal(int face) => FaceNormal(Vertices, Faces[face].Corners);

    public static Vec3 FaceNormal(ImmutableArray<Vec3> vertices, ImmutableArray<int> corners)
    {
        double x = 0, y = 0, z = 0;
        for (var i = 0; i < corners.Length; i++)
        {
            var c = corners[i];
            var next = corners[(i + 1) % corners.Length];
            if (c < 0 || c >= vertices.Length || next < 0 || next >= vertices.Length)
            {
                return Vec3.Zero;
            }
            var (p, q) = (vertices[c], vertices[next]);
            x += (p.Y - q.Y) * (p.Z + q.Z);
            y += (p.Z - q.Z) * (p.X + q.X);
            z += (p.X - q.X) * (p.Y + q.Y);
        }
        var n = new Vec3(x, y, z);
        return n.Length < 1e-12 ? Vec3.Zero : n / n.Length;
    }

    /// <summary>
    /// What is wrong with the mesh, which a tool's result must have none of: a face of fewer than three distinct
    /// vertices or with an index that no vertex has, a slot beyond the mesh's, a face that is not planar within a
    /// millimeter, a mapping with a zero scale, or an edge with more than two faces.
    /// </summary>
    public IReadOnlyList<MeshProblem> Validate()
    {
        var problems = new List<MeshProblem>();
        var edgeFaces = new Dictionary<MeshEdge, int>();
        for (var i = 0; i < Faces.Length; i++)
        {
            var f = Faces[i];
            if (f.Slot < 0 || f.Slot >= MaxSlots)
            {
                problems.Add(new MeshProblem(i, $"uses material slot {f.Slot}, and a mesh has {MaxSlots}"));
            }
            if (f.Corners.Any(c => c < 0 || c >= Vertices.Length))
            {
                problems.Add(new MeshProblem(i, "uses a vertex the mesh does not have"));
                continue;
            }
            if (f.Corners.Distinct().Count() < 3)
            {
                problems.Add(new MeshProblem(i, "has fewer than three distinct vertices"));
                continue;
            }
            if (f.Mapping.ScaleU == 0 || f.Mapping.ScaleV == 0)
            {
                problems.Add(new MeshProblem(i, "has a mapping whose scale is 0"));
            }
            var normal = FaceNormal(i);
            if (normal == Vec3.Zero)
            {
                problems.Add(new MeshProblem(i, "has no area"));
                continue;
            }
            var distance = Vec3.Dot(normal, Vertices[f.Corners[0]]);
            var bend = f.Corners.Max(c => Math.Abs(Vec3.Dot(normal, Vertices[c]) - distance));
            if (bend > PlanarTolerance)
            {
                problems.Add(new MeshProblem(i, $"is not planar: it bends by {bend * 1000:0.##} mm"));
            }
            for (var k = 0; k < f.Corners.Length; k++)
            {
                var edge = new MeshEdge(f.Corners[k], f.Corners[(k + 1) % f.Corners.Length]);
                if (edge.A != edge.B)
                {
                    edgeFaces[edge] = edgeFaces.GetValueOrDefault(edge) + 1;
                }
            }
        }
        foreach (var (edge, count) in edgeFaces.Where(e => e.Value > 2))
        {
            problems.Add(new MeshProblem(-1, $"the edge {Math.Min(edge.A, edge.B)} {Math.Max(edge.A, edge.B)} has {count} faces"));
        }
        foreach (var e in SharpEdges.Where(e => e.A < 0 || e.A >= Vertices.Length || e.B < 0 || e.B >= Vertices.Length))
        {
            problems.Add(new MeshProblem(-1, $"the sharp edge {e.A} {e.B} uses a vertex the mesh does not have"));
        }
        return problems;
    }
}
