using Avalonia;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using EntityInfo = Cinnabar.Editor.Link.Protocol.EntityInfo;
using EntitySnapshot = Cinnabar.Editor.Link.Protocol.EntitySnapshot;
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
        Assert.NotEqual(0u, MeshCutters.HashOf(wall));
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
    public void ADuplicatedWallGetsAResultOfItsOwn()
    {
        using var shell = NewShell(WallEntity(WallId, "Wall") + Instance(DoorId));
        var result = Field(Entity(shell, WallId), SceneEdits.MeshRendererId, "mesh")!;

        var (ops, copy) = SceneEdits.Duplicate(shell.Scene!.Scene, WallId);
        Assert.True(shell.Edit("Duplicate Wall", ops));
        var copied = Field(Entity(shell, copy), SceneEdits.MeshRendererId, "mesh")!;
        Assert.NotEqual(result, copied);
        Assert.Equal(WallMesh, Field(Entity(shell, copy), SceneEdits.CutTargetId, "source"));

        // Moving the copy off the door leaves the first wall's result as it was.
        Assert.True(shell.Edit("Move Copy", Move(copy, 50)));
        Assert.Equal(WallMesh, Field(Entity(shell, copy), SceneEdits.MeshRendererId, "mesh"));
        Assert.Equal(Expected(0), ResultOf(shell, WallId));
    }

    [Fact]
    public void ARefusedFirstCutDrawsItsSourceAndSaysWhyAfterUndoAndRedo()
    {
        const string OpenMesh = "a0000000000000000000000000000009";
        var box = Primitives.Block(new Vec3(-0.5, -0.5, -0.5), new Vec3(0.5, 0.5, 0.5));
        const ulong CutterId = 0x0000000000000005;
        using var shell = NewShell(WallEntity(WallId, "Wall") +
            $"entity {CutterId:x16}\nname = \"Open Cutter\"\n" + Pose(100) + $"component 176 Mesh_Cutter\n\tshape = Mesh\n\tmesh = ${OpenMesh}\n", index: false);
        File.WriteAllText(_temp.Combine("open.mesh"), MeshFile.Write(box.With(faces: box.Faces.RemoveAt(0))));
        Index(shell, TestAssets.Make(OpenMesh, AssetKind.Mesh, "open.mesh"));

        Assert.True(shell.Edit("Move Cutter", Move(CutterId, 0)));
        var result = Field(Entity(shell, WallId), SceneEdits.MeshRendererId, "mesh")!;
        Assert.IsType<CutState.Refused>(shell.Cuts.StateOf(shell.Scene!, WallId));
        Assert.Contains(shell.ProblemsOf(WallId), p => p.Contains("Open Cutter"));
        Assert.Equal(MeshFile.Write(Wall), ResultOf(shell, WallId));

        shell.Scene!.Undo();
        Assert.Null(shell.Cuts.StateOf(shell.Scene, WallId));
        Assert.Empty(shell.ProblemsOf(WallId));
        shell.Scene.Redo();
        Assert.IsType<CutState.Refused>(shell.Cuts.StateOf(shell.Scene, WallId));
        Assert.Equal(MeshFile.Write(Wall), ResultOf(shell, WallId));
        Assert.Equal(result, Field(Entity(shell, WallId), SceneEdits.MeshRendererId, "mesh"));
    }

    [Fact]
    public void WallsInPrefabInstancesAreEachCutThroughTheirInstances()
    {
        const string RoomPrefab = "d0000000000000000000000000000002";
        const ulong RoomA = 0x8000000000000001, RoomB = 0x8000000000000002, WallNode = 0x2000000000000002;
        var room = "scene 4\n\nentity 2000000000000001\nname = \"Room\"\n" + Pose() + "\n" +
            "entity 2000000000000002\nname = \"Wall\"\nparent = @2000000000000001\ncomponent 2 Local_Transform\n\toffset = [0, 0, 0]\n" +
            $"component 33 Mesh_Renderer\n\tmesh = ${WallMesh}\ncomponent 177 Cut_Target\n\tlayer = 0\n";
        var level = $"entity {RoomA:x16}\nname = \"Room A\"\nprefab = ${RoomPrefab}\n" + Pose() + "\n" +
            $"entity {RoomB:x16}\nname = \"Room B\"\nprefab = ${RoomPrefab}\n" + Pose(10) + "\n" + Instance(DoorId) + Instance(OtherDoorId, 10);
        using var shell = NewShell(level, index: false);
        File.WriteAllText(_temp.Combine("room.prefab"), room);
        Index(shell, TestAssets.Make(RoomPrefab, AssetKind.Prefab, "room.prefab"));

        // The scene opened with doors that its walls lack, so one entry cuts both, as overrides of their instances.
        Assert.Equal("Update Cuts", Assert.Single(shell.Scene!.History).Label);
        ulong a = ScenePath.Id(RoomA, WallNode), b = ScenePath.Id(RoomB, WallNode);
        var (resultA, resultB) = (Field(Entity(shell, a), SceneEdits.MeshRendererId, "mesh"), Field(Entity(shell, b), SceneEdits.MeshRendererId, "mesh"));
        Assert.NotEqual(WallMesh, resultA);
        Assert.NotEqual(WallMesh, resultB);
        Assert.NotEqual(resultA, resultB);
        Assert.Equal(Expected(0), ResultOf(shell, a));
        Assert.Equal(Expected(0), ResultOf(shell, b));

        shell.Scene.Undo();
        Assert.Equal(WallMesh, Field(Entity(shell, a), SceneEdits.MeshRendererId, "mesh"));
        Assert.Equal(WallMesh, Field(Entity(shell, b), SceneEdits.MeshRendererId, "mesh"));
        shell.Scene.Redo();
        Assert.Equal(resultA, Field(Entity(shell, a), SceneEdits.MeshRendererId, "mesh"));
        Assert.Equal(Expected(0), ResultOf(shell, b));
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

    // A wall with a collider: a bare one is the default box.
    static string ColliderWall(ulong id, string name, string collider = "") =>
        WallEntity(id, name).TrimEnd('\n') + "\ncomponent 65 Collider\n" + collider + "\n";

    // A box cutter of the scene, at a point of the wall, 0.5 m on a side.
    static string Window(ulong id, double x, double y, bool cutsCollision) =>
        $"entity {id:x16}\nname = \"Window\"\n" +
        $"component 1 Transform\n\tposition = [{(long)(x * Document.Pose.Unit)}, {(long)(y * Document.Pose.Unit)}, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n" +
        $"component 176 Mesh_Cutter\n\textents = [0.25, 0.25, 0.5]\n\tcuts_collision = {(cutsCollision ? "true" : "false")}\n\n";

    const ulong WindowId = 0x0000000000000007;

    [Fact]
    public void ACutMakesItsWallsColliderAMeshOfTheResultInTheSameEntry()
    {
        using var shell = NewShell(ColliderWall(WallId, "Wall"));

        Assert.True(shell.CreateInstance(DoorPrefab, 0));
        Assert.Single(shell.Scene!.History);
        var wall = Entity(shell, WallId);
        var result = Field(wall, SceneEdits.MeshRendererId, "mesh");
        Assert.Equal("Mesh", Field(wall, SceneEdits.ColliderId, "shape"));
        Assert.Equal(result, Field(wall, SceneEdits.ColliderId, "mesh"));

        // Deleting the last door leaves a mesh collider of the source.
        var door = shell.Scene.Expanded.Flat.Entities.Single(e => e.Name == "Door" && e.Parent == 0).Id;
        Assert.True(shell.Edit("Delete Door", [.. PrefabEdits.DestroyTree(shell.Scene, door)]));
        Assert.Equal(WallMesh, Field(Entity(shell, WallId), SceneEdits.ColliderId, "mesh"));

        shell.Scene.Undo();
        Assert.Equal(result, Field(Entity(shell, WallId), SceneEdits.ColliderId, "mesh"));
        shell.Scene.Undo();
        wall = Entity(shell, WallId);
        Assert.Null(Field(wall, SceneEdits.ColliderId, "shape"));
        Assert.Null(Field(wall, SceneEdits.ColliderId, "mesh"));
    }

    [Fact]
    public void ACutterThatSparesCollisionGivesTheColliderAResultOfItsOwn()
    {
        using var shell = NewShell(ColliderWall(WallId, "Wall") + Instance(DoorId) + Window(WindowId, 1.5, 2.25, cutsCollision: false));

        var wall = Entity(shell, WallId);
        var result = Field(wall, SceneEdits.MeshRendererId, "mesh")!;
        var collision = Field(wall, SceneEdits.ColliderId, "mesh")!;
        Assert.NotEqual(result, collision);
        Assert.NotEqual(WallMesh, collision);
        // The collider has the door's opening and not the window's.
        Assert.Equal(Expected(0), MeshFile.Write(shell.Mesh.Meshes.Find(collision)!.Data));
        Assert.NotEqual(Expected(0), ResultOf(shell, WallId));
        Assert.Equal(collision, shell.Cuts.StateOf(shell.Scene!, WallId)!.Collision);

        // Saved, its file is a collision result's.
        Assert.True(shell.SaveScene());
        Assert.Single(Directory.GetFiles(_temp.Combine("level_meshes"), "*.collision.cut.mesh"));

        // Without the window, the collider follows the render result, and its own result closes.
        Assert.True(shell.Edit("Delete Window", [.. PrefabEdits.DestroyTree(shell.Scene!, WindowId)]));
        wall = Entity(shell, WallId);
        Assert.Equal(Field(wall, SceneEdits.MeshRendererId, "mesh"), Field(wall, SceneEdits.ColliderId, "mesh"));
        Assert.Null(shell.Mesh.Meshes.Find(collision));
        shell.Scene!.Undo();
        Assert.Equal(collision, Field(Entity(shell, WallId), SceneEdits.ColliderId, "mesh"));
        // Its saved file holds the cut again, so the host draws that.
        Assert.Equal(collision, shell.Cuts.StateOf(shell.Scene, WallId)!.Collision);
        Assert.Null(shell.Mesh.Meshes.Find(collision));
    }

    [Fact]
    public void ACutNeverWritesIntoAColliderMeshOfTheDesignersOwn()
    {
        const string Own = "a0000000000000000000000000000002";
        var hull = Primitives.Block(new Vec3(-2, 0, -0.2), new Vec3(2, 3, 0.2));
        Directory.CreateDirectory(_temp.Path);
        File.WriteAllText(_temp.Combine("hull.mesh"), MeshFile.Write(hull));
        using var shell = NewShell(ColliderWall(WallId, "Wall", $"\tshape = Mesh\n\tmesh = ${Own}\n") + Window(WindowId, 1.5, 2.25, cutsCollision: false), index: false);
        Index(shell, TestAssets.Make(Own, AssetKind.Mesh, "hull.mesh"));

        // A window that spares collision leaves the collider alone, and a door then gives it a result of its own.
        Assert.Equal(Own, Field(Entity(shell, WallId), SceneEdits.ColliderId, "mesh"));
        Assert.True(shell.CreateInstance(DoorPrefab, 0));
        var collision = Field(Entity(shell, WallId), SceneEdits.ColliderId, "mesh");
        Assert.NotEqual(Own, collision);
        Assert.Null(shell.Mesh.Meshes.Find(Own));
        Assert.Equal(MeshFile.Write(hull), File.ReadAllText(_temp.Combine("hull.mesh")));
    }

    [Fact]
    public void APrimitiveColliderThatNoCutterCutsSaysItIgnoresTheCut()
    {
        using var shell = NewShell(ColliderWall(WallId, "Wall") + Window(WindowId, 0, 1.5, cutsCollision: false));

        Assert.Null(Field(Entity(shell, WallId), SceneEdits.ColliderId, "shape"));
        Assert.Contains(shell.ProblemsOf(WallId), p => p.StartsWith("the box ignores the cut"));

        Assert.True(shell.Edit("Cut Collision", new SetField(WindowId, SceneEdits.MeshCutterId, "cuts_collision", SceneValue.Of(true))));
        Assert.Equal("Mesh", Field(Entity(shell, WallId), SceneEdits.ColliderId, "shape"));
        Assert.Empty(shell.ProblemsOf(WallId));
    }

    [Fact]
    public void AStaticColliderInADoorsOpeningPlugsIt()
    {
        const string Plugged = "d0000000000000000000000000000003";
        string Leaf(string body) => Door +
            "\nentity 1000000000000003\nname = \"Leaf\"\nparent = @1000000000000001\ncomponent 2 Local_Transform\n\toffset = [0, 1, 0]\n" +
            "\tscale = [1, 2, 0.05]\ncomponent 65 Collider\n" + body;
        const string Swinging = "d0000000000000000000000000000004";
        Directory.CreateDirectory(_temp.Path);
        File.WriteAllText(_temp.Combine("plugged.prefab"), Leaf(""));
        File.WriteAllText(_temp.Combine("swinging.prefab"), Leaf("component 64 Rigid_Body\n\tmotion = Kinematic\n"));
        using var shell = NewShell(WallEntity(WallId, "Wall") +
            $"entity {DoorId:x16}\nname = \"Door\"\nprefab = ${Plugged}\n" + Pose() + "\n" +
            $"entity {OtherDoorId:x16}\nname = \"Door\"\nprefab = ${Swinging}\n" + Pose(10) + "\n", index: false);
        Index(shell, TestAssets.Make(Plugged, AssetKind.Prefab, "plugged.prefab"), TestAssets.Make(Swinging, AssetKind.Prefab, "swinging.prefab"));

        Assert.Contains(shell.ProblemsOf(ScenePath.Id(DoorId, OpeningNode)), p => p.Contains("the static collider of Leaf plugs the opening"));
        // A kinematic leaf does not.
        Assert.Empty(shell.ProblemsOf(ScenePath.Id(OtherDoorId, OpeningNode)));
    }

    const double Width = 1600;
    const double Height = 900;
    const ulong WallHandle = 1UL << 32;

    // Mesh mode on a wall that a door cuts, seen from 5 m in front of it, 1.5 m up.
    EditorShell InMeshModeOnACutWall()
    {
        var shell = NewShell(WallEntity(WallId, "Wall") + Instance(DoorId));
        shell.OnGameMessage(new EntitySnapshot([new EntityInfo(WallHandle, "Wall", WallId, 1, 0, true, [1, 33, 177])]));
        shell.Viewports[0].Session.Show(new PixelSize((int)Width, (int)Height));
        shell.Camera.Place([0, (long)(1.5 * Document.Pose.Unit), (long)(-5 * Document.Pose.Unit)], 0, 0);
        shell.Selection.Select(WallHandle);
        shell.Mesh.EnterMeshMode();
        Assert.True(shell.Mesh.InMeshMode);
        return shell;
    }

    // The pixel of a point of the wall's space.
    static Vec2 At(EditorShell shell, double x, double y, double z) =>
        shell.Camera.Project(new Vec3(x, y - 1.5, z + 5), Width, Height)!.Value;

    // The face of a mesh whose corners all lie at z.
    static int FaceAt(MeshData mesh, double z) =>
        Enumerable.Range(0, mesh.Faces.Length).Single(f => mesh.Faces[f].Corners.All(c => Math.Abs(mesh.Vertices[c].Z - z) < 1e-9));

    [Fact]
    public void MeshModeOnACutWallEditsItsSourceAndPicksItsResult()
    {
        using var shell = InMeshModeOnACutWall();
        Assert.Equal([WallMesh], shell.Mesh.EditedMeshes.Keys);
        Assert.NotNull(shell.Cuts.MapOf(shell.Scene!, WallId));

        // Beside the hole, a fragment of the front is the source's front face.
        shell.PickAt(At(shell, 1.5, 1.5, -0.125), SelectMode.Replace);
        Assert.Equal(new MeshItem(WallMesh, FaceAt(Wall, -0.125)), Assert.Single(shell.Mesh.MeshSelection.Items));

        // A jamb that the door made selects nothing, and says what made it.
        var jamb = At(shell, 0.5, 1.5, 0);
        shell.Mesh.HoverMesh(jamb);
        Assert.Contains("made by Opening", shell.Mesh.MeshStatus);
        shell.PickAt(jamb, SelectMode.Replace);
        Assert.True(shell.Mesh.MeshSelection.IsEmpty);
        shell.Mesh.HoverMesh(At(shell, 1.5, 1.5, -0.125));
        Assert.DoesNotContain("made by", shell.Mesh.MeshStatus);
    }

    [Fact]
    public void AnEditOfACutWallsSourceCutsItAgainInTheSameEntry()
    {
        using var shell = InMeshModeOnACutWall();
        var entries = shell.Scene!.History.Count;
        var hash = MeshCutters.HashOf(Entity(shell, WallId));
        var wider = Primitives.Block(new Vec3(-3, 0, -0.125), new Vec3(3, 3, 0.125));

        Assert.True(shell.Mesh.EditMesh("Widen", WallMesh, wider));
        Assert.Equal(entries + 1, shell.Scene.History.Count);
        Assert.NotEqual(hash, MeshCutters.HashOf(Entity(shell, WallId)));
        var cut = MeshBoolean.Subtract(wider, Document.Pose.Identity, Primitives.Block(new Vec3(-0.5, -1, -0.5), new Vec3(0.5, 1, 0.5)),
            new Pose([0, (long)Document.Pose.Unit, 0], Quat.Identity, [1, 1, 1]), 0).Mesh;
        Assert.Equal(MeshFile.Write(cut), ResultOf(shell, WallId));

        shell.Scene.Undo();
        Assert.Equal(hash, MeshCutters.HashOf(Entity(shell, WallId)));
        Assert.Equal(Expected(0), ResultOf(shell, WallId));
    }

    [Fact]
    public void ARefusedCutWallPicksItsSourceAsItIs()
    {
        using var shell = InMeshModeOnACutWall();
        // Without its top, the source is not solid, so the cut is refused and keeps its last good result.
        var open = MeshTools.Delete(Wall, MeshElement.Faces, [Enumerable.Range(0, Wall.Faces.Length).Single(f => Wall.Faces[f].Corners.All(c => Wall.Vertices[c].Y == 3))]);
        Assert.True(shell.Mesh.EditMesh("Delete Top", WallMesh, open));
        Assert.IsType<CutState.Refused>(shell.Cuts.StateOf(shell.Scene!, WallId));
        Assert.Null(shell.Cuts.MapOf(shell.Scene!, WallId));

        // The pick is of the source, whose faces the old map does not know.
        Assert.Equal(new MeshItem(WallMesh, FaceAt(open, -0.125)), shell.Mesh.MeshElementAt(At(shell, 0, 1.5, -0.125)));
    }
}
