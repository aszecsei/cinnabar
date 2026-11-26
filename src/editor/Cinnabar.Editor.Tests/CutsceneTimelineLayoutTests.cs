using Cinnabar.Editor.Document;
using Cinnabar.Editor.Tools;
using L = Cinnabar.Editor.Tools.CutsceneTimelineLayout;

namespace Cinnabar.Editor.Tests;

/// <summary>The timeline's pure part: ticks and pixels, rows, hit tests, glyphs, snapping and clips' hints.</summary>
public sealed class CutsceneTimelineLayoutTests
{
    static CutsceneFile Intro() => CutsceneFile.Parse(CutsceneFileTests.Sample("intro").ReplaceLineEndings("\n")).File!;

    // A tick a pixel per thousand, from 0: tick t is at x = Gutter + t / 1000.
    static readonly TimelineView Thousand = new(0, 1000, TimelineZoom.Ticks);

    static double X(int tick) => L.Gutter + tick / 1000.0;

    static double Y(L layout, string path, CutsceneRowKind kind = CutsceneRowKind.Track) =>
        L.RulerHeight + layout.Rows.First(r => r.Path == path && r.Kind == kind).Top + L.RowHeight / 2;

    [Fact]
    public void ABindingsFilterHidesTheOtherBindingsAndTheTracksOfNone()
    {
        var file = Intro();
        var bindings = file.Bindings.Select(b => b.Id).OfType<int>().ToList();

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
        Assert.Equal(TimelineZoom.Ticks.Min, TimelineView.Fit(0, 100, 1000, TimelineZoom.Ticks).PerPixel);
        Assert.Equal(TimelineZoom.Ticks.Max, fit.ZoomAbout(0, 1e9).PerPixel);
        // A zoom keeps the time under the pointer.
        var zoomed = fit.ZoomAbout(400, 0.25);
        Assert.Equal(fit.At(400), zoomed.At(400), 6);
        Assert.Equal(fit.PerPixel / 4, zoomed.PerPixel, 6);

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
            "Running Fox", "Fox runs", "Stone", "Stone rolls",
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
    public void APointIsOnAnEdgeABodyAKeyOrNothing()
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
    }

    [Fact]
    public void KeysCloseTogetherAreOneGlyphAndOnlyWhatIsInViewDraws()
    {
        var layout = L.Build(Intro(), new HashSet<string>());
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
        Assert.Equal([0, 30000, 174000, 200000, 300000, 360000, 400000, 420000, 480000, 600000, 720000], layout.Edges());
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
    public void AnEaseHandleIsInTheTopOfItsBarBeforeAKey()
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
    }
}
