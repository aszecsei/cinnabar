using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Shell;
using Welcome = Cinnabar.Editor.Link.Cook.Welcome;
using Wire = Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Tests;

/// <summary>Cut walls derived from their cutters in the shell (see docs/editor/mesh-editing.md#cut-meshes).</summary>
public sealed class CutSetTests : IDisposable
{
    readonly TempDirectory _temp = new("cut-set");
    readonly List<ILinkMessage> _sent = [];

    public void Dispose() => _temp.Dispose();

    const string WallMesh = "a0000000000000000000000000000001";
    const string DoorPrefab = "d0000000000000000000000000000001";
    const ulong WallId = 0x0000000000000001;
    const ulong OtherWallId = 0x0000000000000002;
    const ulong DoorId = 0x9000000000000001;
    const ulong OtherDoorId = 0x9000000000000002;
    const ulong OpeningNode = 0x1000000000000002;

    // 4 m wide, 3 m high and 0.25 m thick, about its entity's x and z.
    static readonly MeshData Wall = Primitives.Block(new Vec3(-2, 0, -0.125), new Vec3(2, 3, 0.125));

    static string Pose(double x = 0) =>
        $"component 1 Transform\n\tposition = [{(long)(x * Document.Pose.Unit)}, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n";

    // A door: its root, and its opening 1 m up, a box 1 m wide, 2 m high and 1 m deep.
    const string Door = "scene 4\n\n" +
        "entity 1000000000000001\nname = \"Door\"\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n\n" +
        "entity 1000000000000002\nname = \"Opening\"\nparent = @1000000000000001\ncomponent 2 Local_Transform\n\toffset = [0, 1, 0]\n" +
        "component 176 Mesh_Cutter\n\textents = [0.5, 1, 0.5]\n";

    static string WallEntity(ulong id, string name, double x = 0) =>
        $"entity {id:x16}\nname = \"{name}\"\n" + Pose(x) + $"component 33 Mesh_Renderer\n\tmesh = ${WallMesh}\ncomponent 177 Cut_Target\n\tlayer = 0\n\n";

    static string Instance(ulong id, double x = 0) => $"entity {id:x16}\nname = \"Door\"\nprefab = ${DoorPrefab}\n" + Pose(x) + "\n";

    EditorShell NewShell(string text, bool index = true)
    {
        Directory.CreateDirectory(_temp.Path);
        File.WriteAllText(_temp.Combine("wall.mesh"), MeshFile.Write(Wall));
        File.WriteAllText(_temp.Combine("door.prefab"), Door);
        var shell = TestShell.Open(_temp, "level.scene", "scene 4\n\n" + text);
        shell.Host.LinkForTests(_sent.Add);
        if (index)
        {
            Index(shell);
        }
        return shell;
    }

    void Index(EditorShell shell, params Asset[] more)
    {
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [new Importer(AssetKind.Mesh, ".mesh", []), new Importer(AssetKind.Prefab, ".prefab", [])], [], []));
        shell.Assets.Apply(new AssetSnapshot([TestAssets.Make(WallMesh, AssetKind.Mesh, "wall.mesh"), TestAssets.Make(DoorPrefab, AssetKind.Prefab, "door.prefab"), .. more], []));
    }

    static SceneEntity Entity(EditorShell shell, ulong id) => shell.Scene!.Expanded.Flat.Find(id)!;

    static string? Field(SceneEntity e, ulong component, string name) =>
        e.Components.Find(c => c.Id == component)?.Fields.Find(f => f.Name == name)?.Value is { } v
            ? v.Kind == SceneValueKind.Asset ? v.Asset : v.Text : null;

    // The wall less the door's opening at x along the wall, as the kernel cuts it.
    static string Expected(double x) =>
        MeshFile.Write(MeshBoolean.Subtract(Wall, Document.Pose.Identity,
            Primitives.Block(new Vec3(-0.5, -1, -0.5), new Vec3(0.5, 1, 0.5)),
            new Pose([(long)(x * Document.Pose.Unit), (long)Document.Pose.Unit, 0], Quat.Identity, [1, 1, 1]), 0).Mesh);

    static string ResultOf(EditorShell shell, ulong wall) =>
        MeshFile.Write(shell.Mesh.Meshes.Find(Field(Entity(shell, wall), SceneEdits.MeshRendererId, "mesh")!)!.Data);

    static SetField Move(ulong id, double x) =>
        new(id, SceneEdits.TransformId, "position", SceneEdits.TransformFields(new Pose([(long)(x * Document.Pose.Unit), 0, 0], Quat.Identity, [1, 1, 1]))[0].Value);

    [Fact]
    public void ADoorCutsItsWallAndTheCutFollowsItsMovesUndoAndDelete()
    {
        using var shell = NewShell(WallEntity(WallId, "Wall"));

        Assert.True(shell.CreateInstance(DoorPrefab, 0));
        // The first cut names its result and keeps the source, in the entry that placed the door.
        var entry = Assert.Single(shell.Scene!.History);
        Assert.StartsWith("Create Instance", entry.Label);
        var wall = Entity(shell, WallId);
        Assert.Equal(WallMesh, Field(wall, SceneEdits.CutTargetId, "source"));
        var result = Field(wall, SceneEdits.MeshRendererId, "mesh")!;
        Assert.NotEqual(WallMesh, result);
        Assert.NotEqual("", Field(wall, SceneEdits.CutTargetId, "inputs_hash"));
        Assert.Equal(Expected(0), ResultOf(shell, WallId));
        // The host draws the result before the field that names it arrives.
        var live = _sent.FindIndex(m => m is Wire.LiveMesh l && Convert.ToHexStringLower(l.Guid) == result);
        Assert.True(live >= 0);

        var door = shell.Scene.Expanded.Flat.Entities.Single(e => e.Name == "Door" && e.Parent == 0).Id;
        Assert.True(shell.Edit("Move Door", Move(door, 1)));
        Assert.Equal(Expected(1), ResultOf(shell, WallId));
        Assert.Equal(result, Field(Entity(shell, WallId), SceneEdits.MeshRendererId, "mesh"));

        shell.Scene.Undo();
        Assert.Equal(Expected(0), ResultOf(shell, WallId));

        Assert.True(shell.Edit("Delete Door", [.. PrefabEdits.DestroyTree(shell.Scene, door)]));
        wall = Entity(shell, WallId);
        Assert.Equal(WallMesh, Field(wall, SceneEdits.MeshRendererId, "mesh"));
        Assert.Null(Field(wall, SceneEdits.CutTargetId, "source"));
        Assert.Null(shell.Mesh.Meshes.Find(result));

        shell.Scene.Undo();
        Assert.Equal(result, Field(Entity(shell, WallId), SceneEdits.MeshRendererId, "mesh"));
        Assert.Equal(Expected(0), ResultOf(shell, WallId));
    }

    [Fact]
    public void TwoWallsThatShareASourceAreEachCut()
    {
        using var shell = NewShell(WallEntity(WallId, "Wall") + WallEntity(OtherWallId, "Other Wall", 10) + Instance(DoorId) + Instance(OtherDoorId, 10));
        var before = File.ReadAllText(_temp.Combine("wall.mesh"));

        var a = Field(Entity(shell, WallId), SceneEdits.MeshRendererId, "mesh");
        var b = Field(Entity(shell, OtherWallId), SceneEdits.MeshRendererId, "mesh");
        Assert.NotNull(a);
        Assert.NotNull(b);
        Assert.NotEqual(a, b);
        Assert.NotEqual(WallMesh, a);
        // Each door is at its wall's middle, so the two cuts are the same mesh in their walls' spaces.
        Assert.Equal(Expected(0), ResultOf(shell, WallId));
        Assert.Equal(Expected(0), ResultOf(shell, OtherWallId));
        Assert.Null(shell.Mesh.Meshes.Find(WallMesh));
        Assert.Equal(before, File.ReadAllText(_temp.Combine("wall.mesh")));
    }

    [Fact]
    public void ASavedCutReopensCleanAndASourceChangedOnDiskMakesTheSceneDirty()
    {
        using (var shell = NewShell(WallEntity(WallId, "Wall")))
        {
            Assert.True(shell.CreateInstance(DoorPrefab, 0));
            Assert.True(shell.SaveScene());
        }
        var scene = SceneFile.Parse(File.ReadAllText(_temp.Combine("level.scene"))).Scene!;
        var result = Field(scene.Find(WallId)!, SceneEdits.MeshRendererId, "mesh")!;
        var path = Directory.GetFiles(_temp.Combine("level_meshes"), "*.cut.mesh").Single();
        Assert.Equal(Expected(0), File.ReadAllText(path).ReplaceLineEndings("\n"));
        Assert.Contains(result, File.ReadAllText(path + ".meta"));

        // Reopened with the result in the index: nothing is out of date.
        var asset = TestAssets.Make(result, AssetKind.Mesh, Path.GetRelativePath(_temp.Path, path).Replace('\\', '/'));
        using (var shell = TestShell.Open(_temp, "level.scene", File.ReadAllText(_temp.Combine("level.scene"))))
        {
            Index(shell, asset);
            Assert.False(shell.Scene!.IsDirty);
            Assert.False(shell.Mesh.Meshes.AnyDirty);
            Assert.DoesNotContain(shell.Console.Lines, e => e.Text.StartsWith("cut:"));
        }

        // The source changed while the scene was closed.
        File.WriteAllText(_temp.Combine("wall.mesh"), MeshFile.Write(Primitives.Block(new Vec3(-3, 0, -0.125), new Vec3(3, 3, 0.125))));
        using (var shell = TestShell.Open(_temp, "level.scene", File.ReadAllText(_temp.Combine("level.scene"))))
        {
            // Until the index names the inputs, nothing is derived, and nothing is written.
            Assert.False(shell.Scene!.IsDirty);
            Index(shell, asset);
            Assert.True(shell.Scene.IsDirty);
            Assert.Equal("Update Cuts", Assert.Single(shell.Scene.History).Label);
            Assert.Contains(shell.Console.Lines, e => e.Text.Contains("cut: Wall: the cut is out of date"));
            Assert.Equal(result, Field(Entity(shell, WallId), SceneEdits.MeshRendererId, "mesh"));
            Assert.True(shell.Mesh.Meshes.Find(result)!.IsDirty);
        }
    }

    [Fact]
    public void ADragDerivesOnceAFrameFromItsNewestStep()
    {
        using var shell = NewShell(WallEntity(WallId, "Wall") + Instance(DoorId));
        var result = Field(Entity(shell, WallId), SceneEdits.MeshRendererId, "mesh")!;
        var frames = new List<Action>();
        shell.Cuts.Post = frames.Add;
        int Sent() => _sent.Count(m => m is Wire.LiveMesh l && Convert.ToHexStringLower(l.Guid) == result);
        var before = Sent();

        var drag = shell.TryBeginEdit("Move Door", "the gizmo")!;
        drag.Preview(Move(DoorId, 0.25));
        drag.Preview(Move(DoorId, 0.5));
        drag.Preview(Move(DoorId, 0.75));
        Assert.Equal(before, Sent());
        Assert.Single(frames);

        frames[0]();
        Assert.Equal(before + 1, Sent());
        Assert.Equal(Expected(0.75), ResultOf(shell, WallId));

        drag.Commit();
        Assert.Equal(before + 1, Sent());
    }
}
