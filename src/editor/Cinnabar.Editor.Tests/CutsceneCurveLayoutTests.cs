using Cinnabar.Editor.Document;
using Cinnabar.Editor.Tools;
using L = Cinnabar.Editor.Tools.CutsceneTimelineLayout;

namespace Cinnabar.Editor.Tests;

/// <summary>The curve editor's geometry: hit tests, handles and their slopes and weights, and infinities.</summary>
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
    const string Speed = "section:1/channel:speed";

    // A thousand ticks a pixel from 0, and a hundredth of a value a pixel with 5 at the top: value v is at 500 - 100 v.
    static readonly CurveView View = new(new TimelineView(0, 1000, TimelineZoom.Ticks), new ValueAxis(5, 0.01), false);

    static CutsceneCurveLayout Build(params string[] paths) => CutsceneCurveLayout.Build(Parse(), paths);

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
    public void ACurvesInfinityRunsToItsSectionsEdgeAndANewKeyThereTakesItsValue()
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
