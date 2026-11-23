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
        Assert.Equal((reopened.Ticket, ViewportLookSource.Cuts), (again.Ticket, again.Source));
        // A new serial for the new session, so the game takes it over the last.
        Assert.True(again.Serial > look.Serial);
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

        // At the length a cut would show nothing, so none is added.
        Assert.False(CutsceneEdits.AddCut(editor.File, 720000, 6));

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
    public void AFrameDuringAGestureTakesTheGestureBackWithItsLook()
    {
        var (shell, editor, _) = NewShell();
        using var _ = shell;
        PilotWideShot(shell, editor);
        shell.Keying.AutoKey = true;
        var history = editor.Document.History.Count;

        shell.Looks.BeginGesture(0);
        shell.Looks.Move(0, c => c.Pan(40, 0, 1080));
        Assert.True(editor.Document.InTransaction);
        shell.FrameScene();

        Assert.IsType<ViewLook.Editor>(shell.Looks[0]);
        Assert.False(editor.Document.InTransaction);
        Assert.Equal(history, editor.Document.History.Count);
        Assert.IsType<PreviewValuesState.Empty>(shell.PreviewValues.State);
        // The release that follows does nothing, and a new camera can be made.
        shell.Looks.EndGesture(0, cancel: false);
        Assert.Null(editor.NewCameraRefusal(shell.Viewports[0]));
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

    // The world's Cinematic_Camera, as the game describes it, so values over the preview can name its fields.
    static void LensType(EditorShell shell)
    {
        static FieldInfo Field(string name, uint offset, FieldKind kind) => new(name, offset, kind, kind, [], false, false, 0, 0, false, false, 0, "");
        shell.OnGameMessage(new ComponentTypes([new ComponentType(Panels.CinematicCameraText.CinematicCameraId, "Cinematic_Camera", "Rendering", 40,
        [
            Field("focal_length", 0, FieldKind.F32),
            Field("sensor_width", 4, FieldKind.F32),
            Field("sensor_height", 8, FieldKind.F32),
            Field("focus_distance", 12, FieldKind.F32),
            Field("aperture", 16, FieldKind.F32),
            Field("focus", 24, FieldKind.Entity),
            Field("focus_offset", 32, FieldKind.F32),
        ])]));
    }

    static KeyTarget LensKey(int binding, string field) =>
        new KeyTarget.Property(binding, Panels.CinematicCameraText.CinematicCameraId, field, PropertyShape.Number);

    // A spawned camera of the engine's prefab, made from the first scene view at the playhead: binding 6.
    static int NewCamera(EditorShell shell, CutsceneEditor editor, int tick = 300000)
    {
        LensType(shell);
        editor.SetPlayhead(tick);
        shell.CutscenePreview.Flush();
        var id = editor.NewCameraFromView(shell.Viewports[0]);
        Assert.Equal(6, id);
        return id!.Value;
    }

    [Fact]
    public void ASpawnedCamerasLensShowsItsKeyOrItsPrefabsValueAndATypedValueHoldsUntilEnterKeysIt()
    {
        var (shell, editor, ticket) = NewShell();
        using var _ = shell;
        var camera = NewCamera(shell, editor);
        Assert.IsType<LensTarget.Spawned>(editor.LensTargetOf(camera));
        // The binding of a character has no lens.
        Assert.IsType<LensTarget.Refused>(editor.LensTargetOf(1));

        // The focal length is keyed; the sensor is the prefab's, and the aperture is the default.
        Assert.Equal(20.78, editor.LensValue(camera, "focal_length")!.Value, 2);
        Assert.Equal(24, editor.LensValue(camera, "sensor_height"));
        Assert.Equal(0, editor.LensValue(camera, "aperture"));
        Assert.Equal(KeyState.Keyed, editor.LensKey(camera, "focal_length")!.State);
        Assert.Equal(KeyState.None, editor.LensKey(camera, "aperture")!.State);

        // Without auto-key, a typed aperture holds over the preview, by the binding's ID, and the text stays.
        var text = editor.Document.Text;
        _sent.Clear();
        Assert.Null(editor.SetLens(camera, [("aperture", 2.8)], "Set Aperture"));
        Assert.Equal(text, editor.Document.Text);
        Assert.IsType<PreviewValuesState.Holding>(shell.PreviewValues.State);
        Assert.Equal(2.8, editor.LensValue(camera, "aperture")!.Value, 5);
        var values = _sent.OfType<CutscenePreviewValues>().Last();
        Assert.Equal(ticket, values.Ticket);
        var field = Assert.Single(values.Fields);
        Assert.Equal((OverrideTargetKind.Binding, (ulong)camera, Panels.CinematicCameraText.CinematicCameraId),
            (field.Target.Kind, field.Target.Entity, field.Component));

        // Enter keys it at the playhead.
        Assert.Null(shell.Keying.KeyPreviewValuesRefusal());
        shell.Commands.Get(EditorCommands.CutsceneKeyPreviewValues).Execute();
        Assert.Equal("Key Preview Values", editor.Document.History[^1]);
        Assert.Equal(2.8, Assert.Single(CutsceneKeying.KeysAt(editor.File, LensKey(camera, "aperture"), 300000))!.Value, 5);
        Assert.IsType<PreviewValuesState.Settling>(shell.PreviewValues.State);
    }

    [Fact]
    public void WithAutoKeyALensScrubIsOneKeyAndOneEntryAndACancelPutsItBack()
    {
        var (shell, editor, _) = NewShell();
        using var _ = shell;
        var camera = NewCamera(shell, editor);
        shell.Keying.AutoKey = true;
        var history = editor.Document.History.Count;

        var drag = editor.BeginLensDrag(camera, "focal_length", "Drag Focal Length", out var why);
        Assert.Null(why);
        Assert.True(drag!.Step(30));
        Assert.True(drag.Step(40));
        Assert.Equal(40, editor.LensValue(camera, "focal_length")!.Value, 4);
        drag.End(cancel: false);

        Assert.Equal(history + 1, editor.Document.History.Count);
        Assert.Equal("Drag Focal Length", editor.Document.History[^1]);
        Assert.Equal(40, Assert.Single(CutsceneKeying.KeysAt(editor.File, LensKey(camera, "focal_length"), 300000))!.Value, 4);

        // A cancelled drag leaves no entry, and the key and the value are as they were.
        var again = editor.BeginLensDrag(camera, "focal_length", "Drag Focal Length", out var _)!;
        again.Step(85);
        again.End(cancel: true);
        Assert.Equal(history + 1, editor.Document.History.Count);
        Assert.Equal(40, Assert.Single(CutsceneKeying.KeysAt(editor.File, LensKey(camera, "focal_length"), 300000))!.Value, 4);
        Assert.Equal(40, editor.LensValue(camera, "focal_length")!.Value, 4);
    }

    [Fact]
    public void WithoutAutoKeyALensScrubHoldsItsValueAndNeedsTheTabsPreview()
    {
        var (shell, editor, _) = NewShell();
        using var _ = shell;
        var camera = NewCamera(shell, editor);
        var text = editor.Document.Text;

        var drag = editor.BeginLensDrag(camera, "focus_distance", "Drag Focus", out var _)!;
        drag.Step(3.5);
        drag.End(cancel: false);
        Assert.Equal(text, editor.Document.Text);
        Assert.Equal(3.5, editor.LensValue(camera, "focus_distance")!.Value, 4);

        // While another tab holds the preview, a value cannot hold, and the drag says why.
        var fox = shell.OpenCutscene(shell.Assets.Find(Fox)!)!;
        shell.CutscenePreview.Take(fox);
        Assert.Null(editor.BeginLensDrag(camera, "focus_distance", "Drag Focus", out var why));
        Assert.NotNull(why);
    }

    // Looks the first scene view through a camera, and answers with a pose.
    ViewLook.Camera LookThrough(EditorShell shell, CutsceneEditor editor, int binding)
    {
        editor.ToggleLookThrough(binding);
        var look = _sent.OfType<ViewportLook>().Last();
        shell.OnGameMessage(new ViewportLookShown(0, look.Serial, true, (uint)binding, WideShot, [0, 0, 0, 1], (float)Lens.VerticalFov(35, 24), 35, [36, 24]));
        _sent.Clear();
        return Assert.IsType<ViewLook.Camera>(shell.Looks[0]);
    }

    [Fact]
    public void PickFocusSetsTheFocusDistanceToThePickedDepthAndKeysItWithAutoKey()
    {
        var (shell, editor, _) = NewShell();
        using var _ = shell;
        var camera = NewCamera(shell, editor);
        LookThrough(shell, editor, camera);
        shell.Keying.AutoKey = true;
        shell.Keying.AutoKeyAddTracks = true;
        var history = editor.Document.History.Count;

        // Ctrl+click in the looking view picks there, in that view.
        shell.ClickInLook(0, new Vec2(64, 32), SelectMode.Toggle, control: true);
        var pick = Assert.Single(_sent.OfType<PickRequest>());
        Assert.Equal((0u, 64, 32, 1, 1), (pick.Viewport, pick.X, pick.Y, pick.Width, pick.Height));
        shell.OnGameMessage(new PickResult(pick.Id, [], 4.25f, 0));

        Assert.Equal(history + 1, editor.Document.History.Count);
        Assert.Equal("Pick Focus", editor.Document.History[^1]);
        Assert.Equal(4.25, Assert.Single(CutsceneKeying.KeysAt(editor.File, LensKey(camera, "focus_distance"), 300000))!.Value, 4);

        // Nothing under the pointer sets nothing.
        _sent.Clear();
        Assert.True(editor.PickFocus(0, new Vec2(1, 1)));
        shell.OnGameMessage(new PickResult(_sent.OfType<PickRequest>().Single().Id, [], 0, 0));
        Assert.Equal(history + 1, editor.Document.History.Count);

        // An answer that comes after the look ended sets nothing.
        _sent.Clear();
        Assert.True(editor.PickFocus(0, new Vec2(1, 1)));
        var stale = _sent.OfType<PickRequest>().Single();
        shell.Looks.LookThroughEditor(0);
        shell.OnGameMessage(new PickResult(stale.Id, [], 9, 0));
        Assert.Equal(history + 1, editor.Document.History.Count);
    }

    [Fact]
    public void AnArmedPickTakesTheNextClickAndEscDisarmsIt()
    {
        var (shell, editor, _) = NewShell();
        using var _ = shell;
        var camera = NewCamera(shell, editor);
        LookThrough(shell, editor, camera);

        var command = shell.Commands.Get(EditorCommands.CutscenePickFocus);
        Assert.True(command.CanExecute);
        command.Execute();
        Assert.Equal(camera, editor.FocusArmed);
        Assert.True(editor.PicksFocusOnClick(0));

        // Esc disarms it.
        Assert.True(shell.CancelFocusPick(0));
        Assert.Null(editor.FocusArmed);
        Assert.False(shell.CancelFocusPick(0));

        // Armed again, a plain click picks focus, and without auto-key the value holds.
        command.Execute();
        shell.ClickInLook(0, new Vec2(5, 5), SelectMode.Replace, control: false);
        Assert.Null(editor.FocusArmed);
        shell.OnGameMessage(new PickResult(_sent.OfType<PickRequest>().Last().Id, [], 2.5f, 0));
        Assert.Equal(2.5, editor.LensValue(camera, "focus_distance")!.Value, 4);
        Assert.IsType<PreviewValuesState.Holding>(shell.PreviewValues.State);
    }

    [Fact]
    public void FocusOnSetsTheBindingsConstraintAndThenPickFocusIsRefused()
    {
        var (shell, editor, _) = NewShell();
        using var _ = shell;
        var camera = NewCamera(shell, editor);
        LookThrough(shell, editor, camera);
        Assert.Null(editor.PickFocusRefusal(0));

        editor.SetFocusOn(camera, 1);
        Assert.Equal("Focus On", editor.Document.History[^1]);
        Assert.Equal("1", editor.File.Bindings.Single(b => b.Id == camera).Get("focus"));
        Assert.Equal(1, editor.FocusedOn(camera));
        Assert.NotNull(editor.PickFocusRefusal(0));
        Assert.False(editor.PickFocus(0, new Vec2(1, 1)));
        Assert.Empty(_sent.OfType<PickRequest>());

        editor.SetFocusOn(camera, null);
        Assert.Null(editor.File.Bindings.Single(b => b.Id == camera).Get("focus"));
        Assert.Null(editor.PickFocusRefusal(0));
    }

    [Fact]
    public void TheCutTrackNamesEachCutUpToTheNextAndItsHoverSaysWhereItIs()
    {
        static CutsceneVisibleBar Bar(double x0, double x1, string label, int start, int end) =>
            new(x0, x1, new CutsceneTimelineItem(CutsceneItemKind.Section, start, end, $"s{start}") { Label = label });

        // A short cut followed by a gap names its camera past its end; a name with too little room is left out.
        var names = CutsceneTimelineLayout.CutNames([Bar(-20, 8, "Wide", 0, 1000), Bar(10, 12, "Close", 1000, 2000), Bar(20, 60, "Over", 2000, 3000),
            Bar(200, 400, "Tracking", 3000, 4000)], 300);
        Assert.Equal([(20.0, 174.0, "Over"), (200.0, 94.0, "Tracking")], names);

        Assert.Equal("Wide Shot · 00:01:00–00:02:12 (00:01:12)",
            Cutscenes.CutsceneTimelineInput.CutTip(new CutsceneTimelineItem(CutsceneItemKind.Section, 60000, 150000, "s") { Label = "Wide Shot" }, 24));
    }

    [Fact]
    public void KeyingOneHeldValueLeavesAnotherThatIsNotKeyedHeld()
    {
        var (shell, editor, _) = NewShell();
        using var _ = shell;
        var camera = NewCamera(shell, editor);
        Assert.Null(editor.SetLens(camera, [("aperture", 2.8)], "Set Aperture"));

        // Auto-key keys only a field that has a track: the focal length. The aperture, which has none, stays held.
        shell.Keying.AutoKey = true;
        Assert.Null(editor.SetLens(camera, [("focal_length", 50)], "Set Focal Length"));
        Assert.Equal(50, Assert.Single(CutsceneKeying.KeysAt(editor.File, LensKey(camera, "focal_length"), 300000))!.Value, 4);
        Assert.IsType<PreviewValuesState.Holding>(shell.PreviewValues.State);
        Assert.NotNull(shell.PreviewValues.BindingValueOf(camera, Panels.CinematicCameraText.CinematicCameraId, "aperture"));
    }

    [Fact]
    public void AFocusPickWaitsForTheViewToDrawThroughTheCamera()
    {
        var (shell, editor, _) = NewShell();
        using var _ = shell;
        var camera = NewCamera(shell, editor);
        editor.ToggleLookThrough(camera);

        // The game has not drawn the view through the camera yet, so a pick would hit what the editor camera sees.
        Assert.NotNull(editor.PickFocusRefusal(0));
        Assert.NotNull(editor.ArmFocusPick(camera));
        Assert.Null(editor.FocusArmed);

        var look = _sent.OfType<ViewportLook>().Last();
        shell.OnGameMessage(new ViewportLookShown(0, look.Serial, true, (uint)camera, WideShot, [0, 0, 0, 1], (float)Lens.VerticalFov(35, 24), 35, [36, 24]));
        Assert.Null(editor.ArmFocusPick(camera));
        Assert.Equal(camera, editor.FocusArmed);

        // The pick ends with its look.
        shell.Looks.LookThroughEditor(0);
        Assert.Null(editor.FocusArmed);
        Assert.False(editor.PicksFocusOnClick(0));
    }
}
