using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Shell;
using Operation = Cinnabar.Editor.Document.Operation;
using SceneBehaviour = Cinnabar.Editor.Document.SceneBehaviour;
using SceneComponent = Cinnabar.Editor.Document.SceneComponent;
using SceneEntity = Cinnabar.Editor.Document.SceneEntity;
using SceneField = Cinnabar.Editor.Document.SceneField;
using SceneValue = Cinnabar.Editor.Document.SceneValue;

namespace Cinnabar.Editor.Tests;

/// <summary>The game's commands in the shell, without a host, and their operations on the wire.</summary>
public sealed class GameCommandTests : IDisposable
{
    readonly TempDirectory _temp = new("command");

    EditorShell NewShell()
    {
        return TestShell.Open(_temp, "door.scene", "scene 1\n\nentity 0000000000000001\nname = \"Door\"\n");
    }

    static GameCommandInfo Info(string id, string tab, string group, bool edits = false) => new(id, id, "", tab, group, "", edits);

    [Fact]
    public void OperationsComeBackFromTheWireAsTheyWent()
    {
        var created = new SceneEntity(7) { Name = "Made", Parent = 1, Active = false };
        created.Components.Add(new SceneComponent(1, "Transform", [new SceneField("position", SceneValue.Of(SceneNumber.Of(5L), SceneNumber.Of(-1L), SceneNumber.Of(0L)))]));
        created.Behaviours.Add(new SceneBehaviour("7142e05b3941bc44849ed0379727e60b", [new SceneField("rate", SceneValue.Of(SceneNumber.Of(0.75)))]));
        Operation[] ops =
        [
            new CreateEntity(created),
            new DestroyEntity(7),
            new Rename(1, "Door"),
            new SetParent(1, 9),
            new SetActive(1, true),
            new AddComponent(1, new SceneComponent(1002, "Triangle", [new SceneField("brightness", SceneValue.Of(SceneNumber.Of(2.0)))])),
            new RemoveComponent(1, 1002),
            new SetField(1, 1001, "speed", SceneValue.Of(SceneNumber.Of(-1.0))),
            new SetField(1, 1001, "speed", null),
            new RemoveBehaviour(1, "7142e05b3941bc44849ed0379727e60b"),
            new SetBehaviourField(1, "7142e05b3941bc44849ed0379727e60b", "target", SceneValue.EntityRef(7)),
            new SetBehaviourField(1, "7142e05b3941bc44849ed0379727e60b", "name", null),
        ];
        foreach (var op in ops)
        {
            var back = Operation.FromWire(op.ToWire()!);
            Assert.Equal(SceneFile.Write(Apply(op)), SceneFile.Write(Apply(back)));
        }
    }

    // A small scene with the parts that the operations use, after an operation.
    static Scene Apply(Operation op)
    {
        var scene = new Scene();
        var door = new SceneEntity(1);
        door.Components.Add(new SceneComponent(1001, "Spin", [new SceneField("speed", SceneValue.Of(SceneNumber.Of(1.0)))]));
        door.Components.Add(new SceneComponent(1002, "Triangle", []));
        door.Behaviours.Add(new SceneBehaviour("7142e05b3941bc44849ed0379727e60b", [new SceneField("name", SceneValue.String("a"))]));
        scene.Entities.Add(door);
        scene.Entities.Add(new SceneEntity(9));
        if (op is not CreateEntity)
        {
            scene.Entities.Add(new SceneEntity(7));
        }
        op.Apply(scene);
        return scene;
    }

    [Fact]
    public void TheGamesCommandsComeAndGoWithItsList()
    {
        using var shell = NewShell();
        var ribbonChanges = 0;
        shell.RibbonChanged += () => ribbonChanges++;

        shell.OnGameMessage(new GameCommands([Info("mygame.report", "Game", "Debug"), Info("mygame.add", "Game", "Make", edits: true)]));
        Assert.NotNull(shell.Commands.Find("game.mygame.report"));
        Assert.Contains(shell.Ribbon.Tabs, t => t.Label == "Game");
        Assert.Empty(shell.Ribbon.Validate(shell.Commands));

        // After a code reload, the new list replaces the old one.
        shell.OnGameMessage(new GameCommands([Info("mygame.add", "Game", "Make", edits: true)]));
        Assert.Null(shell.Commands.Find("game.mygame.report"));
        Assert.Equal(2, ribbonChanges);
        Assert.Single(shell.Ribbon.Tabs, t => t.Label == "Game");
        // Without a host, no game command runs.
        Assert.False(shell.Commands.Get("game.mygame.add").CanExecute);
    }

    [Fact]
    public void ACommandsOperationsAreOneUndoEntry()
    {
        using var shell = NewShell();
        shell.OnGameMessage(new GameCommands([Info("mygame.add", "Game", "Make", edits: true)]));
        var created = new SceneEntity(0x42) { Name = "Triangle" };
        shell.OnGameMessage(new GameCommandResult("mygame.add",
            [new CreateEntity(created).ToWire(), new Rename(1, "Front Door").ToWire()], "added a triangle"));

        var entry = Assert.Single(shell.Scene!.History);
        Assert.Equal("mygame.add", entry.Label);
        Assert.NotNull(shell.Scene.Scene.Find(0x42));
        Assert.Contains(shell.Console.Lines, l => l.Text == "added a triangle");
        shell.Scene.Undo();
        Assert.Null(shell.Scene.Scene.Find(0x42));
        Assert.Equal("Door", shell.Scene.Scene.Find(1)!.Name);
    }

    public void Dispose() => _temp.Dispose();
}
