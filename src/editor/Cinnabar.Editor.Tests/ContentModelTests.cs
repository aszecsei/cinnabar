using Cinnabar.Editor.Content;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Tests;

/// <summary>What the content browser shows, without its view: the model outlives the view, and the commands use it either way.</summary>
public sealed class ContentModelTests : IDisposable
{
    const string Door = "9d2e41c0b7a35f6e81c4d2a90b3e7f15";
    const string Util = "00112233445566778899aabbccddeeff";
    const string Kit = "10101010101010101010101010101010";
    const string Wall = "11111111111111111111111111111111";

    readonly TempDirectory _temp = new("content-model");

    EditorShell NewShell()
    {
        var shell = TestShell.Open(_temp, null, null);
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path), new Root("engine", _temp.Combine("engine"))], [], []));
        shell.Assets.Apply(new AssetSnapshot(
        [
            TestAssets.Make(Door, AssetKind.Script, "door.luau"),
            TestAssets.Make(Util, AssetKind.Script, "lib/util.luau"),
            TestAssets.Make(Kit, AssetKind.Model, "lib/kit.glb"),
            TestAssets.Make(Wall, AssetKind.Mesh, "lib/kit.glb", parent: Kit, subasset: "Wall"),
        ], [new Folder("game", "lib")]));
        return shell;
    }

    static string[] Names(ContentBrowserModel model) => [.. model.Items.Select(AssetIndex.DisplayName)];

    [Fact]
    public void NewCommandsHaveAFolderBeforeThePanelShows()
    {
        using var shell = NewShell();
        Assert.Equal(new ContentFolder("game", ""), shell.Content.Folder);
        Assert.Equal("new_script", shell.Content.NewName(AssetTemplate.Script));
    }

    [Fact]
    public void RevealOfASubassetSelectsIt()
    {
        using var shell = NewShell();
        var model = shell.Content.Model;
        Asset? revealed = null;
        model.Revealed += a => revealed = a;

        shell.Content.RevealAsset(Wall);

        Assert.Equal(new ContentFolder("game", "lib"), model.Folder);
        Assert.True(model.IsFileExpanded(Kit));
        Assert.Equal(["kit.glb", "Wall", "util.luau"], Names(model));
        Assert.Equal([Wall], model.Selection);
        Assert.Equal(Wall, revealed?.Guid);
    }

    [Fact]
    public void RevealShowsThePanelThatAnotherTabHides()
    {
        using var shell = NewShell();
        shell.Layout.Close("contentBrowser");
        shell.Content.RevealAsset(Door);
        Assert.True(shell.Layout.IsOpen("contentBrowser"));
    }

    [Fact]
    public void TheSelectionKeepsItsOrderAndLosesWhatLeaves()
    {
        using var shell = NewShell();
        var model = shell.Content.Model;
        model.Open(new ContentFolder("game", "lib"));
        model.Select([Util, Kit]);
        model.Select([Kit, Util]);
        Assert.Equal([Util, Kit], model.Selection);

        shell.Assets.Apply(new AssetDelta([], [Util], [], []));
        Assert.Equal([Kit], model.Selection);

        // What a new folder does not show is no longer selected, once it is asked for.
        model.Open(new ContentFolder("game", ""));
        Assert.Equal(["door.luau"], Names(model));
        Assert.Empty(model.Selection);
    }

    [Fact]
    public void AFolderEndsTheSearch()
    {
        using var shell = NewShell();
        var model = shell.Content.Model;
        model.Search = "  util ";
        Assert.True(model.Searching);
        Assert.Equal(["util.luau"], Names(model));

        model.Open(new ContentFolder("game", ""));
        Assert.False(model.Searching);
        Assert.Equal(["door.luau"], Names(model));
    }

    [Fact]
    public void AFolderThatGoesFallsBackToTheFirstRoot()
    {
        using var shell = NewShell();
        var model = shell.Content.Model;
        model.Open(new ContentFolder("game", "lib"));
        var told = 0;
        model.ContextChanged += () => told++;

        shell.Assets.Apply(new AssetDelta([], [], [], [new Folder("game", "lib")]));

        Assert.Equal(new ContentFolder("game", ""), model.Folder);
        Assert.Equal(1, told);
    }

    [Fact]
    public void RootsStartExpandedAndStayAsTheUserLeftThem()
    {
        using var shell = NewShell();
        var model = shell.Content.Model;
        Assert.Equal([("game", ""), ("game", "lib"), ("engine", "")], model.FolderRows().Select(r => (r.Root, r.Path)));

        model.ToggleFolder("game", "");
        shell.Assets.Apply(new AssetDelta([], [Util], [], []));

        Assert.Equal([("game", ""), ("engine", "")], model.FolderRows().Select(r => (r.Root, r.Path)));
    }

    [Fact]
    public void OpeningAGeneratedPrefabOpensItsGeneratedText()
    {
        using var shell = NewShell();
        var generated = _temp.Combine("cache", "stage.prefab");
        var prefab = TestAssets.Make("22222222222222222222222222222222", AssetKind.Prefab, "sponza.usda", parent: Kit, subasset: "stage", generated: generated);
        string? asked = null;
        shell.OpenSceneFileRequested += path => asked = path;

        shell.OpenAsset(prefab);

        Assert.Equal(generated, asked);
        Assert.True(EditorShell.CanOpen(prefab));
        Assert.Equal("Open Prefab", shell.OpenLabel(prefab));
    }

    [Fact]
    public async Task AutomationChangesAndReportsWhatTheBrowserShows()
    {
        using var shell = NewShell();
        var cancel = TestContext.Current.CancellationToken;
        var settings = System.Text.Json.JsonDocument.Parse("""{"folder":"game/lib","search":""}""").RootElement.EnumerateObject().ToDictionary(p => p.Name, p => p.Value);

        var answer = await shell.HandleAutomation(new Model.AutomationRequest(1, "content", Settings: settings), cancel);

        Assert.True(answer.Ok);
        Assert.Equal("game/lib", answer.Content!.Folder);
        Assert.Equal(["kit.glb", "util.luau"], answer.Content.Items);

        var unknown = System.Text.Json.JsonDocument.Parse("""{"dance":true}""").RootElement.EnumerateObject().ToDictionary(p => p.Name, p => p.Value);
        var refused = await shell.HandleAutomation(new Model.AutomationRequest(2, "content", Settings: unknown), cancel);
        Assert.False(refused.Ok);
        Assert.Contains("dance", refused.Error);
    }

    public void Dispose() => _temp.Dispose();
}
