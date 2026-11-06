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
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path), new Root("engine", _temp.Combine("engine"))], [], [], []));
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
        Assert.Equal(Kit, model.OpenFile);
        Assert.Equal(["Wall"], Names(model));
        Assert.Equal([Wall], model.Selection);
        Assert.Equal(Wall, revealed?.Guid);

        // Leaving goes back to the folder, with the file selected, and the path over the assets says where it is.
        Assert.Equal(["game", "lib", "kit.glb"], model.Crumbs().Select(c => c.Name));
        model.Leave();
        Assert.Null(model.OpenFile);
        Assert.Equal(["kit.glb", "util.luau"], Names(model));
        Assert.Equal([Kit], model.Selection);
    }

    static readonly SettingInfo Mips = new("mips", ["true", "false"], "true", "Make the mips.");
    static readonly SettingInfo Size = new("max_size", ["256", "512", "1024"], "1024", "The largest side.");
    static readonly SettingInfo Tangents = new("tangents", ["file", "generate"], "file", "Where tangents come from.");
    const string Rock = "20202020202020202020202020202020";
    const string Moss = "21212121212121212121212121212121";

    EditorShell DraftShell()
    {
        var shell = TestShell.Open(_temp, null, null);
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)],
        [
            new Importer(AssetKind.Texture, ".png", [Mips, Size]),
            new Importer(AssetKind.Model, ".glb", [Tangents, new SettingInfo("mips", ["on", "off"], "on", "Not the same setting.")]),
            new Importer(AssetKind.Mesh, ".mesh", [Tangents]),
        ], [], []));
        shell.Assets.Apply(new AssetSnapshot(
        [
            TestAssets.Make(Rock, AssetKind.Texture, "rock.png", settings: [new Setting("max_size", "256")]),
            TestAssets.Make(Moss, AssetKind.Texture, "moss.png"),
            TestAssets.Make(Kit, AssetKind.Model, "kit.glb"),
            TestAssets.Make(Wall, AssetKind.Mesh, "kit.glb", parent: Kit, subasset: "Wall"),
        ], []));
        return shell;
    }

    [Fact]
    public void AMixedValueStaysUnsetForAssetsTheEditDoesNotChange()
    {
        using var shell = DraftShell();
        var model = shell.Content.Model;
        var draft = shell.Content.Draft;
        model.Select([Rock, Moss]);

        var rows = draft.Rows();
        Assert.Equal(["mips", "max_size"], rows.Select(r => r.Info.Key));
        Assert.Equal("true", rows[0].Value);
        // The two files differ, so it shows no value.
        Assert.Null(rows[1].Value);
        Assert.False(draft.Dirty);

        // Changing another setting leaves the one that differs as each has it.
        draft.Set("mips", "false");
        Assert.True(draft.Dirty);
        Assert.True(draft.Rows()[0].Changed);
        var request = draft.Request();
        Assert.Equal([new Setting("max_size", "256"), new Setting("mips", "false")], request.Single(a => a.Guid == Rock).Settings);
        Assert.Equal([new Setting("mips", "false")], request.Single(a => a.Guid == Moss).Settings);

        // Setting it back to what each has is no change.
        draft.Set("mips", "true");
        Assert.False(draft.Dirty);
        Assert.Empty(draft.Request());

        // A setting at the default leaves the file that had another value, and the other file is not touched.
        draft.Set("max_size", "1024");
        var request2 = Assert.Single(draft.Request());
        Assert.Equal(Rock, request2.Guid);
        Assert.Empty(request2.Settings);
    }

    [Fact]
    public void ADraftShowsOnlyWhatAllTheFilesTake()
    {
        using var shell = DraftShell();
        var draft = shell.Content.Draft;
        // A model and a texture share no setting: their mips have different values.
        shell.Content.Model.Select([Rock, Kit]);
        Assert.Empty(draft.Rows());

        shell.Content.Model.Select([Kit]);
        Assert.Equal(["tangents", "mips"], draft.Rows().Select(r => r.Info.Key));
    }

    [Fact]
    public void ASubassetShowsItsFilesSettingsAsALink()
    {
        using var shell = DraftShell();
        var draft = shell.Content.Draft;
        shell.Content.Model.Select([Wall]);
        Assert.Empty(draft.Assets);
        Assert.Empty(draft.Rows());

        // With its file, the draft edits the file alone.
        shell.Content.Model.Select([Wall, Kit]);
        Assert.Equal([Kit], draft.Assets);
    }

    [Fact]
    public void LeavingADraftAsksAndKeepsItUntilAnswered()
    {
        using var shell = DraftShell();
        var model = shell.Content.Model;
        var draft = shell.Content.Draft;
        var asked = 0;
        shell.Content.DraftLeft += () => asked++;
        model.Select([Rock]);
        draft.Set("mips", "false");

        // The same files in another order are no change of what it edits.
        model.Select([Rock, Wall]);
        Assert.Equal(0, asked);
        Assert.True(draft.Dirty);

        model.Select([Moss]);
        Assert.Equal(1, asked);
        Assert.True(draft.Dirty);
        Assert.Equal([Rock], draft.Assets);

        shell.Content.FinishDraft();
        Assert.False(draft.Dirty);
        Assert.Equal([Moss], draft.Assets);
    }

    [Fact]
    public void LeavingAFileEndsItsFilter()
    {
        using var shell = NewShell();
        var model = shell.Content.Model;
        model.Enter(Kit);
        model.ToggleKind(ContentKind.Meshes);
        model.Leave();
        Assert.False(model.Filtering);
        Assert.Equal(["kit.glb", "util.luau"], Names(model));
    }

    [Theory]
    [InlineData(Avalonia.Input.Key.Delete, Avalonia.Input.KeyModifiers.None, true)]
    [InlineData(Avalonia.Input.Key.Back, Avalonia.Input.KeyModifiers.None, true)]
    [InlineData(Avalonia.Input.Key.Q, Avalonia.Input.KeyModifiers.None, true)]
    [InlineData(Avalonia.Input.Key.Left, Avalonia.Input.KeyModifiers.Shift, true)]
    [InlineData(Avalonia.Input.Key.A, Avalonia.Input.KeyModifiers.Control, true)]
    [InlineData(Avalonia.Input.Key.Z, Avalonia.Input.KeyModifiers.Control, true)]
    [InlineData(Avalonia.Input.Key.Z, Avalonia.Input.KeyModifiers.Control | Avalonia.Input.KeyModifiers.Shift, true)]
    [InlineData(Avalonia.Input.Key.S, Avalonia.Input.KeyModifiers.Control, false)]
    [InlineData(Avalonia.Input.Key.D, Avalonia.Input.KeyModifiers.Control, false)]
    [InlineData(Avalonia.Input.Key.F2, Avalonia.Input.KeyModifiers.None, false)]
    [InlineData(Avalonia.Input.Key.P, Avalonia.Input.KeyModifiers.Control | Avalonia.Input.KeyModifiers.Alt, false)]
    public void ATextBoxKeepsTheKeysThatItUses(Avalonia.Input.Key key, Avalonia.Input.KeyModifiers modifiers, bool used) =>
        Assert.Equal(used, Ribbon.ShortcutCommand.TextBoxUses(new Avalonia.Input.KeyGesture(key, modifiers)));

    [Fact]
    public void AShortcutDoesNothingWhileATextBoxUsesIt()
    {
        var delete = new Avalonia.Input.KeyGesture(Avalonia.Input.Key.Delete);
        var text = true;
        var ran = new CommunityToolkit.Mvvm.Input.RelayCommand(() => { });
        var shortcut = new Ribbon.ShortcutCommand(ran, delete, () => false, () => text);
        Assert.False(shortcut.CanExecute(null));
        text = false;
        Assert.True(shortcut.CanExecute(null));
    }

    [Fact]
    public void KindChipsFilterSubassetsToo()
    {
        using var shell = NewShell();
        var model = shell.Content.Model;
        Assert.False(model.Filtering);

        model.ToggleKind(ContentKind.Meshes);
        Assert.Equal(["Wall"], Names(model));
        Assert.Equal([(ContentKind.Models, 1), (ContentKind.Meshes, 1), (ContentKind.Scripts, 2)], model.KindCounts());

        model.ToggleKind(ContentKind.Scripts);
        Assert.Equal(["door.luau", "Wall", "util.luau"], Names(model));

        // The search and the kinds narrow together, and Clear ends both.
        model.Search = "door";
        Assert.Equal(["door.luau"], Names(model));
        Assert.Equal([(ContentKind.Scripts, 1)], model.KindCounts());
        model.ClearFilter();
        Assert.False(model.Filtering);
        Assert.Equal(["door.luau"], Names(model));
    }

    [Fact]
    public void AFilterCanStayInTheOpenFolderOrFile()
    {
        using var shell = NewShell();
        var model = shell.Content.Model;
        model.Open(new ContentFolder("game", "lib"));
        model.ToggleKind(ContentKind.Scripts);
        Assert.Equal(["door.luau", "util.luau"], Names(model));

        model.InThisFolder = true;
        Assert.Equal(["util.luau"], Names(model));

        // An open file's filter looks only in the file, and finds what it makes by kind.
        model.Enter(Kit);
        Assert.Empty(model.Items);
        model.ToggleKind(ContentKind.Scripts);
        model.ToggleKind(ContentKind.Meshes);
        Assert.Equal(["Wall"], Names(model));
    }

    [Fact]
    public void GridColumnsFollowTheWidth()
    {
        // A tile is its picture and a gap on each side, and tiles have a gap between them.
        var tile = ContentBrowserModel.DefaultTileSize + 2 * ContentGridLayout.Gap;
        var three = ContentGridLayout.Of(3 * tile + 2 * ContentGridLayout.Gap, ContentViewMode.Grid, ContentBrowserModel.DefaultTileSize);
        Assert.Equal(3, three.Columns);
        Assert.Equal(2, ContentGridLayout.Of(3 * tile + 2 * ContentGridLayout.Gap - 1, ContentViewMode.Grid, ContentBrowserModel.DefaultTileSize).Columns);
        Assert.Equal(1, ContentGridLayout.Of(1, ContentViewMode.Grid, ContentBrowserModel.DefaultTileSize).Columns);
        Assert.Equal(4, three.RowCount(10));
        Assert.Equal(3, three.RowOf(9));

        var list = ContentGridLayout.Of(500, ContentViewMode.List, ContentBrowserModel.DefaultTileSize);
        Assert.Equal(1, list.Columns);
        Assert.Equal(ContentGridLayout.ListRowHeight, list.RowHeight);
    }

    [Fact]
    public void AnIndexFollowsFromAPoint()
    {
        var layout = new ContentGridLayout(3, 100, 130);
        Assert.Equal(0, layout.IndexAt(1, 1, 7));
        Assert.Equal(4, layout.IndexAt(110, 131, 7));
        // Over the gap between tiles, past the last asset, past the last column and above the rows there is none.
        Assert.Null(layout.IndexAt(103, 1, 7));
        Assert.Null(layout.IndexAt(110, 261, 7));
        Assert.Null(layout.IndexAt(320, 1, 7));
        Assert.Null(layout.IndexAt(1, -1, 7));
    }

    [Fact]
    public void ArrowsMoveByARowOfColumns()
    {
        using var shell = NewShell();
        var model = shell.Content.Model;
        model.Enter(Kit);
        shell.Assets.Apply(new AssetDelta(
        [
            TestAssets.Make("a1", AssetKind.Mesh, "lib/kit.glb", parent: Kit, subasset: "A"),
            TestAssets.Make("b1", AssetKind.Mesh, "lib/kit.glb", parent: Kit, subasset: "B"),
            TestAssets.Make("c1", AssetKind.Mesh, "lib/kit.glb", parent: Kit, subasset: "C"),
        ], [], [], []));
        Assert.Equal(["A", "B", "C", "Wall"], Names(model));

        // With nothing selected, the first press starts at an end.
        Assert.Equal("a1", model.Move(1, false)?.Key);
        const int columns = 2;
        Assert.Equal("c1", model.Move(columns, false)?.Key);
        Assert.Equal(["c1"], model.Selection);
        // A step past an end stops there.
        Assert.Equal(Wall, model.Move(columns, false)?.Key);
        Assert.Equal(Wall, model.Move(1, false)?.Key);
        Assert.Equal("a1", model.Move(-100, false)?.Key);
    }

    [Fact]
    public void ShiftSelectsARangeAcrossRows()
    {
        using var shell = NewShell();
        var model = shell.Content.Model;
        model.Open(new ContentFolder("game", ""));
        model.Enter(Kit);
        shell.Assets.Apply(new AssetDelta(
        [
            TestAssets.Make("a1", AssetKind.Mesh, "lib/kit.glb", parent: Kit, subasset: "A"),
            TestAssets.Make("b1", AssetKind.Mesh, "lib/kit.glb", parent: Kit, subasset: "B"),
            TestAssets.Make("c1", AssetKind.Mesh, "lib/kit.glb", parent: Kit, subasset: "C"),
        ], [], [], []));
        _ = model.Items;

        model.Press("a1", false, false);
        model.Press("c1", false, true);
        Assert.Equal(["a1", "b1", "c1"], model.Selection);

        // A range is from the anchor, either way, and shrinks with the pointer.
        model.Press("b1", false, true);
        Assert.Equal(["a1", "b1"], model.Selection);

        // Ctrl takes one out and moves the anchor.
        model.Press("a1", true, false);
        Assert.Equal(["b1"], model.Selection);
        model.Press(Wall, false, true);
        Assert.Equal(["a1", "b1", "c1", Wall], model.Selection.Order(StringComparer.Ordinal).OrderBy(g => g == Wall ? 1 : 0));

        // Arrows with Shift grow from the same anchor.
        model.Press("b1", false, false);
        model.Move(1, true);
        Assert.Equal(["b1", "c1"], model.Selection);

        model.SelectAll();
        Assert.Equal(4, model.Selection.Count);
    }

    [Fact]
    public void TheMarqueeSelectsByGeometry()
    {
        var layout = new ContentGridLayout(3, 100, 130);
        // From the middle of the first tile to the middle of the fifth, either way round.
        Assert.Equal([0, 1, 3, 4], layout.InRect(50, 60, 160, 200, 7));
        Assert.Equal([0, 1, 3, 4], layout.InRect(160, 200, 50, 60, 7));
        // A rectangle that stays in a gap between columns touches nothing.
        Assert.Empty(layout.InRect(101, 10, 105, 20, 7));
        // Past the last asset there is none, however far it reaches.
        Assert.Equal([6], layout.InRect(0, 270, 50, 900, 7));
    }

    [Fact]
    public void ARevealShowsWhatTheFilterHid()
    {
        using var shell = NewShell();
        var model = shell.Content.Model;
        model.ToggleKind(ContentKind.Textures);
        Assert.Empty(model.Items);

        shell.Content.RevealAsset(Door);

        Assert.Empty(model.Kinds);
        Assert.Equal([Door], model.Selection);
        Assert.Contains("door.luau", Names(model));
    }

    [Fact]
    public void TheViewSettingsLastAndStayInRange()
    {
        using var shell = NewShell();
        var model = shell.Content.Model;
        var saved = 0;
        model.ViewSettingsChanged += () => saved++;

        model.TileSize = 1;
        Assert.Equal(ContentBrowserModel.MinTileSize, model.TileSize);
        model.TileSize = 5000;
        Assert.Equal(ContentBrowserModel.MaxTileSize, model.TileSize);
        model.ViewMode = ContentViewMode.List;
        Assert.Equal(3, saved);
        Assert.True(File.Exists(Path.Combine(shell.Settings.Directory, Shell.EditorSettings.ContentViewFileName)));

        using var reopened = TestShell.Open(_temp, null, null);
        Assert.Equal(ContentViewMode.List, reopened.Content.Model.ViewMode);
        Assert.Equal(ContentBrowserModel.MaxTileSize, reopened.Content.Model.TileSize);
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
