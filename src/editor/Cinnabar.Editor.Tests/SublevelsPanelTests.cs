using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using LogLevel = Cinnabar.Editor.Model.LogLevel;
using SceneValue = Cinnabar.Editor.Document.SceneValue;
using SetField = Cinnabar.Editor.Document.SetField;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// The sublevels in the editor (see docs/editor/shell-and-panels.md#sublevels): the panel, assigning the selection,
/// loading sublevels in Edit, the outliner's tag, filter and dimmed rows, and Play with the project's active set.
/// </summary>
public sealed class SublevelsPanelTests : IDisposable
{
    // A lamp in the night with its bulb, a crate in the base, and a moth at dusk.
    const string Room = """
        scene 4

        entity 0000000000000001
        name = "Lamp"
        sublevel = "night"
        component 1001 Spin
        	target = @0000000000000003

        entity 0000000000000002
        name = "Bulb"
        parent = @0000000000000001

        entity 0000000000000003
        name = "Crate"

        entity 0000000000000006
        name = "Moth"
        sublevel = "dusk"

        """;

    const string Hall = "scene 3\n\nentity 0000000000000001\nname = \"Chair\"\n";

    // The project starts with dusk active and night inactive.
    const string Project = "sublevel.night = inactive\nsublevel.dusk = active\n";

    const ulong Lamp = 10, Bulb = 11, Crate = 12, Moth = 13, Chair = 20;

    static readonly FieldInfo Target = new("target", 0, FieldKind.Entity, FieldKind.Entity, [], false, false, 0, 0, false, false, 0, "");

    readonly TempDirectory _temp = new("sublevels-panel");
    readonly List<ILinkMessage> _sent = [];

    public void Dispose() => _temp.Dispose();

    string ProjectPath => _temp.Combine("project.settings");

    // A shell on room.scene in a project that declares night and dusk, linked to a fake game that reports the room.
    EditorShell Open(bool writeProject = true)
    {
        Directory.CreateDirectory(_temp.Path);
        if (writeProject)
        {
            File.WriteAllText(ProjectPath, Project);
        }
        File.WriteAllText(_temp.Combine("hall.scene"), Hall);
        var shell = TestShell.Open(_temp, "room.scene", Room.ReplaceLineEndings("\n"), ProjectPath);
        shell.Host.LinkForTests(_sent.Add);
        shell.OnGameMessage(World(shell.Scene!));
        return shell;
    }

    static EntitySnapshot World(SceneDocument room, SceneDocument? hall = null) => new(
    [
        new EntityInfo(Lamp, "Lamp", 1, room.Number, 0, true, []),
        new EntityInfo(Bulb, "Bulb", 2, room.Number, Lamp, true, []),
        new EntityInfo(Crate, "Crate", 3, room.Number, 0, true, []),
        new EntityInfo(Moth, "Moth", 6, room.Number, 0, true, []),
        .. hall == null ? Array.Empty<EntityInfo>() : [new EntityInfo(Chair, "Chair", 1, hall.Number, 0, true, [])],
    ]);

    static string? SublevelKey(SceneDocument document, ulong id) => document.Scene.Find(id)!.Sublevel;

    LoadedScene PartOf(string sublevel) => _sent.OfType<LoadScene>().Last().Scenes.Single(s => s.Sublevel == sublevel);

    [Fact]
    public void AssignPutsTheSelectedRootsInASublevelWithOneUndoEntryInEachScene()
    {
        using var shell = Open();
        var room = shell.Scene!;
        Assert.True(shell.AddScene(_temp.Combine("hall.scene")));
        var hall = shell.Scene!;
        shell.OnGameMessage(World(room, hall));
        var (roomEntries, hallEntries) = (room.History.Count, hall.History.Count);

        shell.Selection.Set([Crate, Chair]);
        Assert.True(shell.AssignSublevel("night"));

        Assert.Equal(("night", "night"), (SublevelKey(room, 3), SublevelKey(hall, 1)));
        Assert.Equal((roomEntries + 1, hallEntries + 1), (room.History.Count, hall.History.Count));
        Assert.Equal("Move Crate to night", room.History[^1].Label);
        Assert.Equal(4, shell.SublevelCount("night"));

        room.Undo();
        hall.Undo();
        Assert.Equal((null, null), (SublevelKey(room, 3), SublevelKey(hall, 1)));

        // The base takes the lamp back, with its bulb.
        shell.Selection.Set([Lamp]);
        Assert.True(shell.AssignSublevel(""));
        Assert.Null(SublevelKey(room, 1));
        Assert.Equal(0, shell.SublevelCount("night"));
        Assert.Equal("Move Lamp to the Base", room.History[^1].Label);
    }

    [Fact]
    public void AChildIsNotAssignedApartFromItsParentAndTheConsoleSaysWhy()
    {
        using var shell = Open();
        var room = shell.Scene!;
        var entries = room.History.Count;

        shell.Selection.Set([Bulb]);
        Assert.False(shell.AssignSublevel("dusk"));
        Assert.Equal(entries, room.History.Count);
        Assert.Contains(shell.Console.Lines, l => l.Level == LogLevel.Warning && l.Text.Contains("Bulb stays in its parent's sublevel"));

        // With its parent selected, the child goes with it, and nothing is said.
        var lines = shell.Console.Lines.Count;
        shell.Selection.Set([Lamp, Bulb]);
        Assert.True(shell.AssignSublevel("dusk"));
        Assert.Equal("dusk", SublevelKey(room, 1));
        Assert.Equal("dusk", room.Expanded.Flat.SublevelOf(room.Expanded.Flat.Find(2)!));
        Assert.Equal(lines, shell.Console.Lines.Count);
    }

    [Fact]
    public void ThePanelsLoadToggleLoadsAndUnloadsThatSublevelsPartsOnly() => Ui.Run(() =>
    {
        using var shell = Open();
        var view = new SublevelsView(shell);
        view.Subscriptions.Attach();
        Assert.Equal(["", "night", "dusk"], view.Rows.Select(r => r.Name));
        Assert.Equal((1, 2, 1), (view.Rows[0].Count, view.Rows[1].Count, view.Rows[2].Count));
        Assert.Equal((false, true), (view.Rows[1].Active, view.Rows[2].Active));
        var dusk = PartOf("dusk").Scene;
        _sent.Clear();

        Assert.True(shell.Commands.Get(EditorShell.LoadSublevelCommand("dusk")).Execute());
        Assert.Equal(dusk, Assert.Single(_sent.OfType<RemoveScene>()).Scene);
        Assert.Empty(_sent.OfType<AddScene>());
        Assert.Empty(_sent.OfType<LoadScene>());
        Assert.False(view.Rows.Single(r => r.Name == "dusk").Loaded);
        Assert.True(view.Rows.Single(r => r.Name == "night").Loaded);

        _sent.Clear();
        Assert.True(shell.Commands.Get(EditorShell.LoadSublevelCommand("dusk")).Execute());
        var added = Assert.Single(_sent.OfType<AddScene>()).Scene;
        Assert.Equal("dusk", added.Sublevel);
        Assert.Equal(["Moth"], added.Entities.Select(e => e.Name));
        Assert.Empty(_sent.OfType<RemoveScene>());
    });

    [Fact]
    public void TheEditorsChoiceIsKeptForTheProject()
    {
        using (var shell = Open())
        {
            shell.SetSublevelLoaded("night", false);
        }
        _sent.Clear();
        using var again = Open();
        Assert.False(again.IsSublevelChosen("night"));
        Assert.True(again.IsSublevelChosen("dusk"));
        Assert.Equal(["", "dusk"], _sent.OfType<LoadScene>().Last().Scenes.Select(s => s.Sublevel));
    }

    [Fact]
    public void PlayStartsWithTheProjectsActiveSetAndStopBringsBackTheChoice()
    {
        using var shell = Open();
        // The editor shows the night and hides dusk, the other way round from the project.
        shell.SetSublevelLoaded("dusk", false);
        var night = PartOf("night").Scene;
        _sent.Clear();

        shell.Play();
        Assert.Equal(night, Assert.Single(_sent.OfType<RemoveScene>()).Scene);
        var dusk = Assert.Single(_sent.OfType<AddScene>()).Scene;
        Assert.Equal("dusk", dusk.Sublevel);
        Assert.Equal(["Moth"], dusk.Entities.Select(e => e.Name));
        Assert.True(shell.IsSublevelLoaded("dusk"));
        Assert.False(shell.IsSublevelLoaded("night"));
        // The parts change before the game plays, so it starts with them.
        Assert.True(_sent.FindIndex(m => m is SetMode { Mode: EditorMode.Play }) > _sent.FindIndex(m => m is AddScene));

        // A pause and its end send no scene.
        _sent.Clear();
        shell.TogglePause();
        shell.TogglePause();
        Assert.DoesNotContain(_sent, m => m is AddScene or RemoveScene or LoadScene);

        shell.Stop();
        Assert.Equal(["", "night"], _sent.OfType<LoadScene>().Last().Scenes.Select(s => s.Sublevel));
        Assert.False(shell.IsSublevelLoaded("dusk"));
    }

    [Fact]
    public void ThePanelEditsTheDeclarationsInProjectSettings()
    {
        using var shell = Open();

        Assert.True(shell.DeclareSublevel("boss_fight", active: false));
        Assert.True(shell.DeclareSublevel("night", active: true));
        Assert.Equal([("night", true), ("dusk", true), ("boss_fight", false)], ProjectSettings.Sublevels(ProjectPath));
        Assert.Contains("sublevel.night = active", File.ReadAllText(ProjectPath));
        Assert.NotNull(shell.Commands.Find(EditorShell.AssignSublevelCommand("boss_fight")));

        Assert.False(shell.DeclareSublevel("boss fight", active: true));
        Assert.Contains(shell.Console.Lines, l => l.Level == LogLevel.Error && l.Text.Contains("is not a sublevel's name"));

        // The lamp is in the night, so its declaration stays.
        Assert.False(shell.RemoveSublevel("night"));
        Assert.Contains(shell.Console.Lines, l => l.Text.Contains("cannot remove night: 2 entities are in it"));
        Assert.True(shell.RemoveSublevel("boss_fight"));
        Assert.Equal(["night", "dusk"], ProjectSettings.Sublevels(ProjectPath).Select(s => s.Name));
        Assert.Null(shell.Commands.Find(EditorShell.AssignSublevelCommand("boss_fight")));
    }

    [Fact]
    public void ThePanelWarnsOfASublevelThatTheProjectDoesNotDeclare() => Ui.Run(() =>
    {
        Directory.CreateDirectory(_temp.Path);
        File.WriteAllText(ProjectPath, "sublevel.night = inactive\n");
        using var shell = Open(writeProject: false);
        var view = new SublevelsView(shell);
        view.Subscriptions.Attach();
        Assert.Equal([("night", true), ("dusk", false)], view.Rows.Skip(1).Select(r => (r.Name, r.Declared)));
    });

    [Fact]
    public void TheOutlinerFiltersBySublevelAndTagsItsRoots() => Ui.Run(() =>
    {
        using var shell = Open();
        var view = new OutlinerView(shell);
        view.Subscriptions.Attach();
        Assert.Equal([Lamp, Bulb, Crate, Moth], view.Rows.OfType<OutlinerRow>().Select(r => r.Node.Handle));

        shell.Outliner.Sublevel = "night";
        view.Subscriptions.Attach();
        Assert.Equal([Lamp, Bulb], view.Rows.OfType<OutlinerRow>().Select(r => r.Node.Handle));

        shell.Outliner.Sublevel = "";
        view.Subscriptions.Attach();
        Assert.Equal([Crate], view.Rows.OfType<OutlinerRow>().Select(r => r.Node.Handle));

        Assert.Equal("night", shell.SublevelOf(shell.World.Find(Bulb)!));
    });

    [Fact]
    public void TheOutlinerKeepsAnUnloadedSublevelsEntitiesDimmed() => Ui.Run(() =>
    {
        using var shell = Open();
        var view = new OutlinerView(shell);
        view.Subscriptions.Attach();

        shell.SetSublevelLoaded("night", false);
        // The game takes the night's part away.
        shell.OnGameMessage(new EntityDelta([], [Lamp, Bulb]));

        Assert.Equal([Crate, Moth], view.Rows.OfType<OutlinerRow>().Select(r => r.Node.Handle));
        var unloaded = view.Rows.OfType<OutlinerDocumentRow>().ToList();
        Assert.Equal([("Lamp", 0, "night"), ("Bulb", 1, "night")], unloaded.Select(r => (r.Label, r.Depth, r.Sublevel)));

        // The filter applies to them too.
        shell.Outliner.Sublevel = "dusk";
        view.Subscriptions.Attach();
        Assert.Empty(view.Rows.OfType<OutlinerDocumentRow>());
    });

    [Fact]
    public void AReferenceToAnEntityOfAnUnloadedSublevelSaysSo()
    {
        using var shell = Open();
        shell.Edit("Set Target", new SetField(1, 1001, "target", SceneValue.EntityRef(6)));
        var editor = FieldEditor.ForComponent(shell, [1UL], 1001, Target)!;
        Assert.Null(editor.Unavailable);

        shell.SetSublevelLoaded("dusk", false);
        Assert.Equal(("Sublevel not loaded: dusk", "@0000000000000006"), editor.Unavailable);

        shell.SetSublevelLoaded("dusk", true);
        Assert.Null(editor.Unavailable);
    }
}
