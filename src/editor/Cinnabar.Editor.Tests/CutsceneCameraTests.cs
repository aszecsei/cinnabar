using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Maths;
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

    // The engine's camera prefab, as lib/engine/content/prefabs/cinematic_camera.prefab has it.
    const string CameraPrefab = """
        scene 3

        entity 1000000000000001
        name = "Cinematic Camera"
        component 1 Transform
        	position = [0, 0, 0]
        	rotation = [0, 0, 0, 1]
        	scale = [1, 1, 1]
        component 32 Camera
        component 160 Cinematic_Camera
        	focal_length = 35
        	sensor_width = 36
        	sensor_height = 24

        """;

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
        File.WriteAllText(_temp.Combine("cinematic_camera.prefab"), CameraPrefab);
        shell.Assets.Apply(new AssetSnapshot([Make(Intro, "intro"), Make(Fox, "fox_walk"),
            TestAssets.Make(CutsceneEditor.EngineCameraPrefab, AssetKind.Prefab, "cinematic_camera.prefab")], []));
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

    // The camera cut track's sections: their spans and cameras.
    static List<(int Start, int End, string? Camera)> Cuts(CutsceneEditor editor) =>
        [.. editor.File.Tracks.Single(t => t.TrackKind == "camera_cut").Children
            .Where(c => c.Kind == CutsceneBlockKind.Section).Select(s => (s.Start!.Value, s.End!.Value, s.Get("camera")))];

    [Fact]
    public void ANewCameraFromAViewIsOneEntryWithItsBindingItsKeysAndACutWhereNoneIs()
    {
        var (shell, editor, _) = NewShell();
        using var _ = shell;
        var view = shell.Viewports[0];
        // 10 m up x, 2 m up y, turned a quarter to the right; the editor camera's 60° is a 20.78 mm lens on 24 mm.
        view.Camera.Place([10L << 24, 2L << 24, 0], Math.PI / 2, 0);
        // After the last cut, which ends at the range's end, so the cut runs to the length.
        editor.SetPlayhead(630000);
        var before = editor.Document.History.Count;

        var command = shell.Commands.Get(EditorCommands.CutsceneNewCameraFromView);
        Assert.True(command.CanExecute);
        command.Execute();

        Assert.Equal(before + 1, editor.Document.History.Count);
        Assert.Equal("New Camera", editor.Document.History[^1]);
        var binding = editor.File.Bindings.Last();
        Assert.Equal(6, binding.Id);
        Assert.Equal("Camera", binding.Name);
        Assert.Equal($"${CutsceneEditor.EngineCameraPrefab}", binding.Get("spawn"));
        Assert.Equal("[10, 2, 0]", binding.Get("position"));
        Assert.Equal("[0, 0.7071067811865476, 0, 0.7071067811865476]", binding.Get("rotation"));
        Assert.Equal($"binding:6", editor.SelectedPaths.Single());

        // A transform track, relative, with no offset at the playhead, and the lens.
        var transform = editor.File.Tracks.Single(t => t.Get("binding") == "6" && t.TrackKind == "transform");
        Assert.Equal([0.0, 0.0, 0.0], CutsceneKeying.KeysAt(editor.File, new KeyTarget.Pose(6, PosePart.Position), 630000));
        Assert.Equal([0.0, 0.0, 0.0], CutsceneKeying.KeysAt(editor.File, new KeyTarget.Pose(6, PosePart.Rotation), 630000));
        Assert.NotNull(transform);
        var focal = CutsceneKeying.KeysAt(editor.File,
            new KeyTarget.Property(6, Panels.CinematicCameraText.CinematicCameraId, "focal_length", PropertyShape.Number), 630000);
        Assert.Equal(20.78, Assert.Single(focal)!.Value, 2);

        // The cut, at the playhead, to the length.
        Assert.Equal((630000, 720000, "6"), Cuts(editor)[^1]);
        Assert.Equal(4, Cuts(editor).Count);

        // Undo takes all of it back.
        shell.Commands.Get("edit.undo").Execute();
        Assert.DoesNotContain(editor.File.Bindings, b => b.Id == 6);
        Assert.Equal(3, editor.File.Tracks.Single(t => t.TrackKind == "camera_cut").Children.Count(c => c.Kind == CutsceneBlockKind.Section));
    }

    [Fact]
    public void ANewCameraUnderACutAddsNoCutAndAnOrthographicViewHasNoLens()
    {
        var (shell, editor, _) = NewShell();
        using var _ = shell;
        editor.SetPlayhead(100000);

        Assert.Equal(6, editor.NewCameraFromView(shell.Viewports[0]));
        Assert.Equal([3, 4, 5], CutsceneEdits.CutCameras(editor.File).Order());

        shell.Viewports[0].Camera.SetProjection(CameraProjection.Orthographic);
        Assert.NotNull(editor.NewCameraRefusal(shell.Viewports[0]));
        Assert.False(shell.Commands.Get(EditorCommands.CutsceneNewCameraFromView).CanExecute);
    }

    [Fact]
    public void ANewCameraFromALookingViewTakesTheDrawnCamerasPoseAndLens()
    {
        var (shell, editor, _) = NewShell();
        using var _ = shell;
        editor.ToggleLookThrough(4);
        var look = _sent.OfType<ViewportLook>().Last();
        shell.OnGameMessage(new ViewportLookShown(0, look.Serial, true, 4, [3L << 24, 1L << 24, 5L << 24], [0, 1, 0, 0],
            (float)Lens.VerticalFov(50, 24), 50, [36, 24]));

        Assert.Equal(6, editor.NewCameraFromView(shell.Viewports[0]));

        var binding = editor.File.Bindings.Last();
        Assert.Equal("[3, 1, 5]", binding.Get("position"));
        var focal = CutsceneKeying.KeysAt(editor.File,
            new KeyTarget.Property(6, Panels.CinematicCameraText.CinematicCameraId, "focal_length", PropertyShape.Number), editor.Playhead);
        Assert.Equal(50, Assert.Single(focal)!.Value, 2);
    }

    // The Wide Shot's pose as the sample's text spawns it, in World_Position units, looking along +z.
    static readonly long[] WideShot = PoseKeys.Units([149999999998, 1.6, -5]);

    // Looks the first scene view through the Wide Shot, and answers with the pose that the world shows.
    ViewLook.Camera PilotWideShot(EditorShell shell, CutsceneEditor editor)
    {
        editor.ToggleLookThrough(3);
        var look = _sent.OfType<ViewportLook>().Last();
        shell.OnGameMessage(new ViewportLookShown(0, look.Serial, true, 3, WideShot, [0, 0, 0, 1], (float)Lens.VerticalFov(35, 24), 35, [36, 24]));
        _sent.Clear();
        return Assert.IsType<ViewLook.Camera>(shell.Looks[0]);
    }

    static Tools.EditorCamera PilotCamera(EditorShell shell) =>
        Assert.IsType<Pilot.Ready>(Assert.IsType<ViewLook.Camera>(shell.Looks[0]).Pilot).Camera;

    [Fact]
    public void APilotStartsAtTheShownPoseAndItsGestureWithAutoKeyIsOneKeyAndOneEntry()
    {
        var (shell, editor, ticket) = NewShell();
        using var _ = shell;
        var camera = PilotWideShot(shell, editor);
        var pilot = PilotCamera(shell);
        Assert.Equal(WideShot, pilot.Position);
        Assert.Equal(0, pilot.Yaw, 9);
        Assert.Equal(0, pilot.Pitch, 9);
        Assert.Equal(Lens.VerticalFov(35, 24), pilot.VerticalFov, 6);
        var editorPose = shell.Viewports[0].Camera.Pose;
        shell.Keying.AutoKey = true;
        editor.SetPlayhead(60000);
        shell.CutscenePreview.Flush();
        var history = editor.Document.History.Count;

        // A right-button flight, through the editor camera's own inputs: 2 m to the right over half a second, and a turn.
        shell.Looks.BeginGesture(0);
        shell.Looks.Move(0, c => c.Fly(new Vec3(1, 0, 0), 0.5, 1));
        shell.Looks.Move(0, c => c.Look(-100, 0));
        // An empty fly step moves nothing and keys nothing.
        shell.Looks.Move(0, c => c.Fly(new Vec3(0, 0, 0), 0.016, 1));
        shell.Looks.EndGesture(0, cancel: false);

        Assert.Equal(history + 1, editor.Document.History.Count);
        Assert.Equal("Pilot Wide Shot", editor.Document.History[^1]);
        var position = CutsceneKeying.KeysAt(editor.File, new KeyTarget.Pose(3, PosePart.Position), 60000);
        Assert.Equal(2, position[0]!.Value, 4);
        Assert.Equal(0, position[1]!.Value, 4);
        Assert.Equal(0, position[2]!.Value, 4);
        var rotation = CutsceneKeying.KeysAt(editor.File, new KeyTarget.Pose(3, PosePart.Rotation), 60000);
        Assert.Equal(PoseKeys.Euler(PilotCamera(shell).Rotation)[1], rotation[1]!.Value, 3);
        Assert.NotEqual(0, rotation[1]!.Value);
        // The world shows the pose at once, by the binding's ID, and the editor camera never moved.
        var values = _sent.OfType<CutscenePreviewValues>().Last();
        Assert.Equal(ticket, values.Ticket);
        var transform = Assert.Single(values.Transforms);
        Assert.Equal((OverrideTargetKind.Binding, 3UL), (transform.Target.Kind, transform.Target.Entity));
        Assert.Equal(PilotCamera(shell).Position, transform.Position);
        Assert.IsType<PreviewValuesState.Settling>(shell.PreviewValues.State);
        Assert.Equal(editorPose, shell.Viewports[0].Camera.Pose);

        // Undo takes the gesture back in one step.
        shell.Commands.Get("edit.undo").Execute();
        Assert.Equal(history, editor.Document.Position);
        Assert.DoesNotContain(editor.File.Tracks, t => t.Get("binding") == "3" && t.TrackKind == "transform");
        Assert.Equal(3, camera.Binding);
    }

    [Fact]
    public void WithoutAutoKeyAPilotsPoseHoldsUntilEnterKeysIt()
    {
        var (shell, editor, _) = NewShell();
        using var _ = shell;
        PilotWideShot(shell, editor);
        var text = editor.Document.Text;

        shell.Looks.BeginGesture(0);
        shell.Looks.Move(0, c => c.Fly(new Vec3(0, 1, 0), 0.25, 1));
        shell.Looks.EndGesture(0, cancel: false);

        Assert.Equal(text, editor.Document.Text);
        Assert.False(editor.Document.IsDirty);
        Assert.NotNull(shell.PreviewValues.PoseOf(3));
        Assert.IsType<PreviewValuesState.Holding>(shell.PreviewValues.State);
        Assert.Null(shell.Keying.KeyPreviewValuesRefusal());

        // Esc leaves the look, and the pose still waits for its key.
        Assert.True(shell.Looks.Escape(0));
        Assert.IsType<ViewLook.Editor>(shell.Looks[0]);
        shell.Commands.Get(EditorCommands.CutsceneKeyPreviewValues).Execute();
        var position = CutsceneKeying.KeysAt(editor.File, new KeyTarget.Pose(3, PosePart.Position), 0);
        Assert.Equal(1, position[1]!.Value, 4);
        Assert.Equal("Key Preview Values", editor.Document.History[^1]);
        Assert.IsType<PreviewValuesState.Settling>(shell.PreviewValues.State);
    }

    [Fact]
    public void EscTakesBackAGestureAndThenGivesTheViewItsOwnCamera()
    {
        var (shell, editor, _) = NewShell();
        using var _ = shell;
        PilotWideShot(shell, editor);
        shell.Keying.AutoKey = true;
        var start = PilotCamera(shell).Pose;
        var editorPose = shell.Viewports[0].Camera.Pose;
        var history = editor.Document.History.Count;

        shell.Looks.BeginGesture(0);
        shell.Looks.Move(0, c => c.Pan(40, 0, 1080));
        Assert.True(editor.Document.InTransaction);
        Assert.True(shell.Looks.Escape(0));

        Assert.False(editor.Document.InTransaction);
        Assert.Equal(history, editor.Document.History.Count);
        Assert.IsType<PreviewValuesState.Empty>(shell.PreviewValues.State);
        Assert.Equal(start, PilotCamera(shell).Pose);
        Assert.IsType<ViewLook.Camera>(shell.Looks[0]);

        Assert.True(shell.Looks.Escape(0));
        Assert.IsType<ViewLook.Editor>(shell.Looks[0]);
        Assert.Equal(editorPose, shell.Viewports[0].Camera.Pose);
        Assert.False(shell.Looks.Escape(0));
    }

    [Fact]
    public void APossessedCameraIsNotPilotedAndFramingGivesTheViewItsOwnCamera()
    {
        var (shell, editor, _) = NewShell();
        using var _ = shell;
        editor.ToggleLookThrough(1);
        var look = _sent.OfType<ViewportLook>().Last();
        shell.OnGameMessage(new ViewportLookShown(0, look.Serial, true, 1, WideShot, [0, 0, 0, 1], 1, 0, [0, 0]));

        var refused = Assert.IsType<Pilot.Refused>(Assert.IsType<ViewLook.Camera>(shell.Looks[0]).Pilot);
        Assert.Contains("spawned", refused.Reason);
        Assert.Equal(refused.Reason, shell.Looks.PilotRefusal(0));
        shell.Looks.BeginGesture(0);
        shell.Looks.Move(0, c => c.Fly(new Vec3(1, 0, 0), 1, 1));
        Assert.Null(shell.PreviewValues.PoseOf(1));

        shell.FrameScene();
        Assert.IsType<ViewLook.Editor>(shell.Looks[0]);
    }
}
