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
/// closing an editor cancels its cook, so an answer that comes later, or a delayed cook, opens no preview for a slot that
/// the editor gave up.
/// </summary>
public sealed class PreviewCookTests : IDisposable
{
    const string MaterialGuid = "f7eadea8bd278c0ae71b61b681352a82";
    const string GraphGuid = "0123456789abcdef0123456789abcdef";
    const string UiGuid = "5b845a4341f6a3b772ec017211470fac";

    static readonly PreviewResult Cooked = new("", []);
    static readonly PreviewResult Failed = new("the text has an error", []);

    readonly TempDirectory _temp = new("preview-cook");
    readonly FakePreviewCooker _cooker = new();
    readonly ConcurrentQueue<ILinkMessage> _sent = new();

    public void Dispose() => _temp.Dispose();

    public static TheoryData<string> Kinds => ["material", "animation graph", "UI document"];

    // A shell with the host linked and the fake cooker, and an open editor of a kind, with an edit that changes its text.
    (EditorShell Shell, PreviewOwner Editor, Action Edit) Open(string kind)
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
                var editor = shell.OpenMaterial(shell.Assets.Find(MaterialGuid)!)!;
                return (shell, editor, () => editor.AddParam("float"));
            }
            case "animation graph":
            {
                File.Copy(Path.Combine(samples, "models", "fox", "fox.animation_graph"), _temp.Combine("fox.animation_graph"));
                shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [], [], []));
                shell.Assets.Apply(new AssetSnapshot([TestAssets.Make(GraphGuid, AssetKind.AnimationGraph, "fox.animation_graph")], []));
                var editor = shell.OpenAnimationGraph(shell.Assets.Find(GraphGuid)!)!;
                return (shell, editor, () => editor.AddParam("float"));
            }
            default:
            {
                File.Copy(Path.Combine(samples, "ui", "pause.ui"), _temp.Combine("pause.ui"));
                shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [], [], []));
                shell.Assets.Apply(new AssetSnapshot([TestAssets.Make(UiGuid, AssetKind.Ui, "pause.ui")], []));
                var editor = shell.OpenUiDocument(shell.Assets.Find(UiGuid)!)!;
                return (shell, editor, () => Assert.True(editor.AddStyle("probe")));
            }
        }
    }

    [Theory]
    [MemberData(nameof(Kinds))]
    public void AnOpenEditorOpensItsPreviewAgainOnceItsTextCooks(string kind)
    {
        var (shell, editor, _) = Open(kind);
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
    public void ACookThatAnswersAfterTheEditorClosesSendsNothing(string kind)
    {
        var (shell, editor, _) = Open(kind);
        using var _ = shell;
        var cook = Assert.Single(_cooker.Requests);
        _sent.Clear();

        shell.CloseGraph((IGraphEditor)editor, discard: true);
        Assert.IsType<ClosePreview>(Assert.Single(_sent));
        Assert.Null(editor.PreviewId);

        cook.Answer(Cooked);

        Assert.IsType<ClosePreview>(Assert.Single(_sent));
    }

    [Theory]
    [MemberData(nameof(Kinds))]
    public async Task AnEditCooksAMomentLater(string kind)
    {
        var (shell, _, edit) = Open(kind);
        using var _ = shell;
        Assert.Single(_cooker.Requests).Answer(Failed);

        edit();

        await Until(() => _cooker.Requests.Count == 2);
    }

    [Theory]
    [MemberData(nameof(Kinds))]
    public async Task ADelayedCookDoesNotRunAfterTheEditorCloses(string kind)
    {
        var (shell, editor, edit) = Open(kind);
        using var _ = shell;
        // The first text fails, so a later one that cooks would open the preview again.
        Assert.Single(_cooker.Requests).Answer(Failed);
        _sent.Clear();

        edit();
        shell.CloseGraph((IGraphEditor)editor, discard: true);
        await Task.Delay(PreviewCook.Delay * 4, TestContext.Current.CancellationToken);

        Assert.Single(_cooker.Requests);
        Assert.IsType<ClosePreview>(Assert.Single(_sent));
    }

    [Theory]
    [MemberData(nameof(Kinds))]
    public void AClosedPreviewSendsNothing(string kind)
    {
        var (shell, editor, _) = Open(kind);
        using var _ = shell;
        shell.CloseGraph((IGraphEditor)editor, discard: true);
        _sent.Clear();

        editor.Orbit(10, 5);
        editor.Zoom(1);
        editor.SendPreview();

        Assert.Empty(_sent);
    }

    static async Task Until(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(10);
        while (!condition())
        {
            Assert.True(DateTime.UtcNow < deadline, "the condition did not hold within 10 s");
            await Task.Delay(20, TestContext.Current.CancellationToken);
        }
    }

    /// <summary>A cook link that holds each cook until the test answers it.</summary>
    sealed class FakePreviewCooker : IPreviewCooker
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

        public Task<PreviewResult> CookPreview(string guid, string text)
        {
            // Without RunContinuationsAsynchronously, an answer runs the editor's continuation before Answer returns.
            var cook = new Cook(guid, text, new TaskCompletionSource<PreviewResult>());
            lock (_requests)
            {
                _requests.Add(cook);
            }
            return cook.Result.Task;
        }
    }

    sealed record Cook(string Guid, string Text, TaskCompletionSource<PreviewResult> Result)
    {
        public void Answer(PreviewResult result) => Result.SetResult(result);
    }
}
