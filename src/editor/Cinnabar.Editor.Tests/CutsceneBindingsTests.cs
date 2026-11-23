using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using Root = Cinnabar.Editor.Link.Cook.Root;
using Welcome = Cinnabar.Editor.Link.Cook.Welcome;

namespace Cinnabar.Editor.Tests;

/// <summary>A cutscene's bindings in its editor: their rows' state, possess, spawn, rebind, delete and the selection sync (see docs/editor/cutscene-editor.md#bindings).</summary>
public sealed class CutsceneBindingsTests : IDisposable
{
    const string SceneGuid = "5ce5ce5ce5ce5ce5ce5ce5ce5ce5ce51";
    const string ClosedSceneGuid = "c105ed5ce5ce5ce5ce5ce5ce5ce5ce52";
    const string CutsceneGuid = "0123456789abcdef0123456789abcdef";
    const string PrefabGuid = "cafecafecafecafecafecafecafecafe";
    const string SceneText = "scene 1\n\nentity 0000000000000001\nname = \"Door\"\n\nentity 0000000000000002\nname = \"Lamp\"\n";
    const ulong Door = 1UL << 32;
    const ulong Lamp = 2UL << 32;

    const string DoorBinding = $"binding 1 \"Door\"\n\tpossess = @{SceneGuid}/0000000000000001\n";
    const string DoorTrack = "track 1 transform \"Door Move\"\n\tbinding = 1\n\tsection 1 0 60000\n";
    const string Cutscene = $"cutscene 1\nlength = 600000\nrate = 30\n\n{DoorBinding}\n{DoorTrack}";

    readonly TempDirectory _temp = new("cutscene-bindings");
    readonly List<ILinkMessage> _sent = [];

    public void Dispose() => _temp.Dispose();

    // A linked shell in Edit with the door scene, whose door and lamp the game has, and a cutscene open in its tab.
    (EditorShell Shell, CutsceneEditor Editor) NewShell(string cutscene = Cutscene)
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
            TestAssets.Make(ClosedSceneGuid, AssetKind.Scene, "hall.scene"),
            TestAssets.Make(CutsceneGuid, AssetKind.Cutscene, "door.cutscene"),
            TestAssets.Make(PrefabGuid, AssetKind.Prefab, "crate.prefab"),
        ], []));
        shell.Host.LinkForTests(_sent.Add);
        shell.OnGameMessage(new ComponentTypes([]));
        shell.OnGameMessage(new EntitySnapshot(
        [
            new EntityInfo(Door, "Door", 1, 1, 0, true, []),
            new EntityInfo(Lamp, "Lamp", 2, 1, 0, true, []),
        ]));
        var editor = shell.OpenCutscene(shell.Assets.Find(CutsceneGuid)!)!;
        return (shell, editor);
    }

    static CutsceneTimelineRow Row(CutsceneEditor editor, int binding) =>
        editor.Layout().Rows.Single(r => r.Kind == CutsceneRowKind.Binding && r.Path == CutsceneFile.PathOf(editor.File.Bindings.Single(b => b.Id == binding)));

    static string PathOf(CutsceneEditor editor, int binding) => CutsceneFile.PathOf(editor.File.Bindings.Single(b => b.Id == binding));

    [Fact]
    public void AddBindingPossessesTheSelectedEntitiesByTheirSceneLinksAsOneEntryWhereverTheKeyboardIs()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var add = shell.Commands.Get(EditorCommands.CutsceneAddBindingSelected);
        Assert.False(editor.TimelineFocused);

        shell.Selection.Set([Door, Lamp]);
        Assert.True(add.CanExecute);
        add.Execute();

        // The door has a binding already, so only the lamp gets one, after the door's and before the tracks.
        Assert.Contains($"{DoorBinding}binding 2 \"Lamp\"\n\tpossess = @{SceneGuid}/0000000000000002\n\n{DoorTrack}", editor.Document.Text);
        Assert.Equal(["Add Binding"], editor.Document.History);
        Assert.Equal([PathOf(editor, 2)], editor.SelectedPaths);
        Assert.Equal(new CutsceneBindingInfo(CutsceneBindingKind.Possessed, "Lamp", CutsceneBindingState.Bound), Row(editor, 2).Binding);

        // Both are bound now, so there is nothing to add.
        Assert.False(add.CanExecute);
        Assert.NotNull(editor.PossessRefusal());

        shell.Commands.Get("edit.undo").Execute();
        Assert.Equal(Cutscene, editor.Document.Text);
    }

    [Fact]
    public void AnEntityDroppedOnTheTimelinePossessesItOrTheSelectionItIsIn()
    {
        var (shell, editor) = NewShell($"cutscene 1\nlength = 600000\nrate = 30\n");
        using var _ = shell;

        editor.DropEntity(Lamp, null, rebind: false);
        Assert.Contains($"binding 1 \"Lamp\"\n\tpossess = @{SceneGuid}/0000000000000002\n", editor.Document.Text);
        shell.Commands.Get("edit.undo").Execute();

        shell.Selection.Set([Door, Lamp]);
        editor.DropEntity(Lamp, null, rebind: false);
        Assert.Equal(["Add Bindings"], editor.Document.History);
        Assert.Equal(["Door", "Lamp"], editor.File.Bindings.Select(b => b.Name));
    }

    [Fact]
    public void ABindingWhoseEntityLeavesTheSceneIsBrokenAndARebindKeepsItsTracks()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        Assert.Equal(new CutsceneBindingInfo(CutsceneBindingKind.Possessed, "Door", CutsceneBindingState.Bound), Row(editor, 1).Binding);
        var changed = 0;
        editor.Changed += () => changed++;

        shell.Selection.Select(Door);
        shell.DeleteSelected();

        Assert.Null(shell.Scene!.Scene.Find(1));
        Assert.True(changed > 0);
        var broken = Row(editor, 1).Binding!;
        Assert.Equal(CutsceneBindingState.Broken, broken.State);
        Assert.Contains("0000000000000001", broken.Reason);

        // The row is selected, then the lamp in the viewport, which no binding has, so the row stays selected.
        editor.Select(editor.File.Bindings.ElementAt(0));
        shell.Selection.Select(Lamp);
        Assert.Equal([PathOf(editor, 1)], editor.SelectedPaths);
        var rebind = shell.Commands.Get(EditorCommands.CutsceneRebindToSelection);
        Assert.True(rebind.CanExecute);
        rebind.Execute();

        Assert.Equal(Cutscene.Replace("0000000000000001\n", "0000000000000002\n"), editor.Document.Text);
        Assert.Contains(DoorTrack, editor.Document.Text);
        Assert.Equal("Rebind", editor.Document.History[^1]);
        Assert.Equal(new CutsceneBindingInfo(CutsceneBindingKind.Possessed, "Lamp", CutsceneBindingState.Bound), Row(editor, 1).Binding);
        // It possesses the lamp now.
        Assert.Equal("The binding possesses that entity already.", editor.RebindRefusal(Lamp));
    }

    [Fact]
    public void ARowSaysWhetherItsSceneIsOpenAndWhetherItsSceneOrPrefabIsThere()
    {
        var text = $"cutscene 1\nlength = 600000\n\n"
            + $"binding 1 \"Closed\"\n\tpossess = @{ClosedSceneGuid}/0000000000000001\n"
            + "binding 2 \"Nowhere\"\n\tpossess = @00000000000000000000000000000bad/0000000000000001\n"
            + $"binding 3 \"Crate\"\n\tspawn = ${PrefabGuid}\n"
            + "binding 4 \"Gone\"\n\tspawn = $0000000000000000000000000000dead\n"
            + "binding 5 \"Neither\"\n";
        var (shell, editor) = NewShell(text);
        using var _ = shell;

        Assert.Equal(CutsceneBindingState.NotLoaded, Row(editor, 1).Binding!.State);
        Assert.Equal("hall.scene is not open.", Row(editor, 1).Binding!.Reason);
        Assert.Equal(CutsceneBindingState.Broken, Row(editor, 2).Binding!.State);
        Assert.Equal(new CutsceneBindingInfo(CutsceneBindingKind.Spawned, "crate", CutsceneBindingState.Bound), Row(editor, 3).Binding);
        Assert.Equal(CutsceneBindingState.Broken, Row(editor, 4).Binding!.State);
        Assert.Equal(CutsceneBindingKind.Spawned, Row(editor, 4).Binding!.Kind);
        Assert.Equal(new CutsceneBindingInfo(CutsceneBindingKind.Unknown, null, CutsceneBindingState.Broken, "It has neither possess nor spawn."), Row(editor, 5).Binding);
    }

    [Fact]
    public void ADroppedPrefabSpawnsAndASpawnedBindingIsNotRebound()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;

        Assert.Equal([PrefabGuid], editor.PrefabsOf([PrefabGuid, CutsceneGuid]));
        editor.Spawn(editor.PrefabsOf([PrefabGuid]));

        Assert.Contains($"binding 2 \"crate\"\n\tspawn = ${PrefabGuid}\n", editor.Document.Text);
        Assert.Equal(["Add Binding"], editor.Document.History);
        Assert.Equal([PathOf(editor, 2)], editor.SelectedPaths);
        Assert.Equal(CutsceneBindingKind.Spawned, Row(editor, 2).Binding!.Kind);

        shell.Selection.Select(Lamp);
        Assert.Equal([PathOf(editor, 2)], editor.SelectedPaths);
        Assert.Equal("The binding spawns a prefab. Only a possessed binding can be pointed at an entity.", editor.RebindRefusal(Lamp));
        Assert.False(shell.Commands.Get(EditorCommands.CutsceneRebindToSelection).CanExecute);

        shell.Commands.Get("edit.undo").Execute();
        Assert.Equal(Cutscene, editor.Document.Text);
    }

    [Fact]
    public async Task DeletingABindingWithTracksAsksAndRemovesThemAsOneEntry()
    {
        var (shell, editor) = NewShell(Cutscene + $"binding 2 \"Spare\"\n\tspawn = ${PrefabGuid}\n");
        using var _ = shell;
        var asked = new List<(string, string, int)>();
        var answer = false;
        shell.AskDeleteBinding = (binding, cutscene, tracks) =>
        {
            asked.Add((binding, cutscene, tracks));
            return Task.FromResult(answer);
        };
        var text = editor.Document.Text;

        editor.Select(editor.File.Bindings.ElementAt(0));
        Assert.True(editor.CanDeleteBinding);
        await editor.DeleteBinding();
        Assert.Equal([("Door", "door.cutscene", 1)], asked);
        Assert.Equal(text, editor.Document.Text);

        answer = true;
        await editor.DeleteBinding();
        Assert.DoesNotContain("\"Door\"", editor.Document.Text);
        Assert.DoesNotContain("Door Move", editor.Document.Text);
        Assert.Equal(["Delete Binding"], editor.Document.History);
        Assert.Empty(editor.SelectedPaths);

        // One without tracks goes without a question.
        editor.Select(editor.File.Bindings.Single(b => b.Name == "Spare"));
        await editor.DeleteBinding();
        Assert.Equal(2, asked.Count);
        Assert.Empty(editor.File.Bindings);

        shell.Commands.Get("edit.undo").Execute();
        shell.Commands.Get("edit.undo").Execute();
        Assert.Equal(text, editor.Document.Text);
    }

    [Fact]
    public void ABindingThatOtherBlocksNameIsNotDeleted()
    {
        var text = $"cutscene 1\nlength = 600000\n\n{DoorBinding}binding 2 \"Cam\"\n\tspawn = ${PrefabGuid}\n\tlook_at = 1\n";
        var (shell, editor) = NewShell(text);
        using var _ = shell;

        editor.Select(editor.File.Bindings.ElementAt(0));
        Assert.False(editor.CanDeleteBinding);
        Assert.Equal("Other blocks name it: Cam.", editor.DeleteBindingRefusal());
        Assert.False(CutsceneBindings.Remove(editor.File, 1));

        // The camera itself is named by nothing.
        editor.Select(editor.File.Bindings.ElementAt(1));
        Assert.True(editor.CanDeleteBinding);
    }

    [Fact]
    public void ReferencesAreEveryKindOfSettingThatNamesABinding()
    {
        var text = $"cutscene 1\nlength = 600000\n\n{DoorBinding}"
            + "binding 2 \"Child\"\n\tspawn = $00\n\tparent = 1\n"
            + "binding 3 \"Lamp\"\n\tspawn = $00\n"
            + "track 1 camera_cut \"Cuts\"\n\tsection 1 0 100\n\t\tcamera = 3\n\t\tfocus = 1\n"
            + "track 2 transform \"Lamp Move\"\n\tbinding = 3\n\tspace = relative 1\n"
            + "track 3 event \"Events\"\n\ttrigger 1 0 \"Hit\"\n\t\tvalue = entity 1\n"
            + "track 4 sub_sequence \"Sub\"\n\tsection 2 0 100\n\t\tbind 4 = 1\n"
            + "track 5 transform \"Door Move\"\n\tbinding = 1\n\tspace = relative 3\n";
        var file = CutsceneFile.Parse(text).File!;

        var references = CutsceneBindings.ReferencesTo(file, 1);
        Assert.Equal(5, references.Count);
        // The door's own track names the lamp, so the lamp has three, the cut's camera among them, and the track of its own does not count.
        Assert.Equal(2, CutsceneBindings.ReferencesTo(file, 3).Count);
        Assert.Empty(CutsceneBindings.ReferencesTo(file, 2));
        Assert.True(CutsceneBindings.Remove(file, 2));
        Assert.DoesNotContain("Child", file.Text);
    }

    [Fact]
    public void ARowAndItsEntitySelectEachOtherWithoutEchoing()
    {
        var (shell, editor) = NewShell(Cutscene + "binding 2 \"Lost\"\n\tpossess = @00000000000000000000000000000bad/0000000000000001\n");
        using var _ = shell;
        var changes = 0;
        shell.Selection.Changed += (_, _) => changes++;

        editor.Select(editor.File.Bindings.ElementAt(0));
        Assert.Equal([Door], shell.Selection.Entities);
        Assert.Equal(1, changes);

        // The world's selection selects the row and reveals it.
        editor.Select(null);
        string? revealed = null;
        editor.RevealRequested += p => revealed = p;
        shell.Selection.Clear();
        shell.Selection.Select(Door);
        Assert.Equal([PathOf(editor, 1)], editor.SelectedPaths);
        Assert.Equal(PathOf(editor, 1), revealed);

        // An entity that no binding possesses, and none, keep the timeline's selection: here a track.
        var track = CutsceneFile.PathOf(editor.File.Tracks.Single());
        editor.Select([track], SelectMode.Replace);
        shell.Selection.Select(Lamp);
        Assert.Equal([track], editor.SelectedPaths);
        shell.Selection.Clear();
        Assert.Equal([track], editor.SelectedPaths);

        // A broken row keeps the world's selection.
        shell.Selection.Select(Lamp);
        editor.Select(editor.File.Bindings.ElementAt(1));
        Assert.Equal([Lamp], shell.Selection.Entities);
    }

    [Fact]
    public void TheSelectedEntitiesFilterShowsOnlyTheirBindings()
    {
        var (shell, editor) = NewShell(Cutscene.Replace(DoorTrack, $"binding 2 \"Lamp\"\n\tpossess = @{SceneGuid}/0000000000000002\n\n{DoorTrack}track 2 audio \"Music\"\n"));
        using var _ = shell;

        shell.Commands.Get(EditorCommands.CutsceneFilterSelected).Execute();
        Assert.True(editor.SelectedOnly);
        Assert.Empty(editor.Layout().Rows);

        shell.Selection.Select(Door);
        Assert.Equal(["Door", "Door Move"], editor.Layout().Rows.Select(r => r.Label));
        shell.Selection.Set([Door, Lamp]);
        Assert.Equal(["Door", "Door Move", "Lamp"], editor.Layout().Rows.Select(r => r.Label));

        editor.SetSelectedOnly(false);
        Assert.Equal(["Music", "Door", "Door Move", "Lamp"], editor.Layout().Rows.Select(r => r.Label));
    }
}
