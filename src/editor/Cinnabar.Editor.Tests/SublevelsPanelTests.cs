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
/// The sublevels in the editor (see docs/editor/shell-and-panels.md#sublevels): assigning the selection, the editor's
/// choice of what loads, the project's declarations, and Play with the project's active set.
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
        Assert.Equal(4, shell.SublevelCount("night"));

        room.Undo();
        hall.Undo();
        Assert.Equal((null, null), (SublevelKey(room, 3), SublevelKey(hall, 1)));

        // The base takes the lamp back, with its bulb.
        shell.Selection.Set([Lamp]);
        Assert.True(shell.AssignSublevel(""));
        Assert.Null(SublevelKey(room, 1));
        Assert.Equal(0, shell.SublevelCount("night"));
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
}
