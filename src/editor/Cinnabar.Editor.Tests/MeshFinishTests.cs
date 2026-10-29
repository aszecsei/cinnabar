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
/// The finish of the mesh editing design: Keep Planar, Select Linked, Grow and Shrink, Edit Pivot with Center Pivot
/// and Pivot to Grid, and Clean's report as a selection.
/// </summary>
public sealed class MeshFinishTests : IDisposable
{
    readonly string _directory = Path.Combine(Path.GetTempPath(), $"cinnabar-mesh-finish-tests-{Guid.NewGuid():N}");

    const string MeshGuid = "3b7f2c9e4d1a4f6b8c0d2e4f6a8b0c1d";
    const double Width = 1600;
    const double Height = 900;

    static readonly string Text = "scene 1\n\n" +
        "entity 0000000000000001\nname = \"Room\"\ncomponent 1 Transform\n\tposition = [0, 0, 83886080]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n" +
        $"component 33 Mesh_Renderer\n\tmesh = ${MeshGuid}\n\tmaterials.0 = ${EditorShell.DevGrayMaterial}\n";

    static ulong Handle(uint index) => 1UL << 32 | index;

    static readonly MeshData Box = Primitives.Block(new Vec3(0, 0, 0), new Vec3(1, 1, 1));

    // Two boxes in one mesh, apart from each other.
    static MeshData TwoBoxes()
    {
        var other = Primitives.Block(new Vec3(3, 0, 0), new Vec3(4, 1, 1));
        return Box.With(
            vertices: Box.Vertices.AddRange(other.Vertices),
            faces: Box.Faces.AddRange(other.Faces.Select(f => f with { Corners = [.. f.Corners.Select(c => c + Box.Vertices.Length)] })));
    }

    EditorShell NewShell(MeshData mesh)
    {
        Directory.CreateDirectory(_directory);
        var scenePath = Path.Combine(_directory, "main.scene");
        File.WriteAllText(scenePath, Text);
        File.WriteAllText(Path.Combine(_directory, "room.mesh"), MeshFile.Write(mesh));
        var shell = new EditorShell(new EditorOptions("host.exe", "game.dll", scenePath) { AutosaveDirectory = Path.Combine(_directory, "autosave"), ProjectPath = Path.Combine(_directory, "project.settings") },
            new EditorSettings(Path.Combine(_directory, "settings")));
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _directory)], [new Importer(AssetKind.Mesh, ".mesh", [])], []));
        shell.Assets.Apply(new AssetSnapshot([new Asset(MeshGuid, AssetKind.Mesh, "game", "room.mesh", AssetStatus.Current, 0, 0, "", [], [], "", "", 0, [0, 0], "", [], "")], []));
        shell.OnGameMessage(new EntitySnapshot([new EntityInfo(Handle(0), "Room", 1, 0, true, [1, 33])]));
        shell.Viewport.RequestSize(new PixelSize((int)Width, (int)Height));
        shell.Camera.Place([0, 0, 0], 0, 0);
        shell.Selection.Select(Handle(0));
        shell.EnterMeshMode();
        Assert.True(shell.InMeshMode);
        return shell;
    }

    static MeshData Mesh(EditorShell shell) => shell.Meshes.Find(MeshGuid)!.Data;

    static Pose EntityPose(EditorShell shell) => SceneEdits.WorldPose(shell.Scene!.Scene, shell.Scene.Scene.Find(1)!)!;

    [Fact]
    public void KeepPlanarFlattensTheFacesAMoveBends()
    {
        // One vertex of a box pulled out along x bends the three faces around it.
        var bent = MeshTools.MoveVertices(Box, [Box.Faces[0].Corners[0]], v => v + new Vec3(0.3, 0.1, 0.2));
        Assert.Contains(bent.Validate(), p => p.Message.Contains("not planar"));
        var kept = MeshTools.KeepPlanar(bent, [Box.Faces[0].Corners[0]]);
        Assert.DoesNotContain(kept.Validate(), p => p.Message.Contains("not planar"));
        // The moved vertex stays where it was put, and the faces keep their count.
        Assert.Equal(bent.Vertices[Box.Faces[0].Corners[0]], kept.Vertices[Box.Faces[0].Corners[0]]);
        Assert.Equal(6, kept.Faces.Length);
        // A move that bends nothing changes nothing.
        var slid = MeshTools.MoveVertices(Box, Box.Faces[0].Corners, v => v + new Vec3(0.2, 0, 0));
        Assert.Same(slid, MeshTools.KeepPlanar(slid, Box.Faces[0].Corners));
        Assert.Same(Box, MeshTools.KeepPlanar(Box, []));
    }

    [Fact]
    public void LinkedGrowAndShrinkFollowTheNeighbors()
    {
        var mesh = TwoBoxes();
        MeshData? Find(string guid) => guid == MeshGuid ? mesh : null;
        // A face of the first box links to its box only.
        var faces = new MeshSelection(MeshElement.Faces, [new MeshItem(MeshGuid, 0)]);
        Assert.Equal(6, faces.Linked(Find).Count);
        Assert.All(faces.Linked(Find).Items, i => Assert.True(i.Index < 6));
        // Growing a face takes the faces that share a vertex with it: on a box, all but the opposite one.
        Assert.Equal(5, faces.Grown(Find).Count);
        // Growing a vertex takes the three across its edges; shrinking that gives the vertex back.
        var vertex = new MeshSelection(MeshElement.Vertices, [new MeshItem(MeshGuid, 0)]);
        var grown = vertex.Grown(Find);
        Assert.Equal(4, grown.Count);
        Assert.Equal(vertex.Items, grown.Shrunk(Find).Items);
        Assert.Equal(8, vertex.Linked(Find).Count);
        Assert.Equal(12, new MeshSelection(MeshElement.Edges, [new MeshItem(MeshGuid, 0)]).Linked(Find).Count);
        // An edge's neighbors are the four edges at its ends.
        Assert.Equal(5, new MeshSelection(MeshElement.Edges, [new MeshItem(MeshGuid, 0)]).Grown(Find).Count);
        // Shrinking a whole box's faces leaves them, since every neighbor is selected; a lone face goes.
        var box = new MeshSelection(MeshElement.Faces, [.. Enumerable.Range(0, 6).Select(f => new MeshItem(MeshGuid, f))]);
        Assert.Equal(6, box.Shrunk(Find).Count);
        Assert.Equal(0, faces.Shrunk(Find).Count);
    }

    [Fact]
    public void EditPivotMovesTheEntityAndKeepsTheGeometry()
    {
        using var shell = NewShell(Box);
        var before = EntityPose(shell);
        var worldBefore = Mesh(shell).Vertices.Select(v => v + Vec3.Between([0, 0, 0], before.Position)).ToList();
        Assert.True(shell.Commands.Get(EditorCommands.MeshCenterPivot).Execute());
        var after = EntityPose(shell);
        Assert.Equal(new Vec3(0.5, 0.5, 0.5), Vec3.Between(before.Position, after.Position));
        var worldAfter = Mesh(shell).Vertices.Select(v => v + Vec3.Between([0, 0, 0], after.Position)).ToList();
        Assert.Equal(worldBefore, worldAfter);
        Assert.Single(shell.Scene!.History);
        // Pivot to Grid snaps it back onto the grid, at 0.25 m it is on already, so a finer offset shows it.
        shell.Scene.Undo();
        Assert.Equal(before.Position, EntityPose(shell).Position);
        shell.Scene.Redo();
        Assert.True(shell.Commands.Get(EditorCommands.MeshPivotToGrid).CanExecute);
        Assert.False(shell.PivotToGrid());
        // The Edit Pivot gizmo stands on the entity and drags it, with the vertices moving the other way.
        shell.SetTool(Tool.Move);
        Assert.True(shell.Commands.Get(EditorCommands.MeshEditPivot).Execute());
        var (pivot, _) = shell.GizmoPose()!.Value;
        Assert.Equal(EntityPose(shell).Position, pivot);
        var center = shell.Camera.RelativeTo(pivot);
        var size = Gizmo.Size(shell.Camera, center, Height);
        Vec2 Along(double meters) => shell.Camera.Project(center + Vec3.UnitX * meters, Width, Height)!.Value;
        Assert.True(shell.PressGizmo(Along(0.5 * size)));
        shell.DragGizmo(Along(0.5 * size + 0.5), invertSnap: false);
        shell.ReleaseGizmo();
        Assert.Equal(2, shell.Scene.History.Count);
        var dragged = EntityPose(shell);
        Assert.Equal(0.5, Vec3.Between(after.Position, dragged.Position).X, 6);
        Assert.Equal(worldBefore, Mesh(shell).Vertices.Select(v => v + Vec3.Between([0, 0, 0], dragged.Position)).Select(v => new Vec3(Math.Round(v.X, 6), Math.Round(v.Y, 6), Math.Round(v.Z, 6))).ToList());
        Assert.True(shell.EditPivot);
        shell.ToggleEditPivot();
        Assert.False(shell.EditPivot);
    }

    [Fact]
    public void CleanSelectsTheEdgesItReports()
    {
        // A box with a fin on one edge: that edge has three faces.
        var fin = Box.With(
            vertices: Box.Vertices.AddRange(new[] { new Vec3(0, 2, 0), new Vec3(1, 2, 0) }.AsEnumerable()),
            faces: Box.Faces.Add(new MeshFace(0, [Box.Vertices.Length, Box.Vertices.Length + 1, Box.Edges[0].B, Box.Edges[0].A], Mapping.WorldAligned(Vec3.UnitZ))));
        using var shell = NewShell(fin);
        shell.Commands.Get(EditorCommands.MeshClean).Execute();
        Assert.Equal(MeshElement.Edges, shell.MeshElement);
        Assert.Single(shell.MeshSelection.Items);
        var edge = Mesh(shell).Edges[shell.MeshSelection.Items.Single().Index];
        Assert.Equal(3, Mesh(shell).FacesOfEdge(edge).Count);
    }

    [Fact]
    public void KeepPlanarAppliesToADrag()
    {
        using var shell = NewShell(Box);
        shell.SetTool(Tool.Move);
        shell.Commands.Get(EditorCommands.MeshKeepPlanar).Execute();
        Assert.True(shell.KeepPlanar);
        // The front face's corner nearest the camera's right, dragged along x, bends the faces around it unless kept planar.
        var front = Enumerable.Range(0, 6).First(f => Mesh(shell).FaceNormal(f) == -Vec3.UnitZ);
        var corner = Mesh(shell).Faces[front].Corners.OrderBy(c => Mesh(shell).Vertices[c].X).ThenBy(c => Mesh(shell).Vertices[c].Y).First();
        shell.SetMeshSelection(new MeshSelection(MeshElement.Vertices, [new MeshItem(MeshGuid, corner)]), switchKind: true);
        var (pivot, _) = shell.GizmoPose()!.Value;
        var center = shell.Camera.RelativeTo(pivot);
        var size = Gizmo.Size(shell.Camera, center, Height);
        Vec2 Along(double meters) => shell.Camera.Project(center + Vec3.UnitY * meters, Width, Height)!.Value;
        Assert.True(shell.PressGizmo(Along(0.5 * size)));
        shell.DragGizmo(Along(0.5 * size + 0.3), invertSnap: false);
        shell.ReleaseGizmo();
        Assert.DoesNotContain(Mesh(shell).Validate(), p => p.Message.Contains("not planar"));
        Assert.NotEqual(Box.Vertices, Mesh(shell).Vertices);
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory))
        {
            Directory.Delete(_directory, recursive: true);
        }
    }
}
