using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using Asset = Cinnabar.Editor.Link.Cook.Asset;
using Root = Cinnabar.Editor.Link.Cook.Root;
using Welcome = Cinnabar.Editor.Link.Cook.Welcome;

namespace Cinnabar.Editor.Tests;

/// <summary>A cutscene's cameras in the scene views (see docs/editor/cutscene-editor.md#cameras).</summary>
public sealed class CutsceneCameraTests : IDisposable
{
    const string Intro = "0123456789abcdef0123456789abcdef";
    const string Fox = "fedcba9876543210fedcba9876543210";
    const string SceneText = "scene 1\n\nentity 0000000000000001\nname = \"Door\"\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n";

    readonly TempDirectory _temp = new("cutscene-cameras");
    readonly List<ILinkMessage> _sent = [];

    public void Dispose() => _temp.Dispose();

    // A linked shell in Edit with the intro cutscene open and its preview open, with what was sent so far forgotten.
    (EditorShell Shell, CutsceneEditor Editor, ulong Ticket) NewShell()
    {
        var shell = TestShell.Open(_temp, "door.scene", SceneText);
        File.WriteAllText(_temp.Combine("intro.cutscene"), CutsceneFileTests.Sample("intro").ReplaceLineEndings("\n"));
        File.WriteAllText(_temp.Combine("fox_walk.cutscene"), CutsceneFileTests.Sample("fox_walk").ReplaceLineEndings("\n"));
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [], [], []));
        shell.Assets.Apply(new AssetSnapshot([Make(Intro, "intro"), Make(Fox, "fox_walk")], []));
        shell.Host.LinkForTests(_sent.Add);
        _sent.Clear();
        var editor = shell.OpenCutscene(shell.Assets.Find(Intro)!)!;
        var ticket = Answer(shell);
        return (shell, editor, ticket);
    }

    static Asset Make(string guid, string name) => TestAssets.Make(guid, AssetKind.Cutscene, name + ".cutscene");

    // Answers the last Open, and forgets what was sent.
    ulong Answer(EditorShell shell)
    {
        var ticket = _sent.OfType<CutscenePreviewOpen>().Last().Ticket;
        shell.OnGameMessage(new CutscenePreviewOpened(ticket, 0, 0, 600000));
        _sent.Clear();
        return ticket;
    }

    static ViewportLookShown Shown(ViewportLook look, uint binding, bool camera = true) =>
        new(look.Viewport, look.Serial, camera, binding, [1L << 24, 2L << 24, 3L << 24], [0, 0, 0, 1], 0.6f, 50, [36, 24]);

    [Fact]
    public void TheCutsCamerasAreTheCutscenesCameraBindings()
    {
        var (shell, editor, _) = NewShell();
        using var _ = shell;

        Assert.Equal([(3, "Wide Shot"), (4, "Close Shot"), (5, "Tracking Shot")], editor.CameraBindings());
        Assert.False(editor.IsCamera(editor.File.Bindings.First(b => b.Id == 1)));
    }

    [Fact]
    public void LookingThroughTheCutsTellsTheGameOnceForEachSessionAndTakesOnlyItsOwnAnswer()
    {
        var (shell, editor, ticket) = NewShell();
        using var _ = shell;

        editor.LookThroughCuts();

        var look = Assert.Single(_sent.OfType<ViewportLook>());
        Assert.Equal((0u, ticket, ViewportLookSource.Cuts), (look.Viewport, look.Ticket, look.Source));
        var cuts = Assert.IsType<ViewLook.Cuts>(shell.Looks[0]);
        Assert.Null(cuts.Shown);

        // An answer to another look does nothing; the look's own is its answer.
        shell.OnGameMessage(Shown(look with { Serial = look.Serial - 1 }, 3));
        Assert.Null(Assert.IsType<ViewLook.Cuts>(shell.Looks[0]).Shown);
        shell.OnGameMessage(Shown(look, 3));
        Assert.True(Assert.IsType<ViewLook.Cuts>(shell.Looks[0]).Drawn);

        // A new session of the same tab hears the same look, with its ticket.
        _sent.Clear();
        editor.ShowProblems(editor.Document.Text, new PreviewResult("", [], []));
        var reopened = _sent.OfType<CutscenePreviewOpen>().Last();
        var again = Assert.Single(_sent.OfType<ViewportLook>());
        Assert.Equal((look.Serial, reopened.Ticket, ViewportLookSource.Cuts), (again.Serial, again.Ticket, again.Source));
        Assert.Null(Assert.IsType<ViewLook.Cuts>(shell.Looks[0]).Shown);
    }

    [Fact]
    public void ALookThroughABindingTogglesAndEndsWhenAnotherTabTakesThePreview()
    {
        var (shell, editor, ticket) = NewShell();
        using var _ = shell;

        editor.ToggleLookThrough(4);
        var look = Assert.Single(_sent.OfType<ViewportLook>());
        Assert.Equal((ViewportLookSource.Binding, 4u, ticket), (look.Source, look.Binding, look.Ticket));
        Assert.True(editor.LooksThrough(4));
        Assert.Equal(0, shell.Looks.ViewThrough(editor, 4));

        // Again on the same binding gives the view its own camera back, and the game hears it.
        _sent.Clear();
        editor.ToggleLookThrough(4);
        var back = Assert.Single(_sent.OfType<ViewportLook>());
        Assert.Equal(ViewportLookSource.EditorCamera, back.Source);
        Assert.True(back.Serial > look.Serial);
        Assert.IsType<ViewLook.Editor>(shell.Looks[0]);

        // Another tab that takes the preview ends the look.
        editor.ToggleLookThrough(3);
        var fox = shell.OpenCutscene(shell.Assets.Find(Fox)!)!;
        shell.CutscenePreview.Take(fox);
        Assert.IsType<ViewLook.Editor>(shell.Looks[0]);
    }

    [Fact]
    public void TheLookCommandsActOnTheSelectedCameraBindingAndTheActiveView()
    {
        var (shell, editor, _) = NewShell();
        using var _ = shell;
        var look = shell.Commands.Get(EditorCommands.CutsceneLookThrough);
        var editorCamera = shell.Commands.Get(EditorCommands.CutsceneEditorCamera);

        editor.Select(editor.File.Bindings.First(b => b.Id == 1));
        Assert.False(look.CanExecute);
        editor.Select(editor.File.Bindings.First(b => b.Id == 5));
        Assert.True(look.CanExecute);
        Assert.False(editorCamera.CanExecute);

        look.Execute();
        Assert.True(look.IsChecked);
        Assert.Equal(5, Assert.IsType<ViewLook.Camera>(shell.Looks[0]).Binding);
        editorCamera.Execute();
        Assert.IsType<ViewLook.Editor>(shell.Looks[0]);

        shell.Commands.Get(EditorCommands.CutsceneLookThroughCuts).Execute();
        Assert.IsType<ViewLook.Cuts>(shell.Looks[0]);
    }

    [Fact]
    public void TheGuidesAreEachViewsAndViewportJsonKeepsThem()
    {
        var (shell, _, _) = NewShell();
        using var _ = shell;

        shell.Commands.Get(EditorCommands.SafeAreas).Execute();
        shell.SetGuides(shell.Viewports[1], shell.Viewports[1].Guides with { Mask = true, Aspect = GuideAspect.Custom, Custom = 2.2 });

        Assert.True(shell.SettingsViewport.Guides.Safe);
        Assert.False(shell.Viewports[1].Guides.Safe);
        Assert.True(shell.Commands.Get(EditorCommands.SafeAreas).IsChecked);
        var json = shell.Settings.Read(EditorSettings.ViewportFileName)!;
        Assert.Contains("\"Guides\"", json);
        Assert.Contains("2.2", json);
    }
}
