using Avalonia;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Shell;
using EditorCamera = Cinnabar.Editor.Link.Protocol.EditorCamera;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// Several viewports in the shell (see docs/editor/viewport.md#several-viewports), without a host: the arrangement opens
/// and closes them, each has its own camera, settings and gizmo size, and the tools act in the active one.
/// </summary>
public sealed class SceneViewportTests : IDisposable
{
    readonly TempDirectory _temp = new("viewports");
    readonly List<ILinkMessage> _sent = [];

    // One root 5 m ahead of a camera at the origin.
    const string Text = "scene 1\n\n" +
        "entity 0000000000000001\nname = \"Box\"\ncomponent 1 Transform\n\tposition = [0, 0, 83886080]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n";

    const ulong Box = 1UL << 32;

    EditorShell NewShell()
    {
        var shell = TestShell.Open(_temp, "box.scene", Text);
        shell.Host.LinkForTests(_sent.Add);
        shell.OnGameMessage(new EntitySnapshot([new EntityInfo(Box, "Box", 1, 0, true, [1])]));
        shell.Viewport.RequestSize(new PixelSize(1600, 900));
        shell.Camera.Place([0, 0, 0], 0, 0);
        return shell;
    }

    [Fact]
    public void AnArrangementOpensItsViewportsAndClosesTheOthers()
    {
        using var shell = NewShell();
        Assert.Equal([0], shell.OpenViewports.Select(v => v.Index));
        _sent.Clear();

        shell.SetArrangement(ViewportArrangement.SideBySide);

        // The game gets the new viewport's camera, where the first one's is, and how it draws. It hears that the
        // viewport is open once the viewport's control has a size.
        Assert.Equal([0, 1], shell.OpenViewports.Select(v => v.Index));
        var camera = Assert.Single(_sent.OfType<EditorCamera>());
        Assert.Equal(1u, camera.Viewport);
        Assert.Equal(shell.MainViewport.Camera.ToMessage(1), camera, CameraComparer.Instance);
        Assert.Equal(1u, Assert.Single(_sent.OfType<SetViewportSettings>()).Viewport);
        Assert.Empty(_sent.OfType<OpenViewport>());
        shell.Viewports[1].Session.RequestSize(new PixelSize(800, 900));
        Assert.Equal(new OpenViewport(1, 800, 900), Assert.Single(_sent.OfType<OpenViewport>()));

        shell.SetArrangement(ViewportArrangement.Quad);
        Assert.Equal([0, 1, 2, 3], shell.OpenViewports.Select(v => v.Index));

        _sent.Clear();
        shell.SetArrangement(ViewportArrangement.Single);
        Assert.Equal([0], shell.OpenViewports.Select(v => v.Index));
        Assert.Equal([1u, 2u, 3u], _sent.OfType<CloseViewport>().Select(c => c.Viewport));
    }

    [Fact]
    public void AViewportThatOpensAgainKeepsItsCameraAndTellsTheGame()
    {
        using var shell = NewShell();
        shell.SetArrangement(ViewportArrangement.SideBySide);
        var second = shell.Viewports[1];
        second.Session.RequestSize(new PixelSize(800, 900));
        second.Camera.Place([0, 100L << 24, 0], 0, 1.5);
        shell.SetArrangement(ViewportArrangement.Single);
        _sent.Clear();

        shell.SetArrangement(ViewportArrangement.Stacked);

        // The control asked for no new size, so the shell says that the viewport is open, with the size that it had.
        Assert.Equal(100L << 24, second.Camera.Position[1]);
        Assert.Equal(100L << 24, Assert.Single(_sent.OfType<EditorCamera>()).Position[1]);
        Assert.Equal(new OpenViewport(1, 800, 900), Assert.Single(_sent.OfType<OpenViewport>()));
    }

    [Fact]
    public void EachViewportHasItsOwnSettingsAndTheRibbonsAreTheActiveOnes()
    {
        using var shell = NewShell();
        shell.SetArrangement(ViewportArrangement.SideBySide);
        var second = shell.Viewports[1];
        _sent.Clear();

        shell.ApplyViewportSettings(second, second.Settings with { DebugView = DebugView.Albedo });

        Assert.Equal(DebugView.Lit, shell.MainViewport.Settings.DebugView);
        Assert.Equal(DebugView.Lit, shell.ViewportSettings.DebugView);
        var sent = Assert.Single(_sent.OfType<SetViewportSettings>());
        Assert.Equal((1u, DebugView.Albedo), (sent.Viewport, sent.Settings.DebugView));

        var changes = 0;
        shell.ViewportSettingsChanged += () => changes++;
        shell.ActivateViewport(second);
        Assert.Equal(DebugView.Albedo, shell.ViewportSettings.DebugView);
        Assert.Equal(1, changes);
        shell.ViewportSettings = shell.ViewportSettings with { NoBloom = true };
        Assert.True(second.Settings.NoBloom);
        Assert.False(shell.MainViewport.Settings.NoBloom);
    }

    [Fact]
    public void TheSettingsAndTheArrangementStayAcrossSessions()
    {
        using (var shell = NewShell())
        {
            shell.SetArrangement(ViewportArrangement.Quad);
            shell.ApplyViewportSettings(shell.Viewports[2], shell.Viewports[2].Settings with { DebugView = DebugView.Normals });
        }

        using var again = TestShell.Open(_temp, "box.scene", null);
        Assert.Equal(ViewportArrangement.Quad, again.Arrangement);
        Assert.Equal([0, 1, 2, 3], again.OpenViewports.Select(v => v.Index));
        Assert.Equal(DebugView.Normals, again.Viewports[2].Settings.DebugView);
        Assert.Equal(DebugView.Lit, again.MainViewport.Settings.DebugView);
    }

    [Fact]
    public void AFileOfOneViewportsSettingsIsEveryViewportsStart()
    {
        // An editor with one viewport wrote that viewport's settings alone.
        var settings = EditorShell.DefaultViewportSettings with { NoFog = true };
        Directory.CreateDirectory(_temp.Combine("settings"));
        File.WriteAllText(Path.Combine(_temp.Combine("settings"), EditorSettings.ViewportFileName), System.Text.Json.JsonSerializer.Serialize(settings));

        using var shell = TestShell.Open(_temp, "box.scene", Text);

        Assert.Equal(ViewportArrangement.Single, shell.Arrangement);
        Assert.All(shell.Viewports, v => Assert.True(v.Settings.NoFog));
    }

    [Fact]
    public void TheGizmoIsAsLargeOnScreenInEachViewport()
    {
        using var shell = NewShell();
        shell.SetArrangement(ViewportArrangement.SideBySide);
        var second = shell.Viewports[1];
        second.Session.RequestSize(new PixelSize(800, 900));
        // Twice as far from the box as the first viewport's camera.
        second.Camera.Place([0, 0, -5L << 24], 0, 0);
        _sent.Clear();

        shell.Selection.Select(Box);

        var gizmos = _sent.OfType<GizmoState>().Where(g => g.Kind != GizmoKind.None).ToDictionary(g => g.Viewport);
        Assert.Equal([0u, 1u], gizmos.Keys.Order());
        Assert.Equal(gizmos[0].Size * 2, gizmos[1].Size, 3);
    }

    [Fact]
    public void ThePicksAndTheToolsAreTheActiveViewports()
    {
        using var shell = NewShell();
        shell.SetArrangement(ViewportArrangement.SideBySide);
        var second = shell.Viewports[1];
        second.Session.RequestSize(new PixelSize(800, 600));
        Assert.Same(shell.MainViewport, shell.ActiveViewport);
        Assert.Same(shell.MainViewport.Camera, shell.Camera);
        _sent.Clear();

        shell.PickAt(new Vec2(10, 20), SelectMode.Replace);
        shell.ActivateViewport(second);
        shell.PickAt(new Vec2(30, 40), SelectMode.Replace);

        Assert.Equal([(0u, 10, 20), (1u, 30, 40)], _sent.OfType<PickRequest>().Select(p => (p.Viewport, p.X, p.Y)));
        Assert.Same(second.Camera, shell.Camera);
        Assert.Equal((800.0, 600.0), shell.FrameSize);

        // Closing the active viewport makes the first one active again.
        shell.SetArrangement(ViewportArrangement.Single);
        Assert.Same(shell.MainViewport, shell.ActiveViewport);
        // A closed viewport does not become active.
        shell.ActivateViewport(second);
        Assert.Same(shell.MainViewport, shell.ActiveViewport);
    }

    [Fact]
    public void ANewGameStateHearsOfEveryOpenViewport()
    {
        using var shell = NewShell();
        shell.SetArrangement(ViewportArrangement.SideBySide);
        shell.Viewports[1].Session.RequestSize(new PixelSize(800, 900));
        _sent.Clear();

        shell.Host.Receive(new GameReloaded(ReloadKind.SoftRestart));

        Assert.Equal([0u, 1u], _sent.OfType<EditorCamera>().Select(c => c.Viewport));
        Assert.Equal([0u, 1u], _sent.OfType<SetViewportSettings>().Select(s => s.Viewport));
        Assert.Equal(new OpenViewport(1, 800, 900), Assert.Single(_sent.OfType<OpenViewport>()));
    }

    [Fact]
    public void ATargetConnectsItsViewportAndItsFramesAreAcknowledgedByNumber()
    {
        using var shell = NewShell();
        shell.SetArrangement(ViewportArrangement.SideBySide);

        shell.OnGameMessage(new ViewportTarget(1, "cinnabar.viewport0.g3", 3, 800, 900));

        Assert.Equal(3u, shell.Viewports[1].Session.Generation);
        Assert.Equal(0u, shell.MainViewport.Session.Generation);
        // A target for a viewport that is closed is ignored.
        shell.OnGameMessage(new ViewportTarget(2, "cinnabar.viewport1.g1", 1, 800, 900));
        Assert.Equal(0u, shell.Viewports[2].Session.Generation);
    }

    sealed class CameraComparer : IEqualityComparer<EditorCamera>
    {
        public static readonly CameraComparer Instance = new();

        public bool Equals(EditorCamera? a, EditorCamera? b) =>
            a != null && b != null && a.Viewport == b.Viewport && a.Position.SequenceEqual(b.Position) && a.Rotation.SequenceEqual(b.Rotation)
            && a.VerticalFov == b.VerticalFov && a.Near == b.Near;

        public int GetHashCode(EditorCamera camera) => camera.Viewport.GetHashCode();
    }

    public void Dispose() => _temp.Dispose();
}
