using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using LogLevel = Cinnabar.Editor.Panels.LogLevel;
using SceneValue = Cinnabar.Editor.Document.SceneValue;

namespace Cinnabar.Editor.Tests;

/// <summary>Editing in the shell, without a host: the document, saving, autosave, and the host's refusals.</summary>
public sealed class EditingTests : IDisposable
{
    readonly TempDirectory _temp = new("editing");

    const string Text = "scene 1\n\nentity 0000000000000001\nname = \"Door\"\ncomponent 1 Transform\n\tposition = [2516582400000000000, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n";

    EditorShell NewShell(out string scenePath)
    {
        scenePath = _temp.Combine("door.scene");
        return TestShell.Open(_temp, "door.scene", File.Exists(scenePath) ? null : Text);
    }

    [Fact]
    public void EditsUndoRedoAndSaveThroughTheCommands()
    {
        using var shell = NewShell(out var path);
        var changes = 0;
        shell.SceneChanged += () => changes++;

        Assert.False(shell.Commands.Get(EditorCommands.Undo).CanExecute);
        Assert.True(shell.Edit("Rename", new Rename(1, "Front Door")));
        Assert.True(shell.Scene!.IsDirty);
        Assert.True(shell.Commands.Get(EditorCommands.Undo).Execute());
        Assert.Equal("Door", shell.Scene.Scene.Find(1)!.Name);
        Assert.True(shell.Commands.Get(EditorCommands.Redo).Execute());

        Assert.True(shell.Commands.Get(EditorCommands.Save).Execute());
        Assert.False(shell.Scene.IsDirty);
        Assert.Contains("name = \"Front Door\"", File.ReadAllText(path));
        Assert.True(changes >= 4);
    }

    [Fact]
    public void AnEditThatDoesNotFitGoesToTheConsole()
    {
        using var shell = NewShell(out _);

        Assert.False(shell.Edit("Rename", new Rename(99, "Nobody")));

        Assert.Contains(shell.Console.Lines, l => l.Level == LogLevel.Error && l.Text.Contains("cannot rename"));
        Assert.Empty(shell.Scene!.History);
    }

    [Fact]
    public void ANewerAutosaveIsOfferedAndRestored()
    {
        string path;
        using (var shell = NewShell(out path))
        {
            shell.Edit("Rename", new Rename(1, "Unsaved"));
            shell.Tick(DateTime.UtcNow);
            // The editor crashes here: nothing saves the scene.
        }
        File.SetLastWriteTimeUtc(path, DateTime.UtcNow - TimeSpan.FromMinutes(1));

        using var again = NewShell(out _);

        Assert.NotNull(again.PendingRestore);
        Assert.Equal("Door", again.Scene!.Scene.Find(1)!.Name);
        Assert.True(again.RestoreAutosave());
        Assert.Equal("Unsaved", again.Scene!.Scene.Find(1)!.Name);
        Assert.True(again.Scene.IsDirty);
        Assert.Equal(path, again.Scene.Path);

        // Saving puts the changes in the file, and the autosave goes.
        again.SaveScene();
        Assert.Null(again.Autosave.Newer(path));
    }

    [Fact]
    public void UndoingBackToTheFileRemovesTheAutosave()
    {
        using var shell = NewShell(out var path);

        shell.Edit("Rename", new Rename(1, "Unsaved"));
        Assert.True(File.Exists(shell.Autosave.PathOf(path)));
        shell.Scene!.Undo();

        Assert.False(File.Exists(shell.Autosave.PathOf(path)));
    }

    [Fact]
    public void ADiscardedAutosaveIsNotOfferedAgain()
    {
        string path;
        using (var shell = NewShell(out path))
        {
            shell.Edit("Rename", new Rename(1, "Unsaved"));
            shell.Tick(DateTime.UtcNow);
        }
        File.SetLastWriteTimeUtc(path, DateTime.UtcNow - TimeSpan.FromMinutes(1));
        using (var again = NewShell(out _))
        {
            again.DiscardAutosave();
        }

        using var third = NewShell(out _);
        Assert.Null(third.PendingRestore);
    }

    [Fact]
    public void TheHostsRefusalsShowOnTheirEntities()
    {
        using var shell = NewShell(out _);
        var changed = 0;
        shell.ProblemsChanged += () => changed++;

        shell.OnGameMessage(new EditProblems(false, [new EditProblem(1, "Spin has no field speed, so it is not set")]));
        shell.OnGameMessage(new EditProblems(false, [new EditProblem(1, "Spin has no field speed, so it is not set")]));

        Assert.Equal(["Spin has no field speed, so it is not set"], shell.ProblemsOf(1));
        Assert.Contains(shell.Console.Lines, l => l.Level == LogLevel.Warning && l.Text.Contains("did not apply"));

        // A resync's problems replace the ones before it.
        shell.OnGameMessage(new EditProblems(true, []));
        Assert.Empty(shell.ProblemsOf(1));
        Assert.Equal(3, changed);
    }

    [Fact]
    public void TypedValuesBecomeSceneValues()
    {
        using var shell = NewShell(out _);
        FieldInfo Field(FieldKind kind, EnumValue[]? values = null) => TestFields.Of(kind, values: values);

        var position = FieldEditor.ForComponent(shell, 1, 1, Field(FieldKind.Position))!;
        position.Current = SceneValue.Of(SceneNumber.Of(2516582400000000000L), SceneNumber.Of(5L), SceneNumber.Of(0L));
        var moved = position.Parse(1, "1.5 km", out _)!;
        // The other axes keep their raw values exactly.
        Assert.Equal((Int128)2516582400000000000, moved.Numbers[0].Integer);
        Assert.Equal((Int128)(1500L << 24), moved.Numbers[1].Integer);

        var rotation = FieldEditor.ForComponent(shell, 1, 1, Field(FieldKind.Quaternion))!;
        rotation.Current = SceneEdits.Floats(0, 0, 0, 1);
        var turned = rotation.Parse(1, "90°", out _)!;
        Assert.Equal(Math.Sqrt(0.5), turned.Numbers[1].Float, 6);
        Assert.Equal(Math.Sqrt(0.5), turned.Numbers[3].Float, 6);

        var small = FieldEditor.ForComponent(shell, 1, 1, Field(FieldKind.I8))!;
        Assert.Equal((Int128)(-5), small.Parse(-1, "-5", out _)!.Numbers[0].Integer);
        Assert.Null(small.Parse(-1, "300", out var error));
        Assert.Contains("range", error);
        Assert.Null(small.Parse(-1, "1.5", out _));

        var mode = FieldEditor.ForComponent(shell, 1, 1, Field(FieldKind.Enum, [new EnumValue("Idle", 0), new EnumValue("Very_Busy", 5)]))!;
        Assert.Equal(["Idle", "Very Busy"], mode.Options);

        Assert.Null(FieldEditor.ForComponent(shell, 1, 1, TestFields.Of(FieldKind.F32, readOnly: true)));

        var range = FieldEditor.ForComponent(shell, 1, 1, Field(FieldKind.Vector2))!;
        range.Current = SceneEdits.Floats(-8, 4);
        Assert.Equal([-8.0, 6.5], range.Parse(1, "6.5", out _)!.Numbers.Select(n => n.Float));
    }

    [Fact]
    public void ASliderOrPickerDragIsOneUndoEntry()
    {
        using var shell = NewShell(out _);
        var scale = FieldEditor.ForComponent(shell, 1, 1, TestFields.Of(FieldKind.Vector3, name: "scale"))!;
        scale.Current = SceneEdits.Floats(1, 1, 1);

        scale.BeginScrub(-1);
        scale.SetNumbers([2, 2, 2]);
        scale.SetNumbers([0.5, 0.25, 3]);
        scale.EndScrub();

        var entry = Assert.Single(shell.Scene!.History);
        Assert.Equal("Drag Scale", entry.Label);
        var value = shell.Scene.Scene.Find(1)!.Components.Single(c => c.Id == 1).Fields.Single(f => f.Name == "scale").Value;
        Assert.Equal([0.5, 0.25, 3.0], value.Numbers.Select(n => n.Float));

        // Outside a drag, each value is an edit of its own.
        scale.SetNumbers([1, 1, 1]);
        Assert.Equal(2, shell.Scene.History.Count);
    }

    [Fact]
    public void ASettingKeepsItsValueWhileItIsNotOverridden()
    {
        using var shell = NewShell(out _);
        var gain = FieldEditor.ForComponent(shell, 1, 1, TestFields.Of(FieldKind.F32, name: "gain", overrideOffset: 0))!;
        Document.SceneField? Line(string name) => shell.Scene!.Scene.Find(1)!.Components.Single(c => c.Id == 1).Fields.SingleOrDefault(f => f.Name == name);

        // The value that shows becomes the volume's own.
        gain.Current = SceneEdits.Floats(0.5);
        gain.Override();
        Assert.Equal("Override Gain", shell.Scene!.History[^1].Label);
        Assert.Equal(0.5, Line("gain")!.Value.Numbers[0].Float);
        Assert.Null(Line("gain.override"));

        // Clearing the override keeps the value, to compare against what is below.
        gain.StopOverriding();
        Assert.Equal("Stop Overriding Gain", shell.Scene.History[^1].Label);
        Assert.Equal(0.5, Line("gain")!.Value.Numbers[0].Float);
        Assert.False(Line("gain.override")!.Value.Bool);
        shell.Scene.Undo();
        Assert.Null(Line("gain.override"));
        gain.StopOverriding();

        // Changing the value overrides it again.
        gain.SetNumbers([0]);
        Assert.Equal(0.0, Line("gain")!.Value.Numbers[0].Float);
        Assert.Null(Line("gain.override"));

        // A reset forgets both, so the setting has its default.
        gain.StopOverriding();
        gain.Reset();
        Assert.Null(Line("gain"));
        Assert.Null(Line("gain.override"));
        shell.Scene.Undo();
        Assert.False(Line("gain.override")!.Value.Bool);
    }

    [Fact]
    public void ANewVolumeIsGlobalAndOneUndoEntry()
    {
        using var shell = NewShell(out _);

        Assert.True(shell.Commands.Get(EditorCommands.CreateVolume).Execute());

        var created = shell.Scene!.Scene.Entities.Single(e => e.Id != 1);
        Assert.Equal("Volume", created.Name);
        var volume = created.Components.Single(c => c.Id == SceneEdits.VolumeId);
        Assert.Equal("Global", volume.Fields.Single(f => f.Name == "shape").Value.Text);
        Assert.Contains(created.Components, c => c.Id == SceneEdits.TransformId);
        Assert.Equal("Create Volume", Assert.Single(shell.Scene.History).Label);
    }

    [Fact]
    public void ANewEntityGoesWhereTheSelectionIsOrToTheOrigin()
    {
        using var shell = NewShell(out _);

        shell.CreateEntity();

        var created = shell.Scene!.Scene.Entities.Single(e => e.Id != 1);
        Assert.Equal("Entity", created.Name);
        Assert.Equal([0L, 0L, 0L], SceneEdits.WorldPose(shell.Scene.Scene, created)!.Position);
        Assert.Equal("Create Entity", shell.Scene.History[^1].Label);
    }

    public void Dispose() => _temp.Dispose();
}
