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

/// <summary>
/// Mesh mode in the shell, without a host: entering and leaving, the element kinds, clicks, boxes, Delete, a gizmo
/// drag of vertices with the grid's snapping, and Block.
/// </summary>
public sealed class MeshModeTests : IDisposable
{
    readonly TempDirectory _temp = new("mesh-mode");

    const double Width = 1600;
    const double Height = 900;

    // A 1 m box, centered on its entity, 5 m ahead of a camera at the origin.
    static readonly string Text = "scene 1\n\n" +
        "entity 0000000000000001\nname = \"Room\"\ncomponent 1 Transform\n\tposition = [0, 0, 83886080]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n" +
        $"component 33 Mesh_Renderer\n\tmesh = ${MeshFixtures.MeshGuid}\n\n" +
        "entity 0000000000000002\nname = \"Lamp\"\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n";

    static ulong Handle(uint index) => 1UL << 32 | index;

    EditorShell NewShell()
    {
        MeshFixtures.WriteRoom(_temp);
        var shell = TestShell.Open(_temp, "main.scene", Text);
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [new Importer(AssetKind.Mesh, ".mesh", [])], []));
        shell.Assets.Apply(new AssetSnapshot([new Asset(MeshFixtures.MeshGuid, AssetKind.Mesh, "game", "room.mesh", AssetStatus.Current, 0, 0, "", [], [], "", "", 0, [0, 0], "", [], "")], []));
        shell.OnGameMessage(new EntitySnapshot(
        [
            new EntityInfo(Handle(0), "Room", 1, 0, true, [1, 33]),
            new EntityInfo(Handle(1), "Lamp", 2, 0, true, [1]),
        ]));
        shell.Viewport.RequestSize(new PixelSize((int)Width, (int)Height));
        shell.Camera.Place([0, 0, 0], 0, 0);
        return shell;
    }

    EditorShell EnteredShell()
    {
        var shell = NewShell();
        shell.Selection.Select(Handle(0));
        shell.Mesh.EnterMeshMode();
        Assert.True(shell.Mesh.InMeshMode);
        return shell;
    }

    // The pixel of a vertex of the box, as the camera sees it.
    static Vec2 PixelOf(EditorShell shell, Vec3 local)
    {
        var placement = MeshPlacement.Of(new Pose([0, 0, (long)(5 * Pose.Unit)], Quat.Identity, [1, 1, 1]), shell.Camera.Position);
        return shell.Camera.Project(placement.ToView(local), Width, Height)!.Value;
    }

    static Vec2 Center => new(Width / 2, Height / 2);

    [Fact]
    public void EnteringNeedsAMeshFileAndLeavingKeepsTheMeshOpen()
    {
        using var shell = NewShell();
        Assert.False(shell.Mesh.CanEditMesh);
        shell.Selection.Select(Handle(1));
        Assert.False(shell.Mesh.CanEditMesh);
        shell.Mesh.EnterMeshMode();
        Assert.False(shell.Mesh.InMeshMode);
        Assert.Contains(shell.Console.Lines, l => l.Text.Contains("select an entity that places a .mesh file"));

        shell.Selection.Select(Handle(0));
        Assert.True(shell.Mesh.CanEditMesh);
        Assert.True(shell.Commands.Get(EditorCommands.EditMesh).Execute());
        Assert.True(shell.Mesh.InMeshMode);
        Assert.True(shell.Context.IsActive(MeshSession.MeshContext));
        Assert.Equal(MeshElement.Faces, shell.Mesh.MeshElement);
        Assert.Equal("Faces: 0 of 1 mesh", shell.Mesh.MeshStatus);
        var document = Assert.Single(shell.Mesh.Meshes.Documents);
        Assert.True(document.IsLive);
        Assert.Equal([MeshFixtures.MeshGuid], shell.Mesh.EditedMeshes.Keys);

        shell.Commands.Get(EditorCommands.ObjectMode).Execute();
        Assert.False(shell.Mesh.InMeshMode);
        Assert.False(shell.Context.IsActive(MeshSession.MeshContext));
        Assert.Single(shell.Mesh.Meshes.Documents);
        Assert.Empty(shell.Mesh.EditedMeshes);

        // Play leaves the mode too.
        shell.Mesh.ToggleMeshMode();
        Assert.True(shell.Mesh.InMeshMode);
        shell.Play();
        Assert.False(shell.Mesh.InMeshMode);
        shell.Stop();
    }

    [Fact]
    public void ClicksBoxesAndKindsChangeTheSubSelection()
    {
        using var shell = EnteredShell();
        // A click in the middle hits the front face.
        shell.PickAt(Center, SelectMode.Replace);
        Assert.Equal([new MeshItem(MeshFixtures.MeshGuid, 2)], shell.Mesh.MeshSelection.Items);
        Assert.Equal("Faces: 1 of 1 mesh", shell.Mesh.MeshStatus);
        // Vertices: the face's four, and 1 in the viewport is the Vertices command.
        shell.Commands.Get(EditorCommands.MeshVertices).Execute();
        Assert.Equal(MeshElement.Vertices, shell.Mesh.MeshElement);
        Assert.Equal([0, 1, 4, 5], shell.Mesh.MeshSelection.Of(MeshFixtures.MeshGuid).Order());
        // A click near a vertex picks it; Ctrl toggles it away; a click on nothing clears.
        var corner = PixelOf(shell, new Vec3(0.5, 0.5, -0.5)) + new Vec2(2, -2);
        shell.PickAt(corner, SelectMode.Toggle);
        Assert.Equal([0, 1, 4], shell.Mesh.MeshSelection.Of(MeshFixtures.MeshGuid).Order());
        shell.PickAt(new Vec2(5, 5), SelectMode.Replace);
        Assert.True(shell.Mesh.MeshSelection.IsEmpty);
        // Ctrl+A selects every vertex, and a box over the left half the two front ones there.
        shell.Commands.Get(EditorCommands.SelectAll).Execute();
        Assert.Equal(8, shell.Mesh.MeshSelection.Count);
        shell.PickBox(new Vec2(0, 0), new Vec2(Width / 2, Height), SelectMode.Replace);
        Assert.Equal([0, 4], shell.Mesh.MeshSelection.Of(MeshFixtures.MeshGuid).Order());
        shell.Mesh.ToggleSelectThrough();
        shell.PickBox(new Vec2(0, 0), new Vec2(Width / 2, Height), SelectMode.Replace);
        Assert.Equal([0, 3, 4, 7], shell.Mesh.MeshSelection.Of(MeshFixtures.MeshGuid).Order());
        // Edges: those with both ends selected.
        shell.Mesh.SetMeshElement(MeshElement.Edges);
        Assert.Equal(4, shell.Mesh.MeshSelection.Count);
        // Escape clears, then leaves.
        shell.Mesh.EscapeMeshMode();
        Assert.True(shell.Mesh.MeshSelection.IsEmpty && shell.Mesh.InMeshMode);
        shell.Mesh.EscapeMeshMode();
        Assert.False(shell.Mesh.InMeshMode);
    }

    [Fact]
    public void DeleteRemovesTheSelectedFacesAsOneEntry()
    {
        using var shell = EnteredShell();
        shell.PickAt(Center, SelectMode.Replace);
        Assert.True(shell.Commands.Get(EditorCommands.DeleteEntity).CanExecute);
        Assert.True(shell.Commands.Get(EditorCommands.DeleteEntity).Execute());
        Assert.Equal(5, MeshFixtures.Mesh(shell).Faces.Length);
        Assert.Equal("Delete 1 Face", shell.Scene!.History[^1].Label);
        Assert.True(shell.Mesh.MeshSelection.IsEmpty);
        Assert.True(shell.Mesh.Meshes.Find(MeshFixtures.MeshGuid)!.IsDirty);
        // The scene's entities are untouched, and undo brings the face back.
        Assert.Equal(2, shell.Scene.Scene.Entities.Count);
        shell.Scene.Undo();
        Assert.Equal(6, MeshFixtures.Mesh(shell).Faces.Length);
        Assert.False(shell.Mesh.Meshes.Find(MeshFixtures.MeshGuid)!.IsDirty);
    }

    [Fact]
    public void AGizmoDragMovesTheSelectedVerticesAndSnapsThemToTheGrid()
    {
        using var shell = EnteredShell();
        shell.SetTool(Tool.Move);
        shell.PickAt(Center, SelectMode.Replace);
        // The gizmo sits on the front face's centroid, 4.5 m ahead.
        var pose = shell.GizmoPose();
        Assert.NotNull(pose);
        Assert.Equal((long)(4.5 * Pose.Unit), pose.Value.Pivot[2]);
        var center = shell.Camera.RelativeTo(pose.Value.Pivot);
        var size = Gizmo.Size(shell.Camera, center, Height);
        Vec2 Along(double meters) => shell.Camera.Project(center + Vec3.UnitX * meters, Width, Height)!.Value;

        Assert.True(shell.PressGizmo(Along(0.5 * size)));
        Assert.True(shell.IsDraggingGizmo);
        shell.DragGizmo(Along(0.5 * size + 0.3), invertSnap: false);
        shell.DragGizmo(Along(0.5 * size + 0.4), invertSnap: false);
        shell.ReleaseGizmo();

        var entry = Assert.Single(shell.Scene!.History);
        Assert.Equal("Move 1 Face", entry.Label);
        var mesh = MeshFixtures.Mesh(shell);
        // The front face's vertices moved 0.4 m along x; the back face's stayed.
        Assert.Equal(0.9, mesh.Vertices[5].X, 3);
        Assert.Equal(-0.1, mesh.Vertices[0].X, 3);
        Assert.Equal(0.5, mesh.Vertices[6].X, 3);
        Assert.Equal(-0.5, mesh.Vertices[0].Y, 3);
        // The faces are the same arrays, so the host got a vertices-only step.
        Assert.Equal(6, mesh.Faces.Length);

        // Snapping rounds each vertex's world position to the grid: with the entity 5 m ahead and the box's corners
        // at halves, a drag of 0.3 m lands the vertices on quarter meters.
        Assert.True(shell.PressGizmo(Along(0.5 * size + 0.4)));
        shell.DragGizmo(Along(0.5 * size + 0.7), invertSnap: true);
        shell.ReleaseGizmo();
        mesh = MeshFixtures.Mesh(shell);
        Assert.Equal(1.25, mesh.Vertices[5].X, 3);
        Assert.Equal(0.25, mesh.Vertices[0].X, 3);
        Assert.Equal(2, shell.Scene.History.Count);
        shell.Scene.Undo();
        shell.Scene.Undo();
        Assert.Equal(0.5, MeshFixtures.Mesh(shell).Vertices[5].X, 3);
        Assert.False(shell.Mesh.Meshes.Find(MeshFixtures.MeshGuid)!.IsDirty);
    }

    [Fact]
    public void BlockMakesAMeshAndAnEntityThatSaveWrites()
    {
        using var shell = NewShell();
        shell.Commands.Get(EditorCommands.MeshBlock).Execute();
        Assert.Equal(MeshTool.Create, shell.Mesh.MeshTool);
        // Nothing is selected, so the grid's plane faces the camera through its pivot, 5 m ahead. The drag covers the
        // middle of the view: about a meter and a half across at that distance.
        Assert.True(shell.Mesh.BeginBlock(Center + new Vec2(-100, -100)));
        shell.Mesh.DragBlock(Center + new Vec2(100, 100));
        shell.Mesh.EndBlock();

        var entry = Assert.Single(shell.Scene!.History);
        Assert.Equal("Block", entry.Label);
        var block = shell.Scene.Scene.Entities.Single(e => e.Name == "block");
        var renderer = block.Components.Single(c => c.Id == SceneEdits.MeshRendererId);
        var guid = renderer.Fields.Single(f => f.Name == "mesh").Value.Asset;
        Assert.Equal(MeshSession.DevGrayMaterial, renderer.Fields.Single(f => f.Name == "materials.0").Value.Asset);
        var document = shell.Mesh.Meshes.Find(guid);
        Assert.NotNull(document);
        Assert.True(document.IsLive && document.IsDirty);
        Assert.Null(document.Saved);
        Assert.Equal(_temp.Combine("main_meshes", "block.mesh"), document.Path);
        Assert.Equal(6, document.Data.Faces.Length);
        // Its footprint is on the grid, and it is a grid cell deep along the view's axis.
        var size = document.Data.Vertices.Aggregate(new Vec3(-99, -99, -99), (m, v) => new Vec3(Math.Max(m.X, v.X), Math.Max(m.Y, v.Y), Math.Max(m.Z, v.Z)));
        Assert.Equal(MeshGrid.DefaultSize, size.Z, 6);
        Assert.Equal(0, size.X % MeshGrid.DefaultSize, 6);
        Assert.True(size.X > 1 && size.Y > 1);

        // Undo removes the entity and the document together; redo brings them back.
        shell.Scene.Undo();
        Assert.DoesNotContain(shell.Scene.Scene.Entities, e => e.Name == "block");
        Assert.Null(shell.Mesh.Meshes.Find(guid));
        shell.Scene.Redo();
        Assert.NotNull(shell.Mesh.Meshes.Find(guid));

        // Save writes the scene, the mesh and its .meta with the GUID.
        Assert.True(shell.SaveScene());
        Assert.True(File.Exists(document.Path));
        Assert.Contains($"guid = {guid}", File.ReadAllText(document.Path + ".meta"));
        Assert.False(document.IsDirty);
        var (saved, _) = MeshFile.Parse(File.ReadAllText(document.Path));
        Assert.Equal(6, saved!.Faces.Length);

        // A second block gets the next name, and in mesh mode a block joins the edited mesh instead.
        shell.Selection.Select(Handle(0));
        shell.Mesh.EnterMeshMode();
        shell.Mesh.SetPrimitive(PrimitiveKind.Block);
        Assert.True(shell.Mesh.BeginBlock(Center + new Vec2(-50, -50)));
        shell.Mesh.DragBlock(Center + new Vec2(50, 50));
        shell.Mesh.EndBlock();
        Assert.Equal(12, MeshFixtures.Mesh(shell).Faces.Length);
        Assert.Equal(6, shell.Mesh.MeshSelection.Count);
        Assert.Equal(3, shell.Scene.Scene.Entities.Count);
    }

    public void Dispose() => _temp.Dispose();
}
