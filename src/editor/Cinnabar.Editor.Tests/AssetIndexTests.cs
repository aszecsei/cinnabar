using Cinnabar.Editor.Content;
using Cinnabar.Editor.Link.Cook;

namespace Cinnabar.Editor.Tests;

public class AssetIndexTests
{
    static Asset Script(string guid, string path, string behaviour = "", AssetStatus status = AssetStatus.Current, params string[] dependencies) =>
        new(guid, AssetKind.Script, "game", path, status, 0, 0, behaviour, [], dependencies);

    static Asset Scene(string guid, string path, params string[] dependencies) =>
        new(guid, AssetKind.Scene, "game", path, AssetStatus.Current, 0, 0, "", [], dependencies);

    static AssetIndex Index(Asset[] assets, params string[] folders)
    {
        var index = new AssetIndex();
        index.Apply(new Welcome(1, "dev", [new Root("game", "E:/game/content")]));
        index.Apply(new AssetSnapshot(assets, [.. folders.Select(f => new Folder("game", f))]));
        return index;
    }

    [Fact]
    public void FoldersAndAssetsListByParent()
    {
        var index = Index(
            [Script("01", "scripts/door.luau", "Door"), Script("02", "scripts/ui/menu.luau"), Scene("03", "main.scene")],
            "scripts", "scripts/ui", "levels");

        Assert.True(index.Linked);
        Assert.Equal(["levels", "scripts"], index.ChildFolders("game", ""));
        Assert.Equal(["ui"], index.ChildFolders("game", "scripts"));
        Assert.Equal(["03"], index.AssetsIn("game", "").Select(a => a.Guid));
        Assert.Equal(["01"], index.AssetsIn("game", "scripts").Select(a => a.Guid));
        Assert.Equal(Path.GetFullPath("E:/game/content/scripts/door.luau"), index.FullPath(index.Find("01")!));
        Assert.Equal("01", index.FindByPath("E:\\game\\content\\scripts\\door.luau")?.Guid);
    }

    [Fact]
    public void ADeltaChangesRemovesAndMovesFolders()
    {
        var index = Index([Script("01", "a.luau"), Script("02", "b.luau")], "old");
        var changes = 0;
        index.Changed += () => changes++;

        index.Apply(new AssetDelta([Script("01", "a.luau", status: AssetStatus.Failed), Script("03", "new/c.luau")], ["02"], [new Folder("game", "new")], [new Folder("game", "old")]));

        Assert.Equal(1, changes);
        Assert.Equal(AssetStatus.Failed, index.Find("01")!.Status);
        Assert.Null(index.Find("02"));
        Assert.NotNull(index.Find("03"));
        Assert.Equal(["new"], index.ChildFolders("game", ""));
    }

    [Fact]
    public void ProblemsReplaceAndClear()
    {
        var index = Index([Script("01", "a.luau")]);
        var problem = new Problem("E:/game/content/a.luau", 3, 1, true, "oops");

        index.Apply(new AssetProblems("01", [problem]));
        index.Apply(new AssetProblems("", [problem with { Text = "no definitions" }]));
        Assert.Equal([problem], index.ProblemsOf("01"));
        Assert.Equal("no definitions", Assert.Single(index.ProblemsOf("")).Text);

        index.Apply(new AssetProblems("01", []));
        Assert.Empty(index.ProblemsOf("01"));
    }

    [Fact]
    public void TheIndexKeepsItsAssetsWhenTheLinkCloses()
    {
        var index = Index([Script("01", "a.luau")]);
        index.Unlink();
        Assert.False(index.Linked);
        Assert.NotNull(index.Find("01"));
    }

    [Fact]
    public void DependentsAndBehavioursComeFromTheIndex()
    {
        var index = Index([Script("01", "util.luau"), Script("02", "door.luau", "Door", dependencies: "01"), Scene("03", "main.scene", "02")]);

        Assert.Equal(["02"], index.Dependents("01").Select(a => a.Guid));
        Assert.Equal(["03"], index.Dependents("02").Select(a => a.Guid));
        Assert.Equal(["02"], index.Behaviours.Select(a => a.Guid));
    }

    [Theory]
    [InlineData("door", new[] { "02" })]
    [InlineData("DOOR", new[] { "02" })]
    [InlineData("kind:scene", new[] { "03" })]
    [InlineData("kind:script .luau", new[] { "02", "01" })]
    [InlineData("kind:script door", new[] { "02" })]
    [InlineData("nothing", new string[0])]
    public void SearchMatchesEveryWord(string query, string[] guids)
    {
        var index = Index([Script("01", "util.luau"), Script("02", "props/door.luau", "Door"), Scene("03", "main.scene")]);
        Assert.Equal(guids, index.Search(query).Select(a => a.Guid));
    }
}
