using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Tests;

/// <summary>Sublevels in scene files and the project's settings (see docs/editor/document-and-scenes.md#sublevels).</summary>
public sealed class SublevelTests : IDisposable
{
    // A lamp in the night sublevel, its bulb, which inherits it, a crate in the base, a shade whose key is its parent's,
    // an instance in the night sublevel with an override block, and a child of one of its entities. The writer gives
    // the same text back.
    const string Room = """
        scene 4

        entity 0000000000000001
        name = "Lamp"
        sublevel = "night"

        entity 0000000000000002
        name = "Bulb"
        parent = @0000000000000001

        entity 0000000000000003
        name = "Crate"

        entity 0000000000000004
        name = "Shade"
        parent = @0000000000000001
        sublevel = "night"

        entity 0000000000000005
        parent = @5000000000000001#2000000000000002

        entity 0000000000000006
        name = "Moth"
        sublevel = "dusk"

        entity 5000000000000001
        sublevel = "night"
        prefab = $9db8150cc7215ffc2708d20d77cf60bf

        entity 5000000000000001#2000000000000002
        name = "Handle"

        """;

    readonly TempDirectory _temp = new("sublevels");

    public void Dispose() => _temp.Dispose();

    static string Text(string text) => text.ReplaceLineEndings("\n");

    [Fact]
    public void EntitiesInheritTheirParentsSublevel()
    {
        var (scene, problems) = SceneFile.Parse(Text(Room));
        Assert.Empty(problems);
        Assert.NotNull(scene);
        Assert.Equal("night", scene.Find(1)!.Sublevel);
        Assert.Null(scene.Find(2)!.Sublevel);
        Assert.Equal("night", scene.SublevelOf(scene.Find(2)!));
        Assert.Equal("", scene.SublevelOf(scene.Find(3)!));
        Assert.Equal("night", scene.SublevelOf(scene.Find(4)!));
        Assert.Equal("night", scene.SublevelOf(scene.Find(ScenePath.Id([0x5000000000000001, 0x2000000000000002]))!));
        // A parent inside an instance is in the instance's sublevel.
        Assert.Equal("night", scene.SublevelOf(scene.Find(5)!));
    }

    [Fact]
    public void ASceneWithSublevelsRoundTrips()
    {
        var (scene, _) = SceneFile.Parse(Text(Room));
        Assert.Equal(Text(Room), SceneFile.Write(scene!));
        Assert.Equal(Text(Room), SceneFile.Write(scene!.Clone()));
    }

    [Fact]
    public void AFileWithoutSublevelsStaysAtVersion3()
    {
        const string text = "scene 3\n\nentity 0000000000000001\nname = \"Lamp\"\n";
        var (scene, _) = SceneFile.Parse(text);
        Assert.Equal(text, SceneFile.Write(scene!));
        scene!.Find(1)!.Sublevel = "night";
        Assert.StartsWith("scene 4\n", SceneFile.Write(scene));
    }

    [Theory]
    [InlineData("scene 4\nentity 0000000000000001\nsublevel = \"night\"\n\nentity 0000000000000002\nparent = @0000000000000001\nsublevel = \"day\"\n", 7)]
    [InlineData("scene 4\nentity 0000000000000002\nparent = @0000000000000001\nsublevel = \"day\"\n\nentity 0000000000000001\n", 4)]
    [InlineData("scene 4\nentity 5000000000000001\nprefab = $9db8150cc7215ffc2708d20d77cf60bf\n\nentity 5000000000000001#2000000000000002\nsublevel = \"night\"\n", 6)]
    [InlineData("scene 4\nentity 5000000000000001\nprefab = $9db8150cc7215ffc2708d20d77cf60bf\nsublevel = \"night\"\n\nentity 0000000000000005\nparent = @5000000000000001#2000000000000002\nsublevel = \"day\"\n", 8)]
    public void ASublevelOtherThanTheParentsIsAnError(string text, int line)
    {
        var (scene, problems) = SceneFile.Parse(text);
        Assert.Null(scene);
        Assert.Contains(new SceneProblem(line, "an entity cannot be in a sublevel other than its parent's", true), problems);
    }

    [Theory]
    [InlineData("night")]
    [InlineData("\"\"")]
    [InlineData("\"two words\"")]
    [InlineData("\"a-b\"")]
    [InlineData("true")]
    public void ASublevelTakesAQuotedName(string value)
    {
        var (scene, problems) = SceneFile.Parse($"scene 4\nentity 0000000000000001\nsublevel = {value}\n");
        Assert.Null(scene);
        Assert.Contains(problems, p => p.IsError && p.Message.StartsWith("sublevel takes a quoted name", StringComparison.Ordinal));
    }

    [Fact]
    public void APrefabsSublevelIsIgnored()
    {
        var (scene, problems) = SceneFile.Parse("scene 4\nentity 0000000000000001\nsublevel = \"night\"\n", new SceneParseOptions(IsPrefab: true));
        var problem = Assert.Single(problems);
        Assert.False(problem.IsError);
        Assert.Contains("the prefab's sublevel is ignored", problem.Message);
        Assert.Null(scene!.Find(1)!.Sublevel);
        Assert.StartsWith("scene 3\n", SceneFile.Write(scene));
    }

    [Fact]
    public void AnUndeclaredSublevelIsAWarning()
    {
        var (scene, problems) = SceneFile.Parse(Text(Room), new SceneParseOptions(Sublevels: ["night"]));
        var problem = Assert.Single(problems);
        Assert.False(problem.IsError);
        Assert.Equal(24, problem.Line);
        Assert.Contains("does not declare the sublevel dusk", problem.Message);
        // The entity stays in it, and the name round-trips.
        Assert.Equal("dusk", scene!.Find(6)!.Sublevel);
        Assert.Equal(Text(Room), SceneFile.Write(scene));
    }

    [Fact]
    public void TheProjectDeclaresSublevels()
    {
        Directory.CreateDirectory(_temp.Path);
        var project = _temp.Combine("project.settings");
        File.WriteAllText(project, "# Sublevels.\nsublevel.night = inactive\nsublevel.day = active\nsublevel.bad-name = active\nsublevel.dusk = maybe\n");
        File.WriteAllText(ProjectSettings.UserPath(project), "sublevel.night = active\nsublevel.quest_3_after = inactive\n");
        Assert.Equal([("night", true), ("day", true), ("quest_3_after", false)], ProjectSettings.Sublevels(project));
        Assert.Empty(ProjectSettings.Sublevels(_temp.Combine("missing.settings")));
    }
}
