using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using Operation = Cinnabar.Editor.Document.Operation;
using SceneValue = Cinnabar.Editor.Document.SceneValue;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// Several scenes of one world open at once, each a document with its own undo and save state, in one outliner (see
/// docs/editor/document-and-scenes.md#several-scenes).
/// </summary>
public sealed class SeveralScenesTests : IDisposable
{
    readonly TempDirectory _temp = new("several-scenes");
    readonly List<ILinkMessage> _sent = [];

    // Both scenes have an entity with the scene ID 1: a scene ID is unique only in its scene.
    static string Text(string name) => "scene 2\n\n" +
        $"entity 0000000000000001\nname = \"{name}\"\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n" +
        "component 1001 Spin\n\tspeed = 1\n";

    const ulong NorthGate = 1UL << 32 | 0;
    const ulong SouthGate = 1UL << 32 | 1;

    // A shell with north.scene open, and south.scene beside it, linked when link is true.
    (EditorShell Shell, SceneDocument North, SceneDocument South) Open(bool link = false)
    {
        Directory.CreateDirectory(_temp.Path);
        File.WriteAllText(_temp.Combine("south.scene"), Text("South Gate"));
        var shell = TestShell.Open(_temp, "north.scene", Text("North Gate"));
        if (link)
        {
            shell.Host.LinkForTests(_sent.Add);
        }
        var north = shell.Scene!;
        Assert.True(shell.AddScene(_temp.Combine("south.scene")));
        return (shell, north, shell.Scene!);
    }

    // What the game reports after it loads both scenes: each scene's entity, by its scene's number.
    static EntitySnapshot World(SceneDocument north, SceneDocument south) => new(
    [
        new EntityInfo(NorthGate, "North Gate", 1, north.Number, 0, true, [1]),
        new EntityInfo(SouthGate, "South Gate", 1, south.Number, 0, true, [1]),
    ]);

    static Operation Rename(string name) => new Rename(1, name);

    [Fact]
    public void TwoScenesEditUndoAndSaveEachOnItsOwn()
    {
        var (shell, north, south) = Open();
        using var _ = shell;
        Assert.Equal([north, south], shell.Scenes);
        Assert.NotEqual(north.Number, south.Number);
        // The scene that opened last is the active one, which edits act on.
        Assert.Same(south, shell.Scene);

        Assert.True(shell.Edit("Rename", Rename("South Door")));
        shell.ActivateScene(north);
        Assert.True(shell.Edit("Rename", Rename("North Door")));
        Assert.True(shell.Edit("Rename", Rename("North Arch")));

        // Undo takes the active scene's last entry, and the other scene keeps its own.
        Assert.True(shell.Commands.Get(EditorCommands.Undo).Execute());
        Assert.Equal("North Door", north.Scene.Find(1)!.Name);
        Assert.Equal("South Door", south.Scene.Find(1)!.Name);
        Assert.Equal(1, north.Position);
        Assert.Equal(1, south.Position);

        // Saving the active scene writes its file alone: the other stays dirty, and its file as it was.
        Assert.True(shell.Commands.Get(EditorCommands.Save).Execute());
        Assert.False(north.IsDirty);
        Assert.True(south.IsDirty);
        Assert.Contains("name = \"North Door\"", File.ReadAllText(_temp.Combine("north.scene")));
        Assert.Contains("name = \"South Gate\"", File.ReadAllText(_temp.Combine("south.scene")));

        shell.ActivateScene(south);
        Assert.True(shell.Commands.Get(EditorCommands.Undo).Execute());
        Assert.Equal("South Gate", south.Scene.Find(1)!.Name);
        Assert.False(south.IsDirty);
        Assert.Equal("North Door", north.Scene.Find(1)!.Name);
        Assert.True(shell.Commands.Get(EditorCommands.Redo).Execute());
        Assert.True(shell.SaveScene());
        Assert.Contains("name = \"South Door\"", File.ReadAllText(_temp.Combine("south.scene")));
        Assert.False(shell.AnySceneDirty);
    }

    [Fact]
    public void SaveAllWritesEveryDirtySceneAndDiscardForgetsTheirAutosaves()
    {
        var (shell, north, south) = Open();
        using var _ = shell;
        shell.Edit("Rename", Rename("South Door"));
        shell.ActivateScene(north);
        shell.Edit("Rename", Rename("North Door"));
        Assert.True(shell.Commands.Get(EditorCommands.SaveAll).CanExecute);

        Assert.True(shell.Commands.Get(EditorCommands.SaveAll).Execute());

        Assert.False(north.IsDirty);
        Assert.False(south.IsDirty);
        Assert.Contains("name = \"North Door\"", File.ReadAllText(north.Path));
        Assert.Contains("name = \"South Door\"", File.ReadAllText(south.Path));
        Assert.False(shell.Commands.Get(EditorCommands.SaveAll).CanExecute);
    }

    [Fact]
    public void TheHostGetsEveryOpenSceneAndEachEditNamesItsScene()
    {
        var (shell, north, south) = Open(link: true);
        using var _ = shell;

        var load = _sent.OfType<LoadScene>().Last();
        Assert.Equal([north.Number, south.Number], load.Scenes.Select(s => s.Scene));
        Assert.All(load.Scenes, s => Assert.Equal(1UL, Assert.Single(s.Entities).Id));
        Assert.Equal("North Gate", load.Scenes[0].Entities[0].Name);

        _sent.Clear();
        shell.Edit("Rename", Rename("South Door"));
        shell.ActivateScene(north);
        shell.Edit("Rename", Rename("North Door"));
        shell.Scene!.Undo();

        var edits = _sent.OfType<ApplyOperations>().SelectMany(a => a.Operations).ToList();
        Assert.Equal([south.Number, north.Number, north.Number], edits.Select(o => o.Scene));
        Assert.Equal(["South Door", "North Door", "North Gate"], edits.Select(o => o.Name));
    }

    [Fact]
    public void SelectingAnEntityOfAnotherSceneMakesItsSceneActive()
    {
        var (shell, north, south) = Open();
        using var _ = shell;
        shell.OnGameMessage(World(north, south));

        shell.Selection.Select(NorthGate);

        Assert.Same(north, shell.Scene);
        Assert.Equal("North Gate", shell.SelectedSceneEntity!.Name);
        shell.DeleteSelected();
        Assert.Null(north.Scene.Find(1));
        Assert.NotNull(south.Scene.Find(1));

        // An entity with the same scene ID in the other scene is that scene's.
        shell.Selection.Select(SouthGate);
        Assert.Same(south, shell.Scene);
        Assert.Equal("South Gate", shell.SelectedSceneEntity!.Name);
        Assert.Equal(SouthGate, shell.FindInScene(1)!.Handle);
    }

    [Fact]
    public void TheGamesProblemsAreTheirScenes()
    {
        var (shell, north, south) = Open();
        using var _ = shell;
        shell.OnGameMessage(World(north, south));

        shell.OnGameMessage(new EditProblems(false, [new EditProblem(south.Number, 1, "Spin has no field speed, so it is not set")]));

        Assert.Single(shell.ProblemsOf(shell.World.Find(SouthGate)!));
        Assert.Empty(shell.ProblemsOf(shell.World.Find(NorthGate)!));
        shell.ActivateScene(north);
        Assert.Empty(shell.ProblemsOf(1));
    }

    [Fact]
    public void ClosingASceneSendsTheOthersAndTheLastOneStays()
    {
        var (shell, north, south) = Open(link: true);
        using var _ = shell;
        shell.Edit("Rename", Rename("South Door"));
        _sent.Clear();

        Assert.True(shell.Commands.Get(EditorCommands.CloseScene).CanExecute);
        Assert.True(shell.CloseScene(south));

        Assert.Equal([north], shell.Scenes);
        Assert.Same(north, shell.Scene);
        Assert.Equal([north.Number], Assert.Single(_sent.OfType<LoadScene>()).Scenes.Select(s => s.Scene));
        Assert.False(shell.CloseScene(north));
        Assert.False(shell.Commands.Get(EditorCommands.CloseScene).CanExecute);
    }

    [Fact]
    public void AnOpenSceneIsNotOpenedTwiceAndOpenSceneReplacesThemAll()
    {
        var (shell, north, south) = Open();
        using var _ = shell;

        Assert.True(shell.AddScene(north.Path));
        Assert.Equal(2, shell.Scenes.Count);
        Assert.Same(north, shell.Scene);

        File.WriteAllText(_temp.Combine("east.scene"), Text("East Gate"));
        Assert.True(shell.OpenScene(_temp.Combine("east.scene")));
        var east = Assert.Single(shell.Scenes);
        // A number is not used again, so an edit that names a closed scene never edits another.
        Assert.True(east.Number > south.Number);
    }

    [Fact]
    public void ABehavioursEditsOfTwoScenesAreAnEntryInEach()
    {
        var (shell, north, south) = Open(link: true);
        using var _ = shell;
        var ticket = _sent.OfType<LoadScene>().Last().Ticket;
        static Link.Protocol.Operation SetSpeed(SceneDocument scene, double speed) =>
            new SetField(1, 1001, "speed", SceneValue.Of(SceneNumber.Of(speed))).ToWire()! with { Scene = scene.Number };

        shell.OnGameMessage(new BehaviourOperations(4, ticket, "Spin", [SetSpeed(north, 2), SetSpeed(south, 3)]));

        Assert.Equal(new BehaviourOperationsAnswer(4, true), _sent.OfType<BehaviourOperationsAnswer>().Last());
        Assert.Single(north.History);
        Assert.Single(south.History);
        Assert.True(north.History[0].Follows && south.History[0].Follows);

        // A batch that names a scene that is not open is refused, and changes neither.
        shell.OnGameMessage(new BehaviourOperations(5, ticket, "Spin", [SetSpeed(north, 4), SetSpeed(north, 5) with { Scene = 99 }]));
        Assert.Equal(new BehaviourOperationsAnswer(5, false), _sent.OfType<BehaviourOperationsAnswer>().Last());
        Assert.Single(north.History);
    }

    [Fact]
    public void HiddenEntitiesAreTheirScenes()
    {
        var (shell, north, south) = Open(link: true);
        using var _ = shell;
        shell.OnGameMessage(World(north, south));
        _sent.Clear();

        shell.SetHidden(shell.World.Find(SouthGate)!, true);

        Assert.Equal([SouthGate], _sent.OfType<SetHidden>().Last().Entities);
        Assert.True(shell.IsHidden(shell.World.Find(SouthGate)!));
        Assert.False(shell.IsHidden(shell.World.Find(NorthGate)!));
    }

    [Fact]
    public void TheOutlinerShowsEachScenesEntitiesUnderItsHeading() => Ui.Run(() =>
    {
        var (shell, north, south) = Open();
        using var _ = shell;
        shell.OnGameMessage(World(north, south));
        var view = new OutlinerView(shell);
        view.Subscriptions.Attach();

        var rows = view.Rows;
        Assert.Equal(4, rows.Count);
        Assert.Equal(north, Assert.IsType<OutlinerHeading>(rows[0]).Scene);
        Assert.Equal(NorthGate, Assert.IsType<OutlinerRow>(rows[1]).Node.Handle);
        var southHeading = Assert.IsType<OutlinerHeading>(rows[2]);
        Assert.Equal(south, southHeading.Scene);
        Assert.True(southHeading.Active);
        Assert.Equal(SouthGate, Assert.IsType<OutlinerRow>(rows[3]).Node.Handle);

        // The active scene's heading follows the selection.
        shell.Selection.Select(NorthGate);
        Assert.True(Assert.IsType<OutlinerHeading>(view.Rows[0]).Active);

        // With one scene open, the outliner has no headings.
        shell.CloseScene(south);
        shell.OnGameMessage(new EntitySnapshot([new EntityInfo(NorthGate, "North Gate", 1, north.Number, 0, true, [1])]));
        Assert.IsType<OutlinerRow>(Assert.Single(view.Rows));
    });

    public void Dispose() => _temp.Dispose();
}
