using Avalonia;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using CookHotspot = Cinnabar.Editor.Link.Cook.Hotspot;
using EntityInfo = Cinnabar.Editor.Link.Protocol.EntityInfo;
using EntitySnapshot = Cinnabar.Editor.Link.Protocol.EntitySnapshot;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// The texture tools in the shell, without a host: a shift as one undo entry, the texel density from the project's
/// settings and the scale of new faces, Reset Scale, a material set by face and dropped on one, hotspots through the
/// cook index, and the texture gizmo's drag.
/// </summary>
public sealed class MeshTextureModeTests : IDisposable
{
    readonly TempDirectory _temp = new("mesh-texture");

    const string MaterialGuid = "aa112233445566778899aabbccddeeff";
    const string TextureGuid = "bb112233445566778899aabbccddeeff";
    const double Width = 1600;
    const double Height = 900;

    static readonly string Text = "scene 1\n\n" +
        "entity 0000000000000001\nname = \"Room\"\ncomponent 1 Transform\n\tposition = [0, 0, 83886080]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n" +
        $"component 33 Mesh_Renderer\n\tmesh = ${MeshFixtures.MeshGuid}\n\tmaterials.0 = ${MeshSession.DevGrayMaterial}\n";

    static ulong Handle(uint index) => 1UL << 32 | index;

    string ProjectPath => _temp.Combine("project.settings");

    EditorShell NewShell()
    {
        MeshFixtures.WriteRoom(_temp, MeshSession.DevGrayMaterial);
        File.WriteAllText(ProjectPath, "# Test project.\noutput = Sdr\n");
        var shell = TestShell.Open(_temp, "main.scene", Text, ProjectPath);
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [new Importer(AssetKind.Mesh, ".mesh", [])], []));
        shell.Assets.Apply(new AssetSnapshot(
        [
            new Asset(MeshFixtures.MeshGuid, AssetKind.Mesh, "game", "room.mesh", AssetStatus.Current, 0, 0, "", [], [], "", "", 0, [0, 0], "", [], ""),
            new Asset(MaterialGuid, AssetKind.Material, "game", "spots.material", AssetStatus.Current, 0, 0, "", [], [TextureGuid], "", "", 1, [0, 0], TextureGuid,
                [new CookHotspot(0, 0, 256, 256), new CookHotspot(256, 0, 768, 256)], ""),
            new Asset(TextureGuid, AssetKind.Texture, "game", "spots.png", AssetStatus.Current, 0, 0, "", [], [], "", "", 0, [1024, 1024], "", [], ""),
        ], []));
        shell.OnGameMessage(new EntitySnapshot([new EntityInfo(Handle(0), "Room", 1, 0, true, [1, 33])]));
        shell.Viewport.RequestSize(new PixelSize((int)Width, (int)Height));
        shell.Camera.Place([0, 0, 0], 0, 0);
        shell.Selection.Select(Handle(0));
        shell.Mesh.EnterMeshMode();
        Assert.True(shell.Mesh.InMeshMode);
        return shell;
    }

    // The face that fronts the camera, whose normal is -z.
    static int Front(EditorShell shell) => Enumerable.Range(0, MeshFixtures.Mesh(shell).Faces.Length).First(f => MeshFixtures.Mesh(shell).FaceNormal(f) == -Vec3.UnitZ);

    static void SelectFaces(EditorShell shell, params int[] faces) =>
        shell.Mesh.SetMeshSelection(new MeshSelection(MeshElement.Faces, [.. faces.Select(f => new MeshItem(MeshFixtures.MeshGuid, f))]), switchKind: true);

    static Vec2 PixelOf(EditorShell shell, Vec3 local)
    {
        var placement = MeshPlacement.Of(new Pose([0, 0, (long)(5 * Pose.Unit)], Quat.Identity, [1, 1, 1]), shell.Camera.Position);
        return shell.Camera.Project(placement.ToView(local), Width, Height)!.Value;
    }

    [Fact]
    public void ATextureToolIsOneEntryOnTheSelectedFaces()
    {
        using var shell = NewShell();
        var front = Front(shell);
        SelectFaces(shell, front, (front + 1) % 6);
        var before = MeshFixtures.Mesh(shell).Faces[front].Mapping;
        Assert.True(shell.Commands.Get(EditorCommands.TextureShiftLeft).Execute());
        Assert.Single(shell.Scene!.History);
        Assert.Equal(before.ShiftU + MeshTexture.ShiftStep, MeshFixtures.Mesh(shell).Faces[front].Mapping.ShiftU);
        Assert.Equal(before.ShiftU + MeshTexture.ShiftStep, MeshFixtures.Mesh(shell).Faces[(front + 1) % 6].Mapping.ShiftU);
        // The other faces keep their mappings, and the selection stays.
        Assert.Equal(before.ShiftU, MeshFixtures.Mesh(shell).Faces[(front + 2) % 6].Mapping.ShiftU);
        Assert.Equal(2, shell.Mesh.MeshSelection.Count);
        // Shift makes the step ten times, as the viewport's keys ask.
        Assert.True(shell.Mesh.ShiftTexture(0, -1, 10));
        Assert.Equal(before.ShiftV - 10 * MeshTexture.ShiftStep, MeshFixtures.Mesh(shell).Faces[front].Mapping.ShiftV, 9);
        Assert.True(shell.Mesh.RotateTexture(1));
        Assert.Equal(15, MeshFixtures.Mesh(shell).Faces[front].Mapping.Rotation);
        Assert.True(shell.Mesh.ScaleTexture(1));
        Assert.Equal(1.25, MeshFixtures.Mesh(shell).Faces[front].Mapping.ScaleU, 9);
        shell.Scene.Undo();
        Assert.Equal(1, MeshFixtures.Mesh(shell).Faces[front].Mapping.ScaleU);
        // Nothing selected, or another kind, and the tool does not run.
        shell.Mesh.SetMeshElement(MeshElement.Vertices);
        Assert.False(shell.Commands.Get(EditorCommands.TextureShiftLeft).CanExecute);
    }

    [Fact]
    public void TheDensityComesFromTheProjectAndSetsNewFacesScale()
    {
        using var shell = NewShell();
        Assert.Equal(MeshTexture.DefaultDensity, shell.Mesh.TexelDensity);
        // A dev material measures by the engine's grid before the index knows it: 1024 texels at 256 per meter is 4 m.
        Assert.Equal(4, shell.Mesh.NewFaceScale(MeshSession.DevGrayMaterial));
        shell.Mesh.SetTexelDensity(512);
        Assert.Equal("512", ProjectSettings.Get(ProjectPath, MeshSession.TexelDensityKey));
        Assert.Equal(512, shell.Mesh.TexelDensity);
        Assert.Equal(2, shell.Mesh.NewFaceScale(MeshSession.DevGrayMaterial));
        // A material whose texture the index gives measures by it; one it does not know takes the default.
        Assert.Equal(2, shell.Mesh.NewFaceScale(MaterialGuid));
        Assert.Equal(Mapping.DefaultScale, shell.Mesh.NewFaceScale("00112233445566778899aabbccddeeff"));
        // Reset Scale puts the selected faces at the density.
        var front = Front(shell);
        SelectFaces(shell, front);
        Assert.True(shell.Commands.Get(EditorCommands.TextureResetScale).Execute());
        Assert.Equal((2.0, 2.0), (MeshFixtures.Mesh(shell).Faces[front].Mapping.ScaleU, MeshFixtures.Mesh(shell).Faces[front].Mapping.ScaleV));
        // An extruded wall takes the density too.
        shell.SetTool(Tool.Select);
        Assert.True(shell.Commands.Get(EditorCommands.MeshExtrude).Execute());
        var center = shell.Camera.RelativeTo(shell.GizmoPose()!.Value.Pivot);
        var size = Gizmo.Size(shell.Camera, center, Height);
        Vec2 Along(double meters) => shell.Camera.Project(center + new Vec3(0, 0, -1) * meters, Width, Height)!.Value;
        Assert.True(shell.PressGizmo(Along(0.5 * size)));
        shell.DragGizmo(Along(0.5 * size + 0.5), invertSnap: false);
        shell.ReleaseGizmo();
        Assert.Equal(10, MeshFixtures.Mesh(shell).Faces.Length);
        Assert.All(MeshFixtures.Mesh(shell).Faces.Skip(6), f => Assert.Equal(2, f.Mapping.ScaleU));
    }

    [Fact]
    public void AMaterialSetsTheMeshSlotAndTheRendererField()
    {
        using var shell = NewShell();
        var front = Front(shell);
        SelectFaces(shell, front);
        var blue = MeshSession.DevMaterials.First(d => d.Name == "Blue").Guid;
        Assert.True(shell.Mesh.SetFaceMaterial(blue));
        Assert.Single(shell.Scene!.History);
        Assert.Equal(1, MeshFixtures.Mesh(shell).Faces[front].Slot);
        Assert.Equal(blue, MeshFixtures.Mesh(shell).Materials[1]);
        var renderer = shell.Scene.Scene.Find(1)!.Components.Find(c => c.Id == SceneEdits.MeshRendererId)!;
        Assert.Equal(blue, renderer.Fields.Single(f => f.Name == "materials.1").Value.Asset);
        // The dropdown shows it, and undo takes both back.
        Assert.Equal("Blue", ((Commands.ChoiceCommand)shell.Commands.Get(EditorCommands.MeshDevMaterial)).Selected);
        shell.Scene.Undo();
        Assert.Equal(0, MeshFixtures.Mesh(shell).Faces[front].Slot);
        Assert.DoesNotContain(renderer.Fields, f => f.Name == "materials.1");
        Assert.DoesNotContain(shell.Scene.Scene.Find(1)!.Components.Find(c => c.Id == SceneEdits.MeshRendererId)!.Fields, f => f.Name == "materials.1");

        // A drop shows the material on the face under the mouse while the drag is over it, and the drop keeps it.
        shell.Mesh.SetMeshSelection(shell.Mesh.MeshSelection.Clear());
        var pixel = PixelOf(shell, new Vec3(0.1, 0.1, -0.5));
        shell.Mesh.PreviewFaceMaterial(pixel, blue);
        Assert.True(shell.Scene.InTransaction);
        Assert.Equal(blue, MeshFixtures.Mesh(shell).Materials[MeshFixtures.Mesh(shell).Faces[front].Slot]);
        shell.Mesh.PreviewFaceMaterial(null, blue);
        Assert.False(shell.Scene.InTransaction);
        Assert.Equal(MeshSession.DevGrayMaterial, MeshFixtures.Mesh(shell).Materials[MeshFixtures.Mesh(shell).Faces[front].Slot]);
        Assert.True(shell.Mesh.DropFaceMaterial(pixel, blue));
        Assert.Equal(blue, MeshFixtures.Mesh(shell).Materials[MeshFixtures.Mesh(shell).Faces[front].Slot]);
        Assert.Single(shell.Scene.History);
        // A drop over a selected face sets every selected face.
        SelectFaces(shell, front, (front + 1) % 6);
        var red = MeshSession.DevMaterials.First(d => d.Name == "Red").Guid;
        Assert.True(shell.Mesh.DropFaceMaterial(pixel, red));
        Assert.Equal(red, MeshFixtures.Mesh(shell).Materials[MeshFixtures.Mesh(shell).Faces[(front + 1) % 6].Slot]);
        Assert.False(shell.Mesh.DropFaceMaterial(new Vec2(5, 5), red));
    }

    [Fact]
    public void HotspotsComeFromTheIndex()
    {
        using var shell = NewShell();
        var front = Front(shell);
        SelectFaces(shell, front);
        Assert.True(shell.Mesh.SetFaceMaterial(MaterialGuid));
        Assert.Equal((TextureGuid, 1024.0, 1024.0), shell.Mesh.MaterialTexture(MaterialGuid));
        Assert.Equal(2, shell.Mesh.MaterialHotspots(MaterialGuid).Count);
        // The 1 m face is 256 texels at the project's density: the square rectangle.
        Assert.True(shell.Commands.Get(EditorCommands.TextureHotspot).Execute());
        var (minU, maxU, minV, maxV) = MeshTexture.UvBounds(MeshFixtures.Mesh(shell), front, MeshFixtures.Mesh(shell).Faces[front].Mapping);
        Assert.Equal((0, 0.25, 0, 0.25), (Math.Round(minU, 6), Math.Round(maxU, 6), Math.Round(minV, 6), Math.Round(maxV, 6)));
        Assert.True(shell.Commands.Get(EditorCommands.TextureHotspotNext).Execute());
        (minU, maxU, _, _) = MeshTexture.UvBounds(MeshFixtures.Mesh(shell), front, MeshFixtures.Mesh(shell).Faces[front].Mapping);
        Assert.Equal((0.25, 0.75), (Math.Round(minU, 6), Math.Round(maxU, 6)));
        // Random keeps the best rectangle in one of its symmetries.
        Assert.True(shell.Mesh.ApplyHotspot(HotspotChoice.Random, new Random(3)));
        Assert.Equal(0, MeshTexture.CurrentHotspot(MeshFixtures.Mesh(shell), front, MeshFixtures.Mesh(shell).Faces[front].Mapping, shell.Mesh.MaterialHotspots(MaterialGuid), 1024, 1024));
        // A material without hotspots fits instead.
        Assert.True(shell.Mesh.SetFaceMaterial(MeshSession.DevGrayMaterial));
        Assert.True(shell.Mesh.ApplyHotspot(HotspotChoice.Best));
        (minU, maxU, _, _) = MeshTexture.UvBounds(MeshFixtures.Mesh(shell), front, MeshFixtures.Mesh(shell).Faces[front].Mapping);
        Assert.Equal((0, 1), (Math.Round(minU, 6), Math.Round(maxU, 6)));
    }

    [Fact]
    public void TheTextureGizmoDragsTheMappingNotTheVertices()
    {
        using var shell = NewShell();
        var front = Front(shell);
        SelectFaces(shell, front);
        shell.SetTool(Tool.Move);
        Assert.True(shell.Commands.Get(EditorCommands.MeshTransformTexture).Execute());
        Assert.True(shell.Mesh.TextureGizmo);
        // The gizmo's x axis is the face's u axis, +x.
        var (pivot, axes) = shell.GizmoPose()!.Value;
        Assert.Equal(1, Vec3.Dot(axes.Rotate(Vec3.UnitX), Vec3.UnitX), 6);
        var center = shell.Camera.RelativeTo(pivot);
        var size = Gizmo.Size(shell.Camera, center, Height);
        Vec2 Along(double meters) => shell.Camera.Project(center + Vec3.UnitX * meters, Width, Height)!.Value;
        var vertices = MeshFixtures.Mesh(shell).Vertices;
        Assert.True(shell.PressGizmo(Along(0.5 * size)));
        shell.DragGizmo(Along(0.5 * size + 0.5), invertSnap: false);
        shell.ReleaseGizmo();
        Assert.Single(shell.Scene!.History);
        Assert.Equal(vertices, MeshFixtures.Mesh(shell).Vertices);
        // The texture moved half a meter along u: the shift fell by half a repeat at a scale of 1.
        Assert.Equal(-0.5, MeshFixtures.Mesh(shell).Faces[front].Mapping.ShiftU, 6);
        Assert.Equal(0, MeshFixtures.Mesh(shell).Faces[front].Mapping.ShiftV, 6);
        // Off again, and a drag moves the vertices.
        Assert.True(shell.Commands.Get(EditorCommands.MeshTransformTexture).Execute());
        Assert.False(shell.Mesh.TextureGizmo);
        Assert.True(shell.PressGizmo(Along(0.5 * size)));
        shell.DragGizmo(Along(0.5 * size + 0.5), invertSnap: false);
        shell.ReleaseGizmo();
        Assert.NotEqual(vertices, MeshFixtures.Mesh(shell).Vertices);
    }

    [Fact]
    public void TheFacePanelsDragIsOneEntry()
    {
        using var shell = NewShell();
        var front = Front(shell);
        SelectFaces(shell, front);
        Assert.True(shell.Mesh.BeginMappingScrub("Drag Texture Scale"));
        shell.Mesh.PreviewMappings((_, _, m) => m with { ScaleU = 2 });
        shell.Mesh.PreviewMappings((_, _, m) => m with { ScaleU = 3 });
        Assert.Equal(3, MeshFixtures.Mesh(shell).Faces[front].Mapping.ScaleU);
        shell.Mesh.EndMappingScrub();
        Assert.Single(shell.Scene!.History);
        shell.Scene.Undo();
        Assert.Equal(1, MeshFixtures.Mesh(shell).Faces[front].Mapping.ScaleU);
        Assert.True(shell.Mesh.SetTextureScale(null, 0.5));
        Assert.Equal((1.0, 0.5), (MeshFixtures.Mesh(shell).Faces[front].Mapping.ScaleU, MeshFixtures.Mesh(shell).Faces[front].Mapping.ScaleV));
        Assert.True(shell.Mesh.SetTextureRotation(400));
        Assert.Equal(40, MeshFixtures.Mesh(shell).Faces[front].Mapping.Rotation, 9);
    }

    public void Dispose() => _temp.Dispose();
}
