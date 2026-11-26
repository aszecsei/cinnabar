using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using Root = Cinnabar.Editor.Link.Cook.Root;
using Welcome = Cinnabar.Editor.Link.Cook.Welcome;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// What a section shows of its clip from outside the cutscene (see docs/editor/cutscene-editor.md#clip-events): an
/// animation clip's events from its binding's Animator's graph.
/// </summary>
public sealed class CutsceneClipEventsTests : IDisposable
{
    const string SceneGuid = "5ce5ce5ce5ce5ce5ce5ce5ce5ce5ce51";
    const string CutsceneGuid = "0123456789abcdef0123456789abcdef";
    const string PrefabGuid = "cafecafecafecafecafecafecafecafe";
    const string GraphGuid = "9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a";
    const string Walk = "dea303d3f0374a9e56b0bb58f4a85315";
    const string Run = "cf6a8cd8cc1591bd3e6e09437d5754a1";
    const string Hum = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    const string SceneText = $"scene 1\n\nentity 0000000000000001\nname = \"Fox\"\ncomponent 80 Animator\n\tgraph = ${GraphGuid}\n\nentity 0000000000000002\nname = \"Lamp\"\n";
    const string PrefabText = $"scene 3\n\nentity 1000000000000001\nname = \"Guard\"\ncomponent 80 Animator\n\tgraph = ${GraphGuid}\n";
    const string GraphText = $"animation_graph 1\nentry = idle\n\nclip walk = ${Walk}\n\tevent 0.12 footstep \"right\"\n\tevent 0.61 footstep \"left\"\nclip run = ${Run}\n\tevent 0.5 leap\n\nnode 1 state\n\tposition = [0, 0]\n\tname = idle\n\tmotion = walk\n";

    // The fox walks, the guard runs, and the lamp, which has no Animator, walks too.
    const string Cutscene = $"""
        cutscene 1
        length = 600000
        rate = 30

        binding 1 "Fox"
        	possess = @{SceneGuid}/0000000000000001
        binding 2 "Guard"
        	spawn = ${PrefabGuid}
        binding 3 "Lamp"
        	possess = @{SceneGuid}/0000000000000002

        track 1 animation "Fox walk"
        	binding = 1
        	section 1 0 120000
        		asset = ${Walk}
        		loop = true
        track 2 animation "Guard run"
        	binding = 2
        	section 2 0 120000
        		asset = ${Run}
        track 3 animation "Lamp walk"
        	binding = 3
        	section 3 0 120000
        		asset = ${Walk}
        track 4 audio "Hum"
        	section 4 0 120000
        		asset = ${Hum}

        """;

    readonly TempDirectory _temp = new("cutscene-clip-events");

    public void Dispose() => _temp.Dispose();

    (EditorShell Shell, CutsceneEditor Editor) NewShell()
    {
        var shell = TestShell.Open(_temp, "fox.scene", SceneText);
        File.WriteAllText(_temp.Combine("fox.cutscene"), Cutscene.ReplaceLineEndings("\n"));
        File.WriteAllText(_temp.Combine("guard.prefab"), PrefabText);
        File.WriteAllText(_temp.Combine("fox.animation_graph"), GraphText);
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [], [], []));
        shell.Assets.Apply(Snapshot());
        return (shell, shell.OpenCutscene(shell.Assets.Find(CutsceneGuid)!)!);
    }

    static AssetSnapshot Snapshot() => new(
    [
        TestAssets.Make(SceneGuid, AssetKind.Scene, "fox.scene"),
        TestAssets.Make(CutsceneGuid, AssetKind.Cutscene, "fox.cutscene"),
        TestAssets.Make(PrefabGuid, AssetKind.Prefab, "guard.prefab"),
        TestAssets.Make(GraphGuid, AssetKind.AnimationGraph, "fox.animation_graph"),
        TestAssets.Make(Walk, AssetKind.Animation, "models/fox/Fox.gltf", parent: "dddddddddddddddddddddddddddddddd", subasset: "Walk", length: 60000),
        TestAssets.Make(Run, AssetKind.Animation, "models/fox/Fox.gltf", parent: "dddddddddddddddddddddddddddddddd", subasset: "Run", length: 60000),
        TestAssets.Make(Hum, AssetKind.Audio, "audio/hum.wav", length: 120000),
    ], []);

    static CutsceneTimelineItem BarOf(CutsceneEditor editor, string track) => editor.Layout().Rows.First(r => r.Path == track).Bars.Single();

    [Fact]
    public void AnAnimationSectionShowsItsBindingsGraphEvents()
    {
        var (_, editor) = NewShell();

        // A possessed entity's Animator, from the open scene, and a spawned prefab's root's.
        Assert.Equal([new CutsceneClipEvent(7200, "footstep \"right\""), new CutsceneClipEvent(36600, "footstep \"left\"")], BarOf(editor, "track:1").Events);
        Assert.Equal([new CutsceneClipEvent(30000, "leap")], BarOf(editor, "track:2").Events);
        // An entity with no Animator has no graph, and a sound no events.
        Assert.Empty(BarOf(editor, "track:3").Events);
        Assert.Empty(BarOf(editor, "track:4").Events);

        // The walk loops in a section of two of its lengths: each step twice.
        var walk = BarOf(editor, "track:1");
        var view = new TimelineView(0, 1000, TimelineZoom.Ticks);
        Assert.Equal([7.2, 36.6, 67.2, 96.6], CutsceneWaveform.EventTicks(walk, walk.Clip!, walk.Events, view, 1000).Select(t => Math.Round(t.X, 1)));

        // A change to the graph's file shows at the next build of the rows.
        var path = _temp.Combine("fox.animation_graph");
        File.WriteAllText(path, GraphText.Replace("0.61 footstep", "0.5 footstep"));
        File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddMinutes(1));
        Assert.Equal(30000, BarOf(editor, "track:1").Events[1].Tick);
    }
}
