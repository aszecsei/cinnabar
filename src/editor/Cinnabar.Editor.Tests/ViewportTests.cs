using System.Text.Json;
using Avalonia;
using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Docking;
using Cinnabar.Editor.Document;
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
        Show(shell, 4, 640, 360);

        shell.Host.LinkForTests(_sent.Add);

        Assert.Equal([0u, 4u], _sent.OfType<OpenViewport>().Select(o => o.Viewport));
        Assert.Equal([0u], _sent.OfType<EditorCamera>().Select(c => c.Viewport));
    }

    [Fact]
    public void ANewGameStateHearsOfEveryShownViewportAndOnlyThose()
    {
        using var shell = NewShell();
        Show(shell, 1, 800, 900);
        Show(shell, 4, 640, 360);
        Show(shell, 2, 100, 100);
        Hide(shell, 2);
        _sent.Clear();

        shell.Host.Receive(new GameReloaded(ReloadKind.SoftRestart));

        Assert.Equal([0u, 1u, 4u], _sent.OfType<OpenViewport>().Select(o => o.Viewport));
        Assert.Equal(ViewportKind.Game, _sent.OfType<OpenViewport>().Last().Kind);
        // Only a scene view has an editor camera.
        Assert.Equal([0u, 1u], _sent.OfType<EditorCamera>().Select(c => c.Viewport));
        Assert.Equal([0u, 1u, 4u], _sent.OfType<SetViewportSettings>().Select(s => s.Viewport));
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

        Show(shell, 4, 800, 600);
        Assert.Equal(new GameSize(800, 600), Assert.Single(_sent.OfType<GameSize>()));
        _sent.Clear();
        Show(shell, 4, 1024, 768);
        Assert.Equal(new GameSize(1024, 768), Assert.Single(_sent.OfType<GameSize>()));
        _sent.Clear();
        Show(shell, 0, 1000, 700);
        Hide(shell, 4);
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
        Show(shell, 4, 800, 600);
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
        Assert.Equal((4u, DebugView.Albedo), (sent.Viewport, sent.Settings.DebugView));

        // A scene view takes both back, and the Game view's hiding does too.
        shell.ActivateViewport(shell.Viewports[0]);
        Assert.Same(shell.Viewports[0], shell.SettingsViewport);
        shell.ActivateViewport(game);
        Hide(shell, 4);
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
    public void TheTopFrontAndSideViewsStartAtTheFirstViewsPivotLookingAlongTheirAxes()
    {
        using var shell = NewShell();
        shell.Camera.Place([0, 3L << 24, 0], 0.5, 0.25);
        var pivot = shell.Camera.Pivot;
        // The Top view looks down, a degree short of straight so that its heading means something.
        (int View, Vec3 Looks, double Yaw)[] starts = [(1, new Vec3(0, -1, 0), 0), (2, new Vec3(0, 0, -1), Math.PI), (3, new Vec3(-1, 0, 0), -Math.PI / 2)];

        foreach (var (index, looks, yaw) in starts)
        {
            _sent.Clear();
            Show(shell, index, 800, 600);
            var camera = shell.Viewports[index].Camera;

            Assert.True(Vec3.Dot(camera.Forward, looks) > 0.999, $"view {index} looks along {camera.Forward}");
            Assert.True(Vec3.Between(pivot, camera.Pivot).Length < 0.001, $"view {index}'s pivot is {Vec3.Between(pivot, camera.Pivot)} off");
            // They are orthographic: they show what the first view shows at its pivot, from far enough back to clip
            // little that is in front of it.
            Assert.True(camera.IsOrthographic);
            Assert.Equal(2 * shell.Camera.PivotDistance * Math.Tan(shell.Camera.VerticalFov / 2), camera.OrthographicHeight, 6);
            Assert.Equal(Tools.EditorCamera.OrthographicStandoff, camera.PivotDistance, 6);
            Assert.Equal(yaw, camera.Yaw, 6);
            // The game hears of the camera that the view starts with, once.
            var sent = Assert.Single(_sent.OfType<EditorCamera>(), c => c.Viewport == (uint)index);
            Assert.Equal(camera.Position, sent.Position);
            Assert.Equal(CameraProjection.Orthographic, sent.Projection);
            Assert.Equal((float)camera.OrthographicHeight, sent.OrthographicHeight);
            Assert.Equal((float)Tools.EditorCamera.OrthographicFar, sent.Far);
        }
        Assert.False(shell.Camera.IsOrthographic);
        Assert.Equal(["Perspective", "Top", "Front", "Side", "Game"], shell.Viewports.Select(v => v.Title));
    }

    [Fact]
    public void AViewThatHidesAndShowsAgainKeepsItsCamera()
    {
        using var shell = NewShell();
        Show(shell, 2, 800, 600);
        var front = shell.Viewports[2];
        front.Camera.Place([0, 7L << 24, 0], 0, 0);
        Hide(shell, 2);
        shell.Camera.Place([0, 0, 0], 0, 0);
        _sent.Clear();

        Show(shell, 2, 800, 600);

        Assert.Equal(7L << 24, front.Camera.Position[1]);
        var camera = Assert.Single(_sent.OfType<EditorCamera>());
        Assert.Equal((2u, 7L << 24), (camera.Viewport, camera.Position[1]));
    }

    [Fact]
    public void AViewThatWasMovedBeforeItWasShownKeepsItsPlace()
    {
        using var shell = NewShell();
        shell.Viewports[3].Camera.Place([0, 1L << 24, 0], 1, 0);

        Show(shell, 3, 800, 600);

        Assert.Equal(1L << 24, shell.Viewports[3].Camera.Position[1]);
    }

    // --- The Scene's views ---

    const SceneViewSet P = SceneViewSet.Perspective;
    const SceneViewSet T = SceneViewSet.Top;
    const SceneViewSet F = SceneViewSet.Front;
    const SceneViewSet S = SceneViewSet.Side;

    [Fact]
    public void TheSceneStartsWithThePerspectiveViewAloneAndTheTogglesChangeItsViews()
    {
        using var shell = NewShell(show: false);
        Assert.Equal(P, shell.SceneViews);
        Assert.Equal([0], shell.SceneDocumentViews.Select(v => v.Index));
        var changes = 0;
        shell.SceneViewsChanged += () => changes++;

        Assert.True(shell.ToggleSceneView(2));
        Assert.Equal(P | F, shell.SceneViews);
        Assert.Equal([0, 2], shell.SceneDocumentViews.Select(v => v.Index));
        Assert.Equal(1, changes);
        // The same set again changes nothing.
        Assert.True(shell.SetSceneViews(P | F));
        Assert.Equal(1, changes);
        Assert.True(shell.ToggleSceneView(0));
        Assert.Equal(F, shell.SceneViews);
        Assert.Equal(2, changes);
    }

    [Fact]
    public void TheLastViewCannotBeToggledOut()
    {
        using var shell = NewShell(show: false);
        var toggle = shell.Commands.Get(EditorCommands.SceneViewToggle(0));
        Assert.False(toggle.CanExecute);
        Assert.False(shell.CanToggleSceneView(0));

        Assert.False(shell.ToggleSceneView(0));
        Assert.False(shell.SetSceneViews(SceneViewSet.None));

        Assert.Equal(P, shell.SceneViews);
        shell.ToggleSceneView(3);
        Assert.True(toggle.CanExecute);
        Assert.True(toggle.IsChecked);
        Assert.True(shell.Commands.Get(EditorCommands.SceneViewToggle(3)).IsChecked);
        Assert.False(shell.Commands.Get(EditorCommands.SceneViewToggle(1)).IsChecked);
        shell.Commands.Get(EditorCommands.SceneViewToggle(0)).Execute();
        Assert.Equal(S, shell.SceneViews);
        Assert.False(shell.Commands.Get(EditorCommands.SceneViewToggle(3)).CanExecute);
    }

    [Fact]
    public void ThePresetsSetTheTogglesAndTheCurrentOneIsDerivedFromThem()
    {
        using var shell = NewShell(show: false);
        var command = (ChoiceCommand)shell.Commands.Get(EditorCommands.SceneLayout);
        Assert.Equal(["Single", "Two Side by Side", "Quad", "Custom"], command.Options);
        Assert.Equal("Single", command.Selected);

        command.Select("Quad");
        Assert.Equal(SceneViewSet.All, shell.SceneViews);
        Assert.Equal("Quad", command.Selected);
        command.Select("Two Side by Side");
        Assert.Equal(P | T, shell.SceneViews);
        shell.ToggleSceneView(3);
        Assert.Equal("Custom", command.Selected);
        Assert.Equal("Custom", shell.ScenePresetName);
        command.Select("Single");
        Assert.Equal(P, shell.SceneViews);
        // Custom is not a preset to choose.
        shell.ToggleSceneView(1);
        command.Select("Custom");
        Assert.Equal(P | T, shell.SceneViews);
    }

    [Fact]
    public void AViewThatEntersOpensOnceAndOneThatLeavesClosesOnceAndTheOthersAreNotTouched()
    {
        using var shell = NewShell(show: false);
        // The Scene document's controls show their sessions once they have a size.
        Show(shell, 0, 800, 450);
        _sent.Clear();

        // A change of the views sends nothing by itself: the game hears of the controls that appear and go.
        shell.SetSceneViews(P | T | F);
        Assert.DoesNotContain(_sent, m => m is OpenViewport or CloseViewport);
        // The Perspective view stays, and only its size changes.
        Show(shell, 0, 400, 225);
        Show(shell, 1, 400, 225);
        Show(shell, 2, 400, 225);
        Assert.Equal([(0u, 400), (1u, 400), (2u, 400)], _sent.OfType<OpenViewport>().Select(o => (o.Viewport, o.Width)));
        Assert.Equal([1u, 2u], _sent.OfType<EditorCamera>().Select(c => c.Viewport));

        shell.SetSceneViews(P | F);
        _sent.Clear();
        Hide(shell, 1);
        Assert.Equal([1u], _sent.OfType<CloseViewport>().Select(c => c.Viewport));
        Assert.Empty(_sent.OfType<OpenViewport>());
        Assert.Equal([0, 2], shell.ShownViewports.Select(v => v.Index));
    }

    [Fact]
    public void TheGameTabInFrontClosesEveryEditView()
    {
        using var shell = NewShell(show: false);
        shell.SetSceneViews(SceneViewSet.All);
        foreach (var index in new[] { 0, 1, 2, 3 })
        {
            Show(shell, index, 400, 225);
        }
        _sent.Clear();

        // The tab behind another leaves the tree, so all four controls hide, and the Game view's shows.
        foreach (var index in new[] { 0, 1, 2, 3 })
        {
            Hide(shell, index);
        }
        Show(shell, 4, 800, 450);

        Assert.Equal([0u, 1u, 2u, 3u], _sent.OfType<CloseViewport>().Select(c => c.Viewport));
        Assert.Equal(new OpenViewport(4, ViewportKind.Game, 800, 450), Assert.Single(_sent.OfType<OpenViewport>()));
        Assert.Equal([4], shell.ShownViewports.Select(v => v.Index));
        Assert.Same(shell.GameViewport, shell.CaptureViewport);
    }

    [Fact]
    public void AViewThatIsToggledInForTheFirstTimeStartsAlongItsAxis()
    {
        using var shell = NewShell();
        shell.Camera.Place([0, 3L << 24, 0], 0.5, 0.25);

        shell.SetSceneViews(P | S);
        _sent.Clear();
        Show(shell, 3, 400, 225);

        var camera = Assert.Single(_sent.OfType<EditorCamera>());
        Assert.Equal(3u, camera.Viewport);
        Assert.True(Vec3.Dot(shell.Viewports[3].Camera.Forward, new Vec3(-1, 0, 0)) > 0.999);
    }

    [Fact]
    public void TheActiveViewportFallsBackToTheLowestShownViewWhenItLeaves()
    {
        using var shell = NewShell(show: false);
        shell.SetSceneViews(SceneViewSet.All);
        foreach (var index in new[] { 0, 1, 2, 3 })
        {
            Show(shell, index, 400, 225);
        }
        shell.ActivateViewport(shell.Viewports[2]);
        Assert.Same(shell.Viewports[2], shell.ActiveViewport);

        // Toggling the active view out takes it out of the tree, and its control hides.
        shell.ToggleSceneView(2);
        Hide(shell, 2);

        Assert.Same(shell.Viewports[0], shell.ActiveViewport);
        Assert.Same(shell.Viewports[0], shell.SettingsViewport);
        Assert.Same(shell.Viewports[0], shell.CaptureViewport);
        // With the Perspective view out as well, the capture viewport is the lowest left.
        shell.ToggleSceneView(0);
        Hide(shell, 0);
        Assert.Same(shell.Viewports[1], shell.CaptureViewport);
        Assert.Same(shell.Viewports[1], shell.ActiveViewport);
    }

    [Fact]
    public void TheCaptureViewportOfAQuadIsThePerspectiveViewAndTheActiveViewportIsAmongTheFour()
    {
        using var shell = NewShell(show: false);
        shell.SetSceneViews(SceneViewSet.All);
        foreach (var index in new[] { 3, 2, 1, 0 })
        {
            Show(shell, index, 400, 225);
        }
        Assert.Same(shell.Viewports[0], shell.CaptureViewport);
        _sent.Clear();

        shell.ActivateViewport(shell.Viewports[3]);
        shell.PickAt(new Vec2(5, 6), SelectMode.Replace);

        Assert.Same(shell.Viewports[3], shell.ActiveViewport);
        Assert.Same(shell.Viewports[3].Camera, shell.Camera);
        Assert.Equal((3u, 5, 6), (_sent.OfType<PickRequest>().Single().Viewport, _sent.OfType<PickRequest>().Single().X, _sent.OfType<PickRequest>().Single().Y));
    }

    [Fact]
    public void TheViewsStayAcrossSessions()
    {
        using (var shell = NewShell(show: false))
        {
            shell.SetSceneViews(P | F | S);
        }
        using var again = TestShell.Open(_temp, "box.scene", null);
        Assert.Equal(P | F | S, again.SceneViews);
        Assert.Equal("Custom", again.ScenePresetName);
        var text = File.ReadAllText(Path.Combine(_temp.Combine("settings"), EditorSettings.ViewportFileName));
        Assert.Contains("Perspective", text);
        Assert.DoesNotContain("\"Layout\"", text);
    }

    [Theory]
    [InlineData("Quad", SceneViewSet.All)]
    [InlineData("quad", SceneViewSet.All)]
    [InlineData("Single", SceneViewSet.Perspective)]
    [InlineData("Octo", SceneViewSet.Perspective)]
    public void AFileWithTheEarlierLayoutOrNoneReadsAsTheMatchingViews(string layout, SceneViewSet expected)
    {
        var settings = EditorShell.DefaultViewportSettings with { NoFog = true };
        Directory.CreateDirectory(_temp.Combine("settings"));
        var file = Path.Combine(_temp.Combine("settings"), EditorSettings.ViewportFileName);

        File.WriteAllText(file, JsonSerializer.Serialize(new { Viewports = new[] { settings, settings, settings, settings, settings }, Layout = layout }));
        using (var shell = TestShell.Open(_temp, "box.scene", null))
        {
            Assert.Equal(expected, shell.SceneViews);
            Assert.True(shell.Viewports[3].Settings.NoFog);
        }

        // No layout and no views, or the oldest file of one viewport's settings.
        File.WriteAllText(file, JsonSerializer.Serialize(new { Viewports = new[] { settings } }));
        using (var none = TestShell.Open(_temp, "box.scene", null))
        {
            Assert.Equal(P, none.SceneViews);
        }
        File.WriteAllText(file, JsonSerializer.Serialize(settings));
        using var bare = TestShell.Open(_temp, "box.scene", null);
        Assert.Equal(P, bare.SceneViews);
    }

    [Fact]
    public void AFileWithNoViewsInItReadsAsThePerspectiveView()
    {
        Directory.CreateDirectory(_temp.Combine("settings"));
        File.WriteAllText(Path.Combine(_temp.Combine("settings"), EditorSettings.ViewportFileName), """{"Viewports":[],"Views":"None"}""");

        using var shell = TestShell.Open(_temp, "box.scene", null);

        Assert.Equal(P, shell.SceneViews);
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
        Show(shell, 4, 800, 900);
        // A perspective view, twice as far from the box as the first viewport's camera.
        shell.SetProjection(shell.Viewports[1], CameraProjection.Perspective);
        shell.Viewports[1].Camera.Place([0, 0, -5L << 24], 0, 0);
        _sent.Clear();

        shell.Selection.Select(Box);

        var gizmos = _sent.OfType<GizmoState>().Where(g => g.Kind != GizmoKind.None).ToDictionary(g => g.Viewport);
        Assert.Equal([0u, 1u], gizmos.Keys.Order());
        Assert.Equal(gizmos[0].Size * 2, gizmos[1].Size, 3);
        Assert.DoesNotContain(_sent.OfType<GizmoState>(), g => g.Viewport == 4);
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

        Show(shell, 4, 640, 360);
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

        Show(shell, 4, 640, 360);
        Assert.Equal([4], _sent.OfType<CaptureSource>().Select(c => c.Viewport));
        // Another viewport does not change the choice, and a scene view does.
        _sent.Clear();
        Show(shell, 2, 640, 360);
        Assert.Equal([2], _sent.OfType<CaptureSource>().Select(c => c.Viewport));
        _sent.Clear();
        Show(shell, 4, 800, 600);
        Assert.Empty(_sent.OfType<CaptureSource>());
        Hide(shell, 2);
        Assert.Equal([4], _sent.OfType<CaptureSource>().Select(c => c.Viewport));
        _sent.Clear();
        Hide(shell, 4);
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
        Show(shell, 4, 640, 360);
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
        Show(shell, 4, 640, 360);
        _sent.Clear();

        var capture = shell.Screenshot(path: Path.Combine(_temp.Path, "game.png"), viewport: 4);
        await Answer(shell, capture);
        var outcome = await capture;

        Assert.True(outcome.Ok, outcome.Error);
        // The host reads the Game view for the capture, and the default again after.
        Assert.Equal([4, 0], _sent.OfType<CaptureSource>().Select(c => c.Viewport));
        using var sidecar = JsonDocument.Parse(File.ReadAllText(Assert.IsType<string>(outcome.Sidecar)));
        var context = sidecar.RootElement.GetProperty("context");
        Assert.Equal(4, context.GetProperty("viewport").GetInt32());
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
    public async Task TheViewportCommandTogglesTheViewsShowsTheDocumentsAndSetsThePreset()
    {
        using var shell = NewShell();
        var cancel = TestContext.Current.CancellationToken;
        Task<AutomationResponse> Ask(int id, int? viewport, params (string Name, object Value)[] settings) =>
            shell.HandleAutomation(new AutomationRequest(id, "viewport", Settings: Settings(settings), Viewport: viewport), cancel);

        // Viewport 4 is the Game document.
        Assert.True((await Ask(2, 4, ("shown", false))).Ok);
        Assert.False(shell.Layout.IsViewportOpen(ViewportDocument.GameId));
        Assert.True((await Ask(3, 4, ("shown", true))).Ok);
        Assert.True(shell.Layout.IsViewportOpen(ViewportDocument.GameId));
        Assert.True((await Ask(4, 0, ("shown", true))).Ok);
        Assert.True(shell.Layout.IsViewportOpen(ViewportDocument.SceneId));
        Assert.Equal("scene", ActiveDocumentOf(shell, ViewportDocument.SceneId));
        Assert.Equal(P, shell.SceneViews);

        // A scene view, 0 to 3, goes in the Scene or out of it, and showing one brings the Scene's tab to the front.
        var quad = await Ask(5, 2, ("shown", true));
        Assert.True(quad.Ok, quad.Error);
        Assert.Equal(P | F, shell.SceneViews);
        Assert.Equal("scene", ActiveDocumentOf(shell, ViewportDocument.SceneId));
        Assert.True((await Ask(6, 2, ("shown", false))).Ok);
        Assert.Equal(P, shell.SceneViews);
        Assert.True((await Ask(13, 1, ("shown", false))).Ok);
        Assert.Equal(P, shell.SceneViews);
        // The last one in stays, and the answer says why.
        var last = await Ask(14, 0, ("shown", false));
        Assert.False(last.Ok);
        Assert.Contains("only view in the Scene", last.Error);
        Assert.Equal(P, shell.SceneViews);

        // A layout is a preset of the views.
        Assert.True((await Ask(7, null, ("layout", "Single"))).Ok);
        Assert.Equal(P, shell.SceneViews);
        Assert.True((await Ask(8, null, ("layout", "quad"))).Ok);
        Assert.Equal(SceneViewSet.All, shell.SceneViews);
        Assert.True((await Ask(15, null, ("layout", "TwoSideBySide"))).Ok);
        Assert.Equal(P | T, shell.SceneViews);
        var unknown = await Ask(9, null, ("layout", "Octo"));
        Assert.False(unknown.Ok);
        Assert.Contains("Single, Two Side by Side, Quad", unknown.Error);

        var nameless = await Ask(10, null, ("shown", true));
        Assert.False(nameless.Ok);
        Assert.Contains("shown takes a viewport", nameless.Error);
        var wrong = await Ask(11, 1, ("shown", "yes"));
        Assert.False(wrong.Ok);
        Assert.Contains("true or false", wrong.Error);
        Assert.False((await Ask(12, 5, ("shown", true))).Ok);
    }

    [Fact]
    public async Task TheViewportCommandChangesTheNamedViewportsSettings()
    {
        using var shell = NewShell();
        var cancel = TestContext.Current.CancellationToken;
        Show(shell, 4, 640, 360);

        var game = await shell.HandleAutomation(new AutomationRequest(1, "viewport", Settings: Settings(("debugView", "Albedo")), Viewport: 4), cancel);
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

        var game = await shell.HandleAutomation(new AutomationRequest(2, "camera", Position: [0, 2, 0], Viewport: 4), cancel);
        Assert.False(game.Ok);
        Assert.Contains("Game view", game.Error);
        var gone = await shell.HandleAutomation(new AutomationRequest(3, "camera", Position: [0, 2, 0], Viewport: 7), cancel);
        Assert.False(gone.Ok);
    }

    [Fact]
    public async Task AViewsProjectionIsChosenSavedAndSetByAutomation()
    {
        var cancel = TestContext.Current.CancellationToken;
        using (var shell = NewShell())
        {
            Show(shell, 2, 640, 360);
            Assert.True(shell.Viewports[2].Camera.IsOrthographic);
            var pivot = shell.Camera.Pivot;
            var shows = 2 * shell.Camera.PivotDistance * Math.Tan(shell.Camera.VerticalFov / 2);

            // The first view goes orthographic about its pivot, and shows as much of it.
            _sent.Clear();
            Assert.True(shell.SetProjection(shell.Viewports[0], CameraProjection.Orthographic));
            Assert.True(shell.Camera.IsOrthographic);
            Assert.Equal(shows, shell.Camera.OrthographicHeight, 6);
            Assert.True(Vec3.Between(pivot, shell.Camera.Pivot).Length < 0.001);
            Assert.Equal(CameraProjection.Orthographic, _sent.OfType<EditorCamera>().Last(c => c.Viewport == 0).Projection);

            // Automation sets a view's, by its name, and refuses a name that is none and the Game view.
            var front = await shell.HandleAutomation(new AutomationRequest(1, "viewport", Viewport: 2, Settings: Settings(("projection", "perspective"))), cancel);
            Assert.True(front.Ok, front.Error);
            Assert.False(shell.Viewports[2].Camera.IsOrthographic);
            var unknown = await shell.HandleAutomation(new AutomationRequest(2, "viewport", Viewport: 2, Settings: Settings(("projection", "Isometric"))), cancel);
            Assert.False(unknown.Ok);
            Assert.Contains("Perspective, Orthographic", unknown.Error);
            var game = await shell.HandleAutomation(new AutomationRequest(3, "viewport", Viewport: 4, Settings: Settings(("projection", "Orthographic"))), cancel);
            Assert.False(game.Ok);

            // The 2D view looks along +z without perspective, at the pivot, and shows as much of it.
            Show(shell, 3, 640, 360);
            var side = shell.Viewports[3];
            var (sidePivot, sideShows) = (side.Camera.Pivot, side.Camera.OrthographicHeight);
            var flat = await shell.HandleAutomation(new AutomationRequest(4, "viewport", Viewport: 3, Settings: Settings(("view2d", true))), cancel);
            Assert.True(flat.Ok, flat.Error);
            Assert.True(side.Camera.IsOrthographic);
            Assert.True(Vec3.Dot(side.Camera.Forward, Vec3.UnitZ) > 0.999999 && Vec3.Dot(side.Camera.Right, Vec3.UnitX) > 0.999999);
            Assert.True(Vec3.Between(sidePivot, side.Camera.Pivot).Length < 0.001);
            Assert.Equal(sideShows, side.Camera.OrthographicHeight, 6);
            Assert.False(shell.Show2D(shell.Viewports[4]));

            // Orbiting makes a view a perspective one, and leaves what the user chose for it.
            shell.Camera.Orbit(10, 0);
            Assert.False(shell.Camera.IsOrthographic);
            Assert.Equal(CameraProjection.Orthographic, shell.Viewports[0].Projection);
        }
        // The next editor's views have the projections that were chosen.
        using var again = NewShell();
        Assert.True(again.Camera.IsOrthographic);
        Show(again, 2, 640, 360);
        Assert.False(again.Viewports[2].Camera.IsOrthographic);
        Show(again, 1, 640, 360);
        Assert.True(again.Viewports[1].Camera.IsOrthographic);
    }

    [Fact]
    public void LookingAlongAnAxisTurnsAboutThePivotToTheViewsChosenProjection()
    {
        using var shell = NewShell();
        Show(shell, 1, 640, 360);
        var top = shell.Viewports[1];
        // The Top view orbits, which makes it a perspective one and leaves its choice orthographic.
        top.Camera.Orbit(200, -150);
        Assert.False(top.Camera.IsOrthographic);
        var (pivot, shows) = (top.Camera.Pivot, top.Camera.ViewDistance);

        _sent.Clear();
        Assert.True(shell.LookAlong(top, Tools.ViewAxis.Top));
        Assert.NotNull(top.Turn);
        // Half way it still turns, in perspective, about the same pivot.
        Assert.True(shell.StepTurn(top, Tools.CameraTurn.Duration / 2));
        Assert.False(top.Camera.IsOrthographic);
        Assert.True(Vec3.Between(pivot, top.Camera.Pivot).Length < 0.001);
        // At its end it looks down, orthographic, showing as much at the pivot, and the turn is over.
        Assert.False(shell.StepTurn(top, Tools.CameraTurn.Duration));
        Assert.Null(top.Turn);
        Assert.Equal(Tools.ViewAxis.Top, Tools.ViewGizmo.Aligned(top.Camera));
        Assert.True(top.Camera.IsOrthographic);
        Assert.Equal(shows, top.Camera.ViewDistance, 6);
        Assert.True(Vec3.Between(pivot, top.Camera.Pivot).Length < 0.001);
        Assert.Equal(CameraProjection.Orthographic, _sent.OfType<EditorCamera>().Last(c => c.Viewport == 1).Projection);

        // A perspective view turns in perspective, and the Game view has no camera to turn.
        Assert.True(shell.LookAlong(shell.Viewports[0], Tools.ViewAxis.Left, animate: false));
        Assert.Equal(Tools.ViewAxis.Left, Tools.ViewGizmo.Aligned(shell.Viewports[0].Camera));
        Assert.False(shell.Viewports[0].Camera.IsOrthographic);
        Assert.False(shell.LookAlong(shell.Viewports[4], Tools.ViewAxis.Top));

        // A view that was never shown turns about the first view's pivot, where it would have started.
        var front = shell.Viewports[2];
        Assert.True(shell.LookAlong(front, Tools.ViewAxis.Top, animate: false));
        Assert.True(Vec3.Between(shell.Viewports[0].Camera.Pivot, front.Camera.Pivot).Length < 0.001);
        Assert.Equal(Tools.ViewAxis.Top, Tools.ViewGizmo.Aligned(front.Camera));
    }

    [Fact]
    public void AnotherMoveOfTheCameraEndsATurnWhereThatMovePutIt()
    {
        using var shell = NewShell();
        var view = shell.Viewports[0];
        shell.LookAlong(view, Tools.ViewAxis.Front);
        shell.StepTurn(view, 50);

        view.Camera.Pan(30, 0, 900);
        var panned = view.Camera.Pose;

        Assert.False(shell.StepTurn(view, 50));
        Assert.Null(view.Turn);
        Assert.Equal(panned, view.Camera.Pose);
    }

    [Fact]
    public void AViewThatHidesWhileItTurnsEndsTheTurnAtOnce()
    {
        using var shell = NewShell();
        var view = shell.Viewports[0];
        shell.LookAlong(view, Tools.ViewAxis.Right);

        Hide(shell, 0);

        Assert.Null(view.Turn);
        Assert.Equal(Tools.ViewAxis.Right, Tools.ViewGizmo.Aligned(view.Camera));
    }

    [Fact]
    public async Task TheProjectionSwitchIsTheViewsChoiceAndAutomationLooksAlongAnAxis()
    {
        var cancel = TestContext.Current.CancellationToken;
        using (var shell = NewShell())
        {
            Assert.True(shell.ToggleProjection(shell.Viewports[0]));
            Assert.True(shell.Camera.IsOrthographic);
            Assert.Equal(CameraProjection.Orthographic, shell.Viewports[0].Projection);
            Assert.False(shell.ToggleProjection(shell.Viewports[4]));

            var look = await shell.HandleAutomation(new AutomationRequest(1, "viewport", Viewport: 0, Settings: Settings(("look", "bottom"))), cancel);
            Assert.True(look.Ok, look.Error);
            Assert.Null(shell.Viewports[0].Turn);
            Assert.Equal(Tools.ViewAxis.Bottom, Tools.ViewGizmo.Aligned(shell.Camera));
            Assert.True(shell.Camera.IsOrthographic);
            var unknown = await shell.HandleAutomation(new AutomationRequest(2, "viewport", Viewport: 0, Settings: Settings(("look", "Above"))), cancel);
            Assert.False(unknown.Ok);
            Assert.Contains("Top, Bottom, Front, Back, Right, Left", unknown.Error);
            var game = await shell.HandleAutomation(new AutomationRequest(3, "viewport", Viewport: 4, Settings: Settings(("look", "Top"))), cancel);
            Assert.False(game.Ok);
        }
        // The switch is kept as the view's choice.
        using var again = NewShell();
        Assert.True(again.Camera.IsOrthographic);
    }

    [Fact]
    public async Task TheStatusListsTheShownViewports()
    {
        using var shell = NewShell();
        Show(shell, 4, 640, 360);

        var status = await shell.HandleAutomation(new AutomationRequest(1, "status"), TestContext.Current.CancellationToken);

        Assert.Equal([0, 4], status.Status!.Viewports!);
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
    public void TheDefaultLayoutHasTheSceneAndTheGameInOneDockWithTheSceneInFront()
    {
        using var shell = NewShell(show: false);

        Assert.True(shell.Layout.IsViewportOpen(ViewportDocument.SceneId));
        Assert.True(shell.Layout.IsViewportOpen(ViewportDocument.GameId));
        var node = Assert.Single(DocumentNodes(shell.Layout.Save().Root));
        Assert.Equal(["scene", "game"], node.Documents);
        Assert.Equal("scene", node.Active);
    }

    [Fact]
    public void TheSceneAndGameCommandsToggleTheirDocumentsAndEitherMayCloseTheLastToo()
    {
        using var shell = NewShell(show: false);
        var game = shell.Commands.Get(EditorCommands.GameView);
        var scene = shell.Commands.Get(EditorCommands.SceneView);
        Assert.True(game.IsChecked && scene.IsChecked);

        game.Execute();
        Assert.False(shell.Layout.IsViewportOpen(ViewportDocument.GameId));
        Assert.False(game.IsChecked);
        scene.Execute();
        Assert.False(shell.Layout.IsViewportOpen(ViewportDocument.SceneId));

        // The dock stays, empty, and a document opens in it again.
        Assert.Empty(Assert.Single(DocumentNodes(shell.Layout.Save().Root)).Documents!);
        game.Execute();
        Assert.True(shell.Layout.IsViewportOpen(ViewportDocument.GameId));
        Assert.True(game.IsChecked);
        scene.Execute();
        Assert.True(scene.IsChecked);
        Assert.Equal("scene", ActiveDocumentOf(shell, ViewportDocument.SceneId));
    }

    [Fact]
    public void ShowingADocumentMakesItsTabTheActiveOne()
    {
        using var shell = NewShell(show: false);
        Assert.Equal("scene", ActiveDocumentOf(shell, ViewportDocument.SceneId));

        shell.Layout.ShowViewport(ViewportDocument.GameId);

        Assert.Equal("game", ActiveDocumentOf(shell, ViewportDocument.GameId));
    }

    [Fact]
    public void ALayoutWithSeveralDocumentDocksKeepsEachOnesDocumentsAndItsActiveOne()
    {
        using var shell = NewShell(show: false);
        var root = new SplitNode("dock.main", null, false,
        [
            new DocumentsNode("dock.a", 0.5, ["scene"], "scene"),
            new DocumentsNode("dock.b", 0.5, ["game"], "game"),
        ]);

        Assert.True(shell.Layout.Restore(new LayoutFile(LayoutFile.CurrentVersion, root, [])));

        var saved = DocumentNodes(shell.Layout.Save().Root);
        Assert.Equal([["scene"], ["game"]], saved.Select(n => n.Documents!));
        Assert.Equal(["scene", "game"], saved.Select(n => n.Active));
        Assert.Equal(["dock.a", "dock.b"], saved.Select(n => n.Id));
        // A document that closes opens again beside the other one.
        shell.Layout.CloseViewport(ViewportDocument.GameId);
        shell.Layout.ShowViewport(ViewportDocument.GameId);
        Assert.Equal([["scene", "game"], []], DocumentNodes(shell.Layout.Save().Root).Select(n => n.Documents!));
    }

    [Fact]
    public void ADockWithAllItsDocumentsClosedStaysAndComesBackEmpty()
    {
        using var shell = NewShell(show: false);
        var root = new SplitNode("dock.main", null, false,
        [
            new DocumentsNode("dock.a", 0.5, ["scene"], "scene"),
            new DocumentsNode("dock.b", 0.5, [], null),
        ]);

        Assert.True(shell.Layout.Restore(new LayoutFile(LayoutFile.CurrentVersion, root, [])));

        var saved = DocumentNodes(shell.Layout.Save().Root);
        Assert.Equal(2, saved.Count);
        Assert.Empty(saved[1].Documents!);
        Assert.False(shell.Layout.IsViewportOpen(ViewportDocument.GameId));
    }

    [Fact]
    public void ALayoutFileOfAnEditorWithOneViewportRestoresTheSceneAndTheGame()
    {
        using var shell = NewShell(show: false);
        // The single document dock listed no documents.
        var old = """{"version":1,"root":{"kind":"documents","id":"dock.documents","proportion":0.72},"floating":[]}""";
        var file = LayoutFile.FromJson(old);
        Assert.NotNull(file);
        shell.Layout.CloseViewport(ViewportDocument.GameId);

        Assert.True(shell.Layout.Restore(file));

        var node = Assert.Single(DocumentNodes(shell.Layout.Save().Root));
        Assert.Equal(["scene", "game"], node.Documents);
        Assert.Equal("scene", node.Active);
    }

    [Fact]
    public void ALayoutWithADocumentInTwoDocksKeepsItInTheFirst()
    {
        using var shell = NewShell(show: false);
        var root = new SplitNode("dock.main", null, false,
        [
            new DocumentsNode("dock.a", 0.5, ["scene"], null),
            new DocumentsNode("dock.a", 0.5, ["scene", "game", "viewport.9"], null),
        ]);

        Assert.True(shell.Layout.Restore(new LayoutFile(LayoutFile.CurrentVersion, root, [])));

        var saved = DocumentNodes(shell.Layout.Save().Root);
        Assert.Equal([["scene"], ["game"]], saved.Select(n => n.Documents!));
        Assert.Equal(2, saved.Select(n => n.Id).Distinct().Count());
    }

    [Fact]
    public void TheDocumentsAreKeptAcrossSessions()
    {
        string saved;
        using (var shell = NewShell(show: false))
        {
            shell.Layout.CloseViewport(ViewportDocument.GameId);
            shell.SaveLayout();
            saved = shell.Layout.Save().ToJson();
        }

        using var restored = TestShell.Open(_temp, "box.scene", null);

        Assert.Equal(saved, restored.Layout.Save().ToJson());
        Assert.True(restored.Layout.IsViewportOpen(ViewportDocument.SceneId));
        Assert.False(restored.Layout.IsViewportOpen(ViewportDocument.GameId));
        Assert.DoesNotContain(restored.Console.Lines, l => l.Level >= Model.LogLevel.Warning);
    }

    [Fact]
    public void ResettingTheLayoutPutsTheSceneAndTheGameBack()
    {
        using var shell = NewShell(show: false);
        shell.Layout.CloseViewport(ViewportDocument.GameId);
        shell.Layout.CloseViewport(ViewportDocument.SceneId);

        shell.Layout.Reset();

        Assert.True(shell.Layout.IsViewportOpen(ViewportDocument.SceneId) && shell.Layout.IsViewportOpen(ViewportDocument.GameId));
    }

    [Fact]
    public void AMaterialEditorOpensInTheDockOfTheSceneBeforeTheGame()
    {
        using var shell = NewShell(show: false);
        var root = new SplitNode("dock.main", null, false,
        [
            new DocumentsNode("dock.a", 0.5, ["game"], "game"),
            new DocumentsNode("dock.b", 0.5, ["scene"], "scene"),
        ]);
        Assert.True(shell.Layout.Restore(new LayoutFile(LayoutFile.CurrentVersion, root, [])));

        shell.Layout.OpenDocument(new TestDocument());

        var dock = Assert.IsAssignableFrom<IDock>(FindDock(shell.Layout.Root, "scene"));
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

    static string? ActiveDocumentOf(EditorShell shell, string document) =>
        (FindDock(shell.Layout.Root, document) as IDock)?.ActiveDockable?.Id;

    // --- Input ---

    [Fact]
    public void NoFreeCameraCommandExistsAnymore()
    {
        using var shell = NewShell(show: false);

        Assert.DoesNotContain(shell.Commands.All, c => c.Id.Contains("freeCamera", StringComparison.OrdinalIgnoreCase));
    }

    public void Dispose() => _temp.Dispose();
}
