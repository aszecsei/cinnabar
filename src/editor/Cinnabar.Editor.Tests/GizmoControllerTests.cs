using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using GizmoKind = Cinnabar.Editor.Link.Protocol.GizmoKind;
using GizmoPart = Cinnabar.Editor.Link.Protocol.GizmoPart;

namespace Cinnabar.Editor.Tests;

/// <summary>A gizmo drag's undo entry and its target's hooks, with a target that records what it is told.</summary>
public sealed class GizmoControllerTests
{
    readonly List<string> _calls = [];
    bool _previews = true;

    sealed class Target(List<string> calls) : IGizmoTarget
    {
        public IReadOnlyList<Operation> Steps { get; set; } = [new DestroyEntity(1)];

        public IReadOnlyList<Operation> Drag(GizmoDrag drag, Vec2 pixel, bool snap)
        {
            calls.Add($"drag {snap}");
            return Steps;
        }

        public void Previewed() => calls.Add("previewed");

        public void Ending() => calls.Add("ending");

        public void Ended(bool committed) => calls.Add($"ended {committed}");
    }

    GizmoController Controller() => new(label => _calls.Add($"begin {label}"), ops => { _calls.Add($"preview {ops.Count}"); return _previews; },
        () => _calls.Add("commit"), () => _calls.Add("cancel"), () => _calls.Add("sent"));

    static GizmoDrag Drag() => new(GizmoKind.Translate, GizmoPart.X, new EditorCamera(), new Vec3(0, 0, 5), Quat.Identity, new Vec2(800, 450), 1600, 900);

    [Fact]
    public void ADragBeginsPreviewsEachStepAndCommitsOnRelease()
    {
        var gizmo = Controller();
        gizmo.Start(Drag(), new Target(_calls), "Move");
        Assert.True(gizmo.IsDragging);
        gizmo.Drag(new Vec2(810, 450), snap: true);
        gizmo.Release();

        Assert.Equal(["begin Move", "sent", "drag True", "preview 1", "previewed", "ending", "commit", "sent", "ended True"], _calls);
        Assert.False(gizmo.IsDragging);
        Assert.Null(gizmo.Target);
    }

    [Fact]
    public void CancelPutsTheEditBackAndANullLabelBeginsNothing()
    {
        var gizmo = Controller();
        gizmo.Start(Drag(), new Target(_calls), null);
        gizmo.Cancel();

        Assert.Equal(["sent", "ending", "cancel", "sent", "ended False"], _calls);
    }

    [Fact]
    public void AnEmptyStepOrAFailedPreviewIsNotPreviewed()
    {
        var gizmo = Controller();
        var target = new Target(_calls) { Steps = [] };
        gizmo.Start(Drag(), target, "Move");
        gizmo.Drag(new Vec2(810, 450), snap: false);
        target.Steps = [new DestroyEntity(1)];
        _previews = false;
        gizmo.Drag(new Vec2(820, 450), snap: false);

        Assert.Equal(["begin Move", "sent", "drag False", "drag False", "preview 1"], _calls);
    }

    [Fact]
    public void DropForgetsTheDragAndLeavesTheEditAlone()
    {
        var gizmo = Controller();
        gizmo.Start(Drag(), new Target(_calls), "Move");
        _calls.Clear();
        gizmo.Drop();
        gizmo.Drag(new Vec2(810, 450), snap: false);
        gizmo.Release();
        gizmo.Cancel();

        Assert.Empty(_calls);
        Assert.False(gizmo.IsDragging);
    }
}
