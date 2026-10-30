using Avalonia;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using SceneValue = Cinnabar.Editor.Document.SceneValue;

namespace Cinnabar.Editor.Tests;

/// <summary>The viewport's tools in the shell, without a host: selection of several entities, their edits, and gizmo drags.</summary>
public sealed class ViewportToolsTests : IDisposable
{
    readonly TempDirectory _temp = new("viewport");

    // Two roots 1 m apart along x, 5 m ahead of a camera at the origin.
    const string Text = "scene 1\n\n" +
        "entity 0000000000000001\nname = \"Left\"\ncomponent 1 Transform\n\tposition = [0, 0, 83886080]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n\n" +
        "entity 0000000000000002\nname = \"Right\"\ncomponent 1 Transform\n\tposition = [16777216, 0, 83886080]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n";

    static ulong Handle(uint index, uint generation = 1) => (ulong)generation << 32 | index;

    EditorShell NewShell()
    {
        var shell = TestShell.Open(_temp, "two.scene", Text);
        Report(shell, 1);
        shell.Viewport.RequestSize(new PixelSize(1600, 900));
        shell.Camera.Place([0, 0, 0], 0, 0);
        return shell;
    }

    // The host's entity list, with the handles of a generation.
    static void Report(EditorShell shell, uint generation) => shell.OnGameMessage(new EntitySnapshot(
    [
        new EntityInfo(Handle(0, generation), "Left", 1, 0, true, [1]),
        new EntityInfo(Handle(1, generation), "Right", 2, 0, true, [1]),
    ]));

    static long X(EditorShell shell, ulong id) =>
        (long)shell.Scene!.Scene.Find(id)!.Components[0].Fields.Find(f => f.Name == "position")!.Value.Numbers[0].Integer!.Value;

    [Fact]
    public void TheLastEntitySelectedIsThePrimaryOne()
    {
        var selection = new Selection();
        selection.Select(1);
        selection.Add([2, 3]);
        Assert.Equal([1UL, 2, 3], selection.Entities);
        Assert.Equal(3UL, selection.Entity);

        selection.Add([1]);
        Assert.Equal([2UL, 3, 1], selection.Entities);
        selection.Toggle(3);
        Assert.Equal([2UL, 1], selection.Entities);
        selection.Toggle(4);
        Assert.Equal(4UL, selection.Entity);
        selection.Clear();
        Assert.True(selection.IsEmpty);
    }

    [Fact]
    public void AResyncKeepsEverySelectedEntity()
    {
        using var shell = NewShell();
        shell.Selection.Set([Handle(1), Handle(0)]);

        Report(shell, 2);

        Assert.Equal([Handle(1, 2), Handle(0, 2)], shell.Selection.Entities);
    }

    [Fact]
    public void DeletingAndDuplicatingActOnEverySelectedEntity()
    {
        using var shell = NewShell();
        shell.Selection.Set([Handle(0), Handle(1)]);

        Assert.True(shell.Commands.Get(EditorCommands.DuplicateEntity).Execute());
        Assert.Equal(4, shell.Scene!.Scene.Entities.Count);
        Assert.Equal("Duplicate 2 Entities", shell.Scene.History[^1].Label);

        shell.Selection.Set([Handle(0), Handle(1)]);
        Assert.True(shell.Commands.Get(EditorCommands.DeleteEntity).Execute());
        Assert.Equal(2, shell.Scene.Scene.Entities.Count);
        shell.Scene.Undo();
        Assert.Equal(4, shell.Scene.Scene.Entities.Count);
    }

    [Fact]
    public void AFieldEditOfSeveralEntitiesKeepsEachOnesOtherAxes()
    {
        using var shell = NewShell();
        var field = TestFields.Of(FieldKind.Position, name: "position");
        var editor = FieldEditor.ForComponent(shell, [1, 2], SceneEdits.TransformId, field)!;
        editor.SetCurrent(0, SceneValue.Of(SceneNumber.Of(0L), SceneNumber.Of(0L), SceneNumber.Of(83886080L)));
        editor.SetCurrent(1, SceneValue.Of(SceneNumber.Of(16777216L), SceneNumber.Of(0L), SceneNumber.Of(83886080L)));

        Assert.True(editor.Commit(1, "2 m"));

        Assert.Single(shell.Scene!.History);
        Assert.Equal(0, X(shell, 1));
        Assert.Equal(16777216, X(shell, 2));
        var y = shell.Scene.Scene.Find(2)!.Components[0].Fields.Find(f => f.Name == "position")!.Value.Numbers[1].Integer;
        Assert.Equal((Int128)(2L << 24), y);
    }

    [Fact]
    public void AGizmoDragMovesTheSelectionInOneUndoEntry()
    {
        using var shell = NewShell();
        shell.Selection.Set([Handle(0), Handle(1)]);
        var (width, height) = shell.FrameSize;
        var (pivot, axes) = shell.GizmoPose()!.Value;
        Assert.Equal([16777216L, 0, 83886080], pivot);
        var center = shell.Camera.RelativeTo(pivot);
        var size = Gizmo.Size(shell.Camera, center, height);
        Vec2 Along(double meters) => shell.Camera.Project(center + Vec3.UnitX * meters, width, height)!.Value;

        Assert.True(shell.PressGizmo(Along(0.5 * size)));
        Assert.Equal(GizmoPart.X, shell.HotPart);
        shell.DragGizmo(Along(0.5 * size + 0.3), invertSnap: false);
        shell.DragGizmo(Along(0.5 * size + 0.6), invertSnap: false);
        shell.ReleaseGizmo();

        var entry = Assert.Single(shell.Scene!.History);
        Assert.Equal("Move 2 Entities", entry.Label);
        Assert.Equal(2, entry.Operations.Count);
        Assert.InRange(X(shell, 2) - 16777216, (long)(0.59 * (1 << 24)), (long)(0.61 * (1 << 24)));
        Assert.Equal(X(shell, 2) - 16777216, X(shell, 1));

        // Snapping, here by holding Ctrl, rounds the move to its step.
        Assert.True(shell.PressGizmo(Along(0.5 * size + 0.6)));
        shell.DragGizmo(Along(0.5 * size + 0.9), invertSnap: true);
        shell.ReleaseGizmo();
        Assert.Equal(X(shell, 2) - 16777216, X(shell, 1));
        Assert.InRange(X(shell, 1), (long)(0.84 * (1 << 24)), (long)(0.86 * (1 << 24)));
    }

    [Fact]
    public void AGizmoDragCanBeCancelled()
    {
        using var shell = NewShell();
        shell.Selection.Select(Handle(0));
        shell.SetTool(Tool.Rotate);
        var (width, height) = shell.FrameSize;
        var center = shell.Camera.RelativeTo(shell.GizmoPose()!.Value.Pivot);
        var size = Gizmo.Size(shell.Camera, center, height);
        Vec2 OnRing(double degrees) => shell.Camera.Project(
            center + new Vec3(Math.Cos(degrees * Math.PI / 180), Math.Sin(degrees * Math.PI / 180), 0) * size, width, height)!.Value;

        Assert.True(shell.PressGizmo(OnRing(30)));
        shell.DragGizmo(OnRing(70), invertSnap: false);
        Assert.NotEqual(0, shell.Scene!.Scene.Find(1)!.Components[0].Fields.Find(f => f.Name == "rotation")!.Value.Numbers[2].Float);
        shell.CancelGizmo();

        Assert.Empty(shell.Scene.History);
        Assert.Equal(0, shell.Scene.Scene.Find(1)!.Components[0].Fields.Find(f => f.Name == "rotation")!.Value.Numbers[2].Float);
    }

    [Fact]
    public void OrbitSelectionTurnsAboutTheSelection()
    {
        using var shell = NewShell();
        shell.Selection.Set([Handle(1)]);
        var (width, height) = shell.FrameSize;
        long[] right = [16777216, 0, 83886080];
        var before = shell.Camera.Project(shell.Camera.RelativeTo(right), width, height)!.Value;

        // Without the option, Alt-orbit turns about the pivot ahead, and the entity moves on screen.
        shell.Orbit(100, 0);
        Assert.NotEqual(before, shell.Camera.Project(shell.Camera.RelativeTo(right), width, height)!.Value);

        shell.Camera.Place([0, 0, 0], 0, 0);
        Assert.True(shell.Commands.Get(EditorCommands.OrbitSelection).Execute());
        shell.Orbit(100, 30);
        var after = shell.Camera.Project(shell.Camera.RelativeTo(right), width, height)!.Value;
        Assert.InRange(after.X - before.X, -0.01, 0.01);
        Assert.InRange(after.Y - before.Y, -0.01, 0.01);
    }

    [Fact]
    public void TheSelectToolHasNoGizmo()
    {
        using var shell = NewShell();
        shell.Selection.Select(Handle(0));
        Assert.NotNull(shell.GizmoPose());
        shell.Commands.Get(EditorCommands.SelectTool).Execute();
        Assert.Null(shell.GizmoPose());
        Assert.False(shell.PressGizmo(new Vec2(800, 450)));
    }

    [Fact]
    public void HiddenAndLockedEntitiesAreKeptForTheUserAndTheScene()
    {
        using (var shell = NewShell())
        {
            shell.Selection.Set([Handle(0)]);
            Assert.True(shell.Commands.Get(EditorCommands.HideSelected).Execute());
            shell.SetLocked([2], true);

            Assert.True(shell.IsHidden(1) && shell.IsHiddenInTree(Handle(0)));
            Assert.False(shell.IsHiddenInTree(Handle(1)));
            Assert.True(shell.IsLockedInTree(Handle(1)));
            // Neither changes the scene.
            Assert.Empty(shell.Scene!.History);
        }

        // The next session has them back, from the user's settings.
        using var again = NewShell();
        Assert.True(again.IsHidden(1));
        Assert.True(again.IsLocked(2));
        Assert.True(again.Commands.Get(EditorCommands.ShowAll).Execute());
        Assert.False(again.IsHidden(1));
        Assert.False(again.Commands.Get(EditorCommands.ShowAll).CanExecute);
    }

    [Fact]
    public void HidingAParentHidesItsChildren()
    {
        using var shell = NewShell();
        shell.OnGameMessage(new EntitySnapshot(
        [
            new EntityInfo(Handle(0), "Left", 1, 0, true, [1]),
            new EntityInfo(Handle(1), "Right", 2, Handle(0), true, [1]),
        ]));
        shell.SetHidden([1], true);
        Assert.True(shell.IsHiddenInTree(Handle(1)));
        Assert.False(shell.IsHidden(2));
    }

    public void Dispose() => _temp.Dispose();
}
