using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Mesh;

namespace Cinnabar.Editor.Tests;

/// <summary>A cut target's inputs, their hash and the cut that they derive (see docs/editor/mesh-editing.md#cut-meshes).</summary>
public sealed class MeshCutsTests
{
    const string WallMesh = "a0000000000000000000000000000001";
    const string Result = "a0000000000000000000000000000002";
    const string OpenCutter = "a0000000000000000000000000000003";
    const string Jamb = "b0000000000000000000000000000001";

    static readonly MeshData Wall = Primitives.Block(new Vec3(-2, 0, -0.125), new Vec3(2, 3, 0.125));

    static MeshData? MeshOf(string guid) => guid switch
    {
        WallMesh => Wall,
        // A box without its first face, which is not solid, so the boolean refuses it.
        OpenCutter => Primitives.Block(new Vec3(-0.5, -0.5, -0.5), new Vec3(0.5, 0.5, 0.5)) is var box ? box.With(faces: box.Faces.RemoveAt(0)) : null,
        _ => null,
    };

    static string Pose(double x = 0, double y = 0) =>
        $"component 1 Transform\n\tposition = [{(long)(x * Document.Pose.Unit)}, {(long)(y * Document.Pose.Unit)}, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n";

    // A wall, cut or not, and a box cutter 1 m wide and 2 m high at x.
    static string Level(double x, string cutter = "\textents = [0.5, 1, 0.5]\n", bool cut = false, string more = "") =>
        "scene 4\n\nentity 0000000000000001\nname = \"Wall\"\n" + Pose() +
        $"component 33 Mesh_Renderer\n\tmesh = ${(cut ? Result : WallMesh)}\ncomponent 177 Cut_Target\n" + (cut ? $"\tsource = ${WallMesh}\n" : "") + "\n" +
        "entity 0000000000000002\nname = \"Opening\"\n" + Pose(x, 1) + "component 176 Mesh_Cutter\n" + cutter + "\n" + more;

    static CutInputs Inputs(string text)
    {
        var (scene, problems) = SceneFile.Parse(text);
        Assert.True(scene != null, string.Join("\n", problems));
        return Assert.Single(MeshCuts.Plan(PrefabExpansion.Expand(scene, _ => null), MeshOf));
    }

    [Fact]
    public void ACutIsTheSourceLessEachCutterAndItsCapTakesAFreeSlot()
    {
        var inputs = Inputs(Level(0.5, $"\textents = [0.5, 1, 0.5]\n\tcap_material = ${Jamb}\n"));
        var cut = Assert.IsType<CutResult.Cut>(MeshCuts.Derive(inputs));

        var expected = MeshBoolean.Subtract(Wall, inputs.Pose, inputs.Cutters[0].Volume, inputs.Cutters[0].Pose, 1).Mesh;
        Assert.Equal(MeshFile.Write(expected.With(materials: expected.Materials.SetItem(1, Jamb))), MeshFile.Write(cut.Mesh));
        Assert.Equal(Jamb, cut.Slots[1]);
    }

    [Fact]
    public void ATargetWithASourceMatchesByItAndARefusedCutterSaysWhy()
    {
        // The renderer names a result that is no mesh file of the index, so the source is what is cut.
        Assert.Single(Inputs(Level(0, cut: true)).Cutters);

        var refused = MeshCuts.Derive(Inputs(Level(0, $"\tshape = Mesh\n\tmesh = ${OpenCutter}\n")));
        Assert.Contains("Opening", Assert.IsType<CutResult.Refused>(refused).Reason);

        // A cutter off the wall does not cut it, which is Uncut.
        Assert.IsType<CutResult.Uncut>(MeshCuts.Derive(Inputs(Level(10))));
    }

    [Fact]
    public void TheHashChangesWithTheInputsAndNotWithAnythingElse()
    {
        var hash = Inputs(Level(0)).Hash();
        Assert.Equal(hash, Inputs(Level(0, more: "entity 0000000000000003\nname = \"Lamp\"\n" + Pose(5))).Hash());
        // The hash is of the cut's inputs, not of what the scene names, so a cut wall's hash is its uncut one's.
        Assert.Equal(hash, Inputs(Level(0, cut: true)).Hash());
        Assert.NotEqual(hash, Inputs(Level(0.25)).Hash());
        Assert.NotEqual(hash, Inputs(Level(0, "\textents = [0.5, 1.1, 0.5]\n")).Hash());
        Assert.Equal(0u, Inputs(Level(10)).Hash());
    }

    [Fact]
    public void ACutsMapTakesItsFragmentsBackToTheSourceAndKnowsItsCuttersFaces()
    {
        var cut = Assert.IsType<CutResult.Cut>(MeshCuts.Derive(Inputs(Level(0))));
        var map = cut.Map;
        var mesh = cut.Mesh;
        var front = Enumerable.Range(0, Wall.Faces.Length).Single(f => Wall.Faces[f].Corners.All(c => Wall.Vertices[c].Z == -0.125));

        // Every result face is a fragment of a source face that lies on its plane, or a jamb of the opening.
        for (var f = 0; f < mesh.Faces.Length; f++)
        {
            var corners = mesh.Faces[f].Corners.Select(c => mesh.Vertices[c]).ToList();
            if (map.SourceFace(f) is { } s)
            {
                Assert.Null(map.Cutter(f));
                var plane = Wall.Faces[s].Corners.Select(c => Wall.Vertices[c]).ToList();
                var normal = Vec3.Cross(plane[1] - plane[0], plane[2] - plane[0]).Normalized();
                Assert.All(corners, p => Assert.True(Math.Abs(Vec3.Dot(p - plane[0], normal)) < 1e-9));
            }
            else
            {
                Assert.Equal("Opening", map.Cutter(f));
                Assert.All(corners, p => Assert.True(Math.Abs(p.X) <= 0.5 + 1e-9));
            }
        }
        var fragments = map.ResultsOf(MeshElement.Faces, front).ToList();
        Assert.True(fragments.Count >= 1);
        Assert.All(fragments, f => Assert.Equal(front, map.SourceFace(f)));

        // The source's corners are the result's, and the opening's are new.
        for (var v = 0; v < mesh.Vertices.Length; v++)
        {
            var p = mesh.Vertices[v];
            var corner = Math.Abs(p.X) == 2 && (p.Y == 0 || p.Y == 3);
            Assert.Equal(corner, map.SourceVertex(v) is { } s && Wall.Vertices[s] == p);
        }
        // An edge along the source's bottom front edge is that edge, though the opening split it; a jamb's edge is new.
        var bottom = Wall.EdgeIndex(
            Enumerable.Range(0, Wall.Vertices.Length).Single(i => Wall.Vertices[i] == new Vec3(-2, 0, -0.125)),
            Enumerable.Range(0, Wall.Vertices.Length).Single(i => Wall.Vertices[i] == new Vec3(2, 0, -0.125)));
        for (var e = 0; e < mesh.Edges.Length; e++)
        {
            var (a, b) = (mesh.Vertices[mesh.Edges[e].A], mesh.Vertices[mesh.Edges[e].B]);
            if (a.Y == 0 && b.Y == 0 && a.Z == -0.125 && b.Z == -0.125)
            {
                Assert.Equal(bottom, map.SourceEdge(e));
            }
            if (Math.Abs(a.X) == 0.5 && a.X == b.X && a.Y != b.Y)
            {
                Assert.Null(map.SourceEdge(e));
            }
        }
    }

    // The fixtures of the game's tests of a cut wall: a wall 12 m long along z, 3 m high and 0.4 m thick, cut by a
    // doorway 1.2 m wide and 2.3 m high at z, as the kernel cuts it.
    [Theory]
    [InlineData("wall_door_a.cut.mesh", 0.0)]
    [InlineData("wall_door_b.cut.mesh", 3.0)]
    public void TheCutWallFixturesAreTheKernelsCuts(string file, double z)
    {
        var wall = Primitives.Block(new Vec3(-0.2, 0, -6), new Vec3(0.2, 3, 6));
        var door = Primitives.Block(new Vec3(-0.5, -1.15, -0.6), new Vec3(0.5, 1.15, 0.6));
        var cut = MeshBoolean.Subtract(wall, Document.Pose.Identity, door,
            new Pose([0, (long)(1.15 * Document.Pose.Unit), (long)(z * Document.Pose.Unit)], Quat.Identity, [1, 1, 1]), 0);
        Assert.Null(cut.Reason);
        var path = Path.Combine(EditorOptions.RepositoryRoot(), "lib", "engine", "asset", "format", "testdata", "cutters", file);
        Assert.Equal(MeshFile.Write(cut.Mesh), File.ReadAllText(path).ReplaceLineEndings("\n"));
    }
}
