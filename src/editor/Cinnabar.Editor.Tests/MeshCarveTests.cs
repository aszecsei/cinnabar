using Avalonia;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using EntityInfo = Cinnabar.Editor.Link.Protocol.EntityInfo;
using EntitySnapshot = Cinnabar.Editor.Link.Protocol.EntitySnapshot;

namespace Cinnabar.Editor.Tests;

/// <summary>Carve: the primary edited mesh less each other edited mesh, as one undo entry.</summary>
public sealed class MeshCarveTests : IDisposable
{
    readonly TempDirectory _temp = new("mesh-carve");

    const string CutterGuid = "9c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f";
    const string JambMaterial = "0123456789abcdef0123456789abcdef";

    // A wall at z 5, and a cutter entity 1 m along x from it, which places a box through the wall in the world.
    static readonly string Text = "scene 1\n\n" +
        "entity 0000000000000001\nname = \"Wall\"\ncomponent 1 Transform\n\tposition = [0, 0, 83886080]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n" +
        $"component 33 Mesh_Renderer\n\tmesh = ${MeshFixtures.MeshGuid}\n\tmaterials.0 = ${MeshSession.DevGrayMaterial}\n\n" +
        "entity 0000000000000002\nname = \"Opening\"\ncomponent 1 Transform\n\tposition = [16777216, 0, 83886080]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n" +
        $"component 33 Mesh_Renderer\n\tmesh = ${CutterGuid}\n\tmaterials.0 = ${JambMaterial}\n";

    static readonly MeshData Wall = Primitives.Block(Vec3.Zero, new Vec3(4, 3, 0.25), material: MeshSession.DevGrayMaterial);

    // In the opening's space: 1 m wide and 2 m high, through the wall's thickness.
    static readonly MeshData Opening = Primitives.Block(new Vec3(0, 0.5, -0.5), new Vec3(1, 2.5, 0.75), material: JambMaterial);

    static ulong Handle(uint index) => 1UL << 32 | index;

    EditorShell NewShell()
    {
        Directory.CreateDirectory(_temp.Path);
        File.WriteAllText(_temp.Combine("wall.mesh"), MeshFile.Write(Wall));
        File.WriteAllText(_temp.Combine("opening.mesh"), MeshFile.Write(Opening));
        var shell = TestShell.Open(_temp, "main.scene", Text, _temp.Combine("project.settings"));
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [new Importer(AssetKind.Mesh, ".mesh", [])], [], []));
        shell.Assets.Apply(new AssetSnapshot([TestAssets.Make(MeshFixtures.MeshGuid, AssetKind.Mesh, "wall.mesh"), TestAssets.Make(CutterGuid, AssetKind.Mesh, "opening.mesh")], []));
        shell.OnGameMessage(new EntitySnapshot([new EntityInfo(Handle(0), "Wall", 1, 1, 0, true, [1, 33]), new EntityInfo(Handle(1), "Opening", 2, 1, 0, true, [1, 33])]));
        shell.Viewports[0].Session.Show(new PixelSize(1600, 900));
        shell.Camera.Place([0, 0, 0], 0, 0);
        shell.Selection.Select(Handle(0));
        shell.Selection.Add([Handle(1)]);
        shell.Mesh.EnterMeshMode();
        Assert.True(shell.Mesh.InMeshMode);
        return shell;
    }

    [Fact]
    public void CarveCutsTheOpeningAsOneUndoEntry()
    {
        using var shell = NewShell();
        Assert.Equal(2, shell.Mesh.EditedMeshes.Count);
        Assert.Equal(MeshFixtures.MeshGuid, shell.Mesh.PrimaryMeshGuid);
        var carve = shell.Commands.Get(EditorCommands.MeshCarve);
        Assert.True(carve.CanExecute);
        carve.Execute();

        var mesh = MeshFixtures.Mesh(shell);
        Assert.True(mesh.IsSolid);
        Assert.Equal(3 - 0.5, mesh.SignedVolume, 6);
        Assert.Equal("Carve", Assert.Single(shell.Scene!.History).Label);
        // The four jambs are selected, in the opening's material, which the wall's renderer now draws in their slot.
        Assert.Equal(MeshElement.Faces, shell.Mesh.MeshElement);
        var jambs = shell.Mesh.MeshSelection.Of(MeshFixtures.MeshGuid).ToList();
        Assert.Equal(4, jambs.Count);
        var slot = mesh.Faces[jambs[0]].Slot;
        Assert.All(jambs, f => Assert.Equal(slot, mesh.Faces[f].Slot));
        Assert.Equal(JambMaterial, mesh.Materials[slot]);
        var renderer = shell.Scene.Scene.Find(1)!.Components.Single(c => c.Id == SceneEdits.MeshRendererId);
        Assert.Equal(JambMaterial, renderer.Fields.Single(f => f.Name == $"materials.{slot}").Value.Asset);
        // The cutter stays as it was.
        Assert.Equal(Opening.Faces, shell.Mesh.Meshes.Find(CutterGuid)!.Data.Faces);

        // Undo restores the wall and its renderer.
        shell.Scene.Undo();
        Assert.Equal(Wall.Faces, MeshFixtures.Mesh(shell).Faces);
        Assert.DoesNotContain(shell.Scene.Scene.Find(1)!.Components.Single(c => c.Id == SceneEdits.MeshRendererId).Fields, f => f.Name == $"materials.{slot}");
    }

    [Fact]
    public void CarveWithOneEditedMeshIsDisabled()
    {
        using var shell = NewShell();
        shell.Mesh.LeaveMeshMode();
        shell.Selection.Select(Handle(0));
        shell.Mesh.EnterMeshMode();
        Assert.Single(shell.Mesh.EditedMeshes);
        Assert.False(shell.Commands.Get(EditorCommands.MeshCarve).CanExecute);
    }

    public void Dispose() => _temp.Dispose();
}
