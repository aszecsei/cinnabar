using System.Buffers.Binary;
using System.Text;
using Avalonia.Controls;
using Avalonia.LogicalTree;
using Cinnabar.Editor.Docking;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using Asset = Cinnabar.Editor.Link.Cook.Asset;
using Root = Cinnabar.Editor.Link.Cook.Root;
using Welcome = Cinnabar.Editor.Link.Cook.Welcome;

namespace Cinnabar.Editor.Tests;

/// <summary>Keys from the inspector and the viewport into the cutscene that holds the preview (see docs/editor/cutscene-editor.md#keying).</summary>
public sealed class KeyingTests : IDisposable
{
    const string SceneGuid = "5ce5ce5ce5ce5ce5ce5ce5ce5ce5ce51";
    const string CutsceneGuid = "0123456789abcdef0123456789abcdef";
    const string SceneText = "scene 1\n\nentity 0000000000000001\nname = \"Door\"\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n";
    const ulong Door = 1UL << 32;
    const ulong LightId = 160;

    // 30 fps, so a frame is 2000 ticks.
    const string Cutscene = $"cutscene 1\nlength = 600000\nrate = 30\n\nbinding 1 \"Door\"\n\tpossess = @{SceneGuid}/0000000000000001\n";

    static readonly ComponentType Transform = new(SceneEdits.TransformId, "Transform", "Transform", 52,
    [
        Field("position", 0, FieldKind.Position),
        Field("rotation", 24, FieldKind.Quaternion),
        Field("scale", 40, FieldKind.Vector3),
    ]);

    static readonly ComponentType Light = new(LightId, "Light", "Lights", 4, [Field("brightness", 0, FieldKind.F32)]);

    static FieldInfo Field(string name, uint offset, FieldKind kind) => new(name, offset, kind, kind, [], false, false, 0, 0, false, false, 0, "");

    static FieldInfo Brightness => Light.Fields[0];

    readonly TempDirectory _temp = new("keying");
    readonly List<ILinkMessage> _sent = [];

    public void Dispose() => _temp.Dispose();

    // A linked shell in Edit with the door scene and a cutscene that binds the door, whose preview is open at tick 0.
    (EditorShell Shell, CutsceneEditor Editor, ulong Ticket) NewShell(string cutscene = Cutscene, ComponentType? transform = null, int rangeEnd = 600000)
    {
        Directory.CreateDirectory(_temp.Path);
        File.WriteAllText(_temp.Combine("door.scene"), SceneText);
        var options = new EditorOptions("host.exe", "game.dll", _temp.Combine("door.scene")) { AutosaveDirectory = _temp.Combine("autosave") };
        var shell = new EditorShell(options with { Cook = options.Cook with { CachePath = _temp.Combine("cache") } }, new EditorSettings(_temp.Combine("settings")));
        File.WriteAllText(_temp.Combine("door.cutscene"), cutscene);
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [], [], []));
        shell.Assets.Apply(new AssetSnapshot(
        [
            TestAssets.Make(SceneGuid, AssetKind.Scene, "door.scene"),
            TestAssets.Make(CutsceneGuid, AssetKind.Cutscene, "door.cutscene"),
        ], []));
        shell.Host.LinkForTests(_sent.Add);
        shell.OnGameMessage(new ComponentTypes([transform ?? Transform, Light]));
        shell.OnGameMessage(new EntitySnapshot([new EntityInfo(Door, "Door", 1, 1, 0, true, [SceneEdits.TransformId, LightId])]));
        var editor = shell.OpenCutscene(shell.Assets.Find(CutsceneGuid)!)!;
        var ticket = _sent.OfType<CutscenePreviewOpen>().Last().Ticket;
        shell.OnGameMessage(new CutscenePreviewOpened(ticket, 0, 0, rangeEnd));
        Values(shell, Pose([0, 0, 0], Quat.Identity), 2);
        _sent.Clear();
        return (shell, editor, ticket);
    }

    static byte[] Pose(double[] meters, Quat rotation, float scale = 1)
    {
        var bytes = new byte[52];
        for (var i = 0; i < 3; i++)
        {
            BinaryPrimitives.WriteInt64LittleEndian(bytes.AsSpan(i * 8), (long)Math.Round(meters[i] * (1 << 24)));
            BinaryPrimitives.WriteSingleLittleEndian(bytes.AsSpan(40 + i * 4), scale);
        }
        double[] q = [rotation.X, rotation.Y, rotation.Z, rotation.W];
        for (var i = 0; i < 4; i++)
        {
            BinaryPrimitives.WriteSingleLittleEndian(bytes.AsSpan(24 + i * 4), (float)q[i]);
        }
        return bytes;
    }

    static byte[] Lamp(float brightness)
    {
        var bytes = new byte[4];
        BinaryPrimitives.WriteSingleLittleEndian(bytes, brightness);
        return bytes;
    }

    static ulong Hash(string name) => Fnv.Hash64(Encoding.UTF8.GetBytes(name));

    static Quat Yaw(double degrees) => Vec(FieldValues.Quaternion(0, degrees, 0));

    static Quat Vec(double[] q) => new(q[0], q[1], q[2], q[3]);

    // The door's values: the document's pose and brightness, and with a stamp, what the world shows of each that the
    // preview holds.
    static void Values(EditorShell shell, byte[] pose, float brightness, (byte[]? Pose, float? Brightness, ShownPreview Stamp)? shown = null)
    {
        var held = new List<HeldField>();
        var world = new List<ComponentValue>();
        if (shown is { } s)
        {
            if (s.Pose != null)
            {
                held.AddRange(new[] { "position", "rotation", "scale" }.Select(f => new HeldField(SceneEdits.TransformId, Hash(f))));
            }
            if (s.Brightness != null)
            {
                held.Add(new HeldField(LightId, Hash("brightness")));
            }
            world.Add(new ComponentValue(SceneEdits.TransformId, s.Pose ?? pose));
            world.Add(new ComponentValue(LightId, Lamp(s.Brightness ?? brightness)));
        }
        shell.OnGameMessage(new EntityValues(Door, [new ComponentValue(SceneEdits.TransformId, pose), new ComponentValue(LightId, Lamp(brightness))], [],
            [.. held], [.. world], shown?.Stamp ?? new ShownPreview(0, 0, 0, 0)));
    }

    static KeyState? State(EditorShell shell) => shell.Keying.StateOf(Door, LightId, Brightness)?.State;

    [Fact]
    public void TheKeyButtonShowsNoTrackATrackAKeyAndAValueThatDiffers()
    {
        var (shell, editor, ticket) = NewShell();
        using var _ = shell;
        var target = new KeyTarget.Property(1, LightId, "brightness", PropertyShape.Number);

        Assert.Equal(KeyState.None, State(shell));
        shell.Keying.AddTrack(Door, LightId, Brightness);
        Assert.Equal(KeyState.Track, State(shell));
        Assert.Equal("Add Track", editor.Document.History[^1]);

        // Nothing holds the field yet, so the key is the document's value.
        shell.Keying.Key(Door, LightId, Brightness);
        Assert.Equal(KeyState.Keyed, State(shell));
        Assert.Equal([2.0], CutsceneKeying.KeysAt(editor.File, target, 0));
        Assert.Contains("\t\t\tkey 0 2 auto", editor.Document.Text.Split('\n'));

        // The world shows the saved cutscene, not the key: the key holds until the preview plays the edit.
        Values(shell, Pose([0, 0, 0], Quat.Identity), 2, (null, 3, new ShownPreview(ticket, 0, 0, 0)));
        Assert.Equal(KeyState.Keyed, State(shell));
        Assert.Contains("last edit", shell.Keying.StateOf(Door, LightId, Brightness)!.Refusal);

        // The text cooks clean, and the preview plays its blob, where the world shows another value at the playhead.
        var (unsaved, blob) = Cooked(shell, editor);
        Values(shell, Pose([0, 0, 0], Quat.Identity), 2, (null, 3, new ShownPreview(unsaved, 0, blob, 0)));
        Assert.Equal(KeyState.Differs, State(shell));
        Assert.Null(shell.Keying.StateOf(Door, LightId, Brightness)!.Refusal);

        // What the world showed at another time is not the playhead's: the key holds, and a key must wait.
        Values(shell, Pose([0, 0, 0], Quat.Identity), 2, (null, 3, new ShownPreview(unsaved, 2000, blob, 0)));
        Assert.Equal(KeyState.Keyed, State(shell));
        Assert.NotNull(shell.Keying.StateOf(Door, LightId, Brightness)!.Refusal);

        // An edit that has not cooked yet is not what the world shows either.
        Values(shell, Pose([0, 0, 0], Quat.Identity), 2, (null, 3, new ShownPreview(unsaved, 0, blob, 0)));
        editor.Document.Edit("Rename", f => f.Find("track:1")!.SetName("Glow"));
        Assert.Contains("last edit", shell.Keying.StateOf(Door, LightId, Brightness)!.Refusal);
        var before = editor.Document.Text;
        shell.Keying.Key(Door, LightId, Brightness);
        Assert.Equal(before, editor.Document.Text);
    }

    // The daemon cooks the tab's text clean into the preview area, and the preview plays it: the unsaved session's
    // ticket, and the blob's file time.
    (ulong Ticket, long Blob) Cooked(EditorShell shell, CutsceneEditor editor)
    {
        var path = _temp.Combine("cache", "preview", CutsceneGuid + ".blob");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, [1]);
        _sent.Clear();
        editor.ShowProblems(editor.Document.Text, new PreviewResult("", [], []));
        var ticket = _sent.OfType<CutscenePreviewOpen>().Single(o => o.Unsaved).Ticket;
        shell.OnGameMessage(new CutscenePreviewOpened(ticket, 0, 0, 600000));
        _sent.Clear();
        return (ticket, (File.GetLastWriteTimeUtc(path) - DateTime.UnixEpoch).Ticks * 100);
    }

    [Fact]
    public void AKeyWaitsForTheWorldToShowThePlayheadAndNotWhileThePreviewPlays()
    {
        var (shell, editor, ticket) = NewShell();
        using var _ = shell;
        var target = new KeyTarget.Property(1, LightId, "brightness", PropertyShape.Number);
        Values(shell, Pose([0, 0, 0], Quat.Identity), 2, (null, 3, new ShownPreview(ticket, 0, 0, 0)));

        editor.SetPlayhead(2000);
        var before = editor.Document.Text;
        shell.Keying.Key(Door, LightId, Brightness);
        Assert.Equal(before, editor.Document.Text);
        Assert.Contains("Waiting", shell.Keying.StateOf(Door, LightId, Brightness)!.Refusal);

        Values(shell, Pose([0, 0, 0], Quat.Identity), 2, (null, 4, new ShownPreview(ticket, 2000, 0, 0)));
        shell.Keying.Key(Door, LightId, Brightness);
        Assert.Equal([4.0], CutsceneKeying.KeysAt(editor.File, target, 2000));

        shell.OnGameMessage(new CutscenePreviewTick(ticket, 2000, true));
        shell.CutscenePreview.PlayPause();
        Assert.Contains("Pause", shell.Keying.StateOf(Door, LightId, Brightness)!.Refusal);
    }

    [Fact]
    public void KeyTransformFromTheViewportIsOneEntryThatUndoTakesBack()
    {
        var (shell, editor, ticket) = NewShell();
        using var _ = shell;
        shell.Selection.Select(Door);
        shell.Layout.ShowViewport(ViewportDocument.SceneId);
        Assert.Null(shell.ActiveGraphEditor);
        var original = editor.Document.Text;
        // The door stands at 1 m, turned 90° about y. The preview shows it 2 m on along its own x, turned 30° more.
        var own = Yaw(90);
        var moved = own.Rotate(new Vec3(2, 0, 0));
        Values(shell, Pose([1, 0, 0], own), 2, (Pose([1 + moved.X, moved.Y, moved.Z], own * Yaw(30), 2), null, new ShownPreview(ticket, 0, 0, 0)));

        shell.Commands.Get(EditorCommands.CutsceneKeyTransform).Execute();

        var file = editor.File;
        var position = CutsceneKeying.KeysAt(file, new KeyTarget.Pose(1, PosePart.Position), 0);
        Assert.Equal([2.0, 0, 0], position.Select(v => Math.Round(v!.Value, 4)));
        var rotation = CutsceneKeying.KeysAt(file, new KeyTarget.Pose(1, PosePart.Rotation), 0);
        Assert.Equal([0.0, 30, 0], rotation.Select(v => Math.Round(v!.Value, 3)));
        Assert.Equal([2.0, 2, 2], CutsceneKeying.KeysAt(file, new KeyTarget.Pose(1, PosePart.Scale), 0).Select(v => v!.Value));
        Assert.Single(editor.Document.History);
        Assert.False(shell.Scene!.IsDirty);
        Assert.Empty(shell.Scene.History);
        // The keys are on the curve: the button says so.
        Assert.Equal(KeyState.Keyed, shell.Keying.StateOf(Door, SceneEdits.TransformId, Transform.Fields[1])!.State);

        // Undo, from the viewport, takes the key back in one step, and Redo puts it back.
        shell.Commands.Get(EditorCommands.Undo).Execute();
        Assert.Equal(original, editor.Document.Text);
        Assert.Empty(shell.Scene.History);
        shell.Commands.Get(EditorCommands.Redo).Execute();
        Assert.NotEqual(original, editor.Document.Text);

        // A scene edit after it is what Undo takes back next.
        Assert.True(shell.Edit("Rename", new Rename(1, "Gate")));
        Assert.Same(UndoTarget.Scene.Instance, shell.LastEdited);
        shell.Commands.Get(EditorCommands.Undo).Execute();
        Assert.False(shell.Scene.CanUndo);
        Assert.NotEqual(original, editor.Document.Text);
    }

    [Fact]
    public void ClosingTheKeyedCutscenesTabGivesUndoBackToTheScene()
    {
        var (shell, editor, ticket) = NewShell();
        using var _ = shell;
        shell.Selection.Select(Door);
        Values(shell, Pose([0, 0, 0], Quat.Identity), 2);
        shell.Commands.Get(EditorCommands.CutsceneKeyTransform).Execute();
        Assert.Equal(new UndoTarget.Cutscene(editor), shell.LastEdited);

        shell.CloseGraph(editor, discard: true);

        Assert.Same(UndoTarget.Scene.Instance, shell.LastEdited);
        Assert.Null(shell.UndoEditor);
    }

    [Fact]
    public void ACutsceneThatGivesThePreviewAwayIsNotWhatUndoFollowsWhenItTakesItBack()
    {
        var (shell, editor, _) = NewShell();
        using var __ = shell;
        shell.Selection.Select(Door);
        shell.Commands.Get(EditorCommands.CutsceneKeyTransform).Execute();
        File.WriteAllText(_temp.Combine("other.cutscene"), Cutscene);
        shell.Assets.Apply(new AssetSnapshot(
        [
            TestAssets.Make(SceneGuid, AssetKind.Scene, "door.scene"),
            TestAssets.Make(CutsceneGuid, AssetKind.Cutscene, "door.cutscene"),
            TestAssets.Make("fedcba9876543210fedcba9876543210", AssetKind.Cutscene, "other.cutscene"),
        ], []));

        var other = shell.OpenCutscene(shell.Assets.Find("fedcba9876543210fedcba9876543210")!)!;
        shell.CutscenePreview.Take(other);
        Assert.Same(other, shell.CutscenePreview.Owner);
        Assert.Same(UndoTarget.Scene.Instance, shell.LastEdited);
        shell.CutscenePreview.Take(editor);

        Assert.Same(editor, shell.CutscenePreview.Owner);
        Assert.Same(UndoTarget.Scene.Instance, shell.LastEdited);
    }

    [Fact]
    public void KeyTrackedFieldsKeysThePropertyTracksAndThePosePartsTheTransformTrackHas()
    {
        var text = Cutscene + "track 1 transform \"Transform\"\n\tbinding = 1\n\tsection 1 0 600000\n\t\tchannel position_x\n\t\t\tkey 0 0 auto\n"
            + "track 2 property \"Brightness\"\n\tbinding = 1\n\tcomponent = 160\n\tfield = \"brightness\"\n";
        var (shell, editor, _) = NewShell(text);
        using var __ = shell;
        shell.Selection.Select(Door);
        Values(shell, Pose([0, 0, 0], Quat.Identity), 5);

        shell.Commands.Get(EditorCommands.CutsceneKeyTrackedFields).Execute();

        var file = editor.File;
        Assert.Equal([5.0], CutsceneKeying.KeysAt(file, new KeyTarget.Property(1, LightId, "brightness", PropertyShape.Number), 30000 * 0));
        Assert.Equal(["position_x", "position_y", "position_z"], file.Find("section:1")!.Children.Select(c => c.Name));
        Assert.Single(editor.Document.History);
        Assert.Equal("Key Tracked Fields", editor.Document.History[0]);
    }

    [Fact]
    public void AKeyOfAnEntityThatNoBindingPossessesAsksToPossessItAndKeysItInOneEntry()
    {
        var (shell, editor, _) = NewShell(Cutscene.Replace("0000000000000001", "0000000000000002"));
        using var __ = shell;
        var original = editor.Document.Text;
        var asked = new List<IReadOnlyList<string>>();
        var answer = false;
        shell.Keying.AskPossess = (names, cutscene) =>
        {
            asked.Add(names);
            Assert.Equal("door", cutscene);
            return Task.FromResult(answer);
        };

        Assert.Null(shell.Keying.BindingOf(Door));
        var state = shell.Keying.StateOf(Door, LightId, Brightness)!;
        Assert.Equal(KeyState.None, state.State);
        Assert.Null(state.Refusal);
        Assert.Contains("possess", state.Tip);

        // No: nothing changes.
        shell.Keying.Key(Door, LightId, Brightness);
        Assert.Equal(["Door"], Assert.Single(asked));
        Assert.Equal(original, editor.Document.Text);

        // Yes: the binding, its track and the key are one entry.
        answer = true;
        shell.Keying.Key(Door, LightId, Brightness);
        Assert.Equal(["Possess and Key"], editor.Document.History);
        Assert.Equal(2, shell.Keying.BindingOf(Door));
        var lines = editor.Document.Text.Split('\n');
        Assert.Contains("binding 2 \"Door 2\"", lines);
        Assert.Contains($"\tpossess = @{SceneGuid}/0000000000000001", lines);
        Assert.Equal([2.0], CutsceneKeying.KeysAt(editor.File, new KeyTarget.Property(2, LightId, "brightness", PropertyShape.Number), 0));
        Assert.Equal(KeyState.Keyed, State(shell));
    }

    [Fact]
    public void KeyTransformAsksToPossessTheSelectionThatNoBindingHas()
    {
        var (shell, editor, _) = NewShell(Cutscene.Replace("0000000000000001", "0000000000000002"));
        using var __ = shell;
        shell.Selection.Select(Door);
        shell.Keying.AskPossess = (_, _) => Task.FromResult(true);

        Assert.Null(shell.Keying.KeyTransformRefusal());
        shell.Commands.Get(EditorCommands.CutsceneKeyTransform).Execute();

        Assert.Equal(["Possess and Key Transform"], editor.Document.History);
        Assert.Equal([0.0, 0, 0], CutsceneKeying.KeysAt(editor.File, new KeyTarget.Pose(2, PosePart.Position), 0).Select(v => v!.Value));
    }

    [Fact]
    public void AutoKeyAsksOnceToPossessAnEntityAndANoSendsItsEditsToTheScene()
    {
        var (shell, editor, _) = NewShell(Cutscene.Replace("0000000000000001", "0000000000000002"));
        using var __ = shell;
        shell.Keying.AutoKey = true;
        shell.Keying.AutoKeyAddTracks = true;
        var asked = 0;
        shell.Keying.AskPossess = (_, _) =>
        {
            asked++;
            return Task.FromResult(false);
        };

        Assert.IsType<FieldRoute.Refused>(shell.Keying.Route([Door], LightId, Brightness));
        Assert.Equal(1, asked);
        Assert.IsType<FieldRoute.Scene>(shell.Keying.Route([Door], LightId, Brightness));
        Assert.Equal(1, asked);

        // With a yes, the binding comes as an entry of its own, and the next edit keys.
        var (other, otherEditor, _) = NewShell(Cutscene.Replace("0000000000000001", "0000000000000002"));
        using var ___ = other;
        other.Keying.AutoKey = true;
        other.Keying.AutoKeyAddTracks = true;
        other.Keying.AskPossess = (_, _) => Task.FromResult(true);
        Assert.IsType<FieldRoute.Refused>(other.Keying.Route([Door], LightId, Brightness));
        Assert.Equal(["Possess Door"], otherEditor.Document.History);
        Assert.IsType<FieldRoute.Key>(other.Keying.Route([Door], LightId, Brightness));
        Assert.Empty(editor.Document.History);
    }

    [Fact]
    public void ThePropertiesPanelShowsTheKeyButtonsStateAsThePlayheadMoves() => Ui.Run(() =>
    {
        // The Transform's own fields would need a window for their drags' cursor, so it shows only a flag here.
        var (shell, editor, _) = NewShell(transform: new ComponentType(SceneEdits.TransformId, "Transform", "Transform", 52, [Field("frozen", 51, FieldKind.Bool)]));
        using var __ = shell;
        shell.Selection.Select(Door);
        var view = new PropertiesView(shell);
        view.Subscriptions.Attach();
        var content = (StackPanel)view.Content!;
        TextBlock Name() => content.GetLogicalDescendants().OfType<TextBlock>().Single(t => t.Classes.Contains("field-name") && t.Text == "Brightness");
        Button Key() => content.GetLogicalDescendants().OfType<Button>().Single(b => b.ContextMenu != null && b.ContextMenu == Name().ContextMenu);
        var button = Key();
        Assert.Contains("key-none", button.Classes);

        // A click keys the field; the same button shows it, as the panel did not build again.
        button.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        Assert.Same(button, Key());
        Assert.Contains("key-keyed", button.Classes);
        editor.SetPlayhead(4000);
        Assert.Same(button, Key());
        Assert.Contains("key-track", button.Classes);

        // The menu's items act as the state lets them.
        var items = Name().ContextMenu!.Items.OfType<MenuItem>().ToDictionary(i => (string)i.Header!);
        Assert.Equal(["Add Track", "Key", "Remove Key", "Go to Track"], items.Keys);
        Assert.Equal((false, true, false, true), (items["Add Track"].IsEnabled, items["Key"].IsEnabled, items["Remove Key"].IsEnabled, items["Go to Track"].IsEnabled));
        editor.SetPlayhead(0);
        Assert.True(items["Remove Key"].IsEnabled);
        items["Remove Key"].Command!.Execute(null);
        Assert.Contains("key-track", button.Classes);

        // Go to Track shows the cutscene's tab with the track selected.
        shell.Layout.ShowViewport(ViewportDocument.SceneId);
        items["Go to Track"].Command!.Execute(null);
        Assert.Same(editor, shell.ActiveGraphEditor);
        Assert.Equal("track:1", editor.Selection);

        // An entity that no binding possesses has an empty button, which offers to possess it.
        editor.Document.Edit("Unbind", f => f.Find("binding:1")!.Set("possess", $"@{SceneGuid}/0000000000000002"));
        Assert.Contains("key-none", Key().Classes);
        Assert.Contains("possess", (string)ToolTip.GetTip(Key())!);
    });

    [Fact]
    public void PastTheRangeTheWorldHoldsItsEndAndAKeyTakesIt()
    {
        var (shell, editor, ticket) = NewShell(rangeEnd: 300000);
        using var _ = shell;
        editor.SetPlayhead(400000);
        Values(shell, Pose([0, 0, 0], Quat.Identity), 2, (null, 3, new ShownPreview(ticket, 300000, 0, 0)));

        Assert.Null(shell.Keying.StateOf(Door, LightId, Brightness)!.Refusal);
        shell.Keying.Key(Door, LightId, Brightness);

        Assert.Equal([3.0], CutsceneKeying.KeysAt(editor.File, new KeyTarget.Property(1, LightId, "brightness", PropertyShape.Number), 400000));
    }

    [Fact]
    public void AnAbsoluteTracksFirstKeySetsItsOriginInWholeMetersNearTheEntity()
    {
        var (shell, editor, _) = NewShell(Cutscene + "track 1 transform \"Path\"\n\tbinding = 1\n\tspace = absolute\n");
        using var __ = shell;
        shell.Selection.Select(Door);
        Values(shell, Pose([1_000_002.25, 1, -2.6], Yaw(45)), 2);

        shell.Commands.Get(EditorCommands.CutsceneKeyTransform).Execute();

        var file = editor.File;
        Assert.Equal("[1000002, 1, -3]", file.Find("track:1")!.Get("origin"));
        Assert.Equal([0.25, 0, 0.4], CutsceneKeying.KeysAt(file, new KeyTarget.Pose(1, PosePart.Position), 0).Select(v => Math.Round(v!.Value, 4)));
        Assert.Equal([0.0, 45, 0], CutsceneKeying.KeysAt(file, new KeyTarget.Pose(1, PosePart.Rotation), 0).Select(v => Math.Round(v!.Value, 3)));
    }

    [Fact]
    public void PoseKeysTurnTheShortWayAndCompareRotationsAsRotations()
    {
        // 190° is -170°, which turns the short way from a key at 170°; a channel with no key keeps its angle.
        Assert.Equal([190.0, -10, 5], PoseKeys.Unwrap([-170, 350, 5], [170, 0, null]));
        Assert.True(PoseKeys.SameRotation([0, 360, 0], [0, 0, 0]));
        Assert.True(PoseKeys.SameRotation([10, null, 0], [10, 99, 360]));
        Assert.False(PoseKeys.SameRotation([0, 30, 0], [0, 31, 0]));
        Assert.Equal([1.5, 0, -2], PoseKeys.AbsolutePosition([(long)(11.5 * (1 << 24)), 0, -(2L << 24)], [10L << 24, 0, 0]));
        var (meters, units) = PoseKeys.OriginNear([(long)(2.6 * (1 << 24)), -(long)(1.4 * (1 << 24)), 100]);
        Assert.Equal([3L, -1, 0], meters);
        Assert.Equal([3L << 24, -(1L << 24), 0], units);
        // In a relative track, a step along the own turned x is a step along the key's x.
        Assert.Equal([2.0, 0, 0], PoseKeys.RelativePosition(Yaw(90).Rotate(new Vec3(2, 0, 0)), Yaw(90)).Select(v => Math.Round(v, 6)));
        Assert.Equal([0.0, 30, 0], PoseKeys.RelativeRotation(Yaw(90), Yaw(90) * Yaw(30)).Select(v => Math.Round(v, 4)));
    }

    [Fact]
    public void TheKeyCommandsHaveTheirOwnKeys()
    {
        using var shell = TestShell.Open(_temp, "door.scene", SceneText);

        Assert.Equal("Ctrl+K", shell.KeyBindings.ShortcutOf(EditorCommands.CutsceneKeyTransform));
        Assert.Equal("Ctrl+Shift+K", shell.KeyBindings.ShortcutOf(EditorCommands.CutsceneKeyTrackedFields));
        Assert.Equal("Alt+K", shell.KeyBindings.ShortcutOf(EditorCommands.CutsceneAutoKey));
        Assert.Equal("Alt+Shift+K", shell.KeyBindings.ShortcutOf(EditorCommands.CutsceneAutoKeyAddTracks));
        Assert.Equal("Enter", shell.KeyBindings.ShortcutOf(EditorCommands.CutsceneKeyPreviewValues));
        Assert.Equal("K", shell.KeyBindings.ShortcutOf(EditorCommands.CutsceneShuttlePause));
        Assert.Empty(shell.KeyBindings.Warnings);
    }

    // The cutscene with the door's brightness keyed at 2 at 0 s, as a held field.
    const string Glowing = Cutscene + "track 1 property \"Brightness\"\n\tbinding = 1\n\tcomponent = 160\n\tfield = \"brightness\"\n"
        + "\tsection 1 0 600000\n\t\tchannel value\n\t\t\tkey 0 2 auto\n";

    // A field editor of the door's brightness, as the properties panel makes it, with what the world shows.
    static FieldEditor BrightnessEditor(EditorShell shell, double shown)
    {
        var editor = FieldEditor.ForComponent(shell, 1, LightId, Brightness)!;
        editor.Sink = shell.Keying.Sink(new Dictionary<ulong, ulong> { [1] = Door }, LightId, Brightness);
        editor.Current = SceneEdits.Floats(shown);
        return editor;
    }

    [Fact]
    public void WithAutoKeyAFieldDragOfABoundEntityIsOneKeyAndTheSceneStaysClean()
    {
        var (shell, editor, _) = NewShell();
        using var _ = shell;
        shell.Commands.Get(EditorCommands.CutsceneAutoKey).Execute();
        shell.Commands.Get(EditorCommands.CutsceneAutoKeyAddTracks).Execute();
        Assert.True(shell.Keying.AutoKeyShows);
        var field = BrightnessEditor(shell, 2);
        Assert.IsType<FieldRoute.Key>(field.Sink!.Route);

        field.BeginScrub(-1);
        field.SetNumbers([3]);
        field.SetNumbers([5]);
        // The drag's steps show over the preview at once, as the cutscene does not cook them.
        var shown = _sent.OfType<CutscenePreviewValues>().Last();
        Assert.Equal(5.0, Assert.Single(shown.Fields).Value.Floats[0]);
        field.EndScrub();

        var target = new KeyTarget.Property(1, LightId, "brightness", PropertyShape.Number);
        Assert.Equal([5.0], CutsceneKeying.KeysAt(editor.File, target, 0));
        Assert.Equal(["Drag Brightness"], editor.Document.History);
        Assert.False(shell.Scene!.IsDirty);
        Assert.Empty(shell.Scene.History);
        Assert.Equal(new UndoTarget.Cutscene(editor), shell.LastEdited);
        // The values stay until the preview shows the key.
        Assert.IsType<PreviewValuesState.Settling>(shell.PreviewValues.State);

        // A typed value keys too, in one entry.
        Assert.True(field.Commit(0, "7"));
        Assert.Equal([7.0], CutsceneKeying.KeysAt(editor.File, target, 0));
        Assert.Equal(2, editor.Document.History.Count);
        Assert.Empty(shell.Scene.History);
    }

    [Fact]
    public void WithoutAutoKeyAHeldFieldsEditShowsOverThePreviewUntilAScrubDropsItOrEnterKeysIt()
    {
        var (shell, editor, ticket) = NewShell(Glowing);
        using var _ = shell;
        var target = new KeyTarget.Property(1, LightId, "brightness", PropertyShape.Number);
        // The preview holds the brightness, at its key's value; the document's is 1.
        Values(shell, Pose([0, 0, 0], Quat.Identity), 1, (null, 2, new ShownPreview(ticket, 0, 0, 0)));
        Assert.Equal(new byte[] { 0, 0, 0, 64 }, shell.Keying.ShownComponent(Door, LightId));
        var field = BrightnessEditor(shell, 2);
        Assert.IsType<FieldRoute.Preview>(field.Sink!.Route);
        var original = editor.Document.Text;

        Assert.True(field.Commit(0, "6"));
        var values = _sent.OfType<CutscenePreviewValues>().Last();
        Assert.Equal((ticket, 0), (values.Ticket, values.Tick));
        Assert.Equal(6.0, Assert.Single(values.Fields).Value.Floats[0]);
        Assert.Equal(original, editor.Document.Text);
        Assert.Empty(shell.Scene!.History);
        // The world shows the value: the button says it differs from the key, and the row shows it.
        Values(shell, Pose([0, 0, 0], Quat.Identity), 1, (null, 6, new ShownPreview(ticket, 0, 0, values.Serial)));
        Assert.Equal(KeyState.Differs, State(shell));
        Assert.Equal(6f, BinaryPrimitives.ReadSingleLittleEndian(shell.Keying.ShownComponent(Door, LightId)));

        // A scrub away drops it: the game hears that, and nothing was written.
        editor.SetPlayhead(2000);
        var cleared = _sent.OfType<CutscenePreviewValues>().Last();
        Assert.Empty(cleared.Fields);
        Assert.Empty(cleared.Transforms);
        Assert.IsType<PreviewValuesState.Empty>(shell.PreviewValues.State);
        Assert.Equal(original, editor.Document.Text);
        Assert.Empty(shell.Scene.History);
        Assert.False(shell.Scene.IsDirty);

        // Back at the key, a new value waits for Enter, which keys it as one entry.
        editor.SetPlayhead(0);
        shell.CutscenePreview.Flush();
        Values(shell, Pose([0, 0, 0], Quat.Identity), 1, (null, 2, new ShownPreview(ticket, 0, 0, 0)));
        Assert.True(field.Commit(0, "4"));
        var key = shell.Commands.Get(EditorCommands.CutsceneKeyPreviewValues);
        Assert.True(key.CanExecute);
        key.Execute();
        Assert.Equal([4.0], CutsceneKeying.KeysAt(editor.File, target, 0));
        Assert.Equal(["Key Preview Values"], editor.Document.History);
        Assert.IsType<PreviewValuesState.Settling>(shell.PreviewValues.State);
        Assert.Empty(shell.Scene.History);
    }

    [Fact]
    public void AHeldFieldNeverGoesToTheScene()
    {
        var (shell, editor, ticket) = NewShell(Glowing);
        using var _ = shell;
        var field = BrightnessEditor(shell, 2);
        // Nothing holds it yet, so it is the scene's, as before.
        Assert.IsType<FieldRoute.Scene>(field.Sink!.Route);

        // While the preview plays, an edit of a held field goes nowhere, and says why.
        Values(shell, Pose([0, 0, 0], Quat.Identity), 1, (null, 2, new ShownPreview(ticket, 0, 0, 0)));
        shell.CutscenePreview.PlayPause();
        Assert.Contains("Pause", Assert.IsType<FieldRoute.Refused>(field.Sink.Route).Why);
        Assert.False(field.Commit(0, "6"));
        Assert.Empty(shell.Scene!.History);
        Assert.Empty(_sent.OfType<CutscenePreviewValues>());

        // Paused at another time, it waits for the world to show the playhead.
        shell.CutscenePreview.PlayPause();
        editor.SetPlayhead(4000);
        Assert.Contains("Waiting", Assert.IsType<FieldRoute.Refused>(field.Sink.Route).Why);

        // With auto-key on, a field with no track and no add tracks is the scene's.
        shell.Keying.AutoKey = true;
        var other = FieldEditor.ForComponent(shell, 1, SceneEdits.TransformId, Transform.Fields[2])!;
        Assert.IsType<FieldRoute.Scene>(shell.Keying.Route([Door], SceneEdits.TransformId, Transform.Fields[2]));
        Assert.NotNull(other);
    }

    [Fact]
    public void WithAutoKeyAGizmoDragIsOneKeyAndEscTakesItBack()
    {
        var (shell, editor, _) = NewShell();
        using var _ = shell;
        shell.Keying.AutoKey = true;
        shell.Keying.AutoKeyAddTracks = true;
        shell.Selection.Select(Door);
        shell.Viewports[0].Session.Show(new Avalonia.PixelSize(1600, 900));
        shell.Camera.Place([0, 0, -(5L << 24)], 0, 0);
        Assert.IsType<FieldRoute.Key>(shell.Keying.PoseRoute([Door]));
        var (width, height) = shell.FrameSize;
        var (pivot, _) = shell.GizmoPose()!.Value;
        var center = shell.Camera.RelativeTo(pivot);
        var size = Tools.Gizmo.Size(shell.Camera, center, height);
        Vec2 Along(double meters) => shell.Camera.Project(center + Vec3.UnitX * meters, width, height)!.Value;

        Assert.True(shell.PressGizmo(Along(0.5 * size)));
        shell.DragGizmo(Along(0.5 * size + 0.3), invertSnap: false);
        shell.DragGizmo(Along(0.5 * size + 0.6), invertSnap: false);
        // The drag shows over the preview as it goes, and the gizmo goes with it.
        Assert.Single(_sent.OfType<CutscenePreviewValues>().Last().Transforms);
        Assert.InRange(shell.GizmoPose()!.Value.Pivot[0], (long)(0.59 * (1 << 24)), (long)(0.61 * (1 << 24)));
        shell.ReleaseGizmo();

        Assert.Equal(["Move Door"], editor.Document.History);
        var x = CutsceneKeying.KeysAt(editor.File, new KeyTarget.Pose(1, PosePart.Position), 0)[0]!.Value;
        Assert.InRange(x, 0.59, 0.61);
        Assert.Empty(shell.Scene!.History);
        Assert.False(shell.Scene.IsDirty);
        Assert.Equal(new UndoTarget.Cutscene(editor), shell.LastEdited);

        // Esc during a drag leaves no entry, and the values as they were.
        var before = shell.PreviewValues.State;
        var text = editor.Document.Text;
        Assert.True(shell.PressGizmo(Along(0.5 * size + 0.6)));
        shell.DragGizmo(Along(0.5 * size + 1.2), invertSnap: false);
        shell.CancelGizmo();
        Assert.Equal(text, editor.Document.Text);
        Assert.Single(editor.Document.History);
        Assert.False(shell.IsDraggingGizmo);
        Assert.Equal(before.GetType(), shell.PreviewValues.State.GetType());
        Assert.Equal(KeyValuesOf(shell.PreviewValues.ComponentOf(Door, SceneEdits.TransformId)), KeyValuesOf((before as PreviewValuesState.Live)?.Components[(Door, SceneEdits.TransformId)]));
        Assert.Empty(shell.Scene.History);
    }

    static long[]? KeyValuesOf(byte[]? transform) => transform == null ? null : KeyValues.Units(Transform.Fields[0], transform);

    [Fact]
    public void SeveralSelectedEntitiesShareOneKeyButtonThatKeysThemAllInOneEntry()
    {
        const ulong gate = 2UL << 32;
        var (shell, editor, _) = NewShell(Cutscene + $"binding 2 \"Gate\"\n\tpossess = @{SceneGuid}/0000000000000002\n");
        using var _ = shell;
        shell.OnGameMessage(new EntitySnapshot(
        [
            new EntityInfo(Door, "Door", 1, 1, 0, true, [SceneEdits.TransformId, LightId]),
            new EntityInfo(gate, "Gate", 2, 1, 0, true, [SceneEdits.TransformId, LightId]),
        ]));
        shell.OnGameMessage(new EntityValues(gate, [new ComponentValue(SceneEdits.TransformId, Pose([0, 0, 0], Quat.Identity)), new ComponentValue(LightId, Lamp(5))], [],
            [], [], new ShownPreview(0, 0, 0, 0)));
        Values(shell, Pose([0, 0, 0], Quat.Identity), 2);
        ulong[] both = [Door, gate];

        Assert.Equal(KeyState.None, shell.Keying.StateOf(both, LightId, Brightness)!.State);
        shell.Keying.Key(both, LightId, Brightness);
        Assert.Equal(["Key Brightness"], editor.Document.History);
        Assert.Equal([2.0], CutsceneKeying.KeysAt(editor.File, new KeyTarget.Property(1, LightId, "brightness", PropertyShape.Number), 0));
        Assert.Equal([5.0], CutsceneKeying.KeysAt(editor.File, new KeyTarget.Property(2, LightId, "brightness", PropertyShape.Number), 0));
        Assert.Equal(KeyState.Keyed, shell.Keying.StateOf(both, LightId, Brightness)!.State);

        // When they differ, the button shows a track, and says so.
        shell.Keying.RemoveKey(Door, LightId, Brightness);
        var mixed = shell.Keying.StateOf(both, LightId, Brightness)!;
        Assert.Equal(KeyState.Track, mixed.State);
        Assert.Contains("differ", mixed.Tip);
        shell.Keying.RemoveKey(both, LightId, Brightness);
        Assert.Equal(KeyState.Track, shell.Keying.StateOf(both, LightId, Brightness)!.State);
        Assert.Equal("Remove Key", editor.Document.History[^1]);
    }
}
