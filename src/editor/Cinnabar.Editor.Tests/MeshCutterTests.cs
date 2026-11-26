using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Mesh;

namespace Cinnabar.Editor.Tests;

/// <summary>Which meshes a Mesh_Cutter cuts (see docs/editor/mesh-editing.md#cutters-and-cut-targets).</summary>
public sealed class MeshCutterTests
{
    const string DoorPrefab = "d0000000000000000000000000000001";
    const string RoomPrefab = "d0000000000000000000000000000002";
    const string WallMesh = "a0000000000000000000000000000001";
    const string FrameMesh = "a0000000000000000000000000000002";
    // A model's mesh, which is not a .mesh, so it cannot be cut.
    const string ModelMesh = "a0000000000000000000000000000003";

    // 4 m wide, 3 m high and 0.25 m thick, about its entity's x and z.
    static readonly MeshData Wall = Primitives.Block(new Vec3(-2, 0, -0.125), new Vec3(2, 3, 0.125));
    static readonly MeshData Frame = Primitives.Block(new Vec3(-0.6, -1.1, -0.1), new Vec3(0.6, 1.1, 0.1));

    static MeshData? MeshOf(string guid) => guid switch
    {
        WallMesh => Wall,
        FrameMesh => Frame,
        _ => null,
    };

    static string Pose(double x = 0, double y = 0, double z = 0) =>
        $"component 1 Transform\n\tposition = [{(long)(x * Document.Pose.Unit)}, {(long)(y * Document.Pose.Unit)}, {(long)(z * Document.Pose.Unit)}]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n";

    static string Local(double y) => $"component 2 Local_Transform\n\toffset = [0, {y}, 0]\n";

    static string Renderer(string mesh) => $"component 33 Mesh_Renderer\n\tmesh = ${mesh}\n";

    static string Target(int layer) => $"component 177 Cut_Target\n\tlayer = {layer}\n";

    // A door: an opening 1 m wide and 2 m high, 1 m up, that cuts layer 1, and its frame, a target of layer 1 in the
    // opening.
    static string Door(uint layers) => "scene 4\n\n" +
        "entity 1000000000000001\nname = \"Door\"\n" + Pose() + "\n" +
        "entity 1000000000000002\nname = \"Opening\"\nparent = @1000000000000001\n" + Local(1) +
        $"component 176 Mesh_Cutter\n\textents = [0.5, 1, 0.5]\n\tlayers = {layers}\n\n" +
        "entity 1000000000000003\nname = \"Frame\"\nparent = @1000000000000001\n" + Local(1) + Renderer(FrameMesh) + Target(1);

    static Scene Parse(string text)
    {
        var (scene, problems) = SceneFile.Parse(text.ReplaceLineEndings("\n"));
        Assert.True(scene != null, string.Join("\n", problems));
        return scene;
    }

    static string Entity(ulong id, string name, string body) => $"entity {id:x16}\nname = \"{name}\"\n{body}\n";

    static string Instance(ulong id, string prefab, string pose) => $"entity {id:x16}\nprefab = ${prefab}\n{pose}\n";

    static (Expansion Expansion, SceneEntity Opening) Expand(string level, uint layers = 2, Dictionary<string, Scene>? more = null)
    {
        var prefabs = new Dictionary<string, Scene>(more ?? []) { [DoorPrefab] = Parse(Door(layers)) };
        var expansion = PrefabExpansion.Expand(Parse("scene 4\n\n" + level), g => prefabs.GetValueOrDefault(g));
        Assert.Empty(expansion.Problems);
        var opening = expansion.Flat.Entities.Single(e => e.Name == "Opening");
        return (expansion, opening);
    }

    static string[] Targets((Expansion Expansion, SceneEntity Opening) x) =>
        [.. MeshCutters.Targets(x.Expansion, x.Opening, MeshOf).Select(e => e.Name)];

    [Fact]
    public void ACutterCutsOnlyTheTargetsInItsMaskThatItMeets()
    {
        var level =
            Entity(1, "Wall", Pose() + Renderer(WallMesh) + Target(1)) +
            Entity(2, "Other Layer", Pose() + Renderer(WallMesh) + Target(3)) +
            Entity(3, "Not a Target", Pose() + Renderer(WallMesh)) +
            Entity(4, "Model", Pose() + Renderer(ModelMesh) + Target(1)) +
            Entity(5, "Far Wall", Pose(x: 100) + Renderer(WallMesh) + Target(1)) +
            Instance(0x9000000000000001, DoorPrefab, Pose());

        // The door's own frame is a target of layer 1 inside the opening, and is not cut.
        Assert.Equal(["Wall"], Targets(Expand(level)));
    }

    [Fact]
    public void AMaskOf0CutsEveryLayer()
    {
        var level =
            Entity(1, "Wall", Pose() + Renderer(WallMesh) + Target(1)) +
            Entity(2, "Other Layer", Pose() + Renderer(WallMesh) + Target(3)) +
            Instance(0x9000000000000001, DoorPrefab, Pose());

        Assert.Equal(["Wall", "Other Layer"], Targets(Expand(level, layers: 0)));
    }

    [Fact]
    public void ACutterMeetsATargetByItsPoseAndScale()
    {
        // The wall's edge is 2 m along x. A door 2.4 m along meets it with its half width of 0.5 m, and 2.6 m does not.
        var near = Entity(1, "Wall", Pose() + Renderer(WallMesh) + Target(1)) + Instance(0x9000000000000001, DoorPrefab, Pose(x: 2.4));
        var far = Entity(1, "Wall", Pose() + Renderer(WallMesh) + Target(1)) + Instance(0x9000000000000001, DoorPrefab, Pose(x: 2.6));
        Assert.Equal(["Wall"], Targets(Expand(near)));
        Assert.Empty(Targets(Expand(far)));

        // Scaled twice as wide, the door at 2.6 m reaches 1.6 m along x, into the wall.
        var scaled = far.Replace("scale = [1, 1, 1]\n\n", "scale = [2, 1, 1]\n\n");
        Assert.Equal(["Wall"], Targets(Expand(scaled)));
    }

    [Fact]
    public void ADoorInARoomCutsTheRoomsWallsAndNotItsOwnFrame()
    {
        // A room prefab with a wall and a door in it: the door's own instance is the nested one, so the room's wall is
        // not of it.
        var room = Parse("scene 4\n\n" +
            Entity(0x2000000000000001, "Room", Pose()) +
            "entity 2000000000000002\nname = \"Room Wall\"\nparent = @2000000000000001\n" + Local(0) + Renderer(WallMesh) + Target(1) + "\n" +
            $"entity 2000000000000003\nparent = @2000000000000001\nprefab = ${DoorPrefab}\n" + Local(0));
        var level = Instance(0x9000000000000001, RoomPrefab, Pose());

        Assert.Equal(["Room Wall"], Targets(Expand(level, more: new() { [RoomPrefab] = room })));
    }

    [Fact]
    public void ACutterOutsideAPrefabCutsWhatItMeets()
    {
        var level =
            Entity(1, "Wall", Pose() + Renderer(WallMesh) + Target(0)) +
            Entity(2, "Opening", Pose(y: 1) + "component 176 Mesh_Cutter\n");

        Assert.Equal(["Wall"], Targets(Expand(level)));
    }

    [Fact]
    public void TheSamplesDoorCutsTheWallThatItIsPlacedIn()
    {
        var path = Path.Combine(EditorOptions.RepositoryRoot(), "samples", "mygame", "content", "prefabs", "door.prefab");
        const string sample = "e0000000000000000000000000000001";
        var level = Entity(1, "Wall", Pose() + Renderer(WallMesh) + Target(0)) + Instance(0x9000000000000001, sample, Pose(x: 1));

        var x = Expand(level, more: new() { [sample] = Parse(File.ReadAllText(path)) });

        Assert.Equal(["Wall"], Targets(x));
        var cutter = CutterFields.Of(x.Opening.Components.Single(c => c.Id == SceneEdits.MeshCutterId));
        Assert.Equal(CutterShape.Box, cutter.Shape);
        Assert.True(cutter.CutsCollision);
    }

    [Fact]
    public void AMeshCutterUsesItsMeshsBoundsAndNoneWithoutIt()
    {
        var withMesh = Entity(1, "Wall", Pose() + Renderer(WallMesh) + Target(0)) +
            Entity(2, "Opening", Pose(y: 1) + $"component 176 Mesh_Cutter\n\tshape = Mesh\n\tmesh = ${FrameMesh}\n");
        var missing = withMesh.Replace(FrameMesh, ModelMesh);

        Assert.Equal(["Wall"], Targets(Expand(withMesh)));
        Assert.Empty(Targets(Expand(missing)));
    }
}
