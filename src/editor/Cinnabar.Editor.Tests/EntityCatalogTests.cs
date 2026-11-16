using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Tests;

/// <summary>The kinds of entity that the Add menu makes in one step (see docs/editor/shell-and-panels.md#add).</summary>
public sealed class EntityCatalogTests : IDisposable
{
    readonly TempDirectory _temp = new("entity-catalog");

    // A door 5 m along x.
    const string SceneText = "scene 2\n\n" +
        "entity 0000000000000001\nname = \"Door\"\ncomponent 1 Transform\n\tposition = [83886080, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n";

    const ulong Door = 1UL << 32;

    EditorShell NewShell()
    {
        var shell = TestShell.Open(_temp, "door.scene", SceneText);
        shell.OnGameMessage(new EntitySnapshot([new EntityInfo(Door, "Door", 1, 0, true, [1])]));
        return shell;
    }

    static Document.SceneEntity Created(EditorShell shell) => shell.Scene!.Scene.Entities.Single(e => e.Id != 1);

    [Fact]
    public void EveryKindHasACommandAndAnIconAndItsOwnId()
    {
        using var shell = NewShell();

        Assert.Equal(EntityCatalog.All.Count, EntityCatalog.All.Select(t => t.Id).Distinct().Count());
        Assert.Equal(EntityCatalog.All.Count, EntityCatalog.All.Select(t => EditorCommands.AddEntity(t.Id)).Distinct().Count());
        foreach (var template in EntityCatalog.All)
        {
            var command = shell.Commands.Get(EditorCommands.AddEntity(template.Id));
            Assert.Equal(template.Label, command.Label);
            Assert.Equal(template.Icon, command.Icon);
            Assert.True(command.CanExecute);
            // A component is there once, by the ID that the engine registers it with.
            Assert.Equal(template.Components.Count, template.Components.Select(c => c.Id).Distinct().Count());
        }
        // The kinds that had a command before the catalog keep its ID, which a key binding may name.
        Assert.Equal("entity.create", EditorCommands.AddEntity(EntityCatalog.EmptyId));
        Assert.Equal("entity.createVolume", EditorCommands.AddEntity("globalVolume"));
        Assert.Equal("entity.createReflectionProbe", EditorCommands.AddEntity("reflectionProbe"));
        Assert.Equal("Ctrl+Shift+N", shell.Commands.Get(EditorCommands.CreateEntity).Shortcut);
    }

    [Fact]
    public void TheAddMenuHasEveryKindOnceInItsCategory()
    {
        var menu = DefaultRibbon.AddMenu();

        var commands = Commands.MenuEntry.Commands(menu).ToList();
        Assert.Equal(EntityCatalog.All.Select(t => EditorCommands.AddEntity(t.Id)).Order(), commands.Order());
        Assert.Equal(EntityCatalog.Categories, menu.OfType<Commands.Submenu>().Select(s => s.Label));
    }

    [Fact]
    public void APointLightIsLitAndOneUndoEntry()
    {
        using var shell = NewShell();

        Assert.True(shell.Commands.Get(EditorCommands.AddEntity("pointLight")).Execute());

        var created = Created(shell);
        Assert.Equal("Point Light", created.Name);
        var light = created.Components.Single(c => c.Name == "Point_Light");
        // A light that is added as a component alone has an intensity of 0, and shows nothing.
        Assert.True(light.Fields.Single(f => f.Name == "intensity").Value.Numbers[0].Float > 0);
        Assert.True(light.Fields.Single(f => f.Name == "cast_shadows").Value.Bool);
        Assert.Contains(created.Components, c => c.Id == SceneEdits.TransformId);
        Assert.Equal("Add Point Light", Assert.Single(shell.Scene!.History).Label);
        // Undo takes the whole entity, and the catalog's own components are not the scene's to change.
        shell.Scene.Undo();
        Assert.Single(shell.Scene.Scene.Entities);
        Assert.Equal(2, EntityCatalog.Find("pointLight")!.Components[0].Fields.Count);
    }

    [Fact]
    public void ALightThatShinesAlongItsZStartsTurnedDown()
    {
        using var shell = NewShell();

        shell.AddEntity(EntityCatalog.Find("spotLight")!);

        var pose = SceneEdits.WorldPose(shell.Scene!.Scene, Created(shell))!;
        var forward = pose.Rotation.Rotate(new Vec3(0, 0, 1));
        Assert.True(forward.Y < -0.99, $"the spot light points along {forward}");
    }

    [Fact]
    public void ANewEntityGoesWhereTheSelectionIs()
    {
        using var shell = NewShell();
        shell.Viewports[0].Session.Show(new Avalonia.PixelSize(1600, 900));
        shell.Selection.Select(Door);

        shell.AddEntity(EntityCatalog.Find("camera")!);

        Assert.Equal([83886080L, 0L, 0L], SceneEdits.WorldPose(shell.Scene!.Scene, Created(shell))!.Position);
    }

    [Fact]
    public void WithoutASelectionANewEntityGoesWhereTheShownSceneViewLooks()
    {
        using var shell = NewShell();
        shell.Viewports[0].Session.Show(new Avalonia.PixelSize(1600, 900));
        shell.Selection.Clear();
        var pivot = shell.Viewports[0].Camera.Pivot;

        shell.AddEntity(EntityCatalog.Find("audioSource")!);

        Assert.Equal(pivot, SceneEdits.WorldPose(shell.Scene!.Scene, Created(shell))!.Position);
        // The scene's one entity is 5 m from the origin, and the view was framed on it, so the pivot is not the origin.
        Assert.NotEqual([0L, 0L, 0L], pivot);
    }

    [Fact]
    public void NoKindIsAddedWhileTheGamePlays()
    {
        using var shell = NewShell();
        shell.Play();

        Assert.All(EntityCatalog.All, t => Assert.False(shell.Commands.Get(EditorCommands.AddEntity(t.Id)).CanExecute));
        Assert.False(shell.AddEntity(EntityCatalog.Find("pointLight")!));
        Assert.Single(shell.Scene!.Scene.Entities);
    }

    public void Dispose() => _temp.Dispose();
}
