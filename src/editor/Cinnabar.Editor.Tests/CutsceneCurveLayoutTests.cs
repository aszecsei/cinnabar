using Cinnabar.Editor.Document;
using Cinnabar.Editor.Tools;
using L = Cinnabar.Editor.Tools.CutsceneTimelineLayout;

namespace Cinnabar.Editor.Tests;

/// <summary>The curve editor's geometry: its value axis, hit tests, normalized view, framing and colours.</summary>
public sealed class CutsceneCurveLayoutTests
{
    const string Text = """
        cutscene 1
        rate = 30
        length = 240000
        track 1 transform "Walk"
        	binding = 1
        	section 1 0 240000
        		channel position_x
        			key 0 0 auto
        			key 60000 2 auto
        			key 120000 0 linear
        		channel position_y
        			key 0 10 auto
        			key 120000 10 auto
        		channel speed
        			key 0 -4 bezier 0
        			key 120000 4 constant
        """;

    static CutsceneFile Parse() => CutsceneFile.Parse(Text.ReplaceLineEndings("\n")).File!;

    const string X = "section:1/channel:position_x";
    const string Y = "section:1/channel:position_y";
    const string Speed = "section:1/channel:speed";

    // A thousand ticks a pixel from 0, and a hundredth of a value a pixel with 5 at the top: value v is at 500 - 100 v.
    static readonly CurveView View = new(new TimelineView(0, 1000, TimelineZoom.Ticks), new ValueAxis(5, 0.01), false);

    static CutsceneCurveLayout Build(params string[] paths) => CutsceneCurveLayout.Build(Parse(), paths);

    [Fact]
    public void TheValueAxisMapsBothWaysAndZoomsAboutThePointer()
    {
        var axis = new ValueAxis(5, 0.01);
        Assert.Equal(500, axis.Y(0), 9);
        Assert.Equal(2, axis.At(300), 9);
        var zoomed = axis.ZoomAbout(300, 2);
        Assert.Equal(2, zoomed.At(300), 9);
        Assert.Equal(0.02, zoomed.PerPixel, 9);
        // A drag down shows higher values.
        Assert.Equal(6, axis.Pan(100).Top, 9);
        // A fit has a tenth of the span as a margin on each side, and an empty span shows 1 around it.
        var fit = ValueAxis.Fit(0, 10, 120);
        Assert.Equal(11, fit.Top, 9);
        Assert.Equal(-1, fit.At(120), 9);
        Assert.Equal(3.6, ValueAxis.Fit(3, 3, 100).Top, 9);
    }

    [Fact]
    public void ARowHoldsItsChannelsKeysAndColour()
    {
        var layout = Build(X, Y, Speed, "section:1/channel:missing");
        Assert.Equal([X, Y, Speed], layout.Rows.Select(r => r.Path));
        Assert.Equal(["Walk · position_x", "Walk · position_y", "Walk · speed"], layout.Rows.Select(r => r.Name));
        Assert.Equal([0xFFE5534Bu, 0xFF6CC644u, CutsceneCurveLayout.ColorOf("speed", 0)], layout.Rows.Select(r => r.Color));
        Assert.Equal(0xFF5B8DEFu, CutsceneCurveLayout.ColorOf("b", 3));
        Assert.Equal(0xFFA2A2A8u, CutsceneCurveLayout.ColorOf("rotation_w", 3));
        Assert.NotEqual(CutsceneCurveLayout.ColorOf("gain", 0), CutsceneCurveLayout.ColorOf("pitch", 1));
        // A hidden curve, and an asset's keys, have no row.
        Assert.Equal([Y], CutsceneCurveLayout.Build(Parse(), [X, Y], new HashSet<string> { X }).Rows.Select(r => r.Path));
        var file = Parse();
        file.Find($"{Speed}/key:1")!.SetKeyValue("$0d9b84a2116a5529c2cd33741edd33a4");
        Assert.Empty(CutsceneCurveLayout.Build(file, [Speed]).Rows);
    }

    [Fact]
    public void NormalizedEachCurveRunsFromMinusOneToOne()
    {
        var layout = Build(X, Y, Speed);
        var (x, y, speed) = (layout.Rows[0], layout.Rows[1], layout.Rows[2]);
        // position_x peaks at its key of 2, as an auto key at a peak is flat.
        Assert.Equal((0.0, 2.0), (x.Min, x.Max));
        Assert.Equal(1, x.Shown(2, normalized: true), 9);
        Assert.Equal(-1, x.Shown(0, normalized: true), 9);
        Assert.Equal(2, x.Shown(2, normalized: false), 9);
        Assert.Equal(1, x.Scale(normalized: true), 9);
        // A flat curve is 0, and its scale is 1.
        Assert.Equal(0, y.Shown(10, normalized: true), 9);
        Assert.Equal(1, y.Scale(normalized: true), 9);
        Assert.Equal(-1, speed.Shown(-4, normalized: true), 9);
        Assert.Equal(4, speed.Scale(normalized: true), 9);
    }

    [Fact]
    public void FFramesTheSelectedKeysOrEveryCurve()
    {
        var layout = Build(X, Y);
        Assert.Equal((0, 120000, 0.0, 10.0), layout.FrameSpan(new HashSet<string>(), normalized: false));
        Assert.Equal((60000, 120000, 0.0, 2.0), layout.FrameSpan(new HashSet<string> { $"{X}/key:1", $"{X}/key:2" }, normalized: false));
        Assert.Equal((0, 120000, -1.0, 1.0), layout.FrameSpan(new HashSet<string>(), normalized: true));
        Assert.Null(Build().FrameSpan(new HashSet<string>(), normalized: false));
    }

    [Fact]
    public void AHandleComesBeforeAKeyAndAKeyBeforeACurve()
    {
        var layout = Build(X);
        var row = layout.Rows[0];
        // The key at 60000 is at (Gutter + 60, 300).
        var key = CutsceneCurveLayout.KeyPoint(row, 1, View);
        Assert.Equal((L.Gutter + 60.0, 300.0), key);
        var none = new HashSet<string>();
        Assert.Equal(CurveHitKind.Key, layout.HitTest(key.X + 5, key.Y - 5, View, none).Kind);
        Assert.Equal($"{X}/key:1", layout.HitTest(key.X, key.Y, View, none).Path);
        // A flat auto key's handles are 40 pixels to each side, and only a selected key has them.
        var selected = new HashSet<string> { $"{X}/key:1" };
        Assert.Equal((key.X + 40, key.Y), CutsceneCurveLayout.HandlePoint(row, 1, TangentSide.Out, View));
        var handle = layout.HitTest(key.X + 40, key.Y, View, selected);
        Assert.Equal((CurveHitKind.Handle, TangentSide.Out), (handle.Kind, handle.Side));
        Assert.Equal(TangentSide.In, layout.HitTest(key.X - 40, key.Y, View, selected).Side);
        // On the curve, a press finds the curve and its tick; away from it, nothing; over the list, nothing.
        var curve = layout.HitTest(L.Gutter + 30, 500 - 100 * row.ValueAt(30000), View, none);
        Assert.Equal((CurveHitKind.Curve, 30000), (curve.Kind, curve.Tick));
        Assert.Equal(CurveHitKind.None, layout.HitTest(L.Gutter + 30, 20, View, none).Kind);
        Assert.Equal(CurveHitKind.None, layout.HitTest(L.Gutter - 1, 300, View, none).Kind);
        // A linear key has no handles, and an end key none past its end.
        Assert.False(row.HasHandle(2, TangentSide.In));
        Assert.False(row.HasHandle(0, TangentSide.In));
        Assert.True(row.HasHandle(0, TangentSide.Out));
    }

    [Fact]
    public void AHandlesPointReadsBackAsItsSlope()
    {
        var row = Build(Speed).Rows[0];
        foreach (var normalized in new[] { false, true })
        {
            var view = View with { Normalized = normalized };
            var (hx, hy) = CutsceneCurveLayout.HandlePoint(row, 0, TangentSide.Out, view);
            Assert.Equal(0, CutsceneCurveLayout.SlopeAt(row, 0, TangentSide.Out, view, hx, hy), 9);
            // 60 pixels right is a second; 100 pixels up is a value of 1, or normalized, of 4.
            var (kx, ky) = CutsceneCurveLayout.KeyPoint(row, 0, view);
            Assert.Equal(normalized ? 4 : 1, CutsceneCurveLayout.SlopeAt(row, 0, TangentSide.Out, view, kx + 60, ky - 100), 9);
        }
        // A point on the wrong side of the key reads as one a pixel on the right side.
        Assert.True(double.IsFinite(CutsceneCurveLayout.SlopeAt(row, 0, TangentSide.Out, View, L.Gutter - 30, 0)));
    }

    [Fact]
    public void ABoxHoldsTheKeysInsideIt()
    {
        var layout = Build(X, Y);
        Assert.Equal([$"{X}/key:0", $"{X}/key:1"], layout.InBox(L.Gutter - 5, 250, L.Gutter + 70, 510, View));
        // position_y's keys are at 10, above the top edge.
        Assert.Equal([$"{Y}/key:0", $"{Y}/key:1"], layout.InBox(L.Gutter + 130, -490, L.Gutter - 10, -510, View));
    }

    [Fact]
    public void ACurveIsSampledAtWholeTicksAcrossItsSectionInView()
    {
        var row = Build(X).Rows[0];
        var samples = CutsceneCurveLayout.Samples(row, View, 100).ToList();
        // From 0 to 100000, one a pixel, and the end of the view.
        Assert.Equal(101, samples.Count);
        Assert.Equal(L.Gutter, samples[0].X, 9);
        Assert.Equal(500 - 100 * CutsceneCurve.Value(row.Keys, 37000, CurveInfinity.Constant, CurveInfinity.Constant), samples[37].Y, 4);
        // Past the section's end, nothing.
        Assert.Empty(CutsceneCurveLayout.Samples(row, View with { Time = new TimelineView(300000, 1000, TimelineZoom.Ticks) }, 100));
    }

    [Fact]
    public void ACurvesInfinityShowsToItsSectionsEdgeAndCountsInItsSpanAndFraming()
    {
        // speed goes from -4 to 4 over 2 seconds with flat ends, and then repeats, each repeat 8 higher: 8 at 180000,
        // halfway through the first repeat, and 12 at the section's end, 240000.
        var file = Parse();
        Assert.True(CutsceneCurveEdits.SetInfinity(file, [Speed], InfinitySide.Post, CurveInfinity.CycleOffset));
        var row = CutsceneCurveLayout.Build(file, [Speed]).Rows[0];
        Assert.Equal(CurveInfinity.CycleOffset, row.Post);
        Assert.Equal(8, row.ValueAt(180000), 6);
        Assert.Equal(12, row.ValueAt(240000), 6);
        Assert.Equal(12, row.ValueAt(300000), 6);
        Assert.Equal(-4, row.Min, 6);
        Assert.Equal(12, row.Max, 6);
        // F frames the repeats too, to the section's end.
        Assert.Equal((0, 240000, -4.0, 12.0), CutsceneCurveLayout.Build(file, [Speed]).FrameSpan(new HashSet<string>(), false));
        // The part after the last key samples from it to the section's end.
        var after = CutsceneCurveLayout.Samples(row, View, 300, (120000, 240000)).ToList();
        Assert.Equal(L.Gutter + 120, after[0].X, 9);
        Assert.Equal(L.Gutter + 240, after[^1].X, 9);
        Assert.Equal(500 - 100 * 8, after[60].Y, 4);
        // A double-click on the repeat adds a key with its value there, constant after the constant key.
        var hit = CutsceneCurveLayout.Build(file, [Speed]).HitTest(L.Gutter + 180, 500 - 800, View, new HashSet<string>());
        Assert.Equal(CurveHitKind.Curve, hit.Kind);
        Assert.Equal(180000, hit.Tick);
        Assert.NotNull(CutsceneCurveEdits.AddKey(file, Speed, 180000));
        Assert.Equal("key 180000 8 constant", file.Find($"{Speed}/key:2")!.LineTexts.Last().Trim());
    }

    [Fact]
    public void AWeightedHandleIsItsControlPointAndReadsBackAsItsSlopeAndWeight()
    {
        var file = CutsceneFile.Parse("""
            cutscene 1
            length = 120000
            track 1 transform "Walk"
            	binding = 1
            	section 1 0 120000
            		channel position_x
            			key 0 0 bezier 1 weights 0.5 0.5
            			key 60000 1 bezier 1 0 weights 0.01 0.25
            			key 120000 0 linear
            """.ReplaceLineEndings("\n")).File!;
        var row = CutsceneCurveLayout.Build(file, [X]).Rows[0];
        // Half of the minute's first second across, 30 pixels, and the slope of 1 a second over that half second, 50 up.
        var (hx, hy) = CutsceneCurveLayout.HandlePoint(row, 0, TangentSide.Out, View);
        Assert.Equal(L.Gutter + 30, hx, 9);
        Assert.Equal(450, hy, 9);
        Assert.Equal(1, CutsceneCurveLayout.SlopeAt(row, 0, TangentSide.Out, View, hx, hy), 9);
        Assert.Equal(0.5, CutsceneCurveLayout.WeightAt(row, 0, TangentSide.Out, View, hx)!.Value, 9);
        // The second key's out handle is flat, a quarter of its segment across: 15 pixels.
        var (ox, oy) = CutsceneCurveLayout.HandlePoint(row, 1, TangentSide.Out, View);
        Assert.Equal(L.Gutter + 75, ox, 9);
        Assert.Equal(400, oy, 9);
        // Its in handle's weight, 0.01, is under a pixel: it shows at the shortest length, along its slope.
        var (ix, iy) = CutsceneCurveLayout.HandlePoint(row, 1, TangentSide.In, View);
        var (kx, ky) = CutsceneCurveLayout.KeyPoint(row, 1, View);
        Assert.Equal(CutsceneCurveLayout.MinHandleLength, Math.Sqrt((ix - kx) * (ix - kx) + (iy - ky) * (iy - ky)), 9);
        Assert.True(ix < kx && iy > ky);
        // A key without weights reads no weight, and its handle stays the fixed length.
        Assert.Null(CutsceneCurveLayout.WeightAt(row, 2, TangentSide.In, View, L.Gutter));
        Assert.Equal(1, CutsceneCurveLayout.WeightAt(row, 1, TangentSide.Out, View, L.Gutter + 500)!.Value, 9);
    }
}
