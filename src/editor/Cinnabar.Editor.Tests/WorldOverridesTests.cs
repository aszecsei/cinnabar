using System.Text;
using Avalonia.Controls;
using Avalonia.LogicalTree;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Tests;

/// <summary>The editor's overrides of the game's world in Edit, outside the document (see docs/editor/link.md#overrides).</summary>
public sealed class WorldOverridesTests : IDisposable
{
    readonly TempDirectory _temp = new("world-overrides");
    readonly List<ILinkMessage> _sent = [];

    const string Text = "scene 1\n\nentity 0000000000000001\nname = \"Door\"\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n";

    const ulong Door = 1UL << 32;

    static readonly ComponentType Transform = new(1, "Transform", "Transform", 56,
    [
        new FieldInfo("frozen", 52, FieldKind.Bool, FieldKind.Bool, [], false, false, 0, 0, false, false, 0, ""),
    ]);

    EditorShell NewShell()
    {
        var shell = TestShell.Open(_temp, "door.scene", Text);
        shell.Host.LinkForTests(_sent.Add);
        shell.OnGameMessage(new ComponentTypes([Transform]));
        shell.OnGameMessage(new EntitySnapshot([new EntityInfo(Door, "Door", 1, 1, 0, true, [1])]));
        _sent.Clear();
        return shell;
    }

    static OverrideWrites Moved(float x) => new()
    {
        Transforms = [new OverrideTransform(new OverrideTarget(OverrideTargetKind.SceneEntity, 1, 1), [(long)(x * 16777216), 0, 0], [0, 0, 0, 1], [1, 1, 1])],
    };

    static ulong Hash(string name) => Fnv.Hash64(Encoding.UTF8.GetBytes(name));

    [Fact]
    public void AnOverrideWritesTheWorldAndNotTheDocument()
    {
        using var shell = NewShell();
        var token = shell.Overrides.Begin("the test")!;
        Assert.Equal(token.Id, Assert.Single(_sent.OfType<BeginOverride>()).Override);

        Assert.True(token.Write(Moved(2)));

        // One message carries the frame's writes.
        var frame = Assert.Single(_sent.OfType<OverrideFrame>());
        Assert.Equal(token.Id, frame.Override);
        Assert.Single(frame.Transforms);
        Assert.Empty(_sent.OfType<ApplyOperations>());
        Assert.Empty(shell.Scene!.History);
        Assert.False(shell.Scene.IsDirty);
        // The scene's one undo entry is free for an edit.
        var edit = shell.TryBeginEdit("Rename", "the test");
        Assert.NotNull(edit);
        edit!.Cancel();
    }

    [Fact]
    public void ASaveWhileAnOverrideIsOnWritesTheDocument()
    {
        using var shell = NewShell();
        var token = shell.Overrides.Begin("the test")!;
        token.Write(Moved(2));

        Assert.True(shell.SaveScene());

        var saved = File.ReadAllText(_temp.Combine("door.scene"));
        Assert.Contains("position = [0, 0, 0]", saved);
        Assert.DoesNotContain("33554432", saved);
        Assert.False(shell.Scene!.IsDirty);
        Assert.True(token.IsLive);
    }

    [Fact]
    public void AReleaseEndsTheTokenAndAStaleOneDoesNothing()
    {
        using var shell = NewShell();
        var token = shell.Overrides.Begin("the test")!;
        var ended = new List<OverrideEnd>();
        token.Ended += ended.Add;

        token.Release();
        token.Release();

        Assert.Equal([OverrideEnd.Released], ended);
        Assert.Equal(token.Id, Assert.Single(_sent.OfType<ReleaseOverride>()).Override);
        Assert.False(token.Write(Moved(1)));
        Assert.Empty(_sent.OfType<OverrideFrame>());
        // A later override has a higher number, so the game drops what comes late for this one.
        Assert.True(shell.Overrides.Begin("the next")!.Id > token.Id);
    }

    [Fact]
    public void TheGameEndsAnOverrideAndALateEndDoesNothing()
    {
        using var shell = NewShell();
        var token = shell.Overrides.Begin("the test")!;
        var ended = new List<OverrideEnd>();
        token.Ended += ended.Add;

        shell.OnGameMessage(new OverrideEnded(token.Id, OverrideEndReason.CodeReloaded));
        shell.OnGameMessage(new OverrideEnded(token.Id, OverrideEndReason.Mode));

        Assert.Equal([OverrideEnd.CodeReloaded], ended);
        Assert.False(token.IsLive);
        Assert.Empty(_sent.OfType<ReleaseOverride>());
    }

    [Fact]
    public void PlayEndsTheOverridesAndNoneBeginsOutsideEdit()
    {
        using var shell = NewShell();
        var token = shell.Overrides.Begin("the test")!;
        var ended = new List<OverrideEnd>();
        token.Ended += ended.Add;

        shell.Play();

        Assert.Equal([OverrideEnd.Mode], ended);
        Assert.Null(shell.Overrides.Begin("another"));
        Assert.Empty(_sent.OfType<ReleaseOverride>());
    }

    [Fact]
    public void ANewGameStateEndsTheOverridesAndSendsNoneAgain()
    {
        using var shell = NewShell();
        var token = shell.Overrides.Begin("the test")!;
        token.Write(Moved(2));
        var ended = new List<OverrideEnd>();
        token.Ended += ended.Add;
        _sent.Clear();

        shell.Host.Receive(new GameReloaded(ReloadKind.SoftRestart));

        Assert.Equal([OverrideEnd.NewGameState], ended);
        Assert.Empty(_sent.OfType<BeginOverride>());
        Assert.Empty(_sent.OfType<OverrideFrame>());
        Assert.Empty(_sent.OfType<ReleaseOverride>());
        Assert.Empty(shell.Overrides.Live);
    }

    [Fact]
    public void TheLinkClosingEndsTheOverrides()
    {
        using var shell = NewShell();
        var token = shell.Overrides.Begin("the test")!;
        var ended = new List<OverrideEnd>();
        token.Ended += ended.Add;

        shell.Host.Stop();

        Assert.False(shell.Host.Linked);
        Assert.Equal([OverrideEnd.LinkClosed], ended);
        Assert.False(token.Write(Moved(1)));
    }

    [Fact]
    public void WithoutALinkNoOverrideBegins()
    {
        using var shell = TestShell.Open(_temp, "door.scene", Text);
        Assert.Null(shell.Overrides.Begin("the test"));
    }

    [Fact]
    public void AFieldThatAnOverrideHoldsIsMarked() => Ui.Run(() =>
    {
        using var shell = NewShell();
        shell.Selection.Select(Door);
        var view = new PropertiesView(shell);
        view.Subscriptions.Attach();
        var content = (StackPanel)view.Content!;
        TextBlock Frozen() => content.GetLogicalDescendants().OfType<TextBlock>().Single(t => t.Classes.Contains("field-name") && t.Text == "Frozen");

        shell.OnGameMessage(new EntityValues(Door, [new ComponentValue(1, new byte[56])], [], [new HeldField(1, Hash("frozen"))], [], new ShownPreview(0, 0)));
        Assert.Contains("held", Frozen().Classes);

        shell.OnGameMessage(new EntityValues(Door, [new ComponentValue(1, new byte[56])], [], [], [], new ShownPreview(0, 0)));
        Assert.DoesNotContain("held", Frozen().Classes);
    });

    [Fact]
    public void AnEntityThatAnOverrideWritesIsMarkedInTheOutliner() => Ui.Run(() =>
    {
        using var shell = NewShell();
        var view = new OutlinerView(shell);
        view.Subscriptions.Attach();
        static bool Marked(OutlinerView view) => view.OverrideMark(view.Rows.OfType<OutlinerRow>().Single().Node) != null;
        Assert.False(Marked(view));

        shell.OnGameMessage(new OverriddenEntities([Door]));
        Assert.True(shell.World.IsOverridden(Door));
        Assert.True(Marked(view));

        shell.OnGameMessage(new OverriddenEntities([]));
        Assert.False(Marked(view));
    });

    public void Dispose() => _temp.Dispose();
}
