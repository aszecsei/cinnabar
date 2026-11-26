using System.Diagnostics;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Tests;

/// <summary>The boolean kernel: Subtract, Union and Intersect, the poses between two meshes, and the moved mappings.</summary>
public class MeshBooleanTests(ITestOutputHelper output)
{
    // A wall 4 m wide, 3 m high and 0.25 m thick, on the 0.25 m grid.
    static readonly MeshData Wall = Primitives.Block(Vec3.Zero, new Vec3(4, 3, 0.25));

    static Pose At(double x = 0, double y = 0, double z = 0, double[]? scale = null, Quat? rotation = null) =>
        new([(long)(x * Pose.Unit), (long)(y * Pose.Unit), (long)(z * Pose.Unit)], rotation ?? Quat.Identity, scale ?? [1, 1, 1]);

    static BooleanResult Subtract(MeshData target, MeshData cutter, Pose? targetPose = null, Pose? cutterPose = null) =>
        MeshBoolean.Subtract(target, targetPose ?? Pose.Identity, cutter, cutterPose ?? Pose.Identity, 1);

    static void AssertSolid(BooleanResult result, double volume)
    {
        Assert.Null(result.Reason);
        Assert.Empty(result.Mesh.Validate());
        Assert.True(result.Mesh.IsSolid);
        Assert.Equal(volume, result.Mesh.SignedVolume, 1e-6);
        Assert.Equal(result.Mesh.Faces.Length, result.SourceFace.Length);
    }

    static List<int> CutFaces(BooleanResult result) => [.. Enumerable.Range(0, result.SourceFace.Length).Where(i => result.SourceFace[i] < 0)];

    [Fact]
    public void ABoxThroughAWallMakesAHoleWithFourJambs()
    {
        var cutter = Primitives.Block(new Vec3(1, 0.5, -0.5), new Vec3(2, 2.5, 0.75));
        var result = Subtract(Wall, cutter);
        AssertSolid(result, 3 - 0.5);
        var jambs = CutFaces(result);
        Assert.Equal(4, jambs.Count);
        Assert.All(jambs, f => Assert.Equal(4, result.Mesh.Faces[f].Corners.Length));
        Assert.All(jambs, f => Assert.Equal(1, result.Mesh.Faces[f].Slot));
        // Each jamb faces into the hole, and spans the wall's thickness.
        foreach (var f in jambs)
        {
            var center = MeshTools.Centroid(result.Mesh, result.Mesh.Faces[f].Corners);
            Assert.True(Vec3.Dot(result.Mesh.FaceNormal(f), new Vec3(1.5, 1.5, center.Z) - center) > 0);
            Assert.Equal(0.25, result.Mesh.Faces[f].Corners.Max(c => result.Mesh.Vertices[c].Z) - result.Mesh.Faces[f].Corners.Min(c => result.Mesh.Vertices[c].Z), 9);
        }
        // Every fragment of a wall face keeps the face's slot and mapping, so the texture runs on across the cut.
        for (var i = 0; i < result.SourceFace.Length; i++)
        {
            if (result.SourceFace[i] is var source and >= 0)
            {
                Assert.Equal(Wall.Faces[source].Mapping, result.Mesh.Faces[i].Mapping);
                Assert.Equal(Wall.Faces[source].Slot, result.Mesh.Faces[i].Slot);
            }
        }
        // The front and the back are rings around the hole: a ray through the middle meets nothing.
        var ray = new ViewRay(new Vec3(1.5, 1.5, -5), Vec3.UnitZ);
        Assert.Null(MeshPick.Face(result.Mesh, new MeshPlacement(Vec3.Zero, Quat.Identity, new Vec3(1, 1, 1)), ray, through: true));
        // Every wall face is still there, in one or more fragments.
        Assert.Equal(Enumerable.Range(0, Wall.Faces.Length), result.SourceFace.Where(f => f >= 0).Distinct().Order());
    }

    [Fact]
    public void ACutterFaceCoplanarWithTheWallMakesANiche()
    {
        // The cutter's front is the wall's front plane: the niche has a back and four sides, and no face on the front.
        var cutter = Primitives.Block(new Vec3(1, 0.5, 0), new Vec3(2, 2.5, 0.125));
        var result = Subtract(Wall, cutter);
        AssertSolid(result, 3 - 0.25);
        var cut = CutFaces(result);
        Assert.Equal(5, cut.Count);
        Assert.DoesNotContain(cut, f => result.Mesh.Faces[f].Corners.All(c => Math.Abs(result.Mesh.Vertices[c].Z) < 1e-9));
    }

    [Fact]
    public void ACutterThatSharesAnEdgeOrACornerCuts()
    {
        // A notch out of the top right corner, the cutter's faces on the wall's top and side.
        var notch = Subtract(Wall, Primitives.Block(new Vec3(3, 2, -0.5), new Vec3(4, 3, 0.75)));
        AssertSolid(notch, 3 - 0.25);
        Assert.Equal(2, CutFaces(notch).Count);
        // A cutter that touches the wall along one edge only leaves it as it was.
        var touching = Subtract(Wall, Primitives.Block(new Vec3(4, 3, 0), new Vec3(5, 4, 0.25)));
        Assert.Null(touching.Reason);
        Assert.Same(Wall, touching.Mesh);
        // A cutter that touches a face from outside leaves it too.
        Assert.Same(Wall, Subtract(Wall, Primitives.Block(new Vec3(1, 1, 0.25), new Vec3(2, 2, 1))).Mesh);
    }

    [Fact]
    public void ACutterThatMissesLeavesTheTargetAndOneThatContainsItIsRefused()
    {
        var missed = Subtract(Wall, Primitives.Block(new Vec3(10, 10, 10), new Vec3(11, 11, 11)));
        Assert.Null(missed.Reason);
        Assert.Same(Wall, missed.Mesh);
        Assert.Equal(Enumerable.Range(0, Wall.Faces.Length), missed.SourceFace);

        var contains = Subtract(Wall, Primitives.Block(new Vec3(-1, -1, -1), new Vec3(5, 5, 5)));
        Assert.Contains("nothing is left", contains.Reason);
        Assert.Same(Wall, contains.Mesh);

        var open = Primitives.Make(PrimitiveKind.Plane, Vec3.Zero, new Vec3(1, 1, 1), 1, PrimitiveParameters.Default);
        Assert.Contains("cutter is not solid", Subtract(Wall, open).Reason);
        Assert.Contains("target is not solid", Subtract(open, Wall).Reason);
    }

    [Theory]
    // The target's x scaled by 2: the hole at world x 2 to 4 is at 1 to 2 in the wall's space.
    [InlineData(2, 1, 2, 4, 1)]
    // The target mirrored in x: world x -2 to -1 is 1 to 2.
    [InlineData(-1, 1, -2, -1, 1)]
    // The cutter's x scaled by 2, from a cutter mesh half as wide.
    [InlineData(1, 2, 1, 2, 1)]
    // The cutter mirrored in x, from a cutter mesh at negative x.
    [InlineData(1, -1, 1, 2, 1)]
    // Both mirrored.
    [InlineData(-1, -1, -2, -1, 1)]
    public void ScalesOnEitherSideCompose(double targetX, double cutterX, double worldMin, double worldMax, double expectedWidth)
    {
        var cutter = Primitives.Block(new Vec3(Math.Min(worldMin / cutterX, worldMax / cutterX), 0.5, -0.5), new Vec3(Math.Max(worldMin / cutterX, worldMax / cutterX), 2.5, 0.75));
        var result = Subtract(Wall, cutter, At(scale: [targetX, 1, 1]), At(scale: [cutterX, 1, 1]));
        AssertSolid(result, 3 - expectedWidth * 2 * 0.25);
        // The hole is at x 1 to 2 in the wall's space.
        var jambXs = CutFaces(result).SelectMany(f => result.Mesh.Faces[f].Corners).Select(c => result.Mesh.Vertices[c].X).ToList();
        Assert.Equal(1, jambXs.Min(), 9);
        Assert.Equal(2, jambXs.Max(), 9);
    }

    [Fact]
    public void ARotatedAndMovedCutterCutsWhereTheWorldHasIt()
    {
        // The cutter is 2 m along its x and 1 m along its z; turned a quarter about y, it is 1 m wide in x and 2 m deep.
        var cutter = Primitives.Block(new Vec3(-1, 0, -0.5), new Vec3(1, 2, 0.5));
        var quarter = Rotations.AxisAngle(Vec3.UnitY, Math.PI / 2);
        var result = Subtract(Wall, cutter, At(x: 10, y: 5), At(x: 11.5, y: 5.5, rotation: quarter));
        AssertSolid(result, 3 - 1 * 2 * 0.25);
    }

    [Fact]
    public void UnionAndIntersectOfOverlappingBoxesHaveTheirVolumes()
    {
        var a = Primitives.Block(Vec3.Zero, new Vec3(2, 2, 2));
        var b = Primitives.Block(new Vec3(1, 0.5, 1), new Vec3(3, 2.5, 3));
        var overlap = 1 * 1.5 * 1;
        var union = MeshBoolean.Union(a, Pose.Identity, b, Pose.Identity, 0);
        AssertSolid(union, 8 + 8 - overlap);
        var intersection = MeshBoolean.Intersect(a, Pose.Identity, b, Pose.Identity, 0);
        AssertSolid(intersection, overlap);
        var difference = MeshBoolean.Subtract(a, Pose.Identity, b, Pose.Identity, 0);
        AssertSolid(difference, 8 - overlap);
        // Boxes that do not meet: the union is both, and the intersection is refused.
        var apart = MeshBoolean.Union(a, Pose.Identity, b, At(x: 10), 0);
        AssertSolid(apart, 16);
        Assert.Contains("do not meet", MeshBoolean.Intersect(a, Pose.Identity, b, At(x: 10), 0).Reason);
        // A box inside another: the union is the outer one, as it was.
        Assert.Same(a, MeshBoolean.Union(a, Pose.Identity, Primitives.Block(new Vec3(0.5, 0.5, 0.5), new Vec3(1, 1, 1)), Pose.Identity, 0).Mesh);
    }

    [Fact]
    public void ASecondCutMeetsTheRingOfTheFirst()
    {
        var first = Subtract(Wall, Primitives.Block(new Vec3(1, 0.5, -0.5), new Vec3(2, 2.5, 0.75)));
        AssertSolid(first, 2.5);
        // The second hole overlaps the first, through the concave faces that the first left around it.
        var second = Subtract(first.Mesh, Primitives.Block(new Vec3(1.5, 1, -0.5), new Vec3(3, 2, 0.75)));
        AssertSolid(second, 3 - 3 * 0.25);
        // A third, inside the wall only, makes a closed hollow.
        var hollow = Subtract(Wall, Primitives.Block(new Vec3(3, 1, 0.0625), new Vec3(3.5, 2, 0.1875)));
        AssertSolid(hollow, 3 - 0.5 * 1 * 0.125);
        Assert.Equal(6, CutFaces(hollow).Count);
    }

    [Fact]
    public void AMovedMappingGivesEveryPointTheSameUv()
    {
        var mapping = new Mapping(Vec3.UnitX, new Vec3(0, -1, 0), 0.5, 2, 0.25, -0.125, 30);
        var quarter = Rotations.AxisAngle(new Vec3(1, 2, 3).Normalized(), 0.7);
        foreach (var (from, to) in new[]
        {
            (At(1, 2, 3, [2, 0.5, 3], quarter), At(-4, 0, 1, [1, 1, 1])),
            (At(0, 0, 0, [-1, 2, 1]), At(1, 1, 1, [3, -0.5, 1], quarter)),
        })
        {
            var map = MeshPlacement.Between(from, to);
            var moved = map.MoveMapping(mapping)!.Value;
            Assert.Equal(1, moved.UAxis.Length, 12);
            foreach (var p in new[] { Vec3.Zero, new Vec3(1, -2, 0.5), new Vec3(-3, 4, 7) })
            {
                var (u, v) = mapping.Uv(p);
                var (mu, mv) = moved.Uv(map.Apply(p));
                Assert.Equal(u, mu, 9);
                Assert.Equal(v, mv, 9);
            }
            // The map back undoes it.
            var back = map.Inverse!.Value;
            Assert.Equal(0, (back.Apply(map.Apply(new Vec3(1, 2, 3))) - new Vec3(1, 2, 3)).Length, 9);
        }
    }

    [Fact]
    public void SubtractFromAFiveThousandFaceMeshIsMeasured()
    {
        // A 4 m box with each side cut into 29 by 29 quads: 5,046 faces.
        var grid = GridBox(29, 4);
        Assert.Equal(5046, grid.Faces.Length);
        Assert.True(grid.IsSolid);
        var cutter = Primitives.Block(new Vec3(1.1, 1.3, -0.5), new Vec3(2.2, 2.6, 0.5));
        Subtract(grid, cutter);
        var clock = Stopwatch.StartNew();
        var result = Subtract(grid, cutter);
        clock.Stop();
        AssertSolid(result, 64 - 1.1 * 1.3 * 0.5);
        output.WriteLine($"Subtract of a box from {grid.Faces.Length} faces: {clock.Elapsed.TotalMilliseconds:0.0} ms, {result.Mesh.Faces.Length} faces after");

        // A sphere is convex, so its tree is one chain as deep as its faces.
        var sphere = Primitives.Make(PrimitiveKind.Sphere, Vec3.Zero, new Vec3(4, 4, 4), 1, PrimitiveParameters.Default with { Segments = 64, Rings = 32 });
        clock.Restart();
        var bitten = Subtract(sphere, Primitives.Block(new Vec3(1.5, 1.5, 1.5), new Vec3(5, 5, 5)));
        clock.Stop();
        Assert.Null(bitten.Reason);
        Assert.True(bitten.Mesh.IsSolid);
        output.WriteLine($"Subtract of a box from a sphere of {sphere.Faces.Length} faces: {clock.Elapsed.TotalMilliseconds:0.0} ms");
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(10));
    }

    // A box from the origin with each side split into n by n quads, wound to front out, its vertices shared.
    static MeshData GridBox(int n, double size)
    {
        var vertices = new List<Vec3>();
        var index = new Dictionary<(int, int, int), int>();
        int Vertex(int x, int y, int z)
        {
            if (!index.TryGetValue((x, y, z), out var i))
            {
                index[(x, y, z)] = i = vertices.Count;
                vertices.Add(new Vec3(x, y, z) * (size / n));
            }
            return i;
        }
        var faces = new List<MeshFace>();
        for (var axis = 0; axis < 3; axis++)
        {
            foreach (var side in new[] { 0, n })
            {
                var outward = new Vec3(axis == 0 ? 1 : 0, axis == 1 ? 1 : 0, axis == 2 ? 1 : 0) * (side == 0 ? -1 : 1);
                for (var a = 0; a < n; a++)
                {
                    for (var b = 0; b < n; b++)
                    {
                        int At3(int i, int j) => axis switch { 0 => Vertex(side, i, j), 1 => Vertex(i, side, j), _ => Vertex(i, j, side) };
                        List<int> corners = [At3(a, b), At3(a + 1, b), At3(a + 1, b + 1), At3(a, b + 1)];
                        if (Vec3.Dot(MeshData.FaceNormal([.. vertices], [.. corners]), outward) < 0)
                        {
                            corners.Reverse();
                        }
                        faces.Add(new MeshFace(0, [.. corners], Mapping.WorldAligned(outward)));
                    }
                }
            }
        }
        return new MeshData([""], vertices, faces, []);
    }
}
