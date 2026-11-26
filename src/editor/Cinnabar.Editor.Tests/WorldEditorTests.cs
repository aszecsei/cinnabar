using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Shell;
using Asset = Cinnabar.Editor.Link.Cook.Asset;
using Root = Cinnabar.Editor.Link.Cook.Root;
using Welcome = Cinnabar.Editor.Link.Cook.Welcome;

namespace Cinnabar.Editor.Tests;

/// <summary>The streaming sample's shape: a world of a persistent base and four tiles, each a scene file, and a scene with the streamer.</summary>
static class WorldFixture
{
    public const string World = "0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a";
    public const string Base = "aae627e32417d3edb166d3ee07c5176c";
    public static readonly string[] Tiles =
    [
        "2db69102fb44c615805573e397d483bb", "3eb9fa7a0ab06652b1f2bbf9d4b96f79", "dbe5765a71d715a6b49ea2e1218a3f60", "e4902cfac160f5e6ad3bf9142a490969",
    ];

    // The tiles are 40 m along +x from the 1.5e11 m anchor, and load within 25 m.
    public static string WorldText { get; } =
        "# The town.\nworld 1\nscene $" + Base + "\n\tpersistent = true\n"
        + string.Concat(Tiles.Select((t, i) =>
            $"scene ${t}\n\tmin = [{150000000020 + 40 * i}, -5, -25]\n\tmax = [{150000000060 + 40 * i}, 30, 25]\n\tload_distance = 25\n\tunload_distance = 40\n"));

    public static string SceneText(string name, string extra = "") => "scene 2\n\n" +
        $"entity 0000000000000001\nname = \"{name}\"\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n" + extra;

    /// <summary>The world, its scenes and a main scene with a streamer, written in a directory and indexed.</summary>
    public static (EditorShell Shell, Asset World) Open(TempDirectory dir, bool streamer = true)
    {
        Directory.CreateDirectory(dir.Path);
        // The script editor that a world which does not parse falls back to does nothing.
        Directory.CreateDirectory(dir.Combine("settings"));
        File.WriteAllText(dir.Combine("settings", EditorSettings.SettingsFileName), "{ \"scriptEditor\": [\"rem\", \"{file}\"] }");
        File.WriteAllText(dir.Combine("town.world"), WorldText);
        File.WriteAllText(dir.Combine("base.scene"), SceneText("Base"));
        for (var i = 0; i < Tiles.Length; i++)
        {
            File.WriteAllText(dir.Combine($"tile{i}.scene"), SceneText($"Tile {i}"));
        }
        var shell = TestShell.Open(dir, "main.scene", SceneText("Main", streamer ? "component 144 World_Streamer\n\tworld = $" + World + "\n" : ""));
        var world = TestAssets.Make(World, AssetKind.World, "town.world");
        Asset[] assets =
        [
            world,
            TestAssets.Make("ffffffffffffffffffffffffffffffff", AssetKind.Scene, "main.scene"),
            TestAssets.Make(Base, AssetKind.Scene, "base.scene"),
            .. Tiles.Select((t, i) => TestAssets.Make(t, AssetKind.Scene, $"tile{i}.scene")),
        ];
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", dir.Path)], [], [], []));
        shell.Assets.Apply(new AssetSnapshot(assets, []));
        return (shell, world);
    }
}

/// <summary>The World editor, driven without a window (see docs/editor/world-view.md#the-world-editor).</summary>
public sealed class WorldEditorTests : IDisposable
{
    readonly TempDirectory _temp = new("world-editor");

    public void Dispose() => _temp.Dispose();

    [Fact]
    public void AWorldOpensInItsEditorWithoutChanging()
    {
        var (shell, world) = WorldFixture.Open(_temp);
        using var _ = shell;
        shell.OpenAsset(world);
        var editor = Assert.Single(shell.Worlds);
        Assert.Contains(editor, shell.GraphEditors);
        Assert.Equal(WorldFixture.WorldText, editor.Document.Text);
        Assert.False(editor.Document.IsDirty);
        Assert.Equal(5, editor.Scenes.Count);
        // Opening it again shows the same editor.
        shell.OpenAsset(world);
        Assert.Single(shell.Worlds);
    }

    [Fact]
    public void ScenesAreAddedMovedAndRemovedAndEachStepUndoes()
    {
        var (shell, world) = WorldFixture.Open(_temp);
        using var _ = shell;
        var editor = shell.OpenWorld(world)!;
        var extra = "00000000000000000000000000000001";

        // A new scene is a 40 m box about the view's pivot, to the whole meter, with a load distance of 25 m.
        shell.Camera.Place([0, 0, 0], 0, 0);
        var center = shell.Camera.Pivot.Select(p => Math.Round(p / 16777216.0)).ToArray();
        Assert.True(editor.AddScene(extra));
        Assert.False(editor.AddScene(extra));
        Assert.False(editor.AddScene(WorldFixture.Tiles[0]));
        var added = editor.Find(extra)!;
        Assert.False(added.Persistent);
        Assert.Equal(center.Select(c => c - 20), added.Min!);
        Assert.Equal(center.Select(c => c + 20), added.Max!);
        Assert.Equal(25, added.LoadDistance);
        Assert.Null(added.UnloadDistance);

        editor.SetBounds(extra, [0, 0, 0], [10.5, 10, 10]);
        editor.SetDistances(extra, 30, 50);
        editor.SetPersistent(extra, true);
        editor.RemoveScene(WorldFixture.Tiles[3]);
        Assert.Equal(WorldFixture.WorldText.Replace(
            $"scene ${WorldFixture.Tiles[3]}\n\tmin = [150000000140, -5, -25]\n\tmax = [150000000180, 30, 25]\n\tload_distance = 25\n\tunload_distance = 40\n", "")
            + $"scene ${extra}\n\tmin = [0, 0, 0]\n\tmax = [10.5, 10, 10]\n\tload_distance = 30\n\tunload_distance = 50\n\tpersistent = true\n", editor.Document.Text);
        Assert.True(editor.Document.IsDirty);

        for (var i = 0; i < 5; i++)
        {
            editor.Document.Undo();
        }
        Assert.Equal(WorldFixture.WorldText, editor.Document.Text);
        Assert.False(editor.Document.CanUndo);
    }

    [Fact]
    public void ASceneThatStopsBeingPersistentGetsTheBoundsThatItLacks()
    {
        var (shell, world) = WorldFixture.Open(_temp);
        using var _ = shell;
        var editor = shell.OpenWorld(world)!;
        shell.Camera.Place([0, 0, 0], 0, 0);
        var center = shell.Camera.Pivot.Select(p => Math.Round(p / 16777216.0)).ToArray();
        editor.SetPersistent(WorldFixture.Base, false);
        var scene = editor.Find(WorldFixture.Base)!;
        Assert.False(scene.Persistent);
        Assert.Equal(center.Select(c => c - 20), scene.Min!);
        Assert.Equal(25, scene.LoadDistance);
        editor.Document.Undo();
        Assert.True(editor.Find(WorldFixture.Base)!.Persistent);
    }

    [Fact]
    public void TheCheckersProblemsGoOnTheirScenesRows()
    {
        var (shell, world) = WorldFixture.Open(_temp);
        using var _ = shell;
        var editor = shell.OpenWorld(world)!;
        // The text's lines: the base scene is line 3, the first tile's is line 5 and the third tile's is line 15.
        var path = editor.Document.Path;
        Assert.Same(CheckState.Pending, editor.Checks.State);
        editor.Checks.Show(editor.Document.Text, new PreviewResult("bad",
        [
            new Problem(path, 6, 0, true, "min is at most max on each axis, and x is not"),
            new Problem(path, 15, 0, true, "no asset has the GUID"),
            new Problem(path, 2, 0, true, "a world starts with `world 1`"),
        ], []));
        Assert.Equal(["min is at most max on each axis, and x is not"], editor.ProblemsOf(editor.Scenes[1]).Select(p => p.Text));
        Assert.Equal(["no asset has the GUID"], editor.ProblemsOf(editor.Scenes[3]).Select(p => p.Text));
        Assert.Empty(editor.ProblemsOf(editor.Scenes[0]));
        Assert.Equal(3, editor.Problems.Count);
        Assert.Equal(new CheckState.Failed("bad"), editor.Checks.State);
        // An answer about a text that has changed since is dropped.
        editor.SetDistances(WorldFixture.Tiles[0], 30, 40);
        editor.Checks.Show(WorldFixture.WorldText, new PreviewResult("", [], []));
        Assert.Equal(3, editor.Problems.Count);
    }
}
