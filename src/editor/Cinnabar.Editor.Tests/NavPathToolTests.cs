using Avalonia;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Tests;

/// <summary>The Navigation Path tool in the shell: the points that clicks pick, and the probe that the game hears.</summary>
public sealed class NavPathToolTests : IDisposable
{
    readonly TempDirectory _temp = new("nav-path");
    readonly List<ILinkMessage> _sent = [];

    // A box with a mesh, 5 m ahead of a camera at the origin, to enter mesh mode on.
    static readonly string Text = "scene 1\n\n" +
        "entity 0000000000000001\nname = \"Room\"\ncomponent 1 Transform\n\tposition = [0, 0, 83886080]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n" +
        $"component 33 Mesh_Renderer\n\tmesh = ${MeshFixtures.MeshGuid}\n";

    const ulong Room = 1UL << 32;

    static readonly Vec2 Middle = new(800, 450);

    EditorShell NewShell()
    {
        MeshFixtures.WriteRoom(_temp);
        var shell = TestShell.Open(_temp, "main.scene", Text);
        shell.Assets.Apply(new Cinnabar.Editor.Link.Cook.Welcome(1, "dev", [new Root("game", _temp.Path)], [new Importer(AssetKind.Mesh, ".mesh", [])], [], []));
        shell.Assets.Apply(new AssetSnapshot([TestAssets.Make(MeshFixtures.MeshGuid, AssetKind.Mesh, "room.mesh")], []));
        shell.Host.LinkForTests(_sent.Add);
        shell.OnGameMessage(new EntitySnapshot([new EntityInfo(Room, "Room", 1, 0, true, [1, 33])]));
        shell.Viewports[0].Session.Show(new PixelSize(1600, 900));
        shell.Camera.Place([0, 0, 0], 0, 0);
        return shell;
    }

    // Clicks a pixel with the tool and answers the pick as a hit at a depth.
    bool Click(EditorShell shell, Vec2 pixel, float depth = 5)
    {
        _sent.Clear();
        var clicked = shell.AddNavPoint(pixel);
        if (_sent.OfType<PickRequest>().SingleOrDefault() is { } request)
        {
            shell.OnGameMessage(new PickResult(request.Id, [], depth, -1));
        }
        return clicked;
    }

    NavProbe Probe() => Assert.Single(_sent.OfType<NavProbe>());

    [Fact]
    public void ClicksPickAStartThenAGoalThenStartAgain()
    {
        using var shell = NewShell();
        shell.SetTool(Tool.NavPath);

        Assert.True(Click(shell, Middle));
        var start = Probe().Points.Single().Position;
        // The pixel's ray ahead of the camera, 5 m along z: 5 * 2^24.
        Assert.InRange(start[2], 83_000_000, 84_000_000);

        Click(shell, new Vec2(900, 450));
        var both = Probe().Points;
        Assert.Equal(2, both.Length);
        Assert.Equal(start, both[0].Position);
        Assert.True(both[1].Position[0] > start[0]);

        Click(shell, new Vec2(700, 450));
        var again = Probe().Points;
        Assert.Single(again);
        Assert.True(again[0].Position[0] < start[0]);
    }

    [Fact]
    public void ThePointsAreNotSnappedToTheGrid()
    {
        using var shell = NewShell();
        shell.ToggleSnap();
        shell.SetTool(Tool.NavPath);

        Click(shell, new Vec2(901, 450));

        // A snapped point would be a multiple of the grid's step.
        var step = shell.Mesh.GridSize * Pose.Unit;
        Assert.NotEqual(0, Probe().Points.Single().Position[0] % (long)step);
    }

    [Fact]
    public void AClickWithAnotherToolDoesNotPick()
    {
        using var shell = NewShell();
        _sent.Clear();

        Assert.False(shell.AddNavPoint(Middle));

        Assert.Empty(_sent.OfType<PickRequest>());
        Assert.Empty(shell.NavPoints);
    }

    [Fact]
    public void LeavingTheToolClearsTheProbe()
    {
        using var shell = NewShell();
        shell.SetTool(Tool.NavPath);
        Click(shell, Middle);
        _sent.Clear();

        shell.SetTool(Tool.Move);

        Assert.Empty(Probe().Points);
        Assert.Empty(shell.NavPoints);

        _sent.Clear();
        shell.SetTool(Tool.Rotate);
        Assert.Empty(_sent.OfType<NavProbe>());
    }

    [Fact]
    public void AToolThatChangedBeforeThePickAnsweredAddsNothing()
    {
        using var shell = NewShell();
        shell.SetTool(Tool.NavPath);
        _sent.Clear();
        shell.AddNavPoint(Middle);
        var request = Assert.Single(_sent.OfType<PickRequest>());

        shell.SetTool(Tool.Move);
        shell.OnGameMessage(new PickResult(request.Id, [], 5, -1));

        Assert.Empty(shell.NavPoints);
    }

    [Fact]
    public void ANewGameStateSendsTheProbeAgain()
    {
        using var shell = NewShell();
        shell.SetTool(Tool.NavPath);
        Click(shell, Middle);
        var sent = Probe();
        _sent.Clear();

        shell.Host.Receive(new GameReloaded(ReloadKind.SoftRestart));

        var again = Probe();
        Assert.Equal(sent.Points.Single().Position, again.Points.Single().Position);
    }

    [Fact]
    public void ANewGameStateWithNoPointsSendsNoProbe()
    {
        using var shell = NewShell();
        _sent.Clear();

        shell.Host.Receive(new GameReloaded(ReloadKind.SoftRestart));

        Assert.Empty(_sent.OfType<NavProbe>());
    }

    [Fact]
    public void TheToolCannotRunInMeshMode()
    {
        using var shell = NewShell();
        shell.Selection.Select(Room);
        shell.Mesh.EnterMeshMode();
        Assert.True(shell.Mesh.InMeshMode);

        Assert.False(shell.Commands.Get(EditorCommands.NavPathTool).CanExecute);
        shell.SetTool(Tool.NavPath);

        Assert.Equal(Tool.Move, shell.Tool);
    }

    [Fact]
    public void EnteringMeshModeClearsThePoints()
    {
        using var shell = NewShell();
        shell.SetTool(Tool.NavPath);
        Click(shell, Middle);
        shell.Selection.Select(Room);
        _sent.Clear();

        shell.Mesh.EnterMeshMode();

        Assert.True(shell.Mesh.InMeshMode);
        Assert.Empty(Probe().Points);
        Assert.False(shell.AddNavPoint(Middle));
    }

    [Fact]
    public void OpeningAnotherSceneClearsThePoints()
    {
        using var shell = NewShell();
        shell.SetTool(Tool.NavPath);
        Click(shell, Middle);
        File.WriteAllText(_temp.Combine("other.scene"), "scene 1\n");
        _sent.Clear();

        shell.OpenScene(_temp.Combine("other.scene"));

        Assert.Empty(shell.NavPoints);
        Assert.Empty(Assert.Single(_sent.OfType<NavProbe>()).Points);
    }

    [Fact]
    public void TheToolIsACommandWithAKey()
    {
        using var shell = NewShell();
        var command = shell.Commands.Get(EditorCommands.NavPathTool);

        Assert.Equal("tool.nav-path", command.Id);
        Assert.Equal("Navigation Path", command.Label);
        Assert.Equal("nav-path", command.Icon);

        command.Execute();

        Assert.Equal(Tool.NavPath, shell.Tool);
        Assert.True(command.IsChecked);
        Assert.Equal(GizmoKind.None, Gizmo.KindOf(Tool.NavPath));
    }

    public void Dispose() => _temp.Dispose();
}
