using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Cutscenes;
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

/// <summary>
/// The second part of a cutscene's binding edits: convert, Pick and the entities with a broken binding's name, script
/// slots and their stand-ins, Spawn Prefab and a spawn at a place (see docs/editor/cutscene-editor.md#bindings).
/// </summary>
public sealed class CutsceneBindingsConvertTests : IDisposable
{
    const string SceneGuid = "5ce5ce5ce5ce5ce5ce5ce5ce5ce5ce51";
    const string CutsceneGuid = "0123456789abcdef0123456789abcdef";
    const string OtherCutsceneGuid = "0123456789abcdef0123456789abcde2";
    const string PrefabGuid = "cafecafecafecafecafecafecafecafe";
    // A door and a lamp, an instance of the crate prefab at (1, 0, 2) meters, and an instance of only a part of it.
    const string SceneText = "scene 2\n\n"
        + "entity 0000000000000001\nname = \"Door\"\n\n"
        + "entity 0000000000000002\nname = \"Lamp\"\n\n"
        + $"entity 0000000000000003\nname = \"Crate\"\nprefab = ${PrefabGuid}\ncomponent 1 Transform\n\tposition = [16777216, 0, 33554432]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n\n"
        + $"entity 0000000000000004\nname = \"Lid\"\nprefab = ${PrefabGuid}\nnode = @0000000000000001\n";
    const ulong Door = 1UL << 32;
    const ulong Lamp = 2UL << 32;
    const ulong Crate = 3UL << 32;
    const ulong Lid = 4UL << 32;

    const string CrateTrack = "track 1 transform \"Crate Move\"\n\tbinding = 1\n\tsection 1 0 60000\n";
    const string Possessed = $"cutscene 1\nlength = 600000\nrate = 30\n\nbinding 1 \"Crate\"\n\tpossess = @{SceneGuid}/0000000000000003\n\n{CrateTrack}";

    readonly TempDirectory _temp = new("cutscene-bindings-2");

    public void Dispose() => _temp.Dispose();

    (EditorShell Shell, CutsceneEditor Editor) NewShell(string cutscene)
    {
        Directory.CreateDirectory(_temp.Path);
        File.WriteAllText(_temp.Combine("yard.scene"), SceneText);
        var options = new EditorOptions("host.exe", "game.dll", _temp.Combine("yard.scene")) { AutosaveDirectory = _temp.Combine("autosave") };
        var shell = new EditorShell(options with { Cook = options.Cook with { CachePath = _temp.Combine("cache") } }, new EditorSettings(_temp.Combine("settings")));
        File.WriteAllText(_temp.Combine("yard.cutscene"), cutscene);
        File.WriteAllText(_temp.Combine("other.cutscene"), cutscene);
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [], [], []));
        shell.Assets.Apply(new AssetSnapshot(
        [
            TestAssets.Make(SceneGuid, AssetKind.Scene, "yard.scene"),
            TestAssets.Make(CutsceneGuid, AssetKind.Cutscene, "yard.cutscene"),
            TestAssets.Make(OtherCutsceneGuid, AssetKind.Cutscene, "other.cutscene"),
            TestAssets.Make(PrefabGuid, AssetKind.Prefab, "crate.prefab"),
        ], []));
        shell.Host.LinkForTests(_ => { });
        shell.OnGameMessage(new ComponentTypes([]));
        shell.OnGameMessage(new EntitySnapshot(
        [
            new EntityInfo(Door, "Door", 1, 1, 0, true, []),
            new EntityInfo(Lamp, "Lamp", 2, 1, 0, true, []),
            new EntityInfo(Crate, "Crate", 3, 1, 0, true, []),
            new EntityInfo(Lid, "Lid", 4, 1, 0, true, []),
        ]));
        return (shell, shell.OpenCutscene(shell.Assets.Find(CutsceneGuid)!)!);
    }

    static CutsceneBlock Binding(CutsceneEditor editor, int id) => editor.File.Bindings.Single(b => b.Id == id);

    static CutsceneBindingInfo? Info(CutsceneEditor editor, int id) =>
        editor.Layout().Rows.Single(r => r.Kind == CutsceneRowKind.Binding && r.Path == CutsceneFile.PathOf(Binding(editor, id))).Binding;

    [Fact]
    public void APossessedBindingConvertsToASpawnOfItsPrefabWhereItIsAndBackKeepingItsTracks()
    {
        var (shell, editor) = NewShell(Possessed);
        using var _ = shell;
        var undo = shell.Commands.Get("edit.undo");
        editor.Select(Binding(editor, 1));
        var toSpawned = shell.Commands.Get(EditorCommands.CutsceneConvertToSpawned);
        Assert.True(toSpawned.CanExecute);

        toSpawned.Execute();
        var spawned = $"cutscene 1\nlength = 600000\nrate = 30\n\nbinding 1 \"Crate\"\n\tspawn = ${PrefabGuid}\n\tposition = [1, 0, 2]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n\n{CrateTrack}";
        Assert.Equal(spawned, editor.Document.Text);
        Assert.Equal(["Convert to Spawned"], editor.Document.History);
        Assert.Equal(new CutsceneBindingInfo(CutsceneBindingKind.Spawned, "crate", CutsceneBindingState.Bound), Info(editor, 1));
        Assert.NotNull(editor.ConvertRefusal(CutsceneBindingKind.Spawned));

        // Back to the crate, which is the one entity selected.
        shell.Selection.Set([Crate]);
        var toPossessed = shell.Commands.Get(EditorCommands.CutsceneConvertToPossessed);
        Assert.True(toPossessed.CanExecute);
        toPossessed.Execute();
        Assert.Equal(Possessed, editor.Document.Text);
        Assert.Equal(["Convert to Spawned", "Convert to Possessed"], editor.Document.History);

        undo.Execute();
        Assert.Equal(spawned, editor.Document.Text);
        undo.Execute();
        Assert.Equal(Possessed, editor.Document.Text);
    }

    [Fact]
    public void AConvertThatCannotWorkSaysWhy()
    {
        var text = $"cutscene 1\nlength = 600000\n\n"
            + $"binding 1 \"Door\"\n\tpossess = @{SceneGuid}/0000000000000001\n"
            + $"binding 2 \"Lid\"\n\tpossess = @{SceneGuid}/0000000000000004\n"
            + $"binding 3 \"Box\"\n\tspawn = ${PrefabGuid}\n"
            + $"binding 4 \"Box Lid\"\n\tspawn = ${PrefabGuid}\n\tparent = 3\n";
        var (shell, editor) = NewShell(text);
        using var _ = shell;

        editor.Select(Binding(editor, 1));
        Assert.NotNull(editor.ConvertRefusal(CutsceneBindingKind.Spawned));
        editor.Select(Binding(editor, 2));
        Assert.NotNull(editor.ConvertRefusal(CutsceneBindingKind.Spawned));
        // A parent of another spawned binding stays a spawn.
        editor.Select(Binding(editor, 3));
        shell.Selection.Set([Lamp]);
        Assert.NotNull(editor.ConvertRefusal(CutsceneBindingKind.Possessed));
        Assert.NotNull(editor.ConvertRefusal(CutsceneBindingKind.Provided));
        // A spawned binding possesses only one selected entity that no other binding has. Selecting the door selects its
        // binding's row, so the spawned row is selected after it.
        shell.Selection.Set([Door]);
        editor.Select(Binding(editor, 4));
        Assert.NotNull(editor.ConvertRefusal(CutsceneBindingKind.Possessed));
        shell.Selection.Set([Lamp, Crate]);
        editor.Select(Binding(editor, 4));
        Assert.NotNull(editor.ConvertRefusal(CutsceneBindingKind.Possessed));
        Assert.Empty(editor.Document.History);
    }

    [Fact]
    public void AScriptSlotPreviewsWithEachUsersStandInWhichTheAssetNeverHas()
    {
        var slot = $"cutscene 1\nlength = 600000\nrate = 30\n\nbinding 1 \"Companion\"\n\tprovided = true\n\tpolicy = required\n\n{CrateTrack}";
        var (shell, editor) = NewShell(slot);
        using var _ = shell;
        Assert.Equal(new CutsceneBindingInfo(CutsceneBindingKind.Provided, null, CutsceneBindingState.Bound), Info(editor, 1));
        Assert.Equal(slot, editor.CookText);
        Assert.Null(editor.HandleOf(1));

        // The lamp stands in: the preview's text possesses it on the provided line, and the document stays as it was.
        editor.Select(Binding(editor, 1));
        shell.Selection.Set([Lamp]);
        var standIn = shell.Commands.Get(EditorCommands.CutsceneStandInSelection);
        Assert.True(standIn.CanExecute);
        standIn.Execute();
        Assert.Equal(slot, editor.Document.Text);
        Assert.Empty(editor.Document.History);
        Assert.False(editor.Document.IsDirty);
        Assert.Equal(slot.Replace("provided = true", $"possess = @{SceneGuid}/0000000000000002", StringComparison.Ordinal), editor.CookText);
        Assert.Equal(new CutsceneBindingInfo(CutsceneBindingKind.Provided, "Lamp", CutsceneBindingState.Bound), Info(editor, 1));
        Assert.Equal(Lamp, editor.HandleOf(1));
        Assert.Contains("\"StandIns\":{\"1\":\"@" + SceneGuid + "/0000000000000002\"}",
            File.ReadAllText(Path.Combine(_temp.Path, "settings", EditorSettings.CutsceneTimelineFileName)));

        // The lamp's row is the slot's while it stands in, so selecting the lamp selects it.
        editor.Select(null);
        shell.Selection.Set([Door]);
        shell.Selection.Set([Lamp]);
        Assert.Equal([CutsceneFile.PathOf(Binding(editor, 1))], editor.SelectedPaths);

        // A prefab stands in: a spawn has no policy, so that line becomes a comment.
        editor.SetStandIn(1, CutsceneBindings.FormatPrefab(PrefabGuid));
        Assert.Equal(slot.Replace("provided = true", $"spawn = ${PrefabGuid}", StringComparison.Ordinal).Replace("\tpolicy", "\t# policy", StringComparison.Ordinal), editor.CookText);
        Assert.Equal(new CutsceneBindingInfo(CutsceneBindingKind.Provided, "crate", CutsceneBindingState.Bound), Info(editor, 1));

        // A stand-in that is gone breaks the row, and says so.
        editor.SetStandIn(1, "$0000000000000000000000000000dead");
        Assert.Equal(CutsceneBindingState.Broken, Info(editor, 1)!.State);
        editor.SetStandIn(1, null);
        Assert.Equal(slot, editor.CookText);
    }

    [Fact]
    public void ASlotConvertsToItsStandInAndABindingToASlotThatStandsInWhatItBound()
    {
        var (shell, editor) = NewShell(Possessed);
        using var _ = shell;
        editor.Select(Binding(editor, 1));
        shell.Commands.Get(EditorCommands.CutsceneConvertToSlot).Execute();

        Assert.Equal(Possessed.Replace($"possess = @{SceneGuid}/0000000000000003", "provided = true", StringComparison.Ordinal), editor.Document.Text);
        Assert.Equal(["Convert to Script Slot"], editor.Document.History);
        Assert.Equal($"@{SceneGuid}/0000000000000003", editor.StandInOf(1));
        Assert.Equal(Possessed, editor.CookText);

        // With nothing selected, the slot possesses its stand-in again.
        shell.Selection.Set([]);
        Assert.Null(editor.ConvertRefusal(CutsceneBindingKind.Possessed));
        editor.Convert(CutsceneBindingKind.Possessed);
        Assert.Equal(Possessed, editor.Document.Text);

        shell.Commands.Get("edit.undo").Execute();
        Assert.True(CutsceneBindings.IsProvided(Binding(editor, 1)));
        Assert.Equal(Crate, editor.HandleOf(1));
    }

    [Fact]
    public void PickPointsABrokenBindingAtTheNextEntitySelectedAndEscCancelsIt()
    {
        var broken = Possessed.Replace("0000000000000003\n", "0000000000000009\n", StringComparison.Ordinal);
        var (shell, editor) = NewShell(broken);
        using var _ = shell;
        editor.Select(Binding(editor, 1));
        Assert.Equal(CutsceneBindingState.Broken, Info(editor, 1)!.State);
        var pick = shell.Commands.Get(EditorCommands.CutscenePickBinding);
        Assert.True(pick.CanExecute);

        // Esc cancels it: the next selection selects, and rebinds nothing.
        pick.Execute();
        Assert.Equal(new BindingPick(1), editor.Picking);
        Assert.True(shell.CancelBindingPicks());
        Assert.Null(editor.Picking);
        Assert.False(shell.CancelBindingPicks());
        shell.Selection.Set([Lamp]);
        Assert.Equal(broken, editor.Document.Text);
        // So does selecting another row.
        pick.Execute();
        editor.Select(editor.File.Tracks.Single());
        Assert.Null(editor.Picking);
        shell.Selection.Set([Door]);
        Assert.Equal(broken, editor.Document.Text);
        editor.Select(Binding(editor, 1));

        // So does Cancel in a scene view, before mesh mode, and Cancel in the cutscene's tab before the selection.
        var viewport = ScopedCommand.FirstOf([.. shell.ViewportCancels]);
        Assert.False(viewport.CanExecute);
        pick.Execute();
        Assert.True(viewport.CanExecute);
        viewport.Run();
        Assert.Null(editor.Picking);
        var tab = new CutsceneCancelScope(editor, new CutsceneTimelineInput(editor), new CutsceneCurveInput(editor)).Handler(EditorCommands.Cancel)!;
        editor.SetKeyboardPane(CutscenePane.Timeline);
        pick.Execute();
        var selected = editor.SelectedPaths;
        Assert.NotEmpty(selected);
        tab.Run();
        Assert.Null(editor.Picking);
        Assert.Equal(selected, editor.SelectedPaths);
        // Then the selection of the pane that has the keyboard, and with none, nothing.
        tab.Run();
        Assert.Empty(editor.SelectedPaths);
        Assert.False(tab.CanExecute);
        editor.Select(Binding(editor, 1));
        editor.SetKeyboardPane(CutscenePane.None);
        Assert.False(tab.CanExecute);

        // Armed, the next entity selected becomes the binding's, in one entry, and the row stays selected.
        shell.Selection.Set([]);
        pick.Execute();
        shell.Selection.Set([Lamp]);
        Assert.Null(editor.Picking);
        Assert.Equal(broken.Replace("0000000000000009\n", "0000000000000002\n", StringComparison.Ordinal), editor.Document.Text);
        Assert.Equal(["Rebind"], editor.Document.History);
        Assert.Equal([CutsceneFile.PathOf(Binding(editor, 1))], editor.SelectedPaths);
        Assert.Contains(CrateTrack, editor.Document.Text);
    }

    [Fact]
    public void AnEntityThatAnotherBindingHasLeavesThePickArmedAndANewSlotHasNoOldStandIn()
    {
        var broken = Possessed.Replace("0000000000000003\n", "0000000000000009\n", StringComparison.Ordinal);
        var (shell, editor) = NewShell(broken);
        using var _ = shell;
        // A slot that was deleted had a stand-in, which stays for an undo. A new slot with its ID starts with none.
        editor.SetStandIn(2, $"@{SceneGuid}/0000000000000004");
        editor.AddSlot("Guard");
        Assert.Null(editor.StandInOf(2));
        editor.SetStandIn(2, $"@{SceneGuid}/0000000000000001");

        editor.Select(Binding(editor, 1));
        editor.ArmPick();
        shell.Selection.Set([Door]);
        Assert.Equal(new BindingPick(1), editor.Picking);
        Assert.Equal([CutsceneFile.PathOf(Binding(editor, 1))], editor.SelectedPaths);
        Assert.Equal(["Add Script Slot"], editor.Document.History);

        shell.Selection.Set([Lamp]);
        Assert.Null(editor.Picking);
        Assert.Equal(["Add Script Slot", "Rebind"], editor.Document.History);
    }

    [Fact]
    public void OneCutsceneHoldsThePickAndAnotherCutscenesTabEndsIt()
    {
        var broken = Possessed.Replace("0000000000000003\n", "0000000000000009\n", StringComparison.Ordinal);
        var (shell, first) = NewShell(broken);
        using var _ = shell;
        first.Select(Binding(first, 1));
        first.ArmPick();
        Assert.NotNull(first.Picking);

        // The other cutscene's tab ends the first's pick, and the selection there rebinds neither.
        var second = shell.OpenCutscene(shell.Assets.Find(OtherCutsceneGuid)!)!;
        Assert.Same(second, shell.ActiveCutscene);
        Assert.Null(first.Picking);
        second.Select(Binding(second, 1));
        second.ArmPick();
        Assert.NotNull(second.Picking);
        // Arming one cutscene's pick ends any other's: the first arms again, and the second's goes.
        first.Select(Binding(first, 1));
        first.ArmPick();
        Assert.Null(second.Picking);
        Assert.NotNull(first.Picking);

        shell.Selection.Set([Lamp]);
        Assert.Equal(["Rebind"], first.Document.History);
        Assert.Empty(second.Document.History);
    }

    [Fact]
    public void ABrokenBindingListsTheEntitiesWithItsName()
    {
        var text = $"cutscene 1\nlength = 600000\n\nbinding 1 \"Lamp\"\n\tpossess = @{SceneGuid}/0000000000000009\n";
        var (shell, editor) = NewShell(text);
        using var _ = shell;

        var candidate = Assert.Single(editor.CandidatesOf(Binding(editor, 1)));
        Assert.Equal(new BindingCandidate(new PossessRef(SceneGuid, 2), "Lamp", "yard.scene"), candidate);
        editor.RebindTo(1, candidate.Entity);
        Assert.Equal(text.Replace("09\n", "02\n", StringComparison.Ordinal), editor.Document.Text);
        // It is bound now, so it lists none.
        Assert.Empty(editor.CandidatesOf(Binding(editor, 1)));
    }

    [Fact]
    public void ASpawnAtAPlaceKeysItsFirstPositionThereAtThePlayhead()
    {
        var (shell, editor) = NewShell(Possessed);
        using var _ = shell;
        editor.SetPlayhead(30000);

        editor.SpawnAt(PrefabGuid, [3L << 24, 0, -(1L << 23)]);

        var text = editor.Document.Text;
        Assert.Contains($"binding 2 \"crate\"\n\tspawn = ${PrefabGuid}\n\tposition = [3, 0, -0.5]\n", text);
        var track = editor.File.Tracks.Single(t => CutsceneEdits.BindingOf(t) == 2);
        Assert.Equal("transform", track.TrackKind);
        Assert.Equal([0.0, 0.0, 0.0], CutsceneKeying.KeysAt(editor.File, new KeyTarget.Pose(2, PosePart.Position), 30000));
        Assert.Equal(["Add Binding"], editor.Document.History);
        Assert.Equal([CutsceneFile.PathOf(Binding(editor, 2))], editor.SelectedPaths);

        shell.Commands.Get("edit.undo").Execute();
        Assert.Equal(Possessed, editor.Document.Text);
    }
}
