using Cinnabar.Editor.Content;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Tests;

/// <summary>The project's tags: the file, what its edits keep, and the filter that they drive.</summary>
public sealed class TagsTests : IDisposable
{
    const string A = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const string B = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const string C = "cccccccccccccccccccccccccccccccc";

    readonly TempDirectory _temp = new("tags");

    string Project => _temp.Combine("project.settings");

    string TagFile => _temp.Combine("project.tags");

    ProjectTags Open(string? text = null)
    {
        Directory.CreateDirectory(_temp.Path);
        if (text != null)
        {
            File.WriteAllText(TagFile, text);
        }
        var tags = new ProjectTags(TagFile);
        tags.Reload();
        return tags;
    }

    EditorShell NewShell()
    {
        var shell = TestShell.Open(_temp, null, null, Project);
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [], [], []));
        shell.Assets.Apply(new AssetSnapshot(
        [
            TestAssets.Make(A, AssetKind.Texture, "rock.png"),
            TestAssets.Make(B, AssetKind.Script, "lib/door.luau"),
            TestAssets.Make(C, AssetKind.Model, "kit.glb"),
            TestAssets.Make("c1", AssetKind.Mesh, "kit.glb", parent: C, subasset: "Wall"),
        ], [new Folder("game", "lib")]));
        return shell;
    }

    [Fact]
    public void TheFileBelongsBesideTheProject() =>
        Assert.Equal(Path.GetFullPath(Path.Combine("samples", "mygame", "project.tags")), ProjectTags.PathFor(Path.Combine("samples", "mygame", "project.settings")));

    [Theory]
    [InlineData("env", "env")]
    [InlineData(" env/stone/ ", "env/stone")]
    [InlineData("a-b_c/D9", "a-b_c/D9")]
    [InlineData("two words", null)]
    [InlineData("env//stone", null)]
    [InlineData("", null)]
    [InlineData("a,b", null)]
    [InlineData("a=b", null)]
    public void ATagHasOnlyWhatTheFileCanHold(string text, string? tag) => Assert.Equal(tag, ProjectTags.Normalize(text));

    [Fact]
    public void AnEditKeepsCommentsAndOrder()
    {
        var tags = Open($"# Our tags.\n\n{B} = env\n# After B.\n{A} = old, env/stone\n");
        tags.Add([A], "new");
        // An existing line changes in place, whatever the GUIDs' order.
        Assert.Equal($"# Our tags.\n\n{B} = env\n# After B.\n{A} = old, env/stone, new\n", File.ReadAllText(TagFile));

        // A new line goes before the first with a later GUID, and with no tags left, a line goes.
        tags.Add([C], "z");
        tags.Remove([B], "env");
        Assert.Equal($"# Our tags.\n\n# After B.\n{A} = old, env/stone, new\n{C} = z\n", File.ReadAllText(TagFile));
    }

    [Fact]
    public void SlashNestsAndAPrefixMatches()
    {
        var tags = Open($"{A} = env/stone/trim, review\n{B} = environment\n");
        Assert.Equal(["env", "env/stone", "env/stone/trim", "environment", "review"], tags.All());
        Assert.True(tags.Has(A, "env"));
        Assert.True(tags.Has(A, "env/stone"));
        Assert.True(tags.Has(A, "env/stone/trim"));
        // A prefix goes by whole parts.
        Assert.False(tags.Has(B, "env"));
        Assert.False(tags.Has(A, "env/stone/trim/more"));
    }

    [Fact]
    public void RenameMovesEveryChildTag()
    {
        var tags = Open($"{A} = env/stone/trim, envy\n{B} = env, keep\n{C} = other\n");
        tags.Rename("env", "world/ground");
        Assert.Equal(["world/ground/stone/trim", "envy"], tags.Of(A));
        Assert.Equal(["world/ground", "keep"], tags.Of(B));
        Assert.Equal(["other"], tags.Of(C));

        // A rename onto a tag that an asset has already leaves it once.
        tags.Rename("keep", "world/ground");
        Assert.Equal(["world/ground"], tags.Of(B));
    }

    [Fact]
    public void RemovingATagTakesThoseUnderIt()
    {
        var tags = Open($"{A} = env/stone, env, envy\n");
        tags.Remove([A], "env");
        Assert.Equal(["envy"], tags.Of(A));
    }

    [Fact]
    public void AGoneAssetKeepsItsLine()
    {
        using var shell = NewShell();
        shell.Content.Tags.Add([A], "env");
        shell.Assets.Apply(new AssetDelta([], [A], [], []));
        Assert.Contains(A, File.ReadAllText(TagFile));
        Assert.Equal(["env"], shell.Content.Tags.Of(A));
    }

    [Fact]
    public void AnOutsideChangeIsReadAndWhatItWroteStays()
    {
        var tags = Open($"{A} = one\n");
        var told = 0;
        tags.Changed += () => told++;
        tags.Reload();
        Assert.Equal(0, told);

        File.WriteAllText(TagFile, $"{A} = one, two\n{B} = three\n");
        tags.Reload();
        Assert.Equal(1, told);
        Assert.Equal(["three"], tags.Of(B));

        // An edit reads the file first, so it does not undo what another program wrote.
        File.WriteAllText(TagFile, $"{A} = four\n");
        tags.Add([C], "five");
        Assert.Equal($"{A} = four\n{C} = five\n", File.ReadAllText(TagFile));
    }

    [Fact]
    public void ABadLineInTheFileLosesOnlyItsBadTags()
    {
        var tags = Open($"{A} = good, not good, also/good\nnot a line\n");
        Assert.Equal(["good", "also/good"], tags.Of(A));
    }

    [Fact]
    public void TagsFilterAndTheirKindsNarrowTogether()
    {
        using var shell = NewShell();
        var model = shell.Content.Model;
        var tags = shell.Content.Tags;
        tags.Add([A, B], "env/stone");
        tags.Add([B], "review");

        model.ToggleTag("env");
        Assert.True(model.Filtering);
        Assert.Equal(["door.luau", "rock.png"], model.Items.Select(a => AssetIndex.Name(a.Path)));

        // Each tag narrows further.
        model.ToggleTag("review");
        Assert.Equal(["door.luau"], model.Items.Select(a => AssetIndex.Name(a.Path)));
        model.ToggleTag("review");

        model.ToggleKind(ContentKind.Textures);
        Assert.Equal(["rock.png"], model.Items.Select(a => AssetIndex.Name(a.Path)));

        model.ClearFilter();
        Assert.False(model.Filtering);
    }

    [Fact]
    public void ASubassetHasItsFilesTags()
    {
        using var shell = NewShell();
        var model = shell.Content.Model;
        shell.Content.Tags.Add([C], "props");
        model.ToggleTag("props");
        Assert.Equal(["kit.glb", "kit.glb"], model.Items.Select(a => AssetIndex.Name(a.Path)));
        Assert.Contains(model.Items, a => a.Guid == "c1");
    }

    [Fact]
    public void TheSearchTakesATagWord()
    {
        using var shell = NewShell();
        var model = shell.Content.Model;
        shell.Content.Tags.Add([A], "env/stone");
        model.Search = "tag:env";
        Assert.Equal([A], model.Items.Select(a => a.Guid));
        model.Search = "tag:env door";
        Assert.Empty(model.Items);
        model.Search = "tag:nothing";
        Assert.Empty(model.Items);
    }

    [Fact]
    public void TagRowsNestAndCollapse()
    {
        using var shell = NewShell();
        var model = shell.Content.Model;
        shell.Content.Tags.Add([A], "env/stone");
        shell.Content.Tags.Add([B], "env/wood");

        var rows = model.TagRows();
        Assert.Equal(["env", "env/stone", "env/wood"], rows.Select(r => r.Tag));
        Assert.Equal([2, 1, 1], rows.Select(r => r.Count));
        Assert.Equal([0, 1, 1], rows.Select(r => r.Depth));
        Assert.True(rows[0].HasChildren);
        Assert.False(rows[1].HasChildren);

        model.ToggleTagExpanded("env");
        Assert.Equal(["env"], model.TagRows().Select(r => r.Tag));
    }

    [Fact]
    public void ATagThatGoesStopsFiltering()
    {
        using var shell = NewShell();
        var model = shell.Content.Model;
        shell.Content.Tags.Add([A], "env");
        model.ToggleTag("env");
        Assert.Equal([A], model.Items.Select(a => a.Guid));

        shell.Content.Tags.Remove([A], "env");

        Assert.False(model.Filtering);
        Assert.Empty(model.FilterTags);
    }

    [Fact]
    public void ACopyHasItsSourcesTags()
    {
        var tags = Open($"{A} = env, review\n");
        tags.Copy(A, B);
        Assert.Equal(["env", "review"], tags.Of(B));
        // A source with no tags writes nothing.
        tags.Copy(C, "dddddddddddddddddddddddddddddddd");
        Assert.Equal(2, File.ReadAllLines(TagFile).Length);
    }

    public void Dispose() => _temp.Dispose();
}
