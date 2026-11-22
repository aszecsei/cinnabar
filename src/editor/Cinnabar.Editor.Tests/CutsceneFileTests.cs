using Cinnabar.Editor.Document;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Tests;

/// <summary>The cutscene file's reader and writer, which keep every line.</summary>
public sealed class CutsceneFileTests
{
    /// <summary>The text of a new cutscene, which tools/cook/cutscenes.odin's CUTSCENE_TEMPLATE is the same as.</summary>
    internal static string Template =>
        File.ReadAllText(Path.Combine(EditorOptions.RepositoryRoot(), "tools", "cook", "testdata", "cutscenes", "template.cutscene")).ReplaceLineEndings("\n");

    internal static string Sample(string name) =>
        File.ReadAllText(Path.Combine(EditorOptions.RepositoryRoot(), "samples", "mygame", "content", "cutscenes", name + ".cutscene"));

    static CutsceneFile Parse(string text) => CutsceneFile.Parse(text).File!;

    [Theory]
    [InlineData("intro")]
    [InlineData("fox_walk")]
    public void TheSamplesWriteBackAsTheyWereWithEveryLineInABlock(string name)
    {
        var text = Sample(name);
        var file = Parse(text);
        Assert.Equal(text, file.Text);
        // With other line endings too.
        var crlf = text.ReplaceLineEndings("\r\n");
        Assert.Equal(crlf, Parse(crlf).Text);
        Assert.Equal(text.Split('\n').Length - (text.EndsWith('\n') ? 1 : 0), file.Blocks.Sum(b => b.LineTexts.Count()));
    }

    [Fact]
    public void TheTemplateIsTenSecondsAtThirtyWithAnEmptyCameraCutTrack()
    {
        var file = Parse(Template);
        Assert.Equal(Template, file.Text);
        Assert.Equal(600000, file.Length);
        Assert.Equal(30, file.Rate);
        Assert.Empty(file.Bindings);
        var track = Assert.Single(file.Tracks);
        Assert.Equal(("camera_cut", 1, "Cameras"), (track.TrackKind, track.Id, track.Name));
        Assert.Empty(track.Children);
    }

    [Fact]
    public void AHashInsideAWordIsNotAComment()
    {
        const string text = "cutscene 1\n# The header.\nlength = 60000 # after a space\nbinding 1 \"Crate\"\n" +
            "\tpossess = @0123456789abcdef0123456789abcdef/00000000000000b2#00000000000000c3\t# the room's crate\n";
        var file = Parse(text);

        var binding = Assert.Single(file.Bindings);
        Assert.Equal("@0123456789abcdef0123456789abcdef/00000000000000b2#00000000000000c3", binding.Get("possess"));
        Assert.Equal(60000, file.Length);
        // An edit keeps the comment after the value, and the file writes back as it was.
        binding.Set("possess", "@0123456789abcdef0123456789abcdef/00000000000000b2#00000000000000d4");
        Assert.EndsWith("#00000000000000d4\t# the room's crate\n", file.Text);
        Assert.Equal(text, Parse(text).Text);
    }

    [Fact]
    public void BlocksNestByKeywordAsTheCookerReadsThemAndNotByIndent()
    {
        var file = Parse(Sample("intro"));
        Assert.Equal([1, 2, 3, 4, 5], file.Bindings.Select(b => b.Id!.Value));
        Assert.Equal("Walking Fox", file.Bindings.First().Name);
        Assert.Equal("@f496b929575035d9c2626ed56d3165ba/79cea6d7586e3f48", file.Bindings.First().Get("possess"));
        var walk = file.Tracks.First();
        Assert.Equal(("transform", "Fox walks", "1"), (walk.TrackKind, walk.Name, walk.Get("binding")));
        var section = Assert.Single(walk.Children);
        Assert.Equal((CutsceneBlockKind.Section, 1, 0, 600000), (section.Kind, section.Id, section.Start!.Value, section.End!.Value));
        var channel = Assert.Single(section.Children);
        Assert.Equal(("position_x", 2), (channel.Name, channel.Children.Count));
        Assert.Equal(("4", "linear", 600000), (channel.Children[1].KeyValue, channel.Children[1].KeyInterpolation, channel.Children[1].Start!.Value));
        // A sub-sequence's binds are its section's settings.
        Assert.Equal("1", file.Find("section:4")!.Get("bind 1"));

        // Without indents, a file reads the same.
        var flat = string.Join("\n", Sample("intro").Split('\n').Select(l => l.TrimStart()));
        Assert.Equal(file.Blocks.Select(CutsceneFile.PathOf), Parse(flat).Blocks.Select(CutsceneFile.PathOf));
    }

    [Fact]
    public void AMarkerIsABlockOfTheCutsceneWithItsTimeNameAndColor()
    {
        const string Text = "cutscene 1\nlength = 60000\n# The beat.\nmarker 2 30000 \"Beat drop\"\n\tcolor = \"#336699\"\ntrack 1 event \"E\"\n\ttrigger 1 0 go\nmarker 1 0 \"Top\"\n";
        var file = Parse(Text);
        Assert.Equal(Text, file.Text);
        Assert.Equal(["marker:2", "track:1", "marker:1"], file.Root.Children.Select(CutsceneFile.PathOf));
        var beat = file.Find("marker:2")!;
        Assert.Equal((CutsceneBlockKind.Marker, 2, 30000, "Beat drop", "\"#336699\""), (beat.Kind, beat.Id!.Value, beat.Start!.Value, beat.Name!, beat.Get("color")));
        Assert.Null(beat.End);
        // A marker after a track is the cutscene's, not the track's, and the trigger stays the track's.
        Assert.Equal(["marker:2", "marker:1"], file.Markers.Select(CutsceneFile.PathOf));
        Assert.Single(file.Find("track:1")!.Children);

        beat.SetName("Drop");
        beat.SetTime(45000);
        beat.SetId(7);
        Assert.Equal(Text.Replace("marker 2 30000 \"Beat drop\"", "marker 7 45000 \"Drop\""), file.Text);
        Assert.Equal(8, file.NextId(CutsceneBlockKind.Marker));
        // Triggers and ranges share their IDs, as the cooker checks them together.
        Assert.Equal(2, file.NextId(CutsceneBlockKind.Range));
        // A sort of the cutscene's children moves only the markers, among the places that markers have.
        Assert.True(CutsceneFile.SortChildren(file.Root));
        Assert.Equal(["marker:1", "track:1", "marker:7"], file.Root.Children.Select(CutsceneFile.PathOf));
    }

    [Fact]
    public void ALineInNoPlaceStaysInTheOpenBlockForTheCookerToReport()
    {
        const string Text = "cutscene 1\nlength = 60\nkey 0 1 linear\ntrack 1 event \"E\"\nchannel gain\n\tkey 0 1 linear\n";
        var file = Parse(Text);
        Assert.Equal(Text, file.Text);
        // A key outside a channel is the header's line, and a channel outside a section is the track's.
        Assert.Same(file.Root, file.BlockAt(3));
        Assert.Same(file.Tracks.Single(), file.BlockAt(5));
        Assert.Same(file.Tracks.Single(), file.BlockAt(6));
        Assert.Empty(file.Tracks.Single().Children);
    }

    [Fact]
    public void ACommentAboveABlockIsItsAndBlockAtFindsTheInnermost()
    {
        var text = Sample("intro").ReplaceLineEndings("\n");
        var file = Parse(text);
        var lines = text.Split('\n').ToList();
        var comment = lines.IndexOf("\t# A close shot turns to the fox as it passes, while Rack focus pulls the focus in.") + 1;
        var close = file.Find("section:6")!;
        Assert.Same(close, file.BlockAt(comment));
        Assert.Equal(comment + 1, file.LineOf(close));
        Assert.Same(close, file.BlockAt(file.LineOf(close) + 1));
        Assert.Same(file.Root, file.BlockAt(1));
        Assert.Null(file.BlockAt(lines.Count + 1));

        // Removing the section takes its comment and its lines, and nothing else.
        var count = close.Descendants().Sum(b => b.LineTexts.Count());
        file.Remove(close);
        Assert.Equal(string.Join("\n", lines.Take(comment - 1).Concat(lines.Skip(comment - 1 + count))), file.Text);
        Assert.Contains("section 7", file.Text);
    }

    [Fact]
    public void AnEditChangesOnlyItsOwnLinesAndANewSettingComesBeforeTheChildren()
    {
        var text = Sample("intro").ReplaceLineEndings("\n");
        var file = Parse(text);

        var fox = file.Find("binding:1")!;
        fox.SetName("Running Fox");
        Assert.Equal(text.Replace("binding 1 \"Walking Fox\"", "binding 1 \"Running Fox\""), file.Text);

        // A track's new setting goes after its last one, above its first section, with that setting's indent.
        var bark = file.Find("track:3")!;
        bark.Set("muted", "true");
        Assert.Contains("\tbinding = 2\n\tmuted = true\n\tsection 3 360000 420000\n", file.Text);
        // A setting that the block has changes in place, keeping its comment; null removes it.
        file.Root.Set("rate", "24");
        Assert.Contains("\nrate = 24\n", file.Text);
        Assert.Contains("# The range ends at 10 s. The music runs 2 s past it, into gameplay.\nrange = [0, 600000]\nrate = 24\n", file.Text);
        bark.Set("muted", null);
        file.Root.Set("rate", "30");
        fox.SetName("Walking Fox");
        Assert.Equal(text, file.Text);

        // A new header setting goes after the header's last one, before the first binding.
        file.Root.Set("skip", "none");
        Assert.Contains("skip_color = \"#000000\"\nskip = none\n\nbinding 1", file.Text);

        // A block with no settings gets its first a level under its keyword line.
        var bare = Parse(Template);
        bare.Tracks.Single().Set("muted", "true");
        Assert.EndsWith("track 1 camera_cut \"Cameras\"\n\tmuted = true\n", bare.Text);
    }

    [Fact]
    public void SpansTimesAndKeysRewriteTheirKeywordLine()
    {
        var file = Parse(Sample("intro").ReplaceLineEndings("\n"));
        var close = file.Find("section:6")!;
        close.SetSpan(210000, 400000);
        Assert.Contains("\tsection 6 210000 400000\n", file.Text);
        var key = file.Find("section:1/channel:position_x/key:1")!;
        key.SetTime(540000);
        key.SetKeyValue("5");
        key.SetKeyInterpolation("bezier 0.5");
        Assert.Contains("\t\t\tkey 540000 5 bezier 0.5\n", file.Text);
        Assert.Equal("section:1/channel:position_x/key:1", CutsceneFile.PathOf(key));
        // Section IDs are the cutscene's, across its tracks.
        Assert.Equal(14, file.NextId(CutsceneBlockKind.Section));
    }

    [Fact]
    public void OnlyABadFirstLineIsRefused()
    {
        var (file, problem) = CutsceneFile.Parse("# A comment first is fine.\nscene 1\n");
        Assert.Null(file);
        Assert.Equal(2, problem!.Line);
        Assert.Null(CutsceneFile.Parse("").File);
        // Everything else opens, for the cooker to report.
        Assert.NotNull(CutsceneFile.Parse("cutscene 1\nlength = soon\nsection 1 0 10\n").File);
    }

    [Fact]
    public void TimesShowAsTimecodeAndFramesAtTheDisplayRate()
    {
        Assert.Equal("00:10:00", Cutscenes.CutsceneTime.Timecode(600000, 30));
        Assert.Equal(300, Cutscenes.CutsceneTime.Frames(600000, 30));
        Assert.Equal("01:02:12", Cutscenes.CutsceneTime.Timecode(62 * 60000 + 30000, 24));
        Assert.Equal(2500, Cutscenes.CutsceneTime.FrameTicks(24));
    }
}
