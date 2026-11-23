using Cinnabar.Editor.Docking;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Shell;
using Asset = Cinnabar.Editor.Link.Cook.Asset;
using Root = Cinnabar.Editor.Link.Cook.Root;
using Welcome = Cinnabar.Editor.Link.Cook.Welcome;

namespace Cinnabar.Editor.Tests;

/// <summary>The shell's table of graph editor kinds, and the one path that opens and closes each.</summary>
public sealed class GraphEditorKindsTests : IDisposable
{
    const string Cutscene = "11111111111111111111111111111111";
    const string Graph = "22222222222222222222222222222222";
    const string OtherWorld = "33333333333333333333333333333333";

    readonly TempDirectory _temp = new("graph-editor-kinds");

    public void Dispose() => _temp.Dispose();

    // The files of a cutscene, an animation graph and two worlds, and their assets.
    Asset[] WriteAssets()
    {
        Directory.CreateDirectory(_temp.Path);
        File.WriteAllText(_temp.Combine("intro.cutscene"), CutsceneFileTests.Template);
        File.Copy(Path.Combine(EditorOptions.RepositoryRoot(), "samples", "mygame", "content", "models", "fox", "fox.animation_graph"), _temp.Combine("fox.animation_graph"));
        File.WriteAllText(_temp.Combine("town.world"), WorldFixture.WorldText);
        File.WriteAllText(_temp.Combine("hills.world"), WorldFixture.WorldText);
        return
        [
            TestAssets.Make(Cutscene, AssetKind.Cutscene, "intro.cutscene"),
            TestAssets.Make(Graph, AssetKind.AnimationGraph, "fox.animation_graph"),
            TestAssets.Make(WorldFixture.World, AssetKind.World, "town.world"),
            TestAssets.Make(OtherWorld, AssetKind.World, "hills.world"),
        ];
    }

    void Index(EditorShell shell, Asset[] assets)
    {
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [], [], []));
        shell.Assets.Apply(new AssetSnapshot(assets, []));
    }

    [Fact]
    public void EachAssetKindHasOneRowAndEachRowItsOwnPrefix()
    {
        foreach (var kind in Enum.GetValues<AssetKind>())
        {
            Assert.True(EditorShell.GraphEditorKinds.Count(k => k.Handles(kind)) <= 1, $"{kind} has more than one row");
        }
        Assert.Equal(EditorShell.GraphEditorKinds.Length, EditorShell.GraphEditorKinds.Select(k => k.IdPrefix).Distinct().Count());
        Assert.Same(EditorShell.GraphEditorKinds.Single(k => k.Handles(AssetKind.Material)), EditorShell.GraphEditorKinds.Single(k => k.Handles(AssetKind.MaterialFunction)));
    }

    [Fact]
    public void EachKindOpensInADocumentOfItsPrefixAndItsCloseTakesItOut()
    {
        var assets = WriteAssets();
        using var shell = TestShell.Open(_temp, null, null);
        Index(shell, assets);
        foreach (var (asset, prefix) in assets.Take(3).Zip(["cutscene", "animation_graph", "world"]))
        {
            shell.OpenAsset(asset);
            var editor = Assert.Single(shell.GraphEditors, e => e.Guid == asset.Guid);
            Assert.Same(editor, shell.ActiveGraphEditor);
            var document = Assert.IsType<GraphEditorDocument>(shell.Layout.FindDocument(editor));
            Assert.Equal($"{prefix}.{asset.Guid}", document.Id);
        }
        Assert.Single(shell.Cutscenes);
        Assert.Single(shell.AnimationGraphs);
        Assert.Single(shell.Worlds);

        foreach (var editor in shell.GraphEditors.ToList())
        {
            shell.CloseGraph(editor, discard: true);
        }
        Assert.Empty(shell.GraphEditors);
        Assert.Empty(shell.Cutscenes);
        Assert.Null(shell.ActiveGraphEditor);
    }

    [Fact]
    public void TheWorldShownLastIsTheLastWorld()
    {
        var assets = WriteAssets();
        using var shell = TestShell.Open(_temp, null, null);
        Index(shell, assets);
        var town = shell.OpenWorld(assets[2])!;
        var hills = shell.OpenWorld(assets[3])!;
        Assert.Equal([town, hills], shell.Worlds);
        Assert.Same(town, shell.OpenWorld(assets[2]));
        Assert.Equal([hills, town], shell.Worlds);
    }

    [Fact]
    public void TheCommandLinesPathsAndANewAssetOpenOnceTheIndexHasThem()
    {
        var assets = WriteAssets();
        var options = new EditorOptions("host.exe", "game.dll", null)
        {
            AutosaveDirectory = _temp.Combine("autosave"),
            CutscenePaths = [_temp.Combine("intro.cutscene")],
            AnimationGraphPaths = [_temp.Combine("fox.animation_graph")],
        };
        using var shell = new EditorShell(options, new EditorSettings(_temp.Combine("settings")));
        shell.OnAssetCreated(OtherWorld, AssetTemplate.Cutscene);
        Assert.Empty(shell.GraphEditors);
        Index(shell, assets);
        Assert.Single(shell.Cutscenes);
        Assert.Single(shell.AnimationGraphs);
        Assert.Equal(OtherWorld, Assert.Single(shell.Worlds).Guid);
    }
}
