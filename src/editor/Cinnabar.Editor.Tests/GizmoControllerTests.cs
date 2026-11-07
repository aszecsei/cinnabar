using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using GizmoKind = Cinnabar.Editor.Link.Protocol.GizmoKind;
using GizmoPart = Cinnabar.Editor.Link.Protocol.GizmoPart;

namespace Cinnabar.Editor.Tests;

/// <summary>A gizmo drag's undo entry and its target's hooks, with a target that records what it is told.</summary>
public sealed class GizmoControllerTests : IDisposable
{
    readonly TempDirectory _temp = new("gizmo-controller");
    readonly List<string> _calls = [];

    sealed class Target(List<string> calls) : IGizmoTarget
    {
        public IReadOnlyList<Operation> Steps { get; set; } = [new Rename(1, "Moved")];

        public IReadOnlyList<Operation> Drag(GizmoDrag drag, Vec2 pixel, bool snap)
        {
            calls.Add($"drag {snap}");
            return Steps;
        }

        public void Previewed() => calls.Add("previewed");

        public void Ended(bool committed) => calls.Add($"ended {committed}");
    }

    EditorShell NewShell() => TestShell.Open(_temp, "gizmo.scene", "scene 1\n\nentity 0000000000000001\nname = \"Door\"\n");

    GizmoController Controller(EditorShell shell) => new(label =>
    {
        _calls.Add($"begin {label}");
        return shell.TryBeginEdit(label, "the gizmo");
    }, () => _calls.Add("sent"));

    static GizmoDrag Drag() => new(GizmoKind.Translate, GizmoPart.X, new EditorCamera(), new Vec3(0, 0, 5), Quat.Identity, new Vec2(800, 450), 1600, 900);

    static string Name(EditorShell shell) => shell.Scene!.Scene.Find(1)!.Name;

    [Fact]
    public void ADragBeginsPreviewsEachStepAndCommitsOnRelease()
    {
        using var shell = NewShell();
        var gizmo = Controller(shell);
        Assert.True(gizmo.Start(Drag(), new Target(_calls), "Move"));
        Assert.True(gizmo.IsDragging);
        gizmo.Drag(new Vec2(810, 450), snap: true);
        gizmo.Release();

        Assert.Equal(["begin Move", "sent", "drag True", "previewed", "sent", "ended True"], _calls);
        Assert.False(gizmo.IsDragging);
        Assert.Null(gizmo.Target);
        Assert.Equal("Move", Assert.Single(shell.Scene!.History).Label);
        Assert.Null(shell.OpenEdit);
    }

    [Fact]
    public void CancelPutsTheEditBack()
    {
        using var shell = NewShell();
        var gizmo = Controller(shell);
        gizmo.Start(Drag(), new Target(_calls), "Move");
        gizmo.Drag(new Vec2(810, 450), snap: false);
        Assert.Equal("Moved", Name(shell));
        gizmo.Cancel();

        Assert.Equal(["begin Move", "sent", "drag False", "previewed", "sent", "ended False"], _calls);
        Assert.Equal("Door", Name(shell));
        Assert.Empty(shell.Scene!.History);
    }

    [Fact]
    public void AnEmptyStepOrAFailedPreviewIsNotPreviewed()
    {
        using var shell = NewShell();
        var gizmo = Controller(shell);
        var target = new Target(_calls) { Steps = [] };
        gizmo.Start(Drag(), target, "Move");
        gizmo.Drag(new Vec2(810, 450), snap: false);
        // An entity that the document does not have does not fit.
        target.Steps = [new Rename(99, "Gone")];
        gizmo.Drag(new Vec2(820, 450), snap: false);

        Assert.Equal(["begin Move", "sent", "drag False", "drag False"], _calls);
    }

    [Fact]
    public void ADragDoesNotStartWhileAnotherEditIsOpen()
    {
        using var shell = NewShell();
        var other = shell.TryBeginEdit("Scrub", "a field drag")!;
        var gizmo = Controller(shell);

        Assert.False(gizmo.Start(Drag(), new Target(_calls), "Move"));
        Assert.False(gizmo.IsDragging);
        gizmo.Release();
        Assert.Same(other, shell.OpenEdit);
    }

    [Fact]
    public void ADragInAnOpenEditCommitsItForItsOwner()
    {
        using var shell = NewShell();
        var pending = shell.TryBeginEdit("Extrude", "a mesh tool")!;
        var owner = new List<bool>();
        pending.Ended += owner.Add;
        var gizmo = Controller(shell);

        Assert.True(gizmo.Start(Drag(), new Target(_calls), pending));
        gizmo.Drag(new Vec2(810, 450), snap: false);
        gizmo.Release();

        Assert.Equal([true], owner);
        Assert.Equal(["sent", "drag False", "previewed", "sent", "ended True"], _calls);
        Assert.Equal("Extrude", Assert.Single(shell.Scene!.History).Label);
    }

    [Fact]
    public void AnEditEndedElsewhereEndsTheDrag()
    {
        using var shell = NewShell();
        var gizmo = Controller(shell);
        gizmo.Start(Drag(), new Target(_calls), "Move");
        gizmo.Drag(new Vec2(810, 450), snap: false);
        _calls.Clear();
        shell.InterruptEdit();

        Assert.Equal(["sent", "ended False"], _calls);
        Assert.False(gizmo.IsDragging);
        Assert.Equal("Door", Name(shell));
        _calls.Clear();
        gizmo.Drag(new Vec2(820, 450), snap: false);
        gizmo.Release();
        gizmo.Cancel();
        Assert.Empty(_calls);
    }

    public void Dispose() => _temp.Dispose();
}
