using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using LogLevel = Cinnabar.Editor.Model.LogLevel;
using SceneValue = Cinnabar.Editor.Document.SceneValue;

namespace Cinnabar.Editor.Tests;

/// <summary>The scene's open undo entry and the token of its owner: one open at a time, stale tokens, and Play.</summary>
public sealed class SceneEditTests : IDisposable
{
    readonly TempDirectory _temp = new("scene-edit");

    const string Text = "scene 1\n\nentity 0000000000000001\nname = \"Door\"\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n";

    EditorShell NewShell() => TestShell.Open(_temp, "door.scene", Text);

    static string Name(EditorShell shell) => shell.Scene!.Scene.Find(1)!.Name;

    static SceneValue Scale(EditorShell shell) =>
        shell.Scene!.Scene.Find(1)!.Components.Single(c => c.Id == SceneEdits.TransformId).Fields.Single(f => f.Name == "scale").Value;

    [Fact]
    public void OneEditIsOpenAndAStaleTokenDoesNothing()
    {
        using var shell = NewShell();
        var edit = shell.TryBeginEdit("Rename Door", "the test")!;
        var ended = new List<bool>();
        edit.Ended += ended.Add;
        Assert.Same(edit, shell.OpenEdit);
        Assert.Equal("the test", shell.OpenEdit!.Owner);
        // Another does not open, and the open one stays.
        Assert.Null(shell.TryBeginEdit("Other", "another"));
        Assert.True(edit.IsOpen);

        Assert.True(edit.Preview(new Rename(1, "Gate")));
        edit.Commit();
        Assert.Null(shell.OpenEdit);
        Assert.False(edit.IsOpen);
        Assert.Equal([true], ended);

        // Once it ended, the token does nothing: no preview, and no second commit or cancel.
        Assert.False(edit.Preview(new Rename(1, "Wall")));
        edit.Commit();
        edit.Cancel();
        Assert.Equal("Gate", Name(shell));
        Assert.Equal([true], ended);
        Assert.Equal("Rename Door", Assert.Single(shell.Scene!.History).Label);
    }

    [Fact]
    public void AStaleTokenDoesNotEndTheNextOwnersEdit()
    {
        using var shell = NewShell();
        var first = shell.TryBeginEdit("First", "the first")!;
        first.Cancel();
        var second = shell.TryBeginEdit("Second", "the second")!;
        second.Preview(new Rename(1, "Second"));

        first.Commit();
        first.Cancel();
        Assert.False(first.Preview(new Rename(1, "First")));
        Assert.Same(second, shell.OpenEdit);
        Assert.Equal("Second", Name(shell));
    }

    [Fact]
    public void AnEditWhileAnotherIsOpenIsRefusedWithItsOwner()
    {
        using var shell = NewShell();
        var edit = shell.TryBeginEdit("Extrude", "a mesh tool")!;

        Assert.False(shell.Edit("Rename", new Rename(1, "Gate")));
        Assert.Contains(shell.Console.Lines, l => l.Level == LogLevel.Warning && l.Text.Contains("a mesh tool") && l.Text.Contains("\"Extrude\""));
        Assert.Same(edit, shell.OpenEdit);
        Assert.Equal("Door", Name(shell));
    }

    [Fact]
    public void PlayDuringAScrubCommitsItAndTheScrubEndsQuietly()
    {
        using var shell = NewShell();
        var scale = FieldEditor.ForComponent(shell, 1, 1, TestFields.Of(FieldKind.Vector3, name: "scale"))!;
        scale.Current = SceneEdits.Floats(1, 1, 1);

        scale.BeginScrub(-1);
        scale.SetNumbers([2, 2, 2]);
        shell.Play();
        Assert.Null(shell.OpenEdit);
        // The slider lets go after Play: the scrub is over, so it neither throws nor edits.
        scale.SetNumbers([3, 3, 3]);
        scale.EndScrub();

        Assert.Equal("Drag Scale", Assert.Single(shell.Scene!.History).Label);
        Assert.Equal([2.0, 2.0, 2.0], Scale(shell).Numbers.Select(n => n.Float));
    }

    [Fact]
    public void PlayPutsBackADragThatOnlyShowsAnInstanceOrAMaterial()
    {
        using var shell = NewShell();
        var drop = shell.TryBeginEdit("Set Material", "a material drop")!;
        drop.Preview(new Rename(1, "Shown"));

        shell.Play();

        Assert.Null(shell.OpenEdit);
        Assert.Equal("Door", Name(shell));
        Assert.Empty(shell.Scene!.History);
    }

    [Fact]
    public void AScrubDoesNotStartWhileAnotherEditIsOpen()
    {
        using var shell = NewShell();
        var other = shell.TryBeginEdit("Extrude", "a mesh tool")!;
        var scale = FieldEditor.ForComponent(shell, 1, 1, TestFields.Of(FieldKind.Vector3, name: "scale"))!;
        scale.Current = SceneEdits.Floats(1, 1, 1);
        var before = Scale(shell);

        scale.BeginScrub(-1);
        scale.Scrub(0, 100, Avalonia.Input.KeyModifiers.None);
        scale.EndScrub();

        Assert.Same(other, shell.OpenEdit);
        Assert.Equal(before, Scale(shell));
        other.Commit();
        Assert.Empty(shell.Scene!.History);
    }

    public void Dispose() => _temp.Dispose();
}
