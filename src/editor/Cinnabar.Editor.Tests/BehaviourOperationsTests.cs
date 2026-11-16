using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Shell;
using Operation = Cinnabar.Editor.Document.Operation;
using SceneComponent = Cinnabar.Editor.Document.SceneComponent;
using SceneEntity = Cinnabar.Editor.Document.SceneEntity;
using SceneValue = Cinnabar.Editor.Document.SceneValue;
using Welcome = Cinnabar.Editor.Link.Cook.Welcome;
using Wire = Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Tests;

/// <summary>An edit-mode behaviour's edits in the shell, with a fake link: the entry that follows, undo and the answer.</summary>
public sealed class BehaviourOperationsTests : IDisposable
{
    readonly TempDirectory _temp = new("behaviours");
    readonly List<ILinkMessage> _sent = [];

    const string Door = "22222222222222222222222222222222";

    const string Text = "scene 2\n\n" +
        "entity 0000000000000001\nname = \"Door\"\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n" +
        "component 1001 Spin\n\tspeed = 1\n\n" +
        "entity 0000000000000002\nname = \"Hinge\"\nparent = @0000000000000001\ncomponent 2 Local_Transform\n\toffset = [0, 1, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n";

    EditorShell NewShell()
    {
        var shell = TestShell.Open(_temp, "door.scene", Text);
        shell.Host.LinkForTests(_sent.Add);
        _scene = _sent.OfType<LoadScene>().LastOrDefault()?.Ticket ?? 0;
        return shell;
    }

    // The ticket of the scene that the game has: the last one that the editor sent.
    ulong _scene;
    ulong SceneTicket => _sent.OfType<LoadScene>().LastOrDefault()?.Ticket ?? _scene;

    BehaviourOperations Batch(ulong ticket, params Operation[] ops) =>
        new(ticket, SceneTicket, "Ring", [.. ops.Select(o => o.ToWire()!)]);

    static Operation SetSpeed(double speed) => new SetField(1, 1001, "speed", SceneValue.Of(SceneNumber.Of(speed)));

    static double Speed(EditorShell shell) =>
        shell.Scene!.Scene.Find(1)!.Components.Single(c => c.Id == 1001).Fields.Single(f => f.Name == "speed").Value.Numbers[0].Float;

    BehaviourOperationsAnswer Answer() => Assert.IsType<BehaviourOperationsAnswer>(_sent.Last());

    [Fact]
    public void ABehavioursBatchIsAnEntryThatFollowsAndMarksTheSceneDirty()
    {
        using var shell = NewShell();
        Assert.True(shell.Edit("Rename", new Rename(1, "Front Door")));
        _sent.Clear();
        shell.OnGameMessage(Batch(5, SetSpeed(3)));

        Assert.Equal(3, Speed(shell));
        Assert.True(shell.Scene!.IsDirty);
        var entry = shell.Scene.History[^1];
        Assert.Equal("Ring", entry.Label);
        Assert.True(entry.Follows);
        Assert.False(shell.Scene.History[0].Follows);
        // The answer goes after the operations that the edit sent back.
        Assert.IsType<ApplyOperations>(_sent[^2]);
        Assert.Equal(new BehaviourOperationsAnswer(5, true), Answer());
    }

    [Fact]
    public void UndoAndRedoStepOverABehavioursEntryWithItsCause()
    {
        using var shell = NewShell();
        Assert.True(shell.Edit("Rename", new Rename(1, "Front Door")));
        shell.OnGameMessage(Batch(1, SetSpeed(3)));
        shell.OnGameMessage(Batch(2, SetSpeed(4)));
        _sent.Clear();

        shell.Scene!.Undo();
        Assert.Equal(0, shell.Scene.Position);
        Assert.Equal("Door", shell.Scene.Scene.Find(1)!.Name);
        Assert.Equal(1, Speed(shell));
        // One message, so the game runs no frame between the entries.
        Assert.Single(_sent.OfType<ApplyOperations>());

        _sent.Clear();
        shell.Scene.Redo();
        Assert.Equal(3, shell.Scene.Position);
        Assert.Equal(4, Speed(shell));
        Assert.Single(_sent.OfType<ApplyOperations>());
    }

    [Fact]
    public void MovingThroughTheHistoryStopsOnlyBetweenGroups()
    {
        using var shell = NewShell();
        Assert.True(shell.Edit("Rename", new Rename(1, "Front Door")));
        shell.OnGameMessage(Batch(1, SetSpeed(3)));
        Assert.True(shell.Edit("Rename", new Rename(1, "Back Door")));
        Assert.Equal(3, shell.Scene!.History.Count);

        // A click on the behaviour's row, or the one before it, keeps the two together.
        Assert.True(shell.MoveHistoryTo(1));
        Assert.Equal(2, shell.Scene.Position);
        Assert.True(shell.MoveHistoryTo(0));
        Assert.Equal(0, shell.Scene.Position);
    }

    [Fact]
    public void ABatchDuringAnOpenEntryJoinsItAndCancelsWithIt()
    {
        using var shell = NewShell();
        var edit = shell.TryBeginEdit("Drag", "a test")!;
        Assert.True(edit.Preview(new Rename(1, "Dragged")));
        shell.OnGameMessage(Batch(1, SetSpeed(3)));
        Assert.Equal(new BehaviourOperationsAnswer(1, true), Answer());
        Assert.Equal(3, Speed(shell));
        Assert.Empty(shell.Scene!.History);

        edit.Cancel();
        Assert.Equal(1, Speed(shell));
        Assert.Empty(shell.Scene.History);
    }

    [Fact]
    public void ABatchOutsideEditOrForAnotherSceneIsRefused()
    {
        using var shell = NewShell();
        shell.OnGameMessage(new BehaviourOperations(1, SceneTicket + 1, "Ring", [SetSpeed(3).ToWire()!]));
        Assert.Equal(new BehaviourOperationsAnswer(1, false), Answer());

        shell.Play();
        shell.OnGameMessage(Batch(2, SetSpeed(3)));
        Assert.Equal(new BehaviourOperationsAnswer(2, false), Answer());
        Assert.Empty(shell.Scene!.History);
        Assert.Equal(1, Speed(shell));
    }

    [Fact]
    public void ABatchThatDoesNotFitIsPutBack()
    {
        using var shell = NewShell();
        shell.OnGameMessage(Batch(1, SetSpeed(3), new Rename(99, "Nobody")));
        Assert.Equal(new BehaviourOperationsAnswer(1, false), Answer());
        Assert.Equal(1, Speed(shell));
        Assert.Empty(shell.Scene!.History);
    }

    [Fact]
    public void ADestroyTakesTheDescendantsAndAParentKeepsThePose()
    {
        using var shell = NewShell();
        shell.OnGameMessage(Batch(1, new SetParent(2, 0)));
        var hinge = shell.Scene!.Scene.Find(2)!;
        Assert.Equal(0UL, hinge.Parent);
        Assert.Contains(hinge.Components, c => c.Id == SceneEdits.TransformId);

        shell.OnGameMessage(Batch(2, new SetParent(2, 1), new DestroyEntity(1)));
        Assert.Null(shell.Scene.Scene.Find(1));
        Assert.Null(shell.Scene.Scene.Find(2));
        shell.Scene.Undo();
        Assert.NotNull(shell.Scene.Scene.Find(2));
    }

    [Fact]
    public void AnInstanceOperationMakesAnInstance()
    {
        Directory.CreateDirectory(_temp.Path);
        File.WriteAllText(_temp.Combine("door.prefab"), File.ReadAllText(Path.Combine(EditorOptions.RepositoryRoot(), "lib", "engine", "asset", "format", "testdata", "prefabs", "door.prefab")));
        File.WriteAllText(_temp.Combine("lamp.prefab"), File.ReadAllText(Path.Combine(EditorOptions.RepositoryRoot(), "lib", "engine", "asset", "format", "testdata", "prefabs", "lamp.prefab")));
        using var shell = NewShell();
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [new Importer(AssetKind.Prefab, ".prefab", [])], [], []));
        shell.Assets.Apply(new AssetSnapshot(
        [
            TestAssets.Make(Door, AssetKind.Prefab, "door.prefab", dependencies: ["11111111111111111111111111111111"]),
            TestAssets.Make("11111111111111111111111111111111", AssetKind.Prefab, "lamp.prefab"),
        ], []));
        var pose = new SceneComponent(SceneEdits.TransformId, "Transform", SceneEdits.TransformFields(Pose.Identity));
        var wire = new Wire.Operation(OperationKind.CreateInstance, 0x77, [], "", 0, false, 0, [SceneSnapshot.Component(pose)], new byte[16], [], Convert.FromHexString(Door));

        shell.OnGameMessage(new BehaviourOperations(1, SceneTicket, "Scatter", [wire]));

        Assert.Equal(new BehaviourOperationsAnswer(1, true), Answer());
        var instance = shell.Scene!.Scene.Find(0x77)!;
        Assert.Equal(Door, instance.Prefab);
        Assert.False(instance.Active);
        Assert.True(shell.Scene.Expanded.Flat.Entities.Count > 3);
    }

    public void Dispose() => _temp.Dispose();
}
