using Avalonia;
using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using EntityInfo = Cinnabar.Editor.Link.Protocol.EntityInfo;
using EntitySnapshot = Cinnabar.Editor.Link.Protocol.EntitySnapshot;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// The mesh tools in the shell, without a host: a distance tool and its drag, Shift-drag extrusion, Cut and Draw by
/// points, Detach, and a primitive whose parameters change after the drag.
/// </summary>
public sealed class MeshToolModeTests : IDisposable
{
    readonly TempDirectory _temp = new("mesh-tool");

    const double Width = 1600;
    const double Height = 900;

    static readonly string Text = "scene 1\n\n" +
        "entity 0000000000000001\nname = \"Room\"\ncomponent 1 Transform\n\tposition = [0, 0, 83886080]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n" +
        $"component 33 Mesh_Renderer\n\tmesh = ${MeshFixtures.MeshGuid}\n\tmaterials.0 = $00112233445566778899aabbccddeeff\n";

    static ulong Handle(uint index) => 1UL << 32 | index;

    EditorShell NewShell()
    {
        MeshFixtures.WriteRoom(_temp);
        var shell = TestShell.Open(_temp, "main.scene", Text);
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [new Importer(AssetKind.Mesh, ".mesh", [])], []));
        shell.Assets.Apply(new AssetSnapshot([new Asset(MeshFixtures.MeshGuid, AssetKind.Mesh, "game", "room.mesh", AssetStatus.Current, 0, 0, "", [], [], "", "", 0, [0, 0], "", [], "")], []));
        shell.OnGameMessage(new EntitySnapshot([new EntityInfo(Handle(0), "Room", 1, 0, true, [1, 33])]));
        shell.Viewport.RequestSize(new PixelSize((int)Width, (int)Height));
        shell.Camera.Place([0, 0, 0], 0, 0);
        shell.Selection.Select(Handle(0));
        shell.EnterMeshMode();
        Assert.True(shell.InMeshMode);
        return shell;
    }

    static void SelectFaces(EditorShell shell, params int[] faces) =>
        shell.SetMeshSelection(new MeshSelection(MeshElement.Faces, [.. faces.Select(f => new MeshItem(MeshFixtures.MeshGuid, f))]), switchKind: true);

    // A pixel along the x axis from the gizmo's pivot at the press, by meters: the gizmo follows the selection as the
    // drag moves it, but the drag is from where it started.
    static Func<double, Vec2> Along(EditorShell shell)
    {
        var center = shell.Camera.RelativeTo(shell.GizmoPose()!.Value.Pivot);
        return meters => shell.Camera.Project(center + Vec3.UnitX * meters, Width, Height)!.Value;
    }

    static Vec2 PixelOf(EditorShell shell, Vec3 local)
    {
        var placement = MeshPlacement.Of(new Pose([0, 0, (long)(5 * Pose.Unit)], Quat.Identity, [1, 1, 1]), shell.Camera.Position);
        return shell.Camera.Project(placement.ToView(local), Width, Height)!.Value;
    }

    [Fact]
    public void ADistanceToolWaitsForADragAndCommitsOnce()
    {
        using var shell = NewShell();
        // The right face, whose normal is +x, so the gizmo's x axis drags it out.
        SelectFaces(shell, 5);
        shell.SetTool(Tool.Select);
        Assert.True(shell.Commands.Get(EditorCommands.MeshExtrude).Execute());
        Assert.True(shell.HasPendingDistance);
        Assert.Empty(shell.Scene!.History);
        Assert.Equal(6, MeshFixtures.Mesh(shell).Faces.Length);
        // A Move gizmo shows whatever the tool, on the face's centroid.
        Assert.NotNull(shell.GizmoPose());
        var size = Gizmo.Size(shell.Camera, shell.Camera.RelativeTo(shell.GizmoPose()!.Value.Pivot), Height);
        var along = Along(shell);
        Assert.True(shell.PressGizmo(along(0.5 * size)));
        shell.DragGizmo(along(0.5 * size + 0.25), invertSnap: false);
        Assert.Equal(10, MeshFixtures.Mesh(shell).Faces.Length);
        shell.DragGizmo(along(0.5 * size + 0.5), invertSnap: false);
        shell.ReleaseGizmo();

        Assert.False(shell.HasPendingDistance);
        var entry = Assert.Single(shell.Scene.History);
        Assert.Equal("Extrude", entry.Label);
        var mesh = MeshFixtures.Mesh(shell);
        Assert.Equal(10, mesh.Faces.Length);
        Assert.All(mesh.Faces[5].Corners, c => Assert.Equal(1.0, mesh.Vertices[c].X, 3));
        Assert.Equal([5], shell.MeshSelection.Of(MeshFixtures.MeshGuid));
        shell.Scene.Undo();
        Assert.Equal(6, MeshFixtures.Mesh(shell).Faces.Length);

        // Escape cancels a tool that waits, and a tool that is never dragged leaves no entry.
        Assert.True(shell.Commands.Get(EditorCommands.MeshInset).Execute());
        shell.EscapeMeshMode();
        Assert.False(shell.HasPendingDistance);
        Assert.True(shell.Commands.Get(EditorCommands.MeshPushPull).Execute());
        shell.CommitPendingDistance();
        // The undone extrude is still the only entry, at position zero.
        Assert.Single(shell.Scene.History);
        Assert.Equal(0, shell.Scene.Position);
        Assert.Equal(6, MeshFixtures.Mesh(shell).Faces.Length);
    }

    [Fact]
    public void ShiftDragOfTheGizmoExtrudesFirst()
    {
        using var shell = NewShell();
        SelectFaces(shell, 5);
        shell.SetTool(Tool.Move);
        var size = Gizmo.Size(shell.Camera, shell.Camera.RelativeTo(shell.GizmoPose()!.Value.Pivot), Height);
        var along = Along(shell);
        Assert.True(shell.PressGizmo(along(0.5 * size), extrude: true));
        Assert.True(shell.HasPendingDistance);
        shell.DragGizmo(along(0.5 * size + 0.5), invertSnap: false);
        shell.ReleaseGizmo();
        Assert.Equal("Extrude", Assert.Single(shell.Scene!.History).Label);
        Assert.Equal(10, MeshFixtures.Mesh(shell).Faces.Length);
        Assert.Empty(MeshFixtures.Mesh(shell).Validate());
    }

    [Fact]
    public void CutIsALoopCutFromTheEdgeClicked()
    {
        using var shell = NewShell();
        shell.Commands.Get(EditorCommands.MeshCut).Execute();
        Assert.Equal(MeshTool.Cut, shell.MeshTool);
        // Hovering the front face's left edge a quarter up shows the loop; a click cuts it, with no Enter.
        var pixel = PixelOf(shell, new Vec3(-0.5, -0.25, -0.5)) + new Vec2(2, 0);
        shell.HoverMesh(pixel);
        Assert.True(shell.AddToolPoint(pixel));
        var mesh = MeshFixtures.Mesh(shell);
        Assert.Equal(10, mesh.Faces.Length);
        Assert.Equal(12, mesh.Vertices.Length);
        Assert.Equal(MeshElement.Vertices, shell.MeshElement);
        Assert.Equal(4, shell.MeshSelection.Count);
        Assert.All(shell.MeshSelection.Of(MeshFixtures.MeshGuid), v => Assert.Equal(-0.25, mesh.Vertices[v].Y, 2));
        Assert.Equal("Cut", Assert.Single(shell.Scene!.History).Label);
        // A click on nothing with the tool is taken and cuts nothing.
        Assert.True(shell.AddToolPoint(new Vec2(5, 5)));
        Assert.Single(shell.Scene.History);
    }

    [Fact]
    public void DrawCutsAPolygonIntoTheFaceUnderTheFirstClick()
    {
        using var shell = NewShell();
        shell.Commands.Get(EditorCommands.MeshDraw).Execute();
        foreach (var corner in new[] { new Vec3(-0.25, -0.25, -0.5), new Vec3(0.25, -0.25, -0.5), new Vec3(0.25, 0.25, -0.5), new Vec3(-0.25, 0.25, -0.5) })
        {
            Assert.True(shell.AddToolPoint(PixelOf(shell, corner)));
        }
        Assert.Equal(4, shell.ToolPointCount);
        // A click on the first corner closes the polygon.
        Assert.True(shell.AddToolPoint(PixelOf(shell, new Vec3(-0.25, -0.25, -0.5))));
        var mesh = MeshFixtures.Mesh(shell);
        Assert.Equal(8, mesh.Faces.Length);
        Assert.Equal(MeshElement.Faces, shell.MeshElement);
        var inner = mesh.Faces[Assert.Single(shell.MeshSelection.Of(MeshFixtures.MeshGuid))];
        Assert.Equal(4, inner.Corners.Length);
        Assert.All(inner.Corners, c => Assert.Equal(-0.5, mesh.Vertices[c].Z, 6));
        Assert.Empty(mesh.Validate());
        // The new face extrudes inward like a doorway: an Extrude by a negative distance.
        Assert.True(shell.Commands.Get(EditorCommands.MeshExtrude).Execute());
        shell.CommitPendingDistance();
    }

    [Fact]
    public void DetachMovesFacesIntoANewMeshAndEntity()
    {
        using var shell = NewShell();
        SelectFaces(shell, 5);
        Assert.True(shell.Commands.Get(EditorCommands.MeshDetach).Execute());
        var detached = shell.Scene!.Scene.Entities.Single(e => e.Name == "detach");
        var renderer = detached.Components.Single(c => c.Id == SceneEdits.MeshRendererId);
        var guid = renderer.Fields.Single(f => f.Name == "mesh").Value.Asset;
        // The source's material comes along, and the entity is at the source's pose.
        Assert.Equal("00112233445566778899aabbccddeeff", renderer.Fields.Single(f => f.Name == "materials.0").Value.Asset);
        Assert.Equal((long)(5 * Pose.Unit), SceneEdits.WorldPose(shell.Scene.Scene, detached)!.Position[2]);
        Assert.Equal(5, MeshFixtures.Mesh(shell).Faces.Length);
        var document = shell.Meshes.Find(guid)!;
        Assert.Single(document.Data.Faces);
        Assert.Equal(4, document.Data.Vertices.Length);
        Assert.Equal(2, shell.EditedMeshes.Count);
        Assert.Equal([0], shell.MeshSelection.Of(guid));
        Assert.Equal("Detach", Assert.Single(shell.Scene.History).Label);
        // Undo takes the entity, the document and the faces back together.
        shell.Scene.Undo();
        Assert.Equal(6, MeshFixtures.Mesh(shell).Faces.Length);
        Assert.Null(shell.Meshes.Find(guid));
        Assert.DoesNotContain(shell.Scene.Scene.Entities, e => e.Name == "detach");
        // Extract keeps the source.
        SelectFaces(shell, 5);
        Assert.True(shell.Commands.Get(EditorCommands.MeshExtract).Execute());
        Assert.Equal(6, MeshFixtures.Mesh(shell).Faces.Length);
        Assert.Contains(shell.Scene.Scene.Entities, e => e.Name == "extract");
    }

    [Fact]
    public void APrimitivesParametersChangeAfterTheDrag()
    {
        using var shell = NewShell();
        shell.LeaveMeshMode();
        ((ChoiceCommand)shell.Commands.Get(EditorCommands.MeshPrimitive)).Select("Cylinder");
        Assert.Equal(PrimitiveKind.Cylinder, shell.Primitive);
        Assert.Equal(MeshTool.Create, shell.MeshTool);
        var center = new Vec2(Width / 2, Height / 2);
        Assert.True(shell.BeginBlock(center + new Vec2(-100, -100)));
        shell.DragBlock(center + new Vec2(100, 100));
        shell.EndBlock();
        var cylinder = shell.Scene!.Scene.Entities.Single(e => e.Name == "cylinder");
        var guid = cylinder.Components.Single(c => c.Id == SceneEdits.MeshRendererId).Fields.Single(f => f.Name == "mesh").Value.Asset;
        Assert.Equal(18, shell.Meshes.Find(guid)!.Data.Faces.Length);
        Assert.Single(shell.Scene.History);

        // Eight sides, then six: made again in place of the same entry each time.
        ((ChoiceCommand)shell.Commands.Get(EditorCommands.MeshSides)).Select("8");
        Assert.Single(shell.Scene.History);
        var again = shell.Scene.Scene.Entities.Single(e => e.Name == "cylinder");
        var againGuid = again.Components.Single(c => c.Id == SceneEdits.MeshRendererId).Fields.Single(f => f.Name == "mesh").Value.Asset;
        Assert.Equal(10, shell.Meshes.Find(againGuid)!.Data.Faces.Length);
        Assert.Empty(shell.Meshes.Find(againGuid)!.Data.Validate());
        ((ChoiceCommand)shell.Commands.Get(EditorCommands.MeshSides)).Select("6");
        Assert.Single(shell.Scene.History);
        againGuid = shell.Scene.Scene.Entities.Single(e => e.Name == "cylinder").Components.Single(c => c.Id == SceneEdits.MeshRendererId).Fields.Single(f => f.Name == "mesh").Value.Asset;
        Assert.Equal(8, shell.Meshes.Find(againGuid)!.Data.Faces.Length);
        Assert.Equal(2, shell.Scene.Scene.Entities.Count);

        // After another edit, a parameter change makes nothing.
        shell.Selection.Select(Handle(0));
        shell.Commands.Get(EditorCommands.CreateEntity).Execute();
        ((ChoiceCommand)shell.Commands.Get(EditorCommands.MeshSides)).Select("12");
        Assert.Equal(8, shell.Meshes.Find(againGuid)!.Data.Faces.Length);
        Assert.Equal(2, shell.Scene.History.Count);
    }

    public void Dispose() => _temp.Dispose();
}
