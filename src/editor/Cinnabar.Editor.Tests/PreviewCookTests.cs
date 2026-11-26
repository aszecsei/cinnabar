using System.Collections.Concurrent;
using Cinnabar.Editor.Content;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Shell;
using Welcome = Cinnabar.Editor.Link.Cook.Welcome;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// The preview cook that the material, animation graph and UI editors share (see docs/editor/material-editor.md#material-editor):
/// one cook runs at a time, and closing an editor drops its cook, so an answer that comes later opens no preview for a slot
/// that the editor gave up.
/// </summary>
public sealed class PreviewCookTests : IDisposable
{
    const string MaterialGuid = "f7eadea8bd278c0ae71b61b681352a82";
    const string GraphGuid = "0123456789abcdef0123456789abcdef";
    const string UiGuid = "5b845a4341f6a3b772ec017211470fac";

    static readonly PreviewResult Cooked = new("", [], []);

    readonly TempDirectory _temp = new("preview-cook");
    readonly FakePreviewCooker _cooker = new();
    readonly ConcurrentQueue<ILinkMessage> _sent = new();
    // The texts that a preview cook sent with the answers that they wait for, and the texts whose answers it took.
    readonly List<(string Text, TaskCompletionSource<PreviewResult> Answer)> _cooks = [];
    readonly List<string> _cooked = [];

    public void Dispose() => _temp.Dispose();

    public static TheoryData<string> Kinds => ["material", "animation graph", "UI document"];

    // A shell with the host linked and the fake cooker, and an open editor of a kind.
    (EditorShell Shell, PreviewOwner Editor) Open(string kind)
    {
        var shell = TestShell.Open(_temp, null, null);
        shell.PreviewCooker = _cooker;
        shell.Host.LinkForTests(_sent.Enqueue);
        var samples = Path.Combine(EditorOptions.RepositoryRoot(), "samples", "mygame", "content");
        switch (kind)
        {
            case "material":
            {
                File.WriteAllText(_temp.Combine("plain.material"), "material 1\nshading = lit\n\nnode 1 output\n\tposition = [0, 0]\n");
                shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [], MaterialTests.Nodes, []));
                shell.Assets.Apply(new ShadingModels(MaterialTests.Shading));
                shell.Assets.Apply(new AssetSnapshot([TestAssets.Make(MaterialGuid, AssetKind.Material, "plain.material", permutations: 1)], []));
                return (shell, shell.OpenMaterial(shell.Assets.Find(MaterialGuid)!)!);
            }
            case "animation graph":
            {
                File.Copy(Path.Combine(samples, "models", "fox", "fox.animation_graph"), _temp.Combine("fox.animation_graph"));
                shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [], [], []));
                shell.Assets.Apply(new AssetSnapshot([TestAssets.Make(GraphGuid, AssetKind.AnimationGraph, "fox.animation_graph")], []));
                return (shell, shell.OpenAnimationGraph(shell.Assets.Find(GraphGuid)!)!);
            }
            default:
            {
                File.Copy(Path.Combine(samples, "ui", "pause.ui"), _temp.Combine("pause.ui"));
                shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [], [], []));
                shell.Assets.Apply(new AssetSnapshot([TestAssets.Make(UiGuid, AssetKind.Ui, "pause.ui")], []));
                return (shell, shell.OpenUiDocument(shell.Assets.Find(UiGuid)!)!);
            }
        }
    }

    [Theory]
    [MemberData(nameof(Kinds))]
    public void AnOpenEditorOpensItsPreviewAgainOnceItsTextCooks(string kind)
    {
        var (shell, editor) = Open(kind);
        using var _ = shell;
        var cook = Assert.Single(_cooker.Requests);
        Assert.Equal(editor.Guid, cook.Guid);
        _sent.Clear();

        cook.Answer(Cooked);

        var open = Assert.Single(_sent.OfType<OpenPreview>());
        Assert.Equal((uint)editor.PreviewId!, open.Id);
        Assert.True(open.Unsaved);
    }

    [Theory]
    [MemberData(nameof(Kinds))]
    public void ACookThatAnswersAfterTheEditorClosesSendsNothingAndNorDoesItsPreview(string kind)
    {
        var (shell, editor) = Open(kind);
        using var _ = shell;
        var cook = Assert.Single(_cooker.Requests);
        _sent.Clear();

        shell.CloseGraph((IGraphEditor)editor, discard: true);
        Assert.IsType<ClosePreview>(Assert.Single(_sent));
        Assert.Null(editor.PreviewId);

        cook.Answer(Cooked);
        editor.Orbit(10, 5);
        editor.Zoom(1);
        editor.SendPreview();

        Assert.IsType<ClosePreview>(Assert.Single(_sent));
    }

    [Fact]
    public void AMaterialProblemHasItsNodeAndItsLine()
    {
        var (shell, owner) = Open("material");
        using var _ = shell;
        var editor = (MaterialEditor)owner;
        Assert.Same(CheckState.Pending, editor.Checks.State);

        Assert.Single(_cooker.Requests).Answer(new PreviewResult("bad", [new Problem(editor.Document.Path, 4, 0, true, "bad")], []));

        var problem = Assert.Single(editor.Problems);
        Assert.Equal((1, 4), (problem.Node, problem.Line));
        Assert.Equal(new CheckState.Failed("bad"), editor.Checks.State);
    }

    // A preview cook of a text that the test changes, whose cooks wait for the test's answers.
    PreviewCook Cooking(Func<string> text) => new(() => true, text, t =>
    {
        var answer = new TaskCompletionSource<PreviewResult>();
        _cooks.Add((t, answer));
        return answer.Task;
    }, (t, _) => _cooked.Add(t));

    [Fact]
    public void ChangesDuringACookCookTheNewestTextOnceAfterIt()
    {
        var text = "first";
        using var cook = Cooking(() => text);

        _ = cook.CookNow();
        text = "second";
        _ = cook.CookNow();
        text = "third";
        _ = cook.CookNow();
        Assert.Equal(["first"], _cooks.Select(c => c.Text));

        _cooks[0].Answer.SetResult(Cooked);
        Assert.Equal(["first", "third"], _cooks.Select(c => c.Text));
        _cooks[1].Answer.SetResult(Cooked);
        Assert.Equal(["first", "third"], _cooked);
        Assert.Equal(2, _cooks.Count);
    }

    [Fact]
    public void AClosedCookDropsTheAnswerOfTheCookThatRunsAndCooksNoMore()
    {
        using var cook = Cooking(() => "text");
        _ = cook.CookNow();
        // A change while it runs would cook again after it.
        _ = cook.CookNow();

        cook.Dispose();
        _cooks[0].Answer.SetResult(Cooked);
        _ = cook.CookNow();
        cook.Schedule();

        Assert.Single(_cooks);
        Assert.Empty(_cooked);
    }

    /// <summary>A cook link that holds each cook until the test answers it.</summary>
    internal sealed class FakePreviewCooker : IPreviewCooker
    {
        readonly List<Cook> _requests = [];

        public bool Linked => true;

        public IReadOnlyList<Cook> Requests
        {
            get
            {
                lock (_requests)
                {
                    return [.. _requests];
                }
            }
        }

        public Task<PreviewResult> CookPreview(string guid, string text, PlanQuery? plan = null)
        {
            // Without RunContinuationsAsynchronously, an answer runs the editor's continuation before Answer returns.
            var cook = new Cook(guid, text, plan, new TaskCompletionSource<PreviewResult>());
            lock (_requests)
            {
                _requests.Add(cook);
            }
            return cook.Result.Task;
        }
    }

    internal sealed record Cook(string Guid, string Text, PlanQuery? Plan, TaskCompletionSource<PreviewResult> Result)
    {
        public void Answer(PreviewResult result) => Result.SetResult(result);
    }
}
