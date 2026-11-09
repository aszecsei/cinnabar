using System.Text.Json;
using Avalonia;
using Cinnabar.Editor.Docking;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Shell;
using Dock.Model.Core;
using EditorCamera = Cinnabar.Editor.Link.Protocol.EditorCamera;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// The editor's views of the game in the shell, without a host (see docs/editor/viewport.md#views): a viewport is open in
/// the game while its control is shown, the active scene view and the settings viewport, the capture source, the
/// documents in the layout, and the automation that shows and hides them. A test shows a viewport by giving its session
/// a size, as its control does.
/// </summary>
public sealed class ViewportTests : IDisposable
{
    readonly TempDirectory _temp = new("views");
    readonly List<ILinkMessage> _sent = [];

    // One root 5 m ahead of a camera at the origin.
    const string Text = "scene 1\n\n" +
        "entity 0000000000000001\nname = \"Box\"\ncomponent 1 Transform\n\tposition = [0, 0, 83886080]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n";

    const ulong Box = 1UL << 32;

    // A linked shell whose scene view 0 is shown at 1600 by 900.
    EditorShell NewShell(bool show = true)
    {
        var shell = TestShell.Open(_temp, "box.scene", Text);
        shell.Host.LinkForTests(_sent.Add);
        shell.OnGameMessage(new EntitySnapshot([new EntityInfo(Box, "Box", 1, 0, true, [1])]));
        if (show)
        {
            Show(shell, 0, 1600, 900);
            shell.Camera.Place([0, 0, 0], 0, 0);
        }
        return shell;
    }

    static void Show(EditorShell shell, int viewport, int width, int height) => shell.Viewports[viewport].Session.Show(new PixelSize(width, height));

    static void Hide(EditorShell shell, int viewport) => shell.Viewports[viewport].Session.Hide();

    [Fact]
    public void AShownViewportIsOpenedInTheGameOnceAndAHiddenOneIsClosedOnce()
    {
        using var shell = NewShell(show: false);
        Assert.Empty(_sent.OfType<OpenViewport>());

        Show(shell, 0, 1600, 900);

        // The game hears that the viewport is open, then its camera and how it draws.
        Assert.Equal(new OpenViewport(0, ViewportKind.Scene, 1600, 900), Assert.Single(_sent.OfType<OpenViewport>()));
        Assert.Equal(0u, Assert.Single(_sent.OfType<EditorCamera>()).Viewport);
        Assert.Equal(0u, Assert.Single(_sent.OfType<SetViewportSettings>()).Viewport);
        var open = _sent.FindIndex(m => m is OpenViewport);
        Assert.True(open < _sent.FindIndex(m => m is EditorCamera) && open < _sent.FindIndex(m => m is SetViewportSettings));

        // The same size again says nothing.
        _sent.Clear();
        Show(shell, 0, 1600, 900);
        Assert.DoesNotContain(_sent, m => m is OpenViewport or CloseViewport);

        Hide(shell, 0);
        Assert.Equal(0u, Assert.Single(_sent.OfType<CloseViewport>()).Viewport);
        _sent.Clear();
        Hide(shell, 0);
        Assert.Empty(_sent.OfType<CloseViewport>());
    }

    [Fact]
    public void AControlThatDidNotShowTheSessionLastCannotHideIt()
    {
        // Docking can attach the control that replaces another before it detaches the old one.
        var session = new Viewport.ViewportSession();
        object oldControl = new(), newControl = new();
        session.Show(new PixelSize(100, 50), oldControl);
        session.Show(new PixelSize(100, 50), newControl);

        session.Hide(oldControl);
        Assert.IsType<Viewport.ViewportPresence.Shown>(session.Presence);
        session.Hide(newControl);
        Assert.Same(Viewport.ViewportPresence.Hidden, session.Presence);
    }

    [Fact]
    public void AResizeOpensTheViewportAgainAtTheNewSizeAndNothingMore()
    {
        using var shell = NewShell();
        _sent.Clear();

        Show(shell, 0, 800, 450);

        Assert.Equal(new OpenViewport(0, ViewportKind.Scene, 800, 450), Assert.Single(_sent.OfType<OpenViewport>()));
        Assert.Empty(_sent.OfType<EditorCamera>());
        Assert.Empty(_sent.OfType<CloseViewport>());
    }

    [Fact]
    public void AViewportThatIsShownBeforeTheLinkIsOpenedWhenTheLinkComes()
    {
        using var shell = TestShell.Open(_temp, "box.scene", Text);
        Show(shell, 0, 1600, 900);
        Show(shell, 3, 640, 360);

        shell.Host.LinkForTests(_sent.Add);

        Assert.Equal([0u, 3u], _sent.OfType<OpenViewport>().Select(o => o.Viewport));
        Assert.Equal([0u], _sent.OfType<EditorCamera>().Select(c => c.Viewport));
    }

    [Fact]
    public void ANewGameStateHearsOfEveryShownViewportAndOnlyThose()
    {
        using var shell = NewShell();
        Show(shell, 1, 800, 900);
        Show(shell, 3, 640, 360);
        Show(shell, 2, 100, 100);
        Hide(shell, 2);
        _sent.Clear();

        shell.Host.Receive(new GameReloaded(ReloadKind.SoftRestart));

        Assert.Equal([0u, 1u, 3u], _sent.OfType<OpenViewport>().Select(o => o.Viewport));
        Assert.Equal(ViewportKind.Game, _sent.OfType<OpenViewport>().Last().Kind);
        // Only a scene view has an editor camera.
        Assert.Equal([0u, 1u], _sent.OfType<EditorCamera>().Select(c => c.Viewport));
        Assert.Equal([0u, 1u, 3u], _sent.OfType<SetViewportSettings>().Select(s => s.Viewport));
        Assert.Equal(new GameSize(640, 360), Assert.Single(_sent.OfType<GameSize>()));
        Assert.Empty(_sent.OfType<CloseViewport>());
    }

    [Fact]
    public void AViewportThatHidesBeforeAGameRestartIsNotOpenedAgain()
    {
        using var shell = NewShell();
        Show(shell, 1, 800, 900);
        Hide(shell, 1);
        _sent.Clear();

        shell.Host.Receive(new GameReloaded(ReloadKind.SoftRestart));

        Assert.Equal([0u], _sent.OfType<OpenViewport>().Select(o => o.Viewport));
    }

    [Fact]
    public void TheGameSizeIsTheGameViewsAndStaysWhenItHides()
    {
        using var shell = NewShell();
        Assert.Empty(_sent.OfType<GameSize>());

        Show(shell, 3, 800, 600);
        Assert.Equal(new GameSize(800, 600), Assert.Single(_sent.OfType<GameSize>()));
        _sent.Clear();
        Show(shell, 3, 1024, 768);
        Assert.Equal(new GameSize(1024, 768), Assert.Single(_sent.OfType<GameSize>()));
        _sent.Clear();
        Show(shell, 0, 1000, 700);
        Hide(shell, 3);
        Assert.Empty(_sent.OfType<GameSize>());

        // A game that links later is told the size that the Game view last had.
        _sent.Clear();
        shell.Host.Receive(new GameReloaded(ReloadKind.SoftRestart));
        Assert.Equal(new GameSize(1024, 768), Assert.Single(_sent.OfType<GameSize>()));
    }

    [Fact]
    public void ANewGameStateSendsNoGameSizeBeforeTheGameViewHadOne()
    {
        using var shell = NewShell();
        _sent.Clear();

        shell.Host.Receive(new GameReloaded(ReloadKind.SoftRestart));

        Assert.Empty(_sent.OfType<GameSize>());
    }

    [Fact]
    public void TheGameViewIsNeverTheActiveSceneViewButItsSettingsAreTheRibbons()
    {
        using var shell = NewShell();
        Show(shell, 3, 800, 600);
        var game = shell.GameViewport;
        Assert.True(game.IsGame);
        Assert.False(game.HasCamera);
        var changes = 0;
        shell.ViewportSettingsChanged += () => changes++;

        shell.ActivateViewport(game);

        Assert.Same(shell.Viewports[0], shell.ActiveViewport);
        Assert.Same(shell.Viewports[0].Camera, shell.Camera);
        Assert.Same(game, shell.SettingsViewport);
        Assert.Equal(1, changes);
        _sent.Clear();
        shell.ViewportSettings = shell.ViewportSettings with { DebugView = DebugView.Albedo };
        Assert.Equal(DebugView.Albedo, game.Settings.DebugView);
        Assert.Equal(DebugView.Lit, shell.Viewports[0].Settings.DebugView);
        var sent = Assert.Single(_sent.OfType<SetViewportSettings>());
        Assert.Equal((3u, DebugView.Albedo), (sent.Viewport, sent.Settings.DebugView));

        // A scene view takes both back, and the Game view's hiding does too.
        shell.ActivateViewport(shell.Viewports[0]);
        Assert.Same(shell.Viewports[0], shell.SettingsViewport);
        shell.ActivateViewport(game);
        Hide(shell, 3);
        Assert.Same(shell.Viewports[0], shell.SettingsViewport);
    }

    [Fact]
    public void ThePicksAndTheToolsAreTheActiveSceneViews()
    {
        using var shell = NewShell();
        Show(shell, 1, 800, 600);
        var second = shell.Viewports[1];
        Assert.Same(shell.Viewports[0], shell.ActiveViewport);
        _sent.Clear();

        shell.PickAt(new Vec2(10, 20), SelectMode.Replace);
        shell.ActivateViewport(second);
        shell.PickAt(new Vec2(30, 40), SelectMode.Replace);

        Assert.Equal([(0u, 10, 20), (1u, 30, 40)], _sent.OfType<PickRequest>().Select(p => (p.Viewport, p.X, p.Y)));
        Assert.Same(second.Camera, shell.Camera);
        Assert.Equal((800.0, 600.0), shell.FrameSize);

        // Hiding the active scene view makes the other one active.
        Hide(shell, 1);
        Assert.Same(shell.Viewports[0], shell.ActiveViewport);
        // A viewport that is not shown does not become active.
        shell.ActivateViewport(second);
        Assert.Same(shell.Viewports[0], shell.ActiveViewport);
    }

    [Fact]
    public void ASceneViewKeepsItsToolsInPlay()
    {
        using var shell = NewShell();
        shell.Play();
        _sent.Clear();

        shell.PickAt(new Vec2(10, 20), SelectMode.Replace);

        Assert.Equal(0u, Assert.Single(_sent.OfType<PickRequest>()).Viewport);
        Assert.True(shell.InputGoesToGame);
    }

    [Fact]
    public void ASceneViewThatIsShownForTheFirstTimeStartsFromTheActiveOnesCameraAndKeepsItAfter()
    {
        using var shell = NewShell();
        shell.Camera.Place([0, 3L << 24, 0], 0.5, 0.25);

        Show(shell, 2, 800, 600);
        var third = shell.Viewports[2];

        Assert.Equal(3L << 24, third.Camera.Position[1]);
        Assert.Equal((0.5, 0.25), (third.Camera.Yaw, third.Camera.Pitch));
        third.Camera.Place([0, 7L << 24, 0], 0, 0);
        Hide(shell, 2);
        shell.Camera.Place([0, 0, 0], 0, 0);
        _sent.Clear();

        Show(shell, 2, 800, 600);

        Assert.Equal(7L << 24, third.Camera.Position[1]);
        var camera = Assert.Single(_sent.OfType<EditorCamera>());
        Assert.Equal((2u, 7L << 24), (camera.Viewport, camera.Position[1]));
    }

    [Fact]
    public void TheCameraOfAViewportThatIsNotOpenGoesToTheGameWhenItOpens()
    {
        using var shell = NewShell();
        _sent.Clear();

        shell.Viewports[1].Camera.Place([0, 1L << 24, 0], 0, 0);
        Assert.Empty(_sent.OfType<EditorCamera>());
        Show(shell, 1, 800, 600);
        Assert.Equal(1L << 24, Assert.Single(_sent.OfType<EditorCamera>()).Position[1]);

        _sent.Clear();
        shell.Viewports[1].Camera.Place([0, 2L << 24, 0], 0, 0);
        Assert.Equal(2L << 24, Assert.Single(_sent.OfType<EditorCamera>()).Position[1]);
    }

    [Fact]
    public void EachViewportHasItsOwnSettingsAndTheRibbonsAreTheSettingsViewports()
    {
        using var shell = NewShell();
        Show(shell, 1, 800, 900);
        var second = shell.Viewports[1];
        _sent.Clear();

        shell.ApplyViewportSettings(second, second.Settings with { DebugView = DebugView.Albedo });

        Assert.Equal(DebugView.Lit, shell.Viewports[0].Settings.DebugView);
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
        Assert.False(shell.Viewports[0].Settings.NoBloom);
    }

    [Fact]
    public void ASettingOfAViewportThatIsNotOpenGoesToTheGameWhenItOpens()
    {
        using var shell = NewShell();
        var third = shell.Viewports[2];
        _sent.Clear();

        shell.ApplyViewportSettings(third, third.Settings with { NoFog = true });
        Assert.Empty(_sent.OfType<SetViewportSettings>());
        Show(shell, 2, 800, 600);

        Assert.True(Assert.Single(_sent.OfType<SetViewportSettings>()).Settings.NoFog);
    }

    [Fact]
    public void TheSettingsStayAcrossSessionsAndTheGameViewStartsWithoutIconsAndShapes()
    {
        using (var shell = NewShell())
        {
            shell.ApplyViewportSettings(shell.Viewports[2], shell.Viewports[2].Settings with { DebugView = DebugView.Normals });
            shell.ApplyViewportSettings(shell.GameViewport, shell.GameViewport.Settings with { NoBloom = true });
            Assert.True(shell.Viewports[0].Settings.ShowIcons);
            Assert.False(shell.GameViewport.Settings.ShowIcons);
            Assert.Equal(HelperMode.None, shell.GameViewport.Settings.Helpers);
        }

        using var again = TestShell.Open(_temp, "box.scene", null);
        Assert.Equal(DebugView.Normals, again.Viewports[2].Settings.DebugView);
        Assert.Equal(DebugView.Lit, again.Viewports[0].Settings.DebugView);
        Assert.True(again.GameViewport.Settings.NoBloom);
        Assert.False(again.GameViewport.Settings.ShowIcons);
    }

    [Fact]
    public void AFileOfOneViewportsSettingsIsEveryViewportsStart()
    {
        // An editor with one viewport wrote that viewport's settings alone.
        var settings = EditorShell.DefaultViewportSettings with { NoFog = true };
        Directory.CreateDirectory(_temp.Combine("settings"));
        File.WriteAllText(Path.Combine(_temp.Combine("settings"), EditorSettings.ViewportFileName), JsonSerializer.Serialize(settings));

        using var shell = TestShell.Open(_temp, "box.scene", Text);

        Assert.All(shell.Viewports, v => Assert.True(v.Settings.NoFog));
        Assert.True(shell.Viewports[0].Settings.ShowIcons);
        Assert.False(shell.GameViewport.Settings.ShowIcons);
    }

    [Fact]
    public void AFileThatIsNotSettingsIsWarnedAboutAndTheDefaultsAreUsed()
    {
        Directory.CreateDirectory(_temp.Combine("settings"));
        File.WriteAllText(Path.Combine(_temp.Combine("settings"), EditorSettings.ViewportFileName), "[1, 2");

        using var shell = TestShell.Open(_temp, "box.scene", Text);

        Assert.Contains(shell.Console.Lines, l => l.Level == Model.LogLevel.Warning && l.Text.Contains("viewport"));
        Assert.Equal(DebugView.Lit, shell.Viewports[0].Settings.DebugView);
    }

    [Fact]
    public void TheGizmoIsAsLargeOnScreenInEachSceneViewAndTheGameViewHasNone()
    {
        using var shell = NewShell();
        Show(shell, 1, 800, 900);
        Show(shell, 3, 800, 900);
        // Twice as far from the box as the first viewport's camera.
        shell.Viewports[1].Camera.Place([0, 0, -5L << 24], 0, 0);
        _sent.Clear();

        shell.Selection.Select(Box);

        var gizmos = _sent.OfType<GizmoState>().Where(g => g.Kind != GizmoKind.None).ToDictionary(g => g.Viewport);
        Assert.Equal([0u, 1u], gizmos.Keys.Order());
        Assert.Equal(gizmos[0].Size * 2, gizmos[1].Size, 3);
        Assert.DoesNotContain(_sent.OfType<GizmoState>(), g => g.Viewport == 3);
    }

    [Fact]
    public void ATargetConnectsItsViewportAndATargetOfOneThatIsNotOpenIsIgnored()
    {
        using var shell = NewShell();
        Show(shell, 1, 800, 900);

        shell.OnGameMessage(new ViewportTarget(1, "cinnabar.viewport1.g3", 3, 800, 900));
        Assert.Equal(3u, shell.Viewports[1].Session.Generation);
        Assert.Equal(0u, shell.Viewports[0].Session.Generation);

        shell.OnGameMessage(new ViewportTarget(2, "cinnabar.viewport2.g1", 1, 800, 900));
        Assert.Equal(0u, shell.Viewports[2].Session.Generation);

        // The viewport that hides lets go of its target.
        Hide(shell, 1);
        Assert.False(shell.Viewports[1].Session.HasPicture);
    }

    // --- The capture source ---

    [Fact]
    public void TheCaptureViewportIsTheFirstShownSceneViewThenTheGameView()
    {
        using var shell = NewShell(show: false);
        Assert.Null(shell.CaptureViewport);

        Show(shell, 3, 640, 360);
        Assert.Same(shell.GameViewport, shell.CaptureViewport);
        Show(shell, 2, 640, 360);
        Assert.Same(shell.Viewports[2], shell.CaptureViewport);
        Show(shell, 1, 640, 360);
        Assert.Same(shell.Viewports[1], shell.CaptureViewport);
        Show(shell, 0, 640, 360);
        Assert.Same(shell.Viewports[0], shell.CaptureViewport);
        Hide(shell, 0);
        Assert.Same(shell.Viewports[1], shell.CaptureViewport);
    }

    [Fact]
    public void TheHostIsToldWhichViewportToCaptureWhenTheChoiceChanges()
    {
        using var shell = NewShell(show: false);
        _sent.Clear();

        Show(shell, 3, 640, 360);
        Assert.Equal([3], _sent.OfType<CaptureSource>().Select(c => c.Viewport));
        // Another viewport does not change the choice, and a scene view does.
        _sent.Clear();
        Show(shell, 2, 640, 360);
        Assert.Equal([2], _sent.OfType<CaptureSource>().Select(c => c.Viewport));
        _sent.Clear();
        Show(shell, 3, 800, 600);
        Assert.Empty(_sent.OfType<CaptureSource>());
        Hide(shell, 2);
        Assert.Equal([3], _sent.OfType<CaptureSource>().Select(c => c.Viewport));
        _sent.Clear();
        Hide(shell, 3);
        Assert.Equal([-1], _sent.OfType<CaptureSource>().Select(c => c.Viewport));
    }

    [Fact]
    public void ANewGameStateIsToldTheCaptureSourceAgain()
    {
        using var shell = NewShell();
        _sent.Clear();

        shell.Host.Receive(new GameReloaded(ReloadKind.SoftRestart));

        Assert.Equal([0], _sent.OfType<CaptureSource>().Select(c => c.Viewport));
    }

    [Fact]
    public async Task ACaptureWithNoViewportShownFailsWithItsReason()
    {
        using var shell = NewShell(show: false);

        var outcome = await shell.Screenshot();

        Assert.False(outcome.Ok);
        Assert.Contains("no viewport is shown", outcome.Error);
        Assert.Empty(_sent.OfType<CaptureRequest>());
    }

    [Fact]
    public async Task ACaptureOfAViewportThatIsNotShownFailsWithItsReason()
    {
        using var shell = NewShell();

        var outcome = await shell.Gif(viewport: 2);

        Assert.False(outcome.Ok);
        Assert.Contains("viewport 2 is not shown", outcome.Error);
    }

    [Fact]
    public async Task ADebugViewScreenshotSwitchesTheCapturedViewportsSettingsAndPutsThemBack()
    {
        using var shell = NewShell(show: false);
        Show(shell, 1, 640, 360);
        Show(shell, 3, 640, 360);
        shell.ApplyViewportSettings(shell.Viewports[1], shell.Viewports[1].Settings with { NoBloom = true });
        shell.Camera.Place([0, 2L << 24, 0], 0.5, 0.25);
        _sent.Clear();

        var capture = shell.Screenshot([DebugView.Depth], Path.Combine(_temp.Path, "shot.png"));
        await Answer(shell, capture);
        var outcome = await capture;

        Assert.True(outcome.Ok, outcome.Error);
        // The capture viewport is the first shown scene view, 1, which the host reads already. Its settings change and come back.
        Assert.Empty(_sent.OfType<CaptureSource>());
        var changed = _sent.OfType<SetViewportSettings>().ToList();
        Assert.Equal([(1u, DebugView.Depth), (1u, DebugView.Lit)], changed.Select(s => (s.Viewport, s.Settings.DebugView)));
        Assert.True(changed[0].Settings.NoBloom && changed[1].Settings.NoBloom);
        // The sidecar's camera and settings are that viewport's.
        using var sidecar = JsonDocument.Parse(File.ReadAllText(Assert.IsType<string>(outcome.Sidecar)));
        var context = sidecar.RootElement.GetProperty("context");
        Assert.Equal(1, context.GetProperty("viewport").GetInt32());
        Assert.Equal("Scene", context.GetProperty("viewportKind").GetString());
        Assert.Equal(0.5, context.GetProperty("camera").GetProperty("yaw").GetDouble());
        Assert.True(context.GetProperty("settings").GetProperty("noBloom").GetBoolean());
    }

    [Fact]
    public async Task ACaptureOfTheGameViewNamesItAndHasNoCamera()
    {
        using var shell = NewShell();
        Show(shell, 3, 640, 360);
        _sent.Clear();

        var capture = shell.Screenshot(path: Path.Combine(_temp.Path, "game.png"), viewport: 3);
        await Answer(shell, capture);
        var outcome = await capture;

        Assert.True(outcome.Ok, outcome.Error);
        // The host reads the Game view for the capture, and the default again after.
        Assert.Equal([3, 0], _sent.OfType<CaptureSource>().Select(c => c.Viewport));
        using var sidecar = JsonDocument.Parse(File.ReadAllText(Assert.IsType<string>(outcome.Sidecar)));
        var context = sidecar.RootElement.GetProperty("context");
        Assert.Equal(3, context.GetProperty("viewport").GetInt32());
        Assert.Equal("Game", context.GetProperty("viewportKind").GetString());
        Assert.Equal(JsonValueKind.Null, context.GetProperty("camera").ValueKind);
    }

    // Answers the capture's requests as the host would, until the capture is done.
    async Task Answer(EditorShell shell, Task<CaptureOutcome> capture)
    {
        var answered = 0;
        while (!capture.IsCompleted)
        {
            var requests = _sent.OfType<CaptureRequest>().ToList();
            if (requests.Count > answered)
            {
                var request = requests[answered++];
                Assert.True(shell.Captures.Apply(new CaptureResult(request.Id, request.Kind, true, "", request.Path, 1, 640, 360, 0, 0, OutputMode.Sdr)));
            }
            else
            {
                await Task.Delay(5, TestContext.Current.CancellationToken);
            }
        }
    }

    // --- Automation ---

    [Fact]
    public async Task TheViewportCommandShowsAndHidesAViewportsDocument()
    {
        using var shell = NewShell();
        var cancel = TestContext.Current.CancellationToken;
        Assert.False(shell.Layout.IsViewportOpen(2));

        var shown = await shell.HandleAutomation(new AutomationRequest(1, "viewport", Settings: Settings(("shown", true)), Viewport: 2), cancel);
        Assert.True(shown.Ok, shown.Error);
        Assert.True(shell.Layout.IsViewportOpen(2));

        var hidden = await shell.HandleAutomation(new AutomationRequest(2, "viewport", Settings: Settings(("shown", false)), Viewport: 2), cancel);
        Assert.True(hidden.Ok, hidden.Error);
        Assert.False(shell.Layout.IsViewportOpen(2));

        var nameless = await shell.HandleAutomation(new AutomationRequest(3, "viewport", Settings: Settings(("shown", true))), cancel);
        Assert.False(nameless.Ok);
        Assert.Contains("shown takes a viewport", nameless.Error);
        var wrong = await shell.HandleAutomation(new AutomationRequest(4, "viewport", Settings: Settings(("shown", "yes")), Viewport: 1), cancel);
        Assert.False(wrong.Ok);
        Assert.Contains("true or false", wrong.Error);
        var out_ = await shell.HandleAutomation(new AutomationRequest(5, "viewport", Settings: Settings(("shown", true)), Viewport: 4), cancel);
        Assert.False(out_.Ok);
    }

    [Fact]
    public async Task TheViewportCommandChangesTheNamedViewportsSettings()
    {
        using var shell = NewShell();
        var cancel = TestContext.Current.CancellationToken;
        Show(shell, 3, 640, 360);

        var game = await shell.HandleAutomation(new AutomationRequest(1, "viewport", Settings: Settings(("debugView", "Albedo")), Viewport: 3), cancel);
        Assert.True(game.Ok, game.Error);
        Assert.Equal(DebugView.Albedo, shell.GameViewport.Settings.DebugView);
        Assert.Equal(DebugView.Lit, shell.Viewports[0].Settings.DebugView);

        // Without a viewport, the capture viewport's.
        var unnamed = await shell.HandleAutomation(new AutomationRequest(2, "viewport", Settings: Settings(("noFog", true))), cancel);
        Assert.True(unnamed.Ok, unnamed.Error);
        Assert.True(shell.Viewports[0].Settings.NoFog);
    }

    [Fact]
    public async Task TheCameraCommandPlacesASceneViewsCameraAndRefusesTheGameView()
    {
        using var shell = NewShell();
        var cancel = TestContext.Current.CancellationToken;
        Show(shell, 1, 640, 360);

        var placed = await shell.HandleAutomation(new AutomationRequest(1, "camera", Position: [0, 2, 0], Viewport: 1), cancel);
        Assert.True(placed.Ok, placed.Error);
        Assert.Equal(2L << 24, shell.Viewports[1].Camera.Position[1]);
        Assert.Equal(0, shell.Viewports[0].Camera.Position[1]);

        var game = await shell.HandleAutomation(new AutomationRequest(2, "camera", Position: [0, 2, 0], Viewport: 3), cancel);
        Assert.False(game.Ok);
        Assert.Contains("Game view", game.Error);
        var gone = await shell.HandleAutomation(new AutomationRequest(3, "camera", Position: [0, 2, 0], Viewport: 7), cancel);
        Assert.False(gone.Ok);
    }

    [Fact]
    public async Task TheStatusListsTheShownViewports()
    {
        using var shell = NewShell();
        Show(shell, 3, 640, 360);

        var status = await shell.HandleAutomation(new AutomationRequest(1, "status"), TestContext.Current.CancellationToken);

        Assert.Equal([0, 3], status.Status!.Viewports!);
    }

    [Fact]
    public async Task AScreenshotOfAViewportThatIsNotShownIsRefused()
    {
        using var shell = NewShell();

        var answer = await shell.HandleAutomation(new AutomationRequest(1, "screenshot", Viewport: 2), TestContext.Current.CancellationToken);

        Assert.False(answer.Ok);
        Assert.Contains("viewport 2 is not shown", answer.Error);
    }

    static Dictionary<string, JsonElement> Settings(params (string Name, object Value)[] settings) =>
        settings.ToDictionary(s => s.Name, s => JsonSerializer.SerializeToElement(s.Value));

    // --- Documents ---

    [Fact]
    public void TheDefaultLayoutHasTheSceneViewAndTheGameViewInOneDockWithTheSceneViewActive()
    {
        using var shell = NewShell(show: false);

        Assert.True(shell.Layout.IsViewportOpen(0));
        Assert.True(shell.Layout.IsViewportOpen(3));
        Assert.False(shell.Layout.IsViewportOpen(1));
        Assert.False(shell.Layout.IsViewportOpen(2));
        var node = Assert.Single(DocumentNodes(shell.Layout.Save().Root));
        Assert.Equal(["viewport.0", "viewport.3"], node.Documents);
        Assert.Equal("viewport.0", node.Active);
    }

    [Fact]
    public void NewSceneViewOpensTheLowestClosedOneAndIsDisabledAtThree()
    {
        using var shell = NewShell(show: false);
        var command = shell.Commands.Get(EditorCommands.NewSceneView);
        Assert.True(command.CanExecute);

        command.Execute();
        Assert.True(shell.Layout.IsViewportOpen(1));
        Assert.False(shell.Layout.IsViewportOpen(2));
        Assert.Equal("viewport.1", ActiveDocumentOf(shell, 1));
        command.Execute();
        Assert.True(shell.Layout.IsViewportOpen(2));
        Assert.False(command.CanExecute);

        shell.Layout.CloseViewport(0);
        Assert.True(command.CanExecute);
        command.Execute();
        Assert.True(shell.Layout.IsViewportOpen(0));
    }

    [Fact]
    public void TheGameCommandTogglesTheGameViewAndEveryDocumentMayCloseTheLastOneToo()
    {
        using var shell = NewShell(show: false);
        var command = shell.Commands.Get(EditorCommands.GameView);
        Assert.True(command.IsChecked);

        command.Execute();
        Assert.False(shell.Layout.IsViewportOpen(3));
        Assert.False(command.IsChecked);
        shell.Layout.CloseViewport(0);
        Assert.False(shell.Layout.IsViewportOpen(0));

        // The dock stays, empty, and a document opens in it again.
        Assert.Single(DocumentNodes(shell.Layout.Save().Root));
        command.Execute();
        Assert.True(shell.Layout.IsViewportOpen(3));
        Assert.True(command.IsChecked);
    }

    [Fact]
    public void ShowingAViewportMakesItsTabTheActiveOne()
    {
        using var shell = NewShell(show: false);
        Assert.Equal("viewport.0", ActiveDocumentOf(shell, 0));

        shell.Layout.ShowViewport(3);

        Assert.Equal("viewport.3", ActiveDocumentOf(shell, 3));
    }

    [Fact]
    public void ALayoutWithSeveralDocumentDocksKeepsEachOnesViewportsAndItsActiveOne()
    {
        using var shell = NewShell(show: false);
        var root = new SplitNode("dock.main", null, false,
        [
            new DocumentsNode("dock.a", 0.5, ["viewport.0", "viewport.2"], "viewport.2"),
            new DocumentsNode("dock.b", 0.5, ["viewport.3"], "viewport.3"),
        ]);

        Assert.True(shell.Layout.Restore(new LayoutFile(LayoutFile.CurrentVersion, root, [])));

        Assert.True(shell.Layout.IsViewportOpen(0) && shell.Layout.IsViewportOpen(2) && shell.Layout.IsViewportOpen(3));
        Assert.False(shell.Layout.IsViewportOpen(1));
        var saved = DocumentNodes(shell.Layout.Save().Root);
        Assert.Equal([["viewport.0", "viewport.2"], ["viewport.3"]], saved.Select(n => n.Documents!));
        Assert.Equal(["viewport.2", "viewport.3"], saved.Select(n => n.Active));
        Assert.Equal(["dock.a", "dock.b"], saved.Select(n => n.Id));
        // A viewport opens beside the first one that is open.
        shell.Layout.ShowViewport(1);
        Assert.Equal(["viewport.0", "viewport.2", "viewport.1"], DocumentNodes(shell.Layout.Save().Root)[0].Documents);
    }

    [Fact]
    public void ADockWithAllItsViewportsClosedStaysAndComesBackEmpty()
    {
        using var shell = NewShell(show: false);
        var root = new SplitNode("dock.main", null, false,
        [
            new DocumentsNode("dock.a", 0.5, ["viewport.0"], "viewport.0"),
            new DocumentsNode("dock.b", 0.5, [], null),
        ]);

        Assert.True(shell.Layout.Restore(new LayoutFile(LayoutFile.CurrentVersion, root, [])));

        var saved = DocumentNodes(shell.Layout.Save().Root);
        Assert.Equal(2, saved.Count);
        Assert.Empty(saved[1].Documents!);
        Assert.False(shell.Layout.IsViewportOpen(3));
    }

    [Fact]
    public void ALayoutFileOfAnEditorWithOneViewportRestoresTheSceneViewAndTheGameView()
    {
        using var shell = NewShell(show: false);
        // The single document dock listed no documents.
        var old = """{"version":1,"root":{"kind":"documents","id":"dock.documents","proportion":0.72},"floating":[]}""";
        var file = LayoutFile.FromJson(old);
        Assert.NotNull(file);
        shell.Layout.CloseViewport(3);
        shell.Layout.ShowViewport(1);

        Assert.True(shell.Layout.Restore(file));

        var node = Assert.Single(DocumentNodes(shell.Layout.Save().Root));
        Assert.Equal(["viewport.0", "viewport.3"], node.Documents);
        Assert.Equal("viewport.0", node.Active);
        Assert.False(shell.Layout.IsViewportOpen(1));
    }

    [Fact]
    public void ALayoutWithAViewportInTwoDocksKeepsItInTheFirst()
    {
        using var shell = NewShell(show: false);
        var root = new SplitNode("dock.main", null, false,
        [
            new DocumentsNode("dock.a", 0.5, ["viewport.0"], null),
            new DocumentsNode("dock.a", 0.5, ["viewport.0", "viewport.1", "viewport.9"], null),
        ]);

        Assert.True(shell.Layout.Restore(new LayoutFile(LayoutFile.CurrentVersion, root, [])));

        var saved = DocumentNodes(shell.Layout.Save().Root);
        Assert.Equal([["viewport.0"], ["viewport.1"]], saved.Select(n => n.Documents!));
        Assert.Equal(2, saved.Select(n => n.Id).Distinct().Count());
    }

    [Fact]
    public void TheDocumentsAreKeptAcrossSessions()
    {
        string saved;
        using (var shell = NewShell(show: false))
        {
            shell.Layout.ShowViewport(2);
            shell.Layout.CloseViewport(3);
            shell.SaveLayout();
            saved = shell.Layout.Save().ToJson();
        }

        using var restored = TestShell.Open(_temp, "box.scene", null);

        Assert.Equal(saved, restored.Layout.Save().ToJson());
        Assert.True(restored.Layout.IsViewportOpen(2));
        Assert.False(restored.Layout.IsViewportOpen(3));
        Assert.DoesNotContain(restored.Console.Lines, l => l.Level >= Model.LogLevel.Warning);
    }

    [Fact]
    public void ResettingTheLayoutPutsTheSceneViewAndTheGameViewBack()
    {
        using var shell = NewShell(show: false);
        shell.Layout.ShowViewport(1);
        shell.Layout.CloseViewport(3);

        shell.Layout.Reset();

        Assert.True(shell.Layout.IsViewportOpen(0) && shell.Layout.IsViewportOpen(3));
        Assert.False(shell.Layout.IsViewportOpen(1));
    }

    [Fact]
    public void AMaterialEditorOpensInTheDockOfTheFirstOpenViewport()
    {
        using var shell = NewShell(show: false);
        var root = new SplitNode("dock.main", null, false,
        [
            new DocumentsNode("dock.a", 0.5, ["viewport.3"], "viewport.3"),
            new DocumentsNode("dock.b", 0.5, ["viewport.1"], "viewport.1"),
        ]);
        Assert.True(shell.Layout.Restore(new LayoutFile(LayoutFile.CurrentVersion, root, [])));

        // Viewport 1 is the first open one, so the document goes beside it.
        shell.Layout.OpenDocument(new TestDocument());

        var dock = Assert.IsAssignableFrom<IDock>(shell.Layout.Root is IDock ? FindDock(shell.Layout.Root, "viewport.1") : null);
        Assert.Contains(dock.VisibleDockables!, d => d is TestDocument);
    }

    sealed class TestDocument : EditorDocument
    {
        public TestDocument() : base(new object(), () => new Avalonia.Controls.Panel())
        {
            Id = "test.document";
            Title = "Test";
        }
    }

    static IDock? FindDock(IDockable root, string child)
    {
        if (root is IDock dock)
        {
            if (dock.VisibleDockables?.Any(d => d.Id == child) == true)
            {
                return dock;
            }
            foreach (var d in dock.VisibleDockables ?? [])
            {
                if (FindDock(d, child) is { } found)
                {
                    return found;
                }
            }
        }
        return null;
    }

    static List<DocumentsNode> DocumentNodes(LayoutNode node) => node switch
    {
        DocumentsNode documents => [documents],
        SplitNode split => [.. split.Children.SelectMany(DocumentNodes)],
        _ => [],
    };

    static string? ActiveDocumentOf(EditorShell shell, int viewport) =>
        (FindDock(shell.Layout.Root, $"viewport.{viewport}") as IDock)?.ActiveDockable?.Id;

    // --- Input ---

    [Fact]
    public void NoFreeCameraCommandExistsAnymore()
    {
        using var shell = NewShell(show: false);

        Assert.DoesNotContain(shell.Commands.All, c => c.Id.Contains("freeCamera", StringComparison.OrdinalIgnoreCase));
    }

    public void Dispose() => _temp.Dispose();
}
