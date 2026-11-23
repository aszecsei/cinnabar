using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Tests;

/// <summary>The world's reader and writer, and the policy that the preview works out (see docs/editor/world-view.md).</summary>
public sealed class WorldFileTests
{
    const string Base = "aae627e32417d3edb166d3ee07c5176c";
    const string Tile = "2db69102fb44c615805573e397d483bb";

    static string Sample() =>
        File.ReadAllText(Path.Combine(EditorOptions.RepositoryRoot(), "samples", "mygame", "content", "worlds", "streaming.world")).ReplaceLineEndings("\n");

    static WorldFile Read(string text)
    {
        var (file, problem) = WorldFile.Parse(text);
        Assert.Null(problem);
        return file!;
    }

    [Fact]
    public void TheSampleWorldWritesBackAsItWasWithEveryLineEnding()
    {
        var sample = Sample();
        foreach (var text in new[] { sample, sample.ReplaceLineEndings("\r\n"), sample.TrimEnd('\n'), sample.Replace("\n\tmin", "\r\n\tmin") })
        {
            Assert.Equal(text, Read(text).Text);
        }
    }

    [Fact]
    public void TheSampleWorldReadsAsTheCookerDoes()
    {
        var scenes = Read(Sample()).Scenes.ToList();
        Assert.Equal(5, scenes.Count);
        Assert.Equal(Base, scenes[0].Guid);
        Assert.True(scenes[0].Persistent);
        Assert.Null(scenes[0].Min!);
        Assert.Equal(Tile, scenes[1].Guid);
        Assert.False(scenes[1].Persistent);
        Assert.Equal([150000000020, -5, -25], scenes[1].Min!);
        Assert.Equal([150000000060, 30, 25], scenes[1].Max!);
        Assert.Equal(25, scenes[1].LoadDistance);
        Assert.Equal(40, scenes[1].UnloadDistance);
    }

    [Fact]
    public void OnlyAMissingHeaderRefusesTheFile()
    {
        Assert.Equal(1, WorldFile.Parse("").Problem!.Line);
        Assert.Equal(2, WorldFile.Parse("# a world\nscene $aae627e32417d3edb166d3ee07c5176c\n").Problem!.Line);
        // Lines that the cooker reports are kept.
        var text = "world 1\nscene $nothex\nlevel = 3\nscene $aae627e32417d3edb166d3ee07c5176c\n\tpersistent = maybe\n";
        var file = Read(text);
        Assert.Equal(text, file.Text);
        Assert.False(file.Scenes.Single().Persistent);
    }

    [Fact]
    public void EditsChangeOnlyTheirOwnLinesAndKeepTheComments()
    {
        var file = Read("# The town.\nworld 1\n\n# The gate.\nscene $" + Tile + "\n\tmin = [0, 0, 0]  # low\n\tmax = [40, 30, 25]\n\tload_distance = 25 # near\n\tunload_distance = 40\n\n# The base.\nscene $" + Base + "\n\tpersistent = true\n");
        var gate = file.Find(Tile)!;
        file.SetDistances(gate, 30, null);
        file.SetBounds(gate, [-1.5, 0, 0], [40, 30, 25]);
        Assert.Equal("# The town.\nworld 1\n\n# The gate.\nscene $" + Tile + "\n\tmin = [-1.5, 0, 0]  # low\n\tmax = [40, 30, 25]\n\tload_distance = 30 # near\n\n# The base.\nscene $" + Base + "\n\tpersistent = true\n", file.Text);

        // Unload comes back at the end of the scene's lines.
        file.SetDistances(gate, 30, 45.25);
        Assert.Contains("\tload_distance = 30 # near\n\tunload_distance = 45.25\n\n# The base.", file.Text);

        // A scene's removal leaves the comments that follow it.
        file.Remove(file.Find(Tile)!);
        Assert.Equal("# The town.\nworld 1\n\n# The gate.\n\n# The base.\nscene $" + Base + "\n\tpersistent = true\n", file.Text);
    }

    [Fact]
    public void ASceneAddsAtTheEndAndPersistentChangesOnlyItsOwnLine()
    {
        var file = Read("world 1\nscene $" + Base + "\n\tpersistent = true\n\tmin = [0, 0, 0]\n");
        file.AddScene(Tile.ToUpperInvariant(), [0, -0.5, 0], [40, 30, 40], 25);
        Assert.Equal("world 1\nscene $" + Base + "\n\tpersistent = true\n\tmin = [0, 0, 0]\nscene $" + Tile + "\n\tmin = [0, -0.5, 0]\n\tmax = [40, 30, 40]\n\tload_distance = 25\n", file.Text);
        Assert.Equal(5, file.LineOf(file.Find(Tile)!));
        Assert.Same(file.Find(Tile), file.SceneAt(8));
        Assert.Null(file.SceneAt(1));

        // A persistent scene keeps its bounds, which the cooker ignores.
        var before = file.Text;
        file.SetPersistent(file.Find(Base)!, false);
        Assert.Equal(before.Replace("\tpersistent = true\n", ""), file.Text);
        file.SetPersistent(file.Find(Base)!, true);
        Assert.Contains("scene $" + Base + "\n\tmin = [0, 0, 0]\n\tpersistent = true\n", file.Text);
    }

    [Fact]
    public void TheRawBoundsAreTheCookersAtTheFarAnchor()
    {
        var tile = Read(Sample()).Scenes.ElementAt(1);
        Assert.Equal([150000000020L << 24, -5L << 24, -25L << 24], tile.RawMin!);
        Assert.Equal([150000000060L << 24, 30L << 24, 25L << 24], tile.RawMax!);
        // Half a unit rounds away from zero.
        Assert.Equal(1, WorldFile.Raw(Math.ScaleB(1, -25)));
        Assert.Equal(-1, WorldFile.Raw(-Math.ScaleB(1, -25)));
        Assert.Null(WorldFile.Raw(1e30));
    }

    [Fact]
    public void ASceneLoadsWithinItsLoadDistanceOfItsBounds()
    {
        var file = Read(Sample());
        var (persistent, tile) = (file.Scenes.First(), file.Scenes.ElementAt(1));
        long[] At(double x, double y = 0, double z = 0) => [(long)(x * (1 << 24)), (long)(y * (1 << 24)), (long)(z * (1 << 24))];

        // Inside the bounds the distance is 0, and beside them it is the gap.
        Assert.Equal(0, WorldStreaming.Distance(tile, At(150000000040)));
        Assert.Equal(10, WorldStreaming.Distance(tile, At(150000000010)));
        Assert.Equal(5, WorldStreaming.Distance(tile, At(150000000040, 35)));
        Assert.Equal(Math.Sqrt(2 * 100), WorldStreaming.Distance(tile, At(150000000010, 0, 35)));
        Assert.True(WorldStreaming.WouldLoad(tile, At(150000000040)));

        // At the edge, 25 m away, it loads, and one unit further it does not.
        var edge = At(150000000020 - 25);
        Assert.True(WorldStreaming.WouldLoad(tile, edge));
        Assert.False(WorldStreaming.WouldLoad(tile, [edge[0] - 1, edge[1], edge[2]]));

        // A persistent scene loads from anywhere, and a scene without bounds from nowhere.
        Assert.True(WorldStreaming.WouldLoad(persistent, At(0)));
        Assert.Equal(double.PositiveInfinity, WorldStreaming.Distance(persistent, At(0)));
        Assert.False(WorldStreaming.WouldLoad(tile, At(0)));
    }

    [Fact]
    public void ANewSettingIsIndentedWithATabWhateverTheScenesIndent()
    {
        var file = Read("world 1\nscene $" + Base + "\n  min = [0, 0, 0]\n");
        file.SetPersistent(file.Find(Base)!, true);
        Assert.Equal("world 1\nscene $" + Base + "\n  min = [0, 0, 0]\n\tpersistent = true\n", file.Text);
    }
}
