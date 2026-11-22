using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Tests;

/// <summary>The timeline's edits of a cutscene's text: move, trim, slip, split and delete, and what they keep.</summary>
public sealed class CutsceneEditsTests
{
    // 30 fps, so a frame is 2000 ticks.
    const string Text = """
        cutscene 1
        length = 600000
        rate = 30

        binding 1 "Fox"
        	possess = @0123456789abcdef0123456789abcdef/1
        track 1 animation "Walk"
        	binding = 1
        	section 1 0 120000
        		asset = $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        		offset = 6000
        	# The second clip.
        	section 2 180000 300000
        		asset = $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        track 2 transform "Path"
        	binding = 1
        	section 3 60000 240000
        		ease_in = 6000
        		ease_out = 6000
        		channel position_x
        			key 0 0 linear
        			key 120000 4 linear
        track 3 audio "Line"
        	section 4 30000 90000
        		asset = $bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        track 4 presentation "Subs"
        	section 5 30000 90000
        		kind = subtitle
        		text = "Hi"
        		audio = 4
        track 5 event "Story"
        	trigger 1 300000 seen

        """;

    static CutsceneFile Parse() => CutsceneFile.Parse(Text.ReplaceLineEndings("\n")).File!;

    // The text with lines replaced, each pair an old line and the new one.
    static string With(params (string Old, string New)[] lines)
    {
        var text = Text.ReplaceLineEndings("\n");
        foreach (var (old, @new) in lines)
        {
            Assert.Contains(old.ReplaceLineEndings("\n"), text);
            text = text.Replace(old.ReplaceLineEndings("\n"), @new.ReplaceLineEndings("\n"));
        }
        return text;
    }

    [Fact]
    public void AMoveKeepsTheTracksSectionsInOrderWithTheirComments()
    {
        var file = Parse();
        Assert.Equal(["section:1"], CutsceneEdits.Move(file, ["section:1"], 200000));
        // Section 1 now starts after section 2, so it goes after it, and section 2 keeps its comment.
        Assert.Equal(With(("""
            	section 1 0 120000
            		asset = $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            		offset = 6000
            	# The second clip.
            	section 2 180000 300000
            		asset = $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

            """, """
            	# The second clip.
            	section 2 180000 300000
            		asset = $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            	section 1 200000 320000
            		asset = $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            		offset = 6000

            """)), file.Text);
    }

    [Fact]
    public void AMoveStopsAtTheEndsOfTheCutsceneAndOfAKeysSection()
    {
        var file = Parse();
        CutsceneEdits.Move(file, ["section:2", "trigger:1"], 400000);
        // Section 2 ends at the length, and the trigger moves as far.
        Assert.Equal((480000, 600000), (file.Find("section:2")!.Start, file.Find("section:2")!.End));
        Assert.Equal(600000, file.Find("trigger:1")!.Start);
        CutsceneEdits.Move(file, ["section:1"], -50000);
        Assert.Equal(0, file.Find("section:1")!.Start);

        // A key moves inside its section, and one that passes another takes its place in the channel's order.
        var moved = CutsceneEdits.Move(file, ["section:3/channel:position_x/key:0"], 500000);
        Assert.Equal(["section:3/channel:position_x/key:1"], moved);
        Assert.Equal(180000, file.Find("section:3/channel:position_x/key:1")!.Start);
        Assert.Equal(120000, file.Find("section:3/channel:position_x/key:0")!.Start);
    }

    [Fact]
    public void ASubtitleMovesWithItsAudioSectionAndALockedTrackDoesNotMove()
    {
        var file = Parse();
        CutsceneEdits.Move(file, ["section:4"], 6000);
        Assert.Equal((36000, 96000), (file.Find("section:4")!.Start, file.Find("section:4")!.End));
        Assert.Equal((36000, 96000), (file.Find("section:5")!.Start, file.Find("section:5")!.End));

        var locked = Parse();
        Assert.Empty(CutsceneEdits.Move(locked, ["section:1"], 6000, new HashSet<int> { 1 }));
        Assert.Equal(Text.ReplaceLineEndings("\n"), locked.Text);
    }

    [Fact]
    public void ATrimKeepsKeysAndTheSourceWhereTheyAreOnTheCutscenesTime()
    {
        var file = Parse();
        // The head of the animation's section: its offset into the clip goes on as far.
        CutsceneEdits.Trim(file, "section:1", CutsceneEdge.Start, 30000, ripple: false);
        Assert.Equal(With(("section 1 0 120000", "section 1 30000 120000"), ("offset = 6000", "offset = 36000")), file.Text);
        // Back, it stops at the cutscene's start.
        CutsceneEdits.Trim(file, "section:1", CutsceneEdge.Start, -100000, ripple: false);
        Assert.Equal(Text.ReplaceLineEndings("\n"), file.Text);
        // A section whose clip starts at its start cannot take more of it.
        CutsceneEdits.Trim(file, "section:2", CutsceneEdge.Start, -100000, ripple: false);
        Assert.Equal(Text.ReplaceLineEndings("\n"), file.Text);

        // The transform's keys stay where they are on the cutscene's time.
        var keyed = Parse();
        CutsceneEdits.Trim(keyed, "section:3", CutsceneEdge.Start, -20000, ripple: false);
        Assert.Equal(With(("section 3 60000 240000", "section 3 40000 240000"), ("key 0 0 linear", "key 20000 0 linear"), ("key 120000 4 linear", "key 140000 4 linear")), keyed.Text);
        // Its head cannot pass its first key, nor its tail its last.
        CutsceneEdits.Trim(keyed, "section:3", CutsceneEdge.Start, 50000, ripple: false);
        Assert.Equal(60000, keyed.Find("section:3")!.Start);
        CutsceneEdits.Trim(keyed, "section:3", CutsceneEdge.End, -200000, ripple: false);
        Assert.Equal(180000, keyed.Find("section:3")!.End);
    }

    [Fact]
    public void ATrimKeepsTheEasesAndAFrame()
    {
        var file = Parse();
        CutsceneEdits.Trim(file, "section:4", CutsceneEdge.End, -100000, ripple: false);
        Assert.Equal(32000, file.Find("section:4")!.End);
        // Section 3's eases add to 12000 ticks, but its keys hold it longer.
        CutsceneEdits.Delete(file, ["section:3/channel:position_x/key:1", "section:3/channel:position_x/key:0"], ripple: false);
        Assert.Null(file.Find("section:3/channel:position_x"));
        CutsceneEdits.Trim(file, "section:3", CutsceneEdge.End, -500000, ripple: false);
        Assert.Equal(72000, file.Find("section:3")!.End);
    }

    [Fact]
    public void ARippleMovesTheLaterSectionsOfTheTrackByTheChangeOfLength()
    {
        var file = Parse();
        CutsceneEdits.Trim(file, "section:1", CutsceneEdge.End, 30000, ripple: true);
        Assert.Equal(With(("section 1 0 120000", "section 1 0 150000"), ("section 2 180000 300000", "section 2 210000 330000")), file.Text);
        // A ripple of the head keeps the start: the clip starts later in it, and the length is shorter.
        CutsceneEdits.Trim(file, "section:1", CutsceneEdge.Start, 10000, ripple: true);
        Assert.Equal(With(("section 1 0 120000", "section 1 0 140000"), ("offset = 6000", "offset = 16000"), ("section 2 180000 300000", "section 2 200000 320000")), file.Text);

        // A ripple delete closes the gap.
        var deleted = Parse();
        CutsceneEdits.Delete(deleted, ["section:1"], ripple: true);
        Assert.Equal((60000, 180000), (deleted.Find("section:2")!.Start, deleted.Find("section:2")!.End));
    }

    [Fact]
    public void ASlipMovesOnlyTheSource()
    {
        var file = Parse();
        CutsceneEdits.Slip(file, "section:1", -4000);
        Assert.Equal(With(("offset = 6000", "offset = 10000")), file.Text);
        CutsceneEdits.Slip(file, "section:1", 20000);
        Assert.Equal(With(("\t\toffset = 6000\n", "")), file.Text);
        // A transform's section has no source to slip.
        CutsceneEdits.Slip(file, "section:3", 20000);
        Assert.Equal(With(("\t\toffset = 6000\n", "")), file.Text);
    }

    [Fact]
    public void ASplitMakesTwoSectionsWithAKeyAtTheCutInEach()
    {
        var file = Parse();
        Assert.Equal(["section:3", "section:6", "section:1", "section:7"], CutsceneEdits.Split(file, ["section:3", "section:1", "section:4"], 100000));
        Assert.Equal(With(
            ("""
            	section 1 0 120000
            		asset = $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            		offset = 6000

            """, """
            	section 1 0 100000
            		asset = $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            		offset = 6000
            	section 7 100000 120000
            		asset = $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            		offset = 106000

            """),
            ("""
            	section 3 60000 240000
            		ease_in = 6000
            		ease_out = 6000
            		channel position_x
            			key 0 0 linear
            			key 120000 4 linear

            """, """
            	section 3 60000 100000
            		ease_in = 6000
            		channel position_x
            			key 0 0 linear
            			key 40000 1.333333 linear
            	section 6 100000 240000
            		ease_out = 6000
            		channel position_x
            			key 0 1.333333 linear
            			key 80000 4 linear

            """)), file.Text);
    }

    [Fact]
    public void TheRangeAndTheLengthStayInsideEachOther()
    {
        var file = Parse();
        CutsceneEdits.SetRange(file, 60000, 900000);
        Assert.Equal("[60000, 600000]", file.Root.Get("range"));
        Assert.Equal((60000, 600000), CutsceneEdits.RangeOf(file));
        CutsceneEdits.SetRange(file, 0, 600000);
        Assert.Null(file.Root.Get("range"));
        // The length is at least the end of what the cutscene has: the trigger at 300000.
        CutsceneEdits.SetLength(file, 1000);
        Assert.Equal(300000, file.Length);
    }
}
