using System.Diagnostics;
using System.Text;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Tools;
using L = Cinnabar.Editor.Tools.CutsceneTimelineLayout;

namespace Cinnabar.Editor.Tests;

/// <summary>The timeline's pure part: ticks and pixels, rows, hit tests, boxes, snapping, and the cost of a redraw.</summary>
public sealed class CutsceneTimelineLayoutTests
{
    static CutsceneFile Intro() => CutsceneFile.Parse(CutsceneFileTests.Sample("intro").ReplaceLineEndings("\n")).File!;

    // A tick a pixel per thousand, from 0: tick t is at x = Gutter + t / 1000.
    static readonly TimelineView Thousand = new(0, 1000, TimelineZoom.Ticks);

    static double X(int tick) => L.Gutter + tick / 1000.0;

    static double Y(L layout, string path, CutsceneRowKind kind = CutsceneRowKind.Track) =>
        L.RulerHeight + layout.Rows.First(r => r.Path == path && r.Kind == kind).Top + L.RowHeight / 2;

    [Fact]
    public void ABindingsRowCarriesWhatItBindsAndABindingsFilterHidesTheRest()
    {
        var file = Intro();
        var bindings = file.Bindings.Select(b => b.Id).OfType<int>().ToList();
        var info = new CutsceneBindingInfo(CutsceneBindingKind.Spawned, "Prop", CutsceneBindingState.Broken, "gone");

        var all = L.Build(file, new HashSet<string>(), null, b => b.Id == bindings[0] ? info : null);
        var rows = all.Rows.Where(r => r.Kind == CutsceneRowKind.Binding).ToList();
        Assert.Equal(bindings.Count, rows.Count);
        Assert.Same(info, rows[0].Binding);
        Assert.All(rows.Skip(1), r => Assert.Null(r.Binding));
        Assert.All(all.Rows.Where(r => r.Kind != CutsceneRowKind.Binding), r => Assert.Null(r.Binding));

        // Only the first binding and its tracks; not the tracks that no binding has, nor the other bindings.
        var only = L.Build(file, new HashSet<string>(), new CutsceneRowFilter("", null, new HashSet<int> { bindings[0] }));
        Assert.Equal(CutsceneFile.PathOf(file.Bindings.First()), only.Rows[0].Path);
        Assert.All(only.Rows.Skip(1), r => Assert.Equal(1, r.Depth));
        Assert.False(new CutsceneRowFilter("", null, new HashSet<int>()).IsNone);
        Assert.Empty(L.Build(file, new HashSet<string>(), new CutsceneRowFilter("", null, new HashSet<int>())).Rows);
    }

    [Fact]
    public void TicksArePixelsAtEveryZoom()
    {
        var view = new TimelineView(-1000, 50, TimelineZoom.Ticks);
        Assert.Equal(100, view.X(4000));
        Assert.Equal(4000, view.At(100));
        var fit = TimelineView.Fit(0, 600000, 1000, TimelineZoom.Ticks);
        Assert.Equal((-30000.0, 660.0), (fit.Start, fit.PerPixel));
        Assert.Equal(TimelineZoom.Ticks.Min, TimelineView.Fit(0, 100, 1000, TimelineZoom.Ticks).PerPixel);
        Assert.Equal(TimelineZoom.Ticks.Max, fit.ZoomAbout(0, 1e9).PerPixel);
        var zoomed = fit.ZoomAbout(400, 0.25);
        Assert.Equal(fit.At(400), zoomed.At(400), 6);
        Assert.Equal(165, zoomed.PerPixel, 6);

        // The ruler's ticks are whole seconds where a second fits, and whole frames below: at 25 fps, a frame is 2400 ticks.
        Assert.Equal(48000, TimelineGeometry.FrameSpacing(500, 2400));
        Assert.Equal(120000, TimelineGeometry.FrameSpacing(1000, 2400));
        Assert.Equal(4000, TimelineGeometry.FrameSpacing(30, 2000));
        Assert.Equal(60000, TimelineGeometry.FrameSpacing(700, 2000));
    }

    [Fact]
    public void TheTracksWithNoBindingComeFirstAndEachBindingsTracksAreUnderIt()
    {
        var layout = L.Build(Intro(), new HashSet<string>());
        Assert.Equal(
        [
            "Cuts", "Music", "Dialogue", "Story", "Presentation", "Opening shot",
            "Walking Fox", "Fox walks", "Fox walk clip", "Extra Guard", "Bark", "Wide Shot", "Close Shot", "Rack focus", "Tracking Shot",
        ], layout.Rows.Select(r => r.Label));
        Assert.Equal(1, layout.Rows.First(r => r.Label == "Fox walks").Depth);
        // A track's keys are on its row at their time on the cutscene's, and its channels are folded.
        var music = layout.Rows.First(r => r.Label == "Music");
        Assert.Equal([0, 200000, 400000], music.Keys.Select(k => k.Start));
        Assert.True(music is { CanFold: true, Folded: true });

        // Unfolded, a track has a row for each channel; folded, a binding hides its tracks.
        var unfolded = L.Build(Intro(), new HashSet<string> { "track:7", "binding:1" });
        Assert.Contains(unfolded.Rows, r => r is { Kind: CutsceneRowKind.Channel, Label: "gain" } && r.Keys.Count == 3);
        Assert.DoesNotContain(unfolded.Rows, r => r.Label == "Fox walks");
        Assert.Equal((0, 600000), layout.Range);
        Assert.Equal(720000, layout.Length);
    }

    [Fact]
    public void APointIsOnAnEdgeABodyAKeyAHandleOrNothing()
    {
        var layout = L.Build(Intro(), new HashSet<string>());
        var cuts = Y(layout, "track:5");
        CutsceneHit Hit(double x, double y) => layout.HitTest(x, y, Thousand, 0);

        // Section 6 is from 200000 to 400000: x 420 to 620.
        Assert.Equal((CutsceneHitKind.Body, "section:6"), (Hit(X(300000), cuts).Kind, Hit(X(300000), cuts).Paths[0]));
        Assert.Equal(CutsceneHitKind.EndEdge, Hit(X(400000) - 3, cuts).Kind);
        // Where section 6 ends and section 7 starts, the later one is on top.
        Assert.Equal((CutsceneHitKind.StartEdge, "section:7"), (Hit(X(400000) + 1, cuts).Kind, Hit(X(400000) + 1, cuts).Paths[0]));
        Assert.Equal(CutsceneHitKind.Empty, Hit(X(700000), cuts).Kind);
        // The music's key at 200000, before its section's body.
        var music = Y(layout, "track:7");
        Assert.Equal((CutsceneHitKind.Key, "section:9/channel:gain/key:1"), (Hit(X(200000) + 2, music).Kind, Hit(X(200000) + 2, music).Paths[0]));
        Assert.Equal(CutsceneHitKind.Trigger, Hit(X(600000), Y(layout, "track:9")).Kind);

        // The ruler: the length's handle at its top, the range's at its bottom, and the playhead's scrub elsewhere.
        Assert.Equal(CutsceneHitKind.Length, Hit(X(720000), 4).Kind);
        Assert.Equal(CutsceneHitKind.RangeEnd, Hit(X(600000), L.RulerHeight - 2).Kind);
        Assert.Equal(CutsceneHitKind.RangeStart, Hit(X(0) + 1, L.RulerHeight - 2).Kind);
        Assert.Equal(CutsceneHitKind.Ruler, Hit(X(300000), 4).Kind);

        // The headers: a fold, a lock, and the rest of the row.
        var fox = Y(layout, "binding:1", CutsceneRowKind.Binding);
        Assert.Equal(CutsceneHitKind.Fold, Hit(8, fox).Kind);
        Assert.Equal(CutsceneHitKind.Header, Hit(100, fox).Kind);
        Assert.Equal((CutsceneHitKind.Lock, "track:5"), (Hit(L.Gutter - 10, cuts).Kind, Hit(L.Gutter - 10, cuts).Paths[0]));
    }

    [Fact]
    public void ABoxSelectsWhatItCoversAndKeysCloseTogetherAreOneGlyph()
    {
        var layout = L.Build(Intro(), new HashSet<string>());
        // From the cuts' row to the music's, from 150000 to 250000.
        var box = layout.InBox(X(150000), Y(layout, "track:5"), X(250000), Y(layout, "track:7"), Thousand, 0);
        Assert.Equal(["section:5", "section:6", "section:9/channel:gain/key:1", "section:9"], box);

        // Keys under 2 pixels apart merge into one glyph, as a chain: the music's keys are 200000 ticks apart.
        Glyphs(150000, [3]);
        Glyphs(90000, [1, 1, 1]);
        void Glyphs(double perPixel, int[] counts) =>
            Assert.Equal(counts, layout.Visible(new TimelineView(0, perPixel, TimelineZoom.Ticks), 1000, 0, 1000).First(r => r.Row.Label == "Music").Keys.Select(k => k.Items.Count));
        // In view from 0 to 100000, only what is there draws.
        var near = layout.Visible(Thousand, 100, 0, 1000);
        Assert.Equal(["section:5"], near.First(r => r.Row.Label == "Cuts").Bars.Select(b => b.Item.Path));
        Assert.Single(near.First(r => r.Row.Label == "Music").Keys);
        // Rows under the bottom do not draw.
        Assert.Equal(3, layout.Visible(Thousand, 100, 0, L.RulerHeight + 2.5 * L.RowHeight).Count);
    }

    [Fact]
    public void ADragSnapsToATargetNearItOrElseToAFrame()
    {
        int[] targets = [0, 60000, 61000];
        // 1000 ticks a pixel: a target 6 pixels away or nearer wins, the nearest of them.
        Assert.Equal((60000, (int?)60000), TimelineSnap.Snap(56500, targets, 1000, 2000, true));
        Assert.Equal((61000, (int?)61000), TimelineSnap.Snap(62000, targets, 1000, 2000, true));
        Assert.Equal((70000, (int?)null), TimelineSnap.Snap(70500, targets, 1000, 2000, true));
        // Off, as with Ctrl held, a time stays as it is.
        Assert.Equal((56500, (int?)null), TimelineSnap.Snap(56500, targets, 1000, 2000, false));

        var layout = L.Build(Intro(), new HashSet<string>());
        var snapTo = layout.SnapTargets(new HashSet<string> { "section:6" });
        Assert.Contains(400000, snapTo);
        Assert.DoesNotContain(399000, snapTo);
        Assert.Contains(200000, snapTo);
        Assert.Equal([0, 30000, 174000, 200000, 300000, 360000, 400000, 420000, 600000, 720000], layout.Edges());
    }

    [Fact]
    public void AMarkerIsOnTheRulerOverTheHandlesAndIsATargetAndAnEdge()
    {
        var file = Intro();
        CutsceneEdits.AddMarker(file, 720000, "End");
        CutsceneEdits.AddMarker(file, 100000, "Beat");
        file.Find("marker:2")!.Set("color", "\"#336699\"");
        var layout = L.Build(file, new HashSet<string>());
        Assert.Equal([("marker:2", 100000, "Beat", "#336699"), ("marker:1", 720000, "End", (string?)null)],
            layout.Markers.Select(m => (m.Path, m.Start, m.Label!, m.Color)));
        // The flag at the length is the marker's, not the length's handle, and under the flags, the handle is.
        Assert.Equal((CutsceneHitKind.Marker, "marker:1"), (layout.HitTest(X(720000) + 2, 4, Thousand, 0).Kind, layout.HitTest(X(720000) + 2, 4, Thousand, 0).Paths[0]));
        Assert.Equal(CutsceneHitKind.Length, layout.HitTest(X(720000), L.MarkerHeight + 2, Thousand, 0).Kind);
        Assert.Equal(CutsceneHitKind.Ruler, layout.HitTest(X(300000), 4, Thousand, 0).Kind);
        Assert.Contains(100000, layout.SnapTargets(new HashSet<string>()));
        Assert.DoesNotContain(100000, layout.SnapTargets(new HashSet<string> { "marker:2" }));
        Assert.Contains(100000, layout.Edges());
        Assert.Equal((100000, 720000), layout.SpanOf(new HashSet<string> { "marker:1", "marker:2" }));
    }

    [Fact]
    public void AFilterShowsTheTracksThatItNamesOrThatHaveKeysInItsSpan()
    {
        var file = Intro();
        string[] Labels(CutsceneRowFilter filter) => [.. L.Build(file, new HashSet<string>(), filter).Rows.Select(r => r.Label)];
        // A binding that the text names shows all of its tracks; a track that it names shows with its binding.
        Assert.Equal(["Walking Fox", "Fox walks", "Fox walk clip"], Labels(new("fox", null)));
        Assert.Equal(["Extra Guard", "Bark"], Labels(new("BARK", null)));
        Assert.Equal(["Music"], Labels(new("music", null)));
        Assert.Empty(Labels(new("nothing", null)));
        Assert.Equal(L.Build(file, new HashSet<string>()).Rows.Select(r => r.Label), Labels(CutsceneRowFilter.None));

        // With a span, only the tracks with a key in it, and the bindings of those.
        var keyed = L.Build(file, new HashSet<string>(), new("", (150000, 250000)));
        Assert.Contains(keyed.Rows, r => r.Label == "Music");
        Assert.All(keyed.Rows.Where(r => r.Kind == CutsceneRowKind.Track), r => Assert.Contains(r.Keys, k => k.Start is >= 150000 and <= 250000));
        Assert.All(keyed.Rows.Where(r => r.Kind == CutsceneRowKind.Binding), b => Assert.Contains(keyed.Rows, r => r.Depth == 1 && r.Top == b.Top + L.RowHeight));
        Assert.True(keyed.Rows.Count < L.Build(file, new HashSet<string>()).Rows.Count);
    }

    [Fact]
    public void ATracksHeaderHasMuteSoloAndLockAtItsRightEnd()
    {
        var file = Intro();
        file.Find("track:7")!.Set("muted", "true");
        var layout = L.Build(file, new HashSet<string>());
        var music = Y(layout, "track:7");
        CutsceneHitKind Hit(double x, double y) => layout.HitTest(x, y, Thousand, 0).Kind;
        Assert.Equal(CutsceneHitKind.Mute, Hit(L.MuteX + 5, music));
        Assert.Equal(CutsceneHitKind.Solo, Hit(L.SoloX + 5, music));
        Assert.Equal(CutsceneHitKind.Lock, Hit(L.Gutter - 5, music));
        Assert.Equal(CutsceneHitKind.Header, Hit(L.MuteX - 5, music));
        Assert.Equal(CutsceneHitKind.Header, Hit(L.MuteX + 5, Y(layout, "binding:1", CutsceneRowKind.Binding)));
        Assert.True(layout.Rows.First(r => r.Path == "track:7").AssetMuted);
        Assert.False(layout.Rows.First(r => r.Path == "track:5").AssetMuted);
    }

    // The intro's fox walk clip, its bark and its line, as the index knows them, by GUID.
    const string Walk = "dea303d3f0374a9e56b0bb58f4a85315";
    const string BarkSound = "7ce894b4b95e68b918869459e5cd9c93";

    static CutsceneClipInfo? Clips(string guid) => guid switch
    {
        Walk => new CutsceneClipInfo("Walk", 100000),
        BarkSound => new CutsceneClipInfo("bark", null),
        _ => null,
    };

    [Fact]
    public void ALoopingClipHasAMarkAtEachLoopAndCloseMarksAreOneRun()
    {
        var clip = new CutsceneClipSpan(0, 1, true, 100000);
        var marks = L.ClipMarks(0, 350000, clip, Thousand, 1000);
        Assert.Equal([(100.0, 100.0), (200.0, 200.0), (300.0, 300.0)], marks.Loops);
        // The pass that the section ends in goes on past its end, faded.
        Assert.Equal((null, (350.0, 400.0)), (marks.Head, marks.Tail));
        Assert.Null(marks.End);

        // An offset moves the loops, and shows the rest of the first pass before the start.
        var offset = L.ClipMarks(0, 350000, clip with { Offset = 30000 }, Thousand, 1000);
        Assert.Equal([(70.0, 70.0), (170.0, 170.0), (270.0, 270.0)], offset.Loops);
        Assert.Equal(((-30.0, 0.0), (350.0, 370.0)), (offset.Head, offset.Tail));
        // At twice the speed, a pass is half as long.
        Assert.Equal(6, L.ClipMarks(0, 350000, clip with { Speed = 2 }, Thousand, 1000).Loops.Count);
        // Only the marks in view: from 150000 to 250000.
        Assert.Equal([(50.0, 50.0)], L.ClipMarks(0, 350000, clip, new TimelineView(150000, 1000, TimelineZoom.Ticks), 100).Loops);
        // Marks closer than 2 pixels are one run over the part in view.
        var dense = L.ClipMarks(0, 350000, clip, new TimelineView(0, 60000, TimelineZoom.Ticks), 1000);
        var run = Assert.Single(dense.Loops);
        Assert.Equal((100000 / 60000.0, 349999 / 60000.0), run);
        // A section that ends where a pass ends has no tail, and the reach of its bar is its own span.
        Assert.Null(L.ClipMarks(0, 300000, clip, Thousand, 1000).Tail);
        Assert.Equal((0.0, 300000.0), new CutsceneTimelineItem(CutsceneItemKind.Section, 0, 300000, "section:1") { Clip = clip }.Reach);
    }

    [Fact]
    public void AClipThatDoesNotLoopShowsWhereItEndsAndItsCutOffPartsAsHints()
    {
        var clip = new CutsceneClipSpan(20000, 1, false, 100000);
        // Shorter than its clip: the part before the offset and the part past the end are hints, and the clip does not end
        // inside it.
        Assert.Equal(new CutsceneClipHints(-20000, 80000, null), L.Hints(0, 50000, clip));
        Assert.Equal((-20000.0, 80000.0), new CutsceneTimelineItem(CutsceneItemKind.Section, 0, 50000, "section:1") { Clip = clip }.Reach);
        // Longer than its clip: the clip ends at 80000, after which the pose holds, and no tail.
        Assert.Equal(new CutsceneClipHints(-20000, null, 80000), L.Hints(0, 200000, clip));
        var marks = L.ClipMarks(0, 200000, clip, Thousand, 1000);
        Assert.Equal((80.0, 0), (marks.End, marks.Loops.Count));
        // An offset past the clip's end has ended at the start.
        Assert.Equal(new CutsceneClipHints(null, null, 0), L.Hints(0, 200000, clip with { Offset = 150000 }));
        // At half the speed, the clip lasts twice as long.
        Assert.Equal(new CutsceneClipHints(-40000, null, 160000), L.Hints(0, 200000, clip with { Speed = 0.5 }));
        // A clip as long as its section ends at its end: nothing to show.
        Assert.Equal(new CutsceneClipHints(null, null, null), L.Hints(0, 100000, clip with { Offset = 0 }));
    }

    [Fact]
    public void ASectionsLabelIsItsClipsNameAndStaysInTheVisiblePartOfItsBar()
    {
        var layout = L.Build(Intro(), new HashSet<string>(), null, null, Clips);
        CutsceneTimelineItem Bar(string path) => layout.Rows.SelectMany(r => r.Bars).Single(b => b.Path == path);
        // A clip that the index knows is named and has its span; a sound that has not cooked is named, with no span; one
        // that the index does not have shows the ID.
        Assert.Equal(("Walk", new CutsceneClipSpan(0, 1, true, 100000)), (Bar("section:2").Label, Bar("section:2").Clip));
        Assert.Equal(("bark", null), (Bar("section:3").Label, Bar("section:3").Clip));
        Assert.Equal("#10", Bar("section:10").Label);
        Assert.Equal((15000, 15000), (Bar("section:2").EaseIn, Bar("section:2").EaseOut));
        // A camera cut's blends are its own, not eases.
        Assert.Equal((0, 0), (Bar("section:5").EaseIn, Bar("section:5").EaseOut));

        // A section that starts off screen has its label at the left of the time area, to its visible end.
        Assert.Equal((4.0, 292.0), L.LabelRoom(-200, 300, 1000));
        Assert.Equal((104.0, 492.0), L.LabelRoom(100, 600, 1000));
        // It stops at the time area's right, and a part too small for a label has none.
        Assert.Equal((504.0, 492.0), L.LabelRoom(500, 1500, 1000));
        Assert.Null(L.LabelRoom(990, 1500, 1000));
        Assert.Null(L.LabelRoom(100, 120, 1000));
    }

    [Fact]
    public void AnEaseHandleIsInTheTopOfItsBarBeforeAKeyAndOverlapsAreWhereSectionsBlend()
    {
        var layout = L.Build(Intro(), new HashSet<string>());
        CutsceneHit Hit(double x, double y) => layout.HitTest(x, y, Thousand, 0);
        double Top(string path) => L.RulerHeight + layout.Rows.First(r => r.Path == path && r.Kind == CutsceneRowKind.Track).Top + 4;

        // The fox's walk, section 1, eases in over 15000 ticks: its handle is at x 15 in the top of its row.
        var walks = Top("track:1");
        Assert.Equal((CutsceneHitKind.EaseIn, "section:1"), (Hit(X(15000), walks).Kind, Hit(X(15000), walks).Paths[0]));
        // Its ease out handle is at its end, where a key is too: the top of the row is the handle, the middle the key.
        Assert.Equal(CutsceneHitKind.EaseOut, Hit(X(600000) - 2, walks).Kind);
        Assert.Equal(CutsceneHitKind.Key, Hit(X(600000) - 2, Y(layout, "track:1")).Kind);
        // Away from a handle, the top of a bar is its body, and a camera cut has no handles.
        Assert.Equal(CutsceneHitKind.Body, Hit(X(300000), walks).Kind);
        Assert.Equal(CutsceneHitKind.StartEdge, Hit(X(200000) + 1, Top("track:5")).Kind);
        Assert.Equal((15.0, 600.0), L.Handles(layout.Rows.First(r => r.Path == "track:1").Bars[0], Thousand));
        // A bar too narrow for its edges has no handles.
        Assert.Null(L.Handles(new CutsceneTimelineItem(CutsceneItemKind.Section, 0, 10000, "section:1"), Thousand));

        // Sections overlap where one starts before the ones before it end.
        CutsceneVisibleBar Bar(double x0, double x1) => new(x0, x1, new CutsceneTimelineItem(CutsceneItemKind.Section, 0, 1, "section:1"));
        Assert.Equal([(80.0, 100.0), (150.0, 170.0)], L.Overlaps([Bar(0, 100), Bar(80, 200), Bar(150, 170)]));
        Assert.Empty(L.Overlaps([Bar(0, 100), Bar(100, 200)]));
    }
}

/// <summary>
/// The timeline's cost at the size the issue names. It measures time, so it runs alone, not beside the other tests.
/// </summary>
[Collection(TimingCollection.Name)]
public sealed class CutsceneTimelineCostTests
{
    [Fact]
    public void ATimelineOfFiftyTracksAndFiveThousandKeysMakesItsDrawListInUnderFourMilliseconds()
    {
        var text = new StringBuilder("cutscene 1\nlength = 600000\nrate = 30\nbinding 1 \"Actor\"\n\tpossess = @0123456789abcdef0123456789abcdef/1\n");
        for (var t = 1; t <= 50; t++)
        {
            text.Append($"track {t} property \"Track {t}\"\n\tbinding = 1\n\tcomponent = 160\n\tfield = \"f\"\n\tsection {t} 0 600000\n\t\tchannel value\n");
            for (var k = 0; k < 100; k++)
            {
                text.Append($"\t\t\tkey {k * 6000} {k % 7} linear\n");
            }
        }
        var file = CutsceneFile.Parse(text.ToString()).File!;
        var build = Stopwatch.StartNew();
        var layout = L.Build(file, new HashSet<string>());
        build.Stop();
        Assert.Equal(5000, layout.Rows.Sum(r => r.Keys.Count));
        // The whole cutscene across 1400 pixels, with every row in view.
        var view = TimelineView.Fit(0, 600000, 1400, TimelineZoom.Ticks);
        for (var i = 0; i < 10; i++)
        {
            layout.Visible(view, 1400, 0, 2000);
        }
        var times = new List<double>();
        for (var i = 0; i < 50; i++)
        {
            var watch = Stopwatch.StartNew();
            var rows = layout.Visible(view, 1400, 0, 2000);
            watch.Stop();
            Assert.Equal(51, rows.Count);
            times.Add(watch.Elapsed.TotalMilliseconds);
        }
        times.Sort();
        var median = times[times.Count / 2];

        // A drag's step: the text read again from the drag's start, a move, the rows built again, and the draw list.
        var source = file.Text;
        var steps = new List<double>();
        for (var i = 0; i < 20; i++)
        {
            var watch = Stopwatch.StartNew();
            var stepped = CutsceneFile.Parse(source).File!;
            CutsceneEdits.Move(stepped, ["section:7", "section:7/channel:value/key:50"], 2000 * (i + 1));
            // With the search box's text, which every track's name holds, so the filter runs and keeps every row.
            L.Build(stepped, new HashSet<string>(), new CutsceneRowFilter("track", null)).Visible(view, 1400, 0, 2000);
            watch.Stop();
            steps.Add(watch.Elapsed.TotalMilliseconds);
        }
        steps.Sort();
        // A box over every key.
        var box = Stopwatch.StartNew();
        Assert.Equal(5050, layout.InBox(L.Gutter, L.RulerHeight, L.Gutter + 1400, 2000, view, 0).Count);
        box.Stop();
        TestContext.Current.TestOutputHelper?.WriteLine(
            $"50 tracks, 5000 keys: first build {build.Elapsed.TotalMilliseconds:0.00} ms; redraw median {median:0.000} ms, worst {times[^1]:0.000} ms; " +
            $"drag step median {steps[steps.Count / 2]:0.00} ms, worst {steps[^1]:0.00} ms; box of everything {box.Elapsed.TotalMilliseconds:0.00} ms");
        Assert.True(median < 4, $"a redraw's median is {median:0.000} ms");
        Assert.True(steps[steps.Count / 2] < 50, $"a drag step's median is {steps[steps.Count / 2]:0.00} ms");
    }
}

/// <summary>Tests that measure time, which run one at a time and after the others, so that load does not skew them.</summary>
[CollectionDefinition(Name, DisableParallelization = true)]
public sealed class TimingCollection
{
    public const string Name = "Timing";
}
