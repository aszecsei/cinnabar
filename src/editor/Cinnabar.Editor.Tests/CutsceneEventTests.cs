using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using Root = Cinnabar.Editor.Link.Cook.Root;
using Welcome = Cinnabar.Editor.Link.Cook.Welcome;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// Event keys (see docs/editor/cutscene-editor.md#events): Add Event, the names that the bound behaviours handle, the
/// warning for a name that none handles, the payload's typed rows and the flags.
/// </summary>
public sealed class CutsceneEventTests : IDisposable
{
    const string SceneGuid = "5ce5ce5ce5ce5ce5ce5ce5ce5ce5ce51";
    const string CutsceneGuid = "0123456789abcdef0123456789abcdef";
    const string PrefabGuid = "cafecafecafecafecafecafecafecafe";
    const string FoxScript = "f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0";
    const string GuardScript = "9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d";

    // The fox has the Fox behaviour, the lamp none, and the guard's prefab the Guard behaviour.
    const string SceneText = $"scene 1\n\nentity 0000000000000001\nname = \"Fox\"\nbehaviour {FoxScript}\n\nentity 0000000000000002\nname = \"Lamp\"\n";
    const string PrefabText = $"scene 3\n\nentity 1000000000000001\nname = \"Guard\"\nbehaviour {GuardScript}\n";

    // A story track for every behaviour, and bindings for the fox, the guard, the lamp and an entity that is gone.
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
        binding 4 "Ghost"
        	possess = @{SceneGuid}/0000000000000009

        track 1 event "Story"
        	trigger 1 100000 intro_seen

        """;

    static readonly BehaviourHandler[] FoxHandlers =
    [
        new("alarm", 12, [new HandlerParam("level", HandlerParamKind.Number), new HandlerParam("by", HandlerParamKind.Entity)]),
        new("look_begin", 20, [new HandlerParam("target", HandlerParamKind.Entity)]),
        new("look_end", 24, []),
    ];

    static readonly BehaviourHandler[] GuardHandlers = [new("bark", 7, [new HandlerParam("line", HandlerParamKind.Untyped)])];

    readonly TempDirectory _temp = new("cutscene-events");

    public void Dispose() => _temp.Dispose();

    (EditorShell Shell, CutsceneEditor Editor, string Text) NewShell(string tracks = "")
    {
        var shell = TestShell.Open(_temp, "fox.scene", SceneText);
        var text = (Cutscene + tracks).ReplaceLineEndings("\n");
        File.WriteAllText(_temp.Combine("fox.cutscene"), text);
        File.WriteAllText(_temp.Combine("guard.prefab"), PrefabText);
        File.WriteAllText(_temp.Combine("fox.luau"), "return nil\n");
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [], [], []));
        shell.Assets.Apply(new AssetSnapshot(
        [
            TestAssets.Make(SceneGuid, AssetKind.Scene, "fox.scene"),
            TestAssets.Make(CutsceneGuid, AssetKind.Cutscene, "fox.cutscene"),
            TestAssets.Make(PrefabGuid, AssetKind.Prefab, "guard.prefab"),
            TestAssets.Make(FoxScript, AssetKind.Script, "fox.luau", behaviour: "Fox", handlers: FoxHandlers),
            TestAssets.Make(GuardScript, AssetKind.Script, "guard.luau", behaviour: "Guard", handlers: GuardHandlers),
        ], []));
        return (shell, shell.OpenCutscene(shell.Assets.Find(CutsceneGuid)!)!, text);
    }

    static string[] Names(IReadOnlyList<CutsceneHandlerChoice>? choices) => [.. choices!.Select(c => c.Name)];

    [Fact]
    public void AnEventAddedOnABindingTakesANameFromItsBehavioursAndATypedPayload()
    {
        var (shell, editor, text) = NewShell();
        editor.Select(["binding:1"], SelectMode.Replace);
        editor.SetPlayhead(60000);

        // A new event track for the fox, with a trigger at the playhead, named for the fox's first event, selected.
        editor.AddEvent();
        var added = text + "track 2 event \"Events\"\n\tbinding = 1\n\ttrigger 2 60000 alarm\n";
        Assert.Equal(added, editor.Document.Text);
        Assert.Equal(["trigger:2"], editor.SelectedPaths);
        var trigger = editor.Selected!;
        Assert.Equal(["alarm", "look_begin", "look_end"], Names(editor.HandlerChoices(trigger)));
        Assert.Null(editor.HandlerWarning(trigger));

        // The handler's parameters are the payload's rows, typed, and with no values yet.
        Assert.Equal([new CutsceneValueRow("level", CutsceneValueKind.Number, null, false), new CutsceneValueRow("by", CutsceneValueKind.Entity, null, false)],
            editor.ValueRows(trigger));
        // The second value first: the first takes its parameter's default, so the entity lands at by.
        editor.SetEventValue(1, new CutsceneEventValue(CutsceneValueKind.Entity, "2"));
        editor.SetEventValue(0, new CutsceneEventValue(CutsceneValueKind.Number, "2.5"));
        var filled = added + "\t\tvalue = number 2.5\n\t\tvalue = entity 2\n";
        Assert.Equal(filled, editor.Document.Text);

        // A name picked from the list: the look's handler takes one entity, so the second value has no parameter.
        Assert.True(editor.RenameEvent("look_begin"));
        Assert.Equal(filled.Replace("60000 alarm", "60000 look_begin"), editor.Document.Text);
        var rows = editor.ValueRows(editor.Selected!);
        Assert.Equal(new CutsceneValueRow("target", CutsceneValueKind.Entity, new CutsceneEventValue(CutsceneValueKind.Number, "2.5"), true), rows[0]);
        Assert.NotNull(rows[0].Mismatch);
        Assert.Equal(new CutsceneValueRow(null, null, new CutsceneEventValue(CutsceneValueKind.Entity, "2"), true), rows[1]);

        Assert.Equal(["Add Event", "Set Event Value", "Set Event Value", "Rename Event"], editor.Document.History);
        for (var i = 0; i < 4; i++)
        {
            shell.Commands.Get("edit.undo").Execute();
        }
        Assert.Equal(text, editor.Document.Text);
    }

    [Fact]
    public void ANameWithNoHandlerWarnsAndAnUnknownEntityDoesNot()
    {
        var (_, editor, _) = NewShell("""
            track 2 event "Fox"
            	binding = 1
            	trigger 2 0 alrm
            	range 3 0 60000 look
            	range 4 0 60000 alarm
            track 3 event "Lamp"
            	binding = 3
            	trigger 5 0 alarm
            track 4 event "Ghost"
            	binding = 4
            	trigger 6 0 alarm

            """);
        CutsceneBlock Event(string path) => editor.File.Find(path)!;

        // A name that the fox's behaviour does not handle, a range with a begin, and a range without its begin or end.
        Assert.NotNull(editor.HandlerWarning(Event("trigger:2")));
        Assert.Null(editor.HandlerWarning(Event("range:3")));
        Assert.Equal(["look"], Names(editor.HandlerChoices(Event("range:3"))));
        Assert.NotNull(editor.HandlerWarning(Event("range:4")));
        // The lamp has no behaviours, so nothing handles its event. The ghost's entity is gone, so nothing is known.
        Assert.NotNull(editor.HandlerWarning(Event("trigger:5")));
        Assert.Null(editor.HandlerChoices(Event("trigger:6")));
        Assert.Null(editor.HandlerWarning(Event("trigger:6")));

        // The warnings are on the timeline's items, for the outline and the hover.
        var items = editor.Layout().Rows.SelectMany(r => r.Bars.Concat(r.Points)).ToDictionary(i => i.Path, i => i.Warning);
        Assert.NotNull(items["trigger:2"]);
        Assert.Null(items["range:3"]);
        Assert.Null(items["trigger:6"]);

        // A name that an event cannot have is refused.
        editor.Select(["trigger:2"], SelectMode.Replace);
        Assert.False(editor.RenameEvent("two words"));
        Assert.True(editor.RenameEvent("alarm"));
        Assert.Null(editor.HandlerWarning(editor.Selected!));
    }

    [Fact]
    public void TheMasterTrackListsEveryBehavioursEvents()
    {
        var (_, editor, _) = NewShell();
        var story = editor.File.Find("trigger:1")!;

        // Every behaviour script's, by class, with the class that defines each.
        Assert.Equal([("alarm", "Fox"), ("look_begin", "Fox"), ("look_end", "Fox"), ("bark", "Guard")],
            editor.HandlerChoices(story)!.Select(c => (c.Name, c.Class)));
        Assert.NotNull(editor.HandlerWarning(story));

        // The guard's prefab's behaviour gives the guard's events.
        editor.Select(["binding:2"], SelectMode.Replace);
        editor.AddEvent();
        Assert.Equal("bark", editor.Selected!.Name);
        Assert.Equal(["bark"], Names(editor.HandlerChoices(editor.Selected!)));
        // Its parameter has no type, so its row takes any kind.
        Assert.Equal([new CutsceneValueRow("line", null, null, false)], editor.ValueRows(editor.Selected!));
    }

    [Fact]
    public void TheFlagsAndAnUntypedValueEditTheirLines()
    {
        var (shell, editor, text) = NewShell();
        editor.Select(["trigger:1"], SelectMode.Replace);

        editor.SetEventFlag("fire_when_skipped", true);
        editor.SetEventFlag("fire_on_seek", true);
        var flagged = text.Replace("intro_seen\n", "intro_seen\n\t\tfire_when_skipped = true\n\t\tfire_on_seek = true\n");
        Assert.Equal(flagged, editor.Document.Text);

        // No handler, so the values are a list of kinds and values.
        editor.SetEventValue(0, new CutsceneEventValue(CutsceneValueKind.String, "gate \"north\""));
        editor.SetEventValue(1, new CutsceneEventValue(CutsceneValueKind.Asset, PrefabGuid));
        var valued = flagged + $"\t\tvalue = string \"gate \\\"north\\\"\"\n\t\tvalue = asset ${PrefabGuid}\n";
        Assert.Equal(valued, editor.Document.Text);
        Assert.Equal([new CutsceneEventValue(CutsceneValueKind.String, "gate \"north\""), new CutsceneEventValue(CutsceneValueKind.Asset, PrefabGuid)],
            editor.ValueRows(editor.Selected!).Select(r => r.Value));

        // A removed value takes its line, and the later one moves up. A cleared flag takes its line.
        editor.RemoveEventValue(0);
        editor.SetEventFlag("fire_on_seek", false);
        Assert.Equal(text.Replace("intro_seen\n", $"intro_seen\n\t\tfire_when_skipped = true\n\t\tvalue = asset ${PrefabGuid}\n"), editor.Document.Text);
        Assert.Equal(["Set fire_when_skipped", "Set fire_on_seek", "Set Event Value", "Set Event Value", "Remove Event Value", "Clear fire_on_seek"],
            editor.Document.History);
        shell.Commands.Get("edit.undo").Execute();
        shell.Commands.Get("edit.undo").Execute();
        Assert.Equal(valued, editor.Document.Text);
    }
}
