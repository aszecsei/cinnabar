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
            [.. held], [.. world], shown?.Stamp ?? new ShownPreview(0, 0, 0)));
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
        Values(shell, Pose([0, 0, 0], Quat.Identity), 2, (null, 3, new ShownPreview(ticket, 0, 0)));
        Assert.Equal(KeyState.Keyed, State(shell));
        Assert.Contains("last edit", shell.Keying.StateOf(Door, LightId, Brightness)!.Refusal);

        // The text cooks clean, and the preview plays its blob, where the world shows another value at the playhead.
        var (unsaved, blob) = Cooked(shell, editor);
        Values(shell, Pose([0, 0, 0], Quat.Identity), 2, (null, 3, new ShownPreview(unsaved, 0, blob)));
        Assert.Equal(KeyState.Differs, State(shell));
        Assert.Null(shell.Keying.StateOf(Door, LightId, Brightness)!.Refusal);

        // What the world showed at another time is not the playhead's: the key holds, and a key must wait.
        Values(shell, Pose([0, 0, 0], Quat.Identity), 2, (null, 3, new ShownPreview(unsaved, 2000, blob)));
        Assert.Equal(KeyState.Keyed, State(shell));
        Assert.NotNull(shell.Keying.StateOf(Door, LightId, Brightness)!.Refusal);

        // An edit that has not cooked yet is not what the world shows either.
        Values(shell, Pose([0, 0, 0], Quat.Identity), 2, (null, 3, new ShownPreview(unsaved, 0, blob)));
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
        Values(shell, Pose([0, 0, 0], Quat.Identity), 2, (null, 3, new ShownPreview(ticket, 0, 0)));

        editor.SetPlayhead(2000);
        var before = editor.Document.Text;
        shell.Keying.Key(Door, LightId, Brightness);
        Assert.Equal(before, editor.Document.Text);
        Assert.Contains("Waiting", shell.Keying.StateOf(Door, LightId, Brightness)!.Refusal);

        Values(shell, Pose([0, 0, 0], Quat.Identity), 2, (null, 4, new ShownPreview(ticket, 2000, 0)));
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
        Values(shell, Pose([1, 0, 0], own), 2, (Pose([1 + moved.X, moved.Y, moved.Z], own * Yaw(30), 2), null, new ShownPreview(ticket, 0, 0)));

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
    public void AnEntityThatNoBindingPossessesHasNoKeyButton()
    {
        var (shell, _, _) = NewShell(Cutscene.Replace("0000000000000001", "0000000000000002"));
        using var __ = shell;

        Assert.Null(shell.Keying.BindingOf(Door));
        Assert.Null(shell.Keying.StateOf(Door, LightId, Brightness));
        Assert.NotNull(shell.Keying.KeyTransformRefusal());
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

        // An entity that no binding possesses has no button.
        editor.Document.Edit("Unbind", f => f.Find("binding:1")!.Set("possess", $"@{SceneGuid}/0000000000000002"));
        Assert.DoesNotContain(content.GetLogicalDescendants().OfType<Button>(), b => b.ContextMenu != null && b.ContextMenu == Name().ContextMenu);
    });

    [Fact]
    public void PastTheRangeTheWorldHoldsItsEndAndAKeyTakesIt()
    {
        var (shell, editor, ticket) = NewShell(rangeEnd: 300000);
        using var _ = shell;
        editor.SetPlayhead(400000);
        Values(shell, Pose([0, 0, 0], Quat.Identity), 2, (null, 3, new ShownPreview(ticket, 300000, 0)));

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
        Assert.Equal("K", shell.KeyBindings.ShortcutOf(EditorCommands.CutsceneShuttlePause));
        Assert.Empty(shell.KeyBindings.Warnings);
    }
}
