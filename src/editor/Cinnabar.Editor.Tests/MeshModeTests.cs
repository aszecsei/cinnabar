using Avalonia;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
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
    readonly string _directory = Path.Combine(Path.GetTempPath(), $"cinnabar-mesh-mode-tests-{Guid.NewGuid():N}");

    const string MeshGuid = "3b7f2c9e4d1a4f6b8c0d2e4f6a8b0c1d";
    const double Width = 1600;
    const double Height = 900;

    // A 1 m box, centered on its entity, 5 m ahead of a camera at the origin.
    static readonly string Text = "scene 1\n\n" +
        "entity 0000000000000001\nname = \"Room\"\ncomponent 1 Transform\n\tposition = [0, 0, 83886080]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n" +
        $"component 33 Mesh_Renderer\n\tmesh = ${MeshGuid}\n\n" +
        "entity 0000000000000002\nname = \"Lamp\"\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n";

    static ulong Handle(uint index) => 1UL << 32 | index;

    EditorShell NewShell()
    {
        Directory.CreateDirectory(_directory);
        var scenePath = Path.Combine(_directory, "main.scene");
        File.WriteAllText(scenePath, Text);
        File.WriteAllText(Path.Combine(_directory, "room.mesh"), MeshFile.Write(Primitives.Block(new Vec3(-0.5, -0.5, -0.5), new Vec3(0.5, 0.5, 0.5))));
        var shell = new EditorShell(new EditorOptions("host.exe", "game.dll", scenePath) { AutosaveDirectory = Path.Combine(_directory, "autosave") },
            new EditorSettings(Path.Combine(_directory, "settings")));
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _directory)], [new Importer(AssetKind.Mesh, ".mesh", [])], []));
        shell.Assets.Apply(new AssetSnapshot([new Asset(MeshGuid, AssetKind.Mesh, "game", "room.mesh", AssetStatus.Current, 0, 0, "", [], [], "", "", 0)], []));
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
        shell.EnterMeshMode();
        Assert.True(shell.InMeshMode);
        return shell;
    }

    static MeshData Mesh(EditorShell shell) => shell.Meshes.Find(MeshGuid)!.Data;

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
        Assert.False(shell.CanEditMesh);
        shell.Selection.Select(Handle(1));
        Assert.False(shell.CanEditMesh);
        shell.EnterMeshMode();
        Assert.False(shell.InMeshMode);
        Assert.Contains(shell.Console.Lines, l => l.Text.Contains("select an entity that places a .mesh file"));

        shell.Selection.Select(Handle(0));
        Assert.True(shell.CanEditMesh);
        Assert.True(shell.Commands.Get(EditorCommands.EditMesh).Execute());
        Assert.True(shell.InMeshMode);
        Assert.True(shell.Context.IsActive(EditorShell.MeshContext));
        Assert.Equal(MeshElement.Faces, shell.MeshElement);
        Assert.Equal("Faces: 0 of 1 mesh", shell.MeshStatus);
        var document = Assert.Single(shell.Meshes.Documents);
        Assert.True(document.IsLive);
        Assert.Equal([MeshGuid], shell.EditedMeshes.Keys);

        shell.Commands.Get(EditorCommands.ObjectMode).Execute();
        Assert.False(shell.InMeshMode);
        Assert.False(shell.Context.IsActive(EditorShell.MeshContext));
        Assert.Single(shell.Meshes.Documents);
        Assert.Empty(shell.EditedMeshes);

        // Play leaves the mode too.
        shell.ToggleMeshMode();
        Assert.True(shell.InMeshMode);
        shell.Play();
        Assert.False(shell.InMeshMode);
        shell.Stop();
    }

    [Fact]
    public void ClicksBoxesAndKindsChangeTheSubSelection()
    {
        using var shell = EnteredShell();
        // A click in the middle hits the front face.
        shell.PickAt(Center, SelectMode.Replace);
        Assert.Equal([new MeshItem(MeshGuid, 2)], shell.MeshSelection.Items);
        Assert.Equal("Faces: 1 of 1 mesh", shell.MeshStatus);
        // Vertices: the face's four, and 1 in the viewport is the Vertices command.
        shell.Commands.Get(EditorCommands.MeshVertices).Execute();
        Assert.Equal(MeshElement.Vertices, shell.MeshElement);
        Assert.Equal([0, 1, 4, 5], shell.MeshSelection.Of(MeshGuid).Order());
        // A click near a vertex picks it; Ctrl toggles it away; a click on nothing clears.
        var corner = PixelOf(shell, new Vec3(0.5, 0.5, -0.5)) + new Vec2(2, -2);
        shell.PickAt(corner, SelectMode.Toggle);
        Assert.Equal([0, 1, 4], shell.MeshSelection.Of(MeshGuid).Order());
        shell.PickAt(new Vec2(5, 5), SelectMode.Replace);
        Assert.True(shell.MeshSelection.IsEmpty);
        // Ctrl+A selects every vertex, and a box over the left half the two front ones there.
        shell.Commands.Get(EditorCommands.SelectAll).Execute();
        Assert.Equal(8, shell.MeshSelection.Count);
        shell.PickBox(new Vec2(0, 0), new Vec2(Width / 2, Height), SelectMode.Replace);
        Assert.Equal([0, 4], shell.MeshSelection.Of(MeshGuid).Order());
        shell.ToggleSelectThrough();
        shell.PickBox(new Vec2(0, 0), new Vec2(Width / 2, Height), SelectMode.Replace);
        Assert.Equal([0, 3, 4, 7], shell.MeshSelection.Of(MeshGuid).Order());
        // Edges: those with both ends selected.
        shell.SetMeshElement(MeshElement.Edges);
        Assert.Equal(4, shell.MeshSelection.Count);
        // Escape clears, then leaves.
        shell.EscapeMeshMode();
        Assert.True(shell.MeshSelection.IsEmpty && shell.InMeshMode);
        shell.EscapeMeshMode();
        Assert.False(shell.InMeshMode);
    }

    [Fact]
    public void DeleteRemovesTheSelectedFacesAsOneEntry()
    {
        using var shell = EnteredShell();
        shell.PickAt(Center, SelectMode.Replace);
        Assert.True(shell.Commands.Get(EditorCommands.DeleteEntity).CanExecute);
        Assert.True(shell.Commands.Get(EditorCommands.DeleteEntity).Execute());
        Assert.Equal(5, Mesh(shell).Faces.Length);
        Assert.Equal("Delete 1 Face", shell.Scene!.History[^1].Label);
        Assert.True(shell.MeshSelection.IsEmpty);
        Assert.True(shell.Meshes.Find(MeshGuid)!.IsDirty);
        // The scene's entities are untouched, and undo brings the face back.
        Assert.Equal(2, shell.Scene.Scene.Entities.Count);
        shell.Scene.Undo();
        Assert.Equal(6, Mesh(shell).Faces.Length);
        Assert.False(shell.Meshes.Find(MeshGuid)!.IsDirty);
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
        var mesh = Mesh(shell);
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
        mesh = Mesh(shell);
        Assert.Equal(1.25, mesh.Vertices[5].X, 3);
        Assert.Equal(0.25, mesh.Vertices[0].X, 3);
        Assert.Equal(2, shell.Scene.History.Count);
        shell.Scene.Undo();
        shell.Scene.Undo();
        Assert.Equal(0.5, Mesh(shell).Vertices[5].X, 3);
        Assert.False(shell.Meshes.Find(MeshGuid)!.IsDirty);
    }

    [Fact]
    public void BlockMakesAMeshAndAnEntityThatSaveWrites()
    {
        using var shell = NewShell();
        shell.Commands.Get(EditorCommands.MeshBlock).Execute();
        Assert.Equal(MeshTool.Create, shell.MeshTool);
        // Nothing is selected, so the grid's plane faces the camera through its pivot, 5 m ahead. The drag covers the
        // middle of the view: about a meter and a half across at that distance.
        Assert.True(shell.BeginBlock(Center + new Vec2(-100, -100)));
        shell.DragBlock(Center + new Vec2(100, 100));
        shell.EndBlock();

        var entry = Assert.Single(shell.Scene!.History);
        Assert.Equal("Block", entry.Label);
        var block = shell.Scene.Scene.Entities.Single(e => e.Name == "block");
        var renderer = block.Components.Single(c => c.Id == SceneEdits.MeshRendererId);
        var guid = renderer.Fields.Single(f => f.Name == "mesh").Value.Asset;
        Assert.Equal(EditorShell.DevGrayMaterial, renderer.Fields.Single(f => f.Name == "materials.0").Value.Asset);
        var document = shell.Meshes.Find(guid);
        Assert.NotNull(document);
        Assert.True(document.IsLive && document.IsDirty);
        Assert.Null(document.Saved);
        Assert.Equal(Path.Combine(_directory, "main_meshes", "block.mesh"), document.Path);
        Assert.Equal(6, document.Data.Faces.Length);
        // Its footprint is on the grid, and it is a grid cell deep along the view's axis.
        var size = document.Data.Vertices.Aggregate(new Vec3(-99, -99, -99), (m, v) => new Vec3(Math.Max(m.X, v.X), Math.Max(m.Y, v.Y), Math.Max(m.Z, v.Z)));
        Assert.Equal(MeshGrid.DefaultSize, size.Z, 6);
        Assert.Equal(0, size.X % MeshGrid.DefaultSize, 6);
        Assert.True(size.X > 1 && size.Y > 1);

        // Undo removes the entity and the document together; redo brings them back.
        shell.Scene.Undo();
        Assert.DoesNotContain(shell.Scene.Scene.Entities, e => e.Name == "block");
        Assert.Null(shell.Meshes.Find(guid));
        shell.Scene.Redo();
        Assert.NotNull(shell.Meshes.Find(guid));

        // Save writes the scene, the mesh and its .meta with the GUID.
        Assert.True(shell.SaveScene());
        Assert.True(File.Exists(document.Path));
        Assert.Contains($"guid = {guid}", File.ReadAllText(document.Path + ".meta"));
        Assert.False(document.IsDirty);
        var (saved, _) = MeshFile.Parse(File.ReadAllText(document.Path));
        Assert.Equal(6, saved!.Faces.Length);

        // A second block gets the next name, and in mesh mode a block joins the edited mesh instead.
        shell.Selection.Select(Handle(0));
        shell.EnterMeshMode();
        shell.SetPrimitive(PrimitiveKind.Block);
        Assert.True(shell.BeginBlock(Center + new Vec2(-50, -50)));
        shell.DragBlock(Center + new Vec2(50, 50));
        shell.EndBlock();
        Assert.Equal(12, Mesh(shell).Faces.Length);
        Assert.Equal(6, shell.MeshSelection.Count);
        Assert.Equal(3, shell.Scene.Scene.Entities.Count);
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory))
        {
            Directory.Delete(_directory, recursive: true);
        }
    }
}
