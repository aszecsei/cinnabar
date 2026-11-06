using Cinnabar.Editor.Content;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Tests;

/// <summary>Taking part of a prefab: its tree, the browser's way through it, and where a part lands.</summary>
public sealed class PrefabPartTests : IDisposable
{
    readonly TempDirectory _temp = new("prefab-part");

    const string Stand = "33333333333333333333333333333333";
    const string StageFile = "44444444444444444444444444444444";
    const string Moss = "55555555555555555555555555555555";
    const string Stone = "66666666666666666666666666666666";
    const string MeshA = "77777777777777777777777777777777";
    const ulong Root = 0x1000000000000001;
    const ulong Floor = 0x1000000000000002;
    const ulong ColumnA = 0x1000000000000003;
    const ulong ColumnB = 0x1000000000000004;
    const ulong Roof = 0x1000000000000005;

    // Shaped as Sponza's stage is: a group with no offset, turned -90 degrees about X, whose children hold the offsets.
    // Without the group's rotation, its columns lie on their sides.
    const string StandText = "scene 2\n\n" +
        "entity 1000000000000001\nname = \"Stand\"\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n\n" +
        "entity 1000000000000002\nname = \"Floor\"\nparent = @1000000000000001\ncomponent 2 Local_Transform\n\toffset = [0, 0, 0]\n\trotation = [-0.7071068, 0, 0, 0.7071068]\n\tscale = [1, 1, 1]\n\n" +
        "entity 1000000000000003\nname = \"Column A\"\nparent = @1000000000000002\ncomponent 2 Local_Transform\n\toffset = [1, 1, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\ncomponent 33 Mesh_Renderer\n\tmesh = $77777777777777777777777777777777\n\tmaterials.0 = $55555555555555555555555555555555\n\tmaterials.1 = $66666666666666666666666666666666\n\n" +
        "entity 1000000000000004\nname = \"Column B\"\nparent = @1000000000000002\ncomponent 2 Local_Transform\n\toffset = [3, 1, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\ncomponent 33 Mesh_Renderer\n\tmesh = $77777777777777777777777777777777\n\n" +
        "entity 1000000000000005\nname = \"Roof\"\nparent = @1000000000000001\ncomponent 2 Local_Transform\n\toffset = [0, 9, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n";

    public void Dispose() => _temp.Dispose();

    EditorShell NewShell(string? generated = null)
    {
        Directory.CreateDirectory(_temp.Path);
        File.WriteAllText(_temp.Combine("stand.prefab"), StandText);
        var shell = TestShell.Open(_temp, "level.scene", "scene 2\n");
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [new Importer(AssetKind.Prefab, ".prefab", [])], [], []));
        shell.Assets.Apply(new AssetSnapshot(
        [
            TestAssets.Make(Stand, AssetKind.Prefab, "stand.prefab", generated: generated ?? ""),
            TestAssets.Make(Moss, AssetKind.Material, "moss.material"),
            TestAssets.Make(Stone, AssetKind.Material, "stone.material"),
            TestAssets.Make(MeshA, AssetKind.Mesh, "column.mesh"),
        ], []));
        return shell;
    }

    static Scene Parse(string text) => SceneFile.Parse(text).Scene!;

    static double[] WorldOf(EditorShell shell, string name)
    {
        var flat = shell.Scene!.Expanded.Flat;
        var pose = SceneEdits.WorldPose(flat, flat.Entities.Single(e => e.Name == name))!;
        return [.. pose.Position.Select(p => p / Pose.Unit)];
    }

    static void Near(double[] want, double[] got)
    {
        for (var i = 0; i < want.Length; i++)
        {
            Assert.Equal(want[i], got[i], 3);
        }
    }

    [Fact]
    public void SponzaShapedTreeHasItsGroups()
    {
        var tree = PrefabTree.Of(Parse(StandText), _ => null)!;

        Assert.Equal(Root, tree.Root);
        Assert.Equal([Floor, Roof], tree.Find(Root)!.Children.Order());
        Assert.Equal([ColumnA, ColumnB], tree.Find(Floor)!.Children.Order());
        Assert.Equal(1, tree.Find(Floor)!.Depth);
        Assert.Equal(2, tree.Find(ColumnA)!.Depth);
        Assert.Equal(MeshA, tree.Find(ColumnA)!.Mesh);
        Assert.Equal([Moss, Stone], tree.Find(ColumnA)!.Materials);
        Assert.Equal("", tree.Find(Floor)!.Mesh);

        // The group is turned, and what is under it is turned with it: (1, 1, 0) goes to (1, 0, -1).
        Assert.Equal(-0.7071068, tree.Find(Floor)!.Pose.Rotation.X, 5);
        Near([1, 0, -1], [.. tree.Find(ColumnA)!.Pose.Position.Select(p => p / Pose.Unit)]);
    }

    [Fact]
    public void TheAnchorIsTheMeanOfThePivots()
    {
        var tree = PrefabTree.Of(Parse(StandText), _ => null)!;
        // In the group's own space, the columns are at (1, 1, 0) and (3, 1, 0).
        Near([2, 1, 0], tree.Find(Floor)!.Anchor);
        // A column is its own pivot, and what draws nothing has none.
        Near([0, 0, 0], tree.Find(ColumnA)!.Anchor);
        Near([0, 0, 0], tree.Find(Roof)!.Anchor);
    }

    [Fact]
    public void ANestedInstancesEntitiesAreInTheTree()
    {
        const string outer = "scene 2\n\nentity 2000000000000001\nname = \"Outer\"\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n\n" +
            "entity 2000000000000002\nname = \"Inner\"\nparent = @2000000000000001\nprefab = $33333333333333333333333333333333\ncomponent 2 Local_Transform\n\toffset = [5, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n";

        var tree = PrefabTree.Of(Parse(outer), g => g == Stand ? Parse(StandText) : null)!;

        var column = tree.Find(ScenePath.Id(0x2000000000000002, ColumnA))!;
        Assert.Equal("Column A", column.Name);
        Near([6, 0, -1], [.. column.Pose.Position.Select(p => p / Pose.Unit)]);
    }

    [Fact]
    public void APrefabWithoutOneRootHasNoTree() =>
        Assert.Null(PrefabTree.Of(Parse("scene 2\n\nentity 0000000000000001\n\nentity 0000000000000002\n"), _ => null));

    [Fact]
    public void AColumnKeepsItsRotationWhenDropped()
    {
        using var shell = NewShell();
        long[] at = [(long)(10 * Pose.Unit), 0, 0];

        shell.PreviewPrefab(Stand, at, Floor);
        Assert.True(shell.CommitPrefab());

        var block = shell.Scene!.Scene.Entities.Single(e => e.Prefab == Stand);
        Assert.Equal(Floor, block.Node);
        // It stands as it stood in the prefab.
        var world = SceneEdits.WorldPose(shell.Scene.Expanded.Flat, shell.Scene.Expanded.Flat.Find(block.Id)!)!;
        Assert.Equal(-0.7071068, world.Rotation.X, 5);
        Assert.Equal(0.7071068, world.Rotation.W, 5);
        // And what it draws is around the drop, not its pivot: the columns' mean is the point.
        var a = WorldOf(shell, "Column A");
        var b = WorldOf(shell, "Column B");
        Near([10, 0, 0], [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2, (a[2] + b[2]) / 2]);
        // The columns are upright relative to each other, along the group's X.
        Assert.Equal(2, b[0] - a[0], 3);
        Assert.DoesNotContain(shell.Scene.Expanded.Flat.Entities, e => e.Name == "Roof");
    }

    [Fact]
    public void ADragThatMovesKeepsItsPart()
    {
        using var shell = NewShell();
        shell.PreviewPrefab(Stand, [0, 0, 0], Floor);
        shell.PreviewPrefab(Stand, [(long)(4 * Pose.Unit), 0, 0], Floor);
        Assert.True(shell.CommitPrefab());
        Assert.Equal(Floor, shell.Scene!.Scene.Entities.Single(e => e.Prefab == Stand).Node);
        var a = WorldOf(shell, "Column A");
        var b = WorldOf(shell, "Column B");
        Assert.Equal(4, (a[0] + b[0]) / 2, 3);
        Assert.Single(shell.Scene.History);
    }

    [Fact]
    public void TwoPartsDroppedInTheOutlinerReassemble()
    {
        using var shell = NewShell();
        Assert.True(shell.CreateInstance(Stand, 0, ColumnA));
        Assert.True(shell.CreateInstance(Stand, 0, ColumnB));
        var a = WorldOf(shell, "Column A");
        var b = WorldOf(shell, "Column B");

        // As the whole prefab has them, at the origin.
        Assert.True(shell.CreateInstance(Stand, 0));
        var flat = shell.Scene!.Expanded.Flat;
        var whole = flat.Entities.Where(e => e.Name is "Column A" or "Column B" && e.Parent != 0)
            .ToDictionary(e => e.Name, e => SceneEdits.WorldPose(flat, e)!.Position.Select(p => p / Pose.Unit).ToArray());
        Near(whole["Column A"], a);
        Near(whole["Column B"], b);
        Assert.Equal(3, shell.Scene.Scene.Entities.Count(e => e.Prefab == Stand));
    }

    [Fact]
    public void AWholePrefabDroppedInTheOutlinerStaysAtTheOrigin()
    {
        using var shell = NewShell();
        Assert.True(shell.CreateInstance(Stand, 0));
        var block = shell.Scene!.Scene.Entities.Single(e => e.Prefab == Stand);
        Assert.Equal(0ul, block.Node);
        Near([0, 0, 0], [.. SceneEdits.WorldPose(shell.Scene.Expanded.Flat, shell.Scene.Expanded.Flat.Find(block.Id)!)!.Position.Select(p => p / Pose.Unit)]);
    }

    [Fact]
    public void AltUnpacksInOneUndoEntry()
    {
        using var shell = NewShell();

        Assert.True(shell.CreateInstance(Stand, 0, Floor, unpack: true));

        Assert.DoesNotContain(shell.Scene!.Scene.Entities, e => e.Prefab != "");
        Assert.Equal(["Column A", "Column B", "Floor"], shell.Scene.Scene.Entities.Select(e => e.Name).Order());
        Assert.Single(shell.Scene.History);
        Assert.DoesNotContain(shell.Scene.Expanded.Problems, p => p.IsError);

        shell.Scene.Undo();
        Assert.Empty(shell.Scene.Scene.Entities);
    }

    [Fact]
    public void AltInTheViewportUnpacksToo()
    {
        using var shell = NewShell();
        shell.PreviewPrefab(Stand, [(long)(10 * Pose.Unit), 0, 0], Floor);
        Assert.True(shell.CommitPrefab(unpack: true));

        Assert.DoesNotContain(shell.Scene!.Scene.Entities, e => e.Prefab != "");
        var world = WorldOf(shell, "Column A");
        var other = WorldOf(shell, "Column B");
        Assert.Equal(10, (world[0] + other[0]) / 2, 3);
        Assert.Single(shell.Scene.History);
    }

    [Fact]
    public void ATakenPartOfAGeneratedPrefabIsFromItsGeneratedText()
    {
        Directory.CreateDirectory(_temp.Path);
        var generated = _temp.Combine("generated.prefab");
        File.WriteAllText(generated, StandText);
        using var shell = NewShell(generated);
        File.WriteAllText(_temp.Combine("stand.prefab"), "this file is a USD stage, not a scene");

        Assert.NotNull(shell.PrefabTreeOf(Stand));
    }

    [Fact]
    public void AStageOffersItsPrefabToPlace()
    {
        using var shell = NewShell();
        shell.Assets.Apply(new AssetDelta(
        [
            TestAssets.Make(StageFile, AssetKind.Stage, "sponza.usda"),
            TestAssets.Make("88888888888888888888888888888888", AssetKind.Prefab, "sponza.usda", parent: StageFile, subasset: "stage"),
        ], [], [], []));

        Assert.Equal("88888888888888888888888888888888", shell.PrefabToPlace(StageFile));
        Assert.Equal(Stand, shell.PrefabToPlace(Stand));
        Assert.Null(shell.PrefabToPlace(Moss));
    }

    [Fact]
    public void TheBrowserWalksThroughAPrefab()
    {
        using var shell = NewShell();
        var model = shell.Content.Model;
        model.Open(new ContentFolder("game", ""));
        model.Enter(Stand);

        Assert.Equal(["Floor", "Roof"], model.Tiles.Select(t => t.Name).Order());
        Assert.Equal(["game", "stand.prefab"], model.Crumbs().Select(c => c.Name));

        model.EnterNode(Floor);
        Assert.Equal(["Column A", "Column B"], model.Tiles.Select(t => t.Name).Order());
        Assert.Equal(["game", "stand.prefab", "Floor"], model.Crumbs().Select(c => c.Name));

        // An entity with what it draws shows its mesh and materials as assets: that is how to reach a material.
        model.EnterNode(ColumnA);
        Assert.Equal([MeshA, Moss, Stone], model.Tiles.Select(t => t.Asset?.Guid));
        Assert.Equal(["game", "stand.prefab", "Floor", "Column A"], model.Crumbs().Select(c => c.Name));

        model.Leave();
        Assert.Equal(Floor, model.OpenNode);
        Assert.Equal([ContentBrowserModel.PartKey(Stand, ColumnA)], model.Selection);

        model.Leave();
        Assert.Equal(0ul, model.OpenNode);
        Assert.Equal([ContentBrowserModel.PartKey(Stand, Floor)], model.Selection);

        model.Leave();
        Assert.Null(model.OpenPrefab);
        Assert.Equal([Stand], model.Selection);
    }

    [Fact]
    public void ALiveDropFollowsARecook()
    {
        using var shell = NewShell();
        Assert.True(shell.CreateInstance(Stand, 0, Floor));
        Assert.Contains(shell.Scene!.Expanded.Flat.Entities, e => e.Name == "Column A");

        // The stage cooks again, with a new name for what the part holds.
        File.WriteAllText(_temp.Combine("stand.prefab"), StandText.Replace("Column A", "Column C"));
        shell.Scene.Prefabs.ReloadChanged([]);
        shell.Scene.Invalidate();

        Assert.Contains(shell.Scene.Expanded.Flat.Entities, e => e.Name == "Column C");
        Assert.DoesNotContain(shell.Scene.Expanded.Flat.Entities, e => e.Name == "Column A");
        Assert.DoesNotContain(shell.Scene.Expanded.Flat.Entities, e => e.Name == "Roof");
    }

    [Fact]
    public void AFiltersKindsNarrowAPrefabsTiles()
    {
        using var shell = NewShell();
        var model = shell.Content.Model;
        model.Enter(Stand);
        model.EnterNode(ColumnA);
        Assert.Equal([(ContentKind.Meshes, 1), (ContentKind.Materials, 2)], model.KindCounts());
        model.ToggleKind(ContentKind.Materials);
        Assert.Equal([Moss, Stone], model.Tiles.Select(t => t.Asset?.Guid));

        model.ClearFilter();
        model.EnterNode(0);
        model.Search = "roo";
        Assert.Equal(["Roof"], model.Tiles.Select(t => t.Name));
    }

    [Fact]
    public void ASelectedPartIsNotAnAssetForTheCommands()
    {
        using var shell = NewShell();
        var model = shell.Content.Model;
        model.Enter(Stand);
        var key = ContentBrowserModel.PartKey(Stand, Floor);
        model.Press(key, false, false);

        Assert.Equal([key], model.Selection);
        Assert.Empty(shell.Content.SelectedAssets);
        Assert.Empty(shell.Content.Draft.Assets);
        Assert.False(shell.Commands.Get(EditorCommands.DeleteAsset).CanExecute);

        // An index message does not take a part out of the selection, as it does a gone asset.
        shell.Assets.Apply(new AssetDelta([], [Moss], [], []));
        Assert.Equal([key], model.Selection);
    }

    [Fact]
    public void APartsKeyRoundTrips()
    {
        var key = ContentBrowserModel.PartKey(Stand, 0x0000000000000a01);
        Assert.Equal((Stand, 0x0000000000000a01ul), ContentBrowserModel.ParsePartKey(key));
        Assert.Null(ContentBrowserModel.ParsePartKey(Stand));
    }
}
