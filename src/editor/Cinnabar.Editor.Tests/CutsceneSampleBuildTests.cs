using System.Globalization;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using Root = Cinnabar.Editor.Link.Cook.Root;
using Welcome = Cinnabar.Editor.Link.Cook.Welcome;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// A designer builds the sample's intro in the editor and never edits its text (see docs/editor/cutscene-editor.md): the
/// test starts from a new cutscene and makes the intro with the editor's commands and the builders that its gestures call,
/// then compares the result with the sample's file.
/// </summary>
public sealed class CutsceneSampleBuildTests : IDisposable
{
    const string SceneGuid = "f496b929575035d9c2626ed56d3165ba";
    const string CutsceneGuid = "0123456789abcdef0123456789abcdef";
    const string FoxWalkGuid = "497bcb7bb533b902877cd8d56fbf97cd";
    const string GuardPrefab = "0d9b84a2116a5529c2cd33741edd33a4";
    const string ShotCameraPrefab = "7fb86acbe194450180b90ee9fb0ecf42";
    const string StonePrefab = "9a2728bfc2e9b1d21ce27d2eb945c856";
    const string WalkClip = "dea303d3f0374a9e56b0bb58f4a85315";
    const string BarkSound = "7ce894b4b95e68b918869459e5cd9c93";
    const string MusicSound = "ac87e25625175689bc0e47ad70107ebe";
    const string LineSound = "cde14b9399a74a289146a8362e6a9a9e";
    const string HudGuid = "bdeaa563d6faa121b2f06fde16f065e5";

    const ulong WalkingFoxId = 0x79cea6d7586e3f48;
    const ulong RunningFoxId = 0x76b64f812f12cecf;
    const ulong WalkingFox = 1UL << 32;
    const ulong RunningFox = 2UL << 32;

    // The scene's entities as the animation scene has them, which the intro possesses by scene link.
    static readonly string SceneText =
        $"scene 1\n\nentity {WalkingFoxId:x16}\nname = \"Walking Fox\"\n\nentity {RunningFoxId:x16}\nname = \"Running Fox\"\n";

    // What a command or a gesture of the editor labels its undo entry with. A raw text edit has no label of its own, so
    // an entry with any other label would be one that the editor did not make.
    static readonly string[] Labels =
    [
        "Add Binding", "Rename", "Add Section", "Add Event", "Rename Event", "Set Event Value", "Set fire_when_skipped",
        "Key Position", "Key Rotation", "Key Focus Distance", "Delete", "Linear", "Move End", "Drag Trim Start", "Drag Trim End",
        "Drag Ease In", "Drag Ease Out", "Drag Length", "Drag Range", "Add Cut", "Add Gain Key", "Add Letterbox", "Add Subtitle",
        "Add Event Range",
    ];

    readonly TempDirectory _temp = new("cutscene-sample-build");
    readonly List<ILinkMessage> _sent = [];

    public void Dispose() => _temp.Dispose();

    // A linked shell on the animation scene, whose two foxes the game has, with the sample's assets in the index and a
    // new cutscene open in its tab, as the content browser's New Cutscene makes one: the daemon writes the template.
    (EditorShell Shell, CutsceneEditor Editor) NewShell()
    {
        Directory.CreateDirectory(_temp.Path);
        File.WriteAllText(_temp.Combine("animation.scene"), SceneText);
        var options = new EditorOptions("host.exe", "game.dll", _temp.Combine("animation.scene")) { AutosaveDirectory = _temp.Combine("autosave") };
        var shell = new EditorShell(options with { Cook = options.Cook with { CachePath = _temp.Combine("cache") } }, new EditorSettings(_temp.Combine("settings")));
        File.WriteAllText(_temp.Combine("intro.cutscene"), CutsceneFileTests.Template);
        File.WriteAllText(_temp.Combine("fox_walk.cutscene"), CutsceneFileTests.Sample("fox_walk").ReplaceLineEndings("\n"));
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [], [], []));
        shell.Assets.Apply(new AssetSnapshot([], []));
        shell.OnAssetCreated(CutsceneGuid, AssetTemplate.Cutscene);
        shell.Assets.Apply(new AssetSnapshot(
        [
            TestAssets.Make(SceneGuid, AssetKind.Scene, "animation.scene"),
            TestAssets.Make(CutsceneGuid, AssetKind.Cutscene, "intro.cutscene"),
            TestAssets.Make(FoxWalkGuid, AssetKind.Cutscene, "fox_walk.cutscene"),
            TestAssets.Make(GuardPrefab, AssetKind.Prefab, "guard.prefab"),
            TestAssets.Make(ShotCameraPrefab, AssetKind.Prefab, "shot_camera.prefab"),
            TestAssets.Make(StonePrefab, AssetKind.Prefab, "stone.prefab"),
            TestAssets.Make(WalkClip, AssetKind.Animation, "fox.gltf", subasset: "fox_walk"),
            TestAssets.Make(BarkSound, AssetKind.Audio, "bark.wav"),
            TestAssets.Make(MusicSound, AssetKind.Audio, "ambience.wav"),
            TestAssets.Make(LineSound, AssetKind.Audio, "line.wav"),
        ], []));
        shell.Host.LinkForTests(_sent.Add);
        shell.OnGameMessage(new ComponentTypes([]));
        shell.OnGameMessage(new EntitySnapshot(
        [
            new EntityInfo(WalkingFox, "Walking Fox", WalkingFoxId, 1, 0, true, []),
            new EntityInfo(RunningFox, "Running Fox", RunningFoxId, 1, 0, true, []),
        ]));
        return (shell, Assert.Single(shell.Cutscenes));
    }

    // Edits that the details panel makes of the selected block, as its rows do: its Add row, a field's box and its ×.

    static string TrackPath(CutsceneEditor editor, string name) => CutsceneFile.PathOf(editor.File.Tracks.Single(t => t.Name == name));

    static string BindingPath(CutsceneEditor editor, string name) => CutsceneFile.PathOf(editor.File.Bindings.Single(b => b.Name == name));

    static string SectionPath(CutsceneEditor editor, string track, int index) =>
        CutsceneFile.PathOf(editor.File.Tracks.Single(t => t.Name == track).Children.Where(c => c.Kind == CutsceneBlockKind.Section).ElementAt(index));

    static void Pick(CutsceneEditor editor, string path)
    {
        editor.Select([path], SelectMode.Replace);
        Assert.Equal(path, editor.Selection);
    }

    static void Rename(CutsceneEditor editor, string path, string name)
    {
        Pick(editor, path);
        editor.EditSelected("Rename", b => b.SetName(name));
    }

    static void Set(CutsceneEditor editor, string path, string key, string value)
    {
        Pick(editor, path);
        editor.EditSelected($"Set {key}", b => b.Set(key, value));
    }

    static void Clear(CutsceneEditor editor, string path, string key)
    {
        Pick(editor, path);
        editor.EditSelected($"Remove {key}", b => b.Set(key, null));
    }

    // The End box of a section's details, which the clip's length leaves a second or a clip's long.
    static void MoveEnd(CutsceneEditor editor, string path, int end)
    {
        Pick(editor, path);
        editor.EditSelected("Move End", b => b.SetSpan(b.Start ?? 0, end));
    }

    // A drag on the timeline, in one step, as its handles make one.
    static void Drag(CutsceneEditor editor, string label, Func<CutsceneFile, IReadOnlyList<string>> edit)
    {
        Assert.True(editor.BeginDrag(label));
        editor.StepDrag(edit);
        editor.EndDrag(cancel: false);
    }

    // A drag of a section's start edge to a time, or of its end edge.
    static void TrimStartTo(CutsceneEditor editor, string path, int to) =>
        Drag(editor, "Drag Trim Start", f => CutsceneEdits.Trim(f, path, CutsceneEdge.Start, to - f.Find(path)!.Start!.Value, false, editor.Locked, editor.ChildStart));

    static void TrimEndTo(CutsceneEditor editor, string path, int to) =>
        Drag(editor, "Drag Trim End", f => CutsceneEdits.Trim(f, path, CutsceneEdge.End, to - f.Find(path)!.End!.Value, false, editor.Locked, editor.ChildStart));

    // A drag of an ease handle to a time on the cutscene's time.
    static void EaseTo(CutsceneEditor editor, string path, CutsceneEdge edge, int at) =>
        Drag(editor, edge == CutsceneEdge.Start ? "Drag Ease In" : "Drag Ease Out", f => CutsceneEdits.SetEaseAt(f, path, edge, at, editor.Locked));

    // The inspector's key button for a transform part: keys the part at a time, adding the track and its section as it
    // needs them, which the playhead and the entity's values decide in the editor.
    static void KeyPose(CutsceneEditor editor, int binding, PosePart part, int tick, double[] values, string track) =>
        editor.Key(part == PosePart.Position ? "Key Position" : "Key Rotation",
            f => CutsceneKeying.SetKeys(f, new KeyTarget.Pose(binding, part), tick, values, track, editor.Locked));

    // The keys that a gesture made in channels it did not mean to, as a key button's three channels make one: Delete on
    // the selected keys, which also removes a channel that loses its last key.
    static void DeleteChannels(CutsceneEditor editor, string section, params string[] channels)
    {
        var block = editor.File.Find(section)!;
        var keys = channels.SelectMany(name => block.Children.Single(c => c.Kind == CutsceneBlockKind.Channel && c.Name == name).Children)
            .Select(CutsceneFile.PathOf).ToList();
        editor.Select(keys, SelectMode.Replace);
        editor.DeleteSelected(ripple: false);
    }

    static void Straighten(CutsceneEditor editor, string section, string channel)
    {
        var block = editor.File.Find(section)!;
        var keys = block.Children.Single(c => c.Kind == CutsceneBlockKind.Channel && c.Name == channel).Children.Select(CutsceneFile.PathOf).ToList();
        editor.Select(keys, SelectMode.Replace);
        editor.SetTangents(TangentMode.Linear);
    }

    // A track that one keyed pose makes: its section runs the length, which a drag of its edges then trims to the sample's.
    static void KeyTrack(CutsceneEditor editor, int binding, string track, int from, int to, (PosePart Part, double[] From, double[] To)[] parts, string[] drop)
    {
        foreach (var (part, a, b) in parts)
        {
            KeyPose(editor, binding, part, from, a, track);
            KeyPose(editor, binding, part, to, b, track);
        }
        var name = editor.File.Tracks.Last(t => t.TrackKind == "transform" && CutsceneEdits.BindingOf(t) == binding).Name!;
        if (name != track)
        {
            Rename(editor, TrackPathOfBinding(editor, binding), track);
        }
        var section = SectionPath(editor, track, 0);
        if (from > 0)
        {
            TrimStartTo(editor, section, from);
        }
        if (to < editor.File.Length)
        {
            TrimEndTo(editor, section, to);
        }
        DeleteChannels(editor, section, drop);
    }

    static string TrackPathOfBinding(CutsceneEditor editor, int binding) =>
        CutsceneFile.PathOf(editor.File.Tracks.Last(t => t.TrackKind == "transform" && CutsceneEdits.BindingOf(t) == binding));

    [Fact]
    public void TheSampleIntroIsBuiltFromCommands()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var template = editor.Document.Text;
        Assert.Equal(CutsceneFileTests.Template, template);
        Assert.Empty(editor.Document.History);

        // The bindings, in the sample's order. The walking fox and the running fox are selected in the viewport and
        // possessed by Add Binding; a prefab picked in Spawn Prefab spawns, and the designer names it.
        var add = shell.Commands.Get(EditorCommands.CutsceneAddBindingSelected);
        shell.Selection.Set([WalkingFox]);
        Assert.True(add.CanExecute);
        add.Execute();
        Set(editor, BindingPath(editor, "Walking Fox"), "policy", "required");

        editor.Spawn([GuardPrefab]);
        Rename(editor, editor.SelectedPaths.Single(), "Extra Guard");
        Set(editor, BindingPath(editor, "Extra Guard"), "position", "[150000000002, 0, 1.5]");
        Set(editor, BindingPath(editor, "Extra Guard"), "rotation", "[0, 0.7071068, 0, 0.7071068]");

        editor.Spawn([ShotCameraPrefab]);
        Rename(editor, editor.SelectedPaths.Single(), "Wide Shot");
        Set(editor, BindingPath(editor, "Wide Shot"), "position", "[149999999998, 1.6, -5]");
        editor.Spawn([ShotCameraPrefab]);
        Rename(editor, editor.SelectedPaths.Single(), "Close Shot");
        Set(editor, BindingPath(editor, "Close Shot"), "position", "[150000000003, 1.2, 2.5]");
        Set(editor, BindingPath(editor, "Close Shot"), "rotation", "[0, 1, 0, 0]");
        editor.Spawn([ShotCameraPrefab]);
        Rename(editor, editor.SelectedPaths.Single(), "Tracking Shot");
        Set(editor, BindingPath(editor, "Tracking Shot"), "position", "[150000000002, 1.2, -3]");

        shell.Selection.Set([RunningFox]);
        add.Execute();
        Set(editor, BindingPath(editor, "Running Fox"), "policy", "optional");

        editor.Spawn([StonePrefab]);
        Rename(editor, editor.SelectedPaths.Single(), "Stone");
        Set(editor, BindingPath(editor, "Stone"), "position", "[150000000002.5, 0.12, 1.2]");
        Set(editor, BindingPath(editor, "Stone"), "scale", "[0.12, 0.12, 0.12]");
        Assert.Equal([1, 2, 3, 4, 5, 6, 7], editor.File.Bindings.Select(b => b.Id!.Value));

        // The three transform tracks, keyed as the key button keys, while the length is still the template's. A key
        // button keys all three channels of a part, so each track keeps the channel that the sample has and deletes the
        // others' keys, which takes their channels too.
        KeyTrack(editor, 1, "Fox walks", 0, 600000, [(PosePart.Position, [0, 0, 0], [4, 0, 0])], ["position_y", "position_z"]);
        Set(editor, TrackPath(editor, "Fox walks"), "when_finished", "keep");
        var walkSection = SectionPath(editor, "Fox walks", 0);
        Straighten(editor, walkSection, "position_x");
        EaseTo(editor, walkSection, CutsceneEdge.Start, 15000);

        KeyTrack(editor, 6, "Fox runs", 0, 600000, [(PosePart.Position, [0, 0, 0], [0, 0, 3])], ["position_x", "position_y"]);
        Straighten(editor, SectionPath(editor, "Fox runs", 0), "position_z");

        KeyTrack(editor, 7, "Stone rolls", 360000, 480000,
            [(PosePart.Position, [0, 0, 0], [1.5, 0, 0]), (PosePart.Rotation, [0, 0, 0], [0, 0, -716])],
            ["position_y", "position_z", "rotation_x", "rotation_y"]);

        // The length handle, then the range bar: the music plays 2 s past the end of the range.
        Drag(editor, "Drag Length", f => { CutsceneEdits.SetLength(f, 720000); return []; });
        Drag(editor, "Drag Range", f => { CutsceneEdits.SetRange(f, 0, 600000); return []; });
        Assert.Equal(720000, editor.File.Length);
        Assert.Equal((0, 600000), CutsceneEdits.RangeOf(editor.File));

        // The header's other settings, in the details of the cutscene.
        var root = CutsceneFile.PathOf(editor.File.Root);
        Set(editor, root, "clock", "game");
        Set(editor, root, "skip_fade", "15000");
        Set(editor, root, "skip_color", "\"#000000\"");
        Set(editor, root, "input_context", "\"cutscene\"");
        Set(editor, root, "hide_ui", $"[${HudGuid}]");

        // Drops from the content browser. The fox's walk clip goes on its binding's row, the bark on the guard's, so it
        // plays where the guard stands, and the fox_walk cutscene on no row, as a sub-sequence.
        editor.DropClips([WalkClip], BindingPath(editor, "Walking Fox"), 0);
        var clipTrack = editor.File.Tracks.Single(t => t.TrackKind == "animation");
        Rename(editor, CutsceneFile.PathOf(clipTrack), "Fox walk clip");
        var clip = SectionPath(editor, "Fox walk clip", 0);
        MoveEnd(editor, clip, 600000);
        EaseTo(editor, clip, CutsceneEdge.Start, 15000);
        EaseTo(editor, clip, CutsceneEdge.End, 585000);
        Set(editor, clip, "loop", "true");
        Set(editor, clip, "root_motion", "in_place");

        editor.DropClips([BarkSound], BindingPath(editor, "Extra Guard"), 360000);
        Rename(editor, CutsceneFile.PathOf(editor.File.Tracks.Single(t => t.TrackKind == "audio")), "Bark");
        var bark = SectionPath(editor, "Bark", 0);
        MoveEnd(editor, bark, 420000);
        Set(editor, bark, "bus", "2");
        Set(editor, bark, "min_distance", "2");
        Set(editor, bark, "max_distance", "30");

        editor.DropClips([FoxWalkGuid], null, 0);
        Rename(editor, CutsceneFile.PathOf(editor.File.Tracks.Single(t => t.TrackKind == "sub_sequence")), "Opening shot");
        var shot = SectionPath(editor, "Opening shot", 0);
        MoveEnd(editor, shot, 300000);
        Set(editor, shot, "bind 1", "1");

        // The music goes on the first audio track of no binding. A second sound dropped on no row goes on that track too,
        // so the dialogue is dropped on the fox's row, which makes it a track of its own, and its details' × takes the
        // binding off the new track: the sample's dialogue track has none.
        editor.DropClips([MusicSound], null, 0);
        var music = editor.File.Tracks.Single(t => t.TrackKind == "audio" && CutsceneEdits.BindingOf(t) == null);
        Rename(editor, CutsceneFile.PathOf(music), "Music");
        var musicSection = SectionPath(editor, "Music", 0);
        MoveEnd(editor, musicSection, 720000);
        EaseTo(editor, musicSection, CutsceneEdge.Start, 60000);
        EaseTo(editor, musicSection, CutsceneEdge.End, 600000);
        Set(editor, musicSection, "bus", "1");
        Set(editor, musicSection, "loop", "true");
        Set(editor, musicSection, "plays_through_skip", "true");
        // Its gain, keyed with Add Gain Key at the playhead on the selected section, and each key's value and
        // interpolation typed in its details.
        foreach (var (tick, value) in new[] { (0, "0.6"), (200000, "1"), (400000, "0.8") })
        {
            editor.SetPlayhead(tick);
            Pick(editor, musicSection);
            Assert.Null(editor.AddGainKeyRefusal());
            editor.AddGainKey();
            var gain = editor.File.Find(musicSection)!.Children.Single(c => c.Kind == CutsceneBlockKind.Channel && c.Name == "gain");
            Pick(editor, CutsceneFile.PathOf(gain.Children.Single(k => k.Start == tick)));
            editor.EditSelected("Set Key Value", b => b.SetKeyValue(value));
            editor.EditSelected("Set Interpolation", b => b.SetKeyInterpolation("auto"));
        }

        editor.DropClips([LineSound], BindingPath(editor, "Walking Fox"), 30000);
        var dialogue = editor.File.Tracks.Single(t => t.TrackKind == "audio" && CutsceneEdits.BindingOf(t) == 1);
        Rename(editor, CutsceneFile.PathOf(dialogue), "Dialogue");
        Clear(editor, TrackPath(editor, "Dialogue"), "binding");
        var line = SectionPath(editor, "Dialogue", 0);
        MoveEnd(editor, line, 174000);

        // The cuts. A cut to a camera at the playhead runs to the next cut or the range's end, so they go from the last.
        editor.Select((CutsceneBlock?)null);
        var cuts = CutsceneFile.PathOf(editor.File.Tracks.Single(t => t.TrackKind == "camera_cut"));
        Rename(editor, cuts, "Cuts");
        foreach (var (tick, camera) in new[] { (400000, "Tracking Shot"), (200000, "Close Shot"), (0, "Wide Shot") })
        {
            var id = editor.File.Bindings.Single(b => b.Name == camera).Id!.Value;
            editor.Key("Add Cut", f => Assert.True(CutsceneEdits.AddCut(f, tick, id)));
        }
        string Cut(int index) => SectionPath(editor, "Cuts", index);
        Set(editor, Cut(0), "blend_in", "30000 smooth");
        foreach (var index in new[] { 0, 1, 2 })
        {
            Set(editor, Cut(index), "look_at", "1");
            Set(editor, Cut(index), "look_at_offset", "[0, 0.5, 0]");
        }
        Set(editor, Cut(0), "focus", "1");
        Set(editor, Cut(1), "look_at_damping", "12000");
        Set(editor, Cut(2), "follow", "1");
        Set(editor, Cut(2), "follow_offset", "[1.5, 1.2, -3]");
        Set(editor, Cut(2), "blend_out", "60000 smooth");
        Set(editor, Cut(2), "blend_on_skip", "true");

        // The close shot's focus is keyed at the playhead, as the lens rows key a spawned camera's field, and the section
        // that the first key makes, which runs the length, is trimmed to the shot.
        var close = editor.File.Bindings.Single(b => b.Name == "Close Shot").Id!.Value;
        KeyFocus(editor, close, 200000, 6);
        KeyFocus(editor, close, 320000, 1.5);
        Rename(editor, TrackPathOfProperty(editor), "Rack focus");
        var rack = SectionPath(editor, "Rack focus", 0);
        TrimStartTo(editor, rack, 200000);
        TrimEndTo(editor, rack, 400000);

        // The story track: a trigger at the playhead, which no selected binding or track gives to one of its own, then its
        // name, flag and value.
        editor.Select((CutsceneBlock?)null);
        editor.SetPlayhead(600000);
        editor.AddEvent();
        Assert.True(editor.RenameEvent("intro_seen"));
        Rename(editor, CutsceneFile.PathOf(editor.File.Tracks.Single(t => t.TrackKind == "event")), "Story");
        Pick(editor, CutsceneFile.PathOf(editor.File.Tracks.Single(t => t.Name == "Story").Children.Single()));
        editor.SetEventFlag("fire_when_skipped", true);
        editor.SetEventValue(0, new CutsceneEventValue(CutsceneValueKind.Entity, "1"));
        // The bark's range, over in and out points set at its start and end, on the selected story track.
        Pick(editor, TrackPath(editor, "Story"));
        editor.SetIn(360000);
        editor.SetOut(420000);
        editor.AddEventRange();
        Assert.True(editor.RenameEvent("guard_bark"));

        // The presentation: letterbox bars over the range, which ease in and out, and the line's subtitle over its sound,
        // each over in and out points, with the subtitle's details typed in.
        editor.SetIn(0);
        editor.SetOut(600000);
        editor.AddPresentation("letterbox");
        var letterbox = SectionPath(editor, "Presentation", 0);
        EaseTo(editor, letterbox, CutsceneEdge.Start, 30000);
        EaseTo(editor, letterbox, CutsceneEdge.End, 540000);
        editor.SetIn(30000);
        editor.SetOut(174000);
        editor.AddPresentation("subtitle");
        var subtitle = SectionPath(editor, "Presentation", 1);
        Set(editor, subtitle, "speaker", "\"Narrator\"");
        Set(editor, subtitle, "text", "\"The fox walks this path every evening.\"");
        Set(editor, subtitle, "key", "\"intro.narrator.path\"");
        Set(editor, subtitle, "audio", editor.File.Find(line)!.Id!.Value.ToString(CultureInfo.InvariantCulture));
        editor.ClearInOut();

        // Every undo entry is one that a command or a gesture made.
        Assert.NotEmpty(editor.Document.History);
        Assert.All(editor.Document.History, label => Assert.True(
            Labels.Contains(label) || label.StartsWith("Set ", StringComparison.Ordinal) || label.StartsWith("Remove ", StringComparison.Ordinal),
            $"an undo entry labeled \"{label}\" is not one that a command or a gesture makes"));

        var expected = Describe(CutsceneFile.Parse(CutsceneFileTests.Sample("intro").ReplaceLineEndings("\n")).File!);
        var built = Describe(editor.File);

        Assert.Equal(expected, built);
    }

    static void KeyFocus(CutsceneEditor editor, int binding, int tick, double value) =>
        editor.Key("Key Focus Distance", f => CutsceneKeying.SetKeys(
            f, new KeyTarget.Property(binding, CinematicCameraText.CinematicCameraId, "focus_distance", PropertyShape.Number), tick, [value], "Focus Distance", editor.Locked));

    static string TrackPathOfProperty(CutsceneEditor editor) => CutsceneFile.PathOf(editor.File.Tracks.Single(t => t.TrackKind == "property"));

    // The file as lines that say what it holds and not how its text is laid out: a block's fields in a fixed order, tracks
    // by name and not ID, the bindings that settings name by their IDs (which the order of the builds gives the same), and
    // a subtitle's audio by the section that it names. Comments are not in the model, so they are not in the lines.
    static List<string> Describe(CutsceneFile file)
    {
        var lines = new List<string>();
        void Fields(string at, CutsceneBlock block)
        {
            foreach (var (key, value) in block.Fields.OrderBy(f => f.Key, StringComparer.Ordinal).ThenBy(f => f.Value, StringComparer.Ordinal))
            {
                var shown = key == "audio" && CutsceneFile.TryParseId(value.Trim(), out var id) ? SectionName(file, id) : Normal(value);
                lines.Add($"{at} {key} = {shown}");
            }
        }

        Fields("header", file.Root);
        foreach (var binding in file.Bindings)
        {
            Fields($"binding {binding.Id} {binding.Name}", binding);
        }
        foreach (var track in file.Tracks.OrderBy(t => t.Name, StringComparer.Ordinal))
        {
            var at = $"track {track.TrackKind} {track.Name}";
            lines.Add(at);
            Fields(at, track);
            foreach (var child in track.Children)
            {
                var head = child.Kind switch
                {
                    CutsceneBlockKind.Section => $"{at}/section {child.Start}-{child.End}",
                    CutsceneBlockKind.Range => $"{at}/range {child.Start}-{child.End} {child.Name}",
                    _ => $"{at}/{child.Kind.ToString().ToLowerInvariant()} {child.Start} {child.Name}",
                };
                lines.Add(head);
                Fields(head, child);
                foreach (var channel in child.Children.Where(c => c.Kind == CutsceneBlockKind.Channel).OrderBy(c => c.Name, StringComparer.Ordinal))
                {
                    var keys = channel.Children.Select(k => $"{k.Start} {Normal(k.KeyValue ?? "")} {k.KeyInterpolation}");
                    lines.Add($"{head}/channel {channel.Name}: {string.Join("; ", keys)}");
                    Fields($"{head}/channel {channel.Name}", channel);
                }
            }
        }
        return lines;
    }

    // The name that a subtitle's audio gives: the track's and the section's place in it, since a section's ID is the editor's.
    static string SectionName(CutsceneFile file, int id)
    {
        var section = file.Blocks.Single(b => b.Kind == CutsceneBlockKind.Section && b.Id == id);
        var track = section.Parent!;
        return $"{track.Name}#{track.Children.Where(c => c.Kind == CutsceneBlockKind.Section).ToList().IndexOf(section)}";
    }

    // A value as a number when it is one, so 4 and 4.0 are the same, and with single spaces otherwise.
    static string Normal(string value)
    {
        var text = string.Join(' ', value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var number) ? number.ToString("R", CultureInfo.InvariantCulture) : text;
    }
}
