using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Tests;

/// <summary>The curve editor's edits of a cutscene's text: tangents, slopes, moves and new keys.</summary>
public sealed class CutsceneCurveEditsTests
{
    const string Text = """
        cutscene 1
        rate = 30
        length = 240000
        track 1 property "Glow"
        	binding = 1
        	component = 7
        	field = "intensity"
        	section 1 60000 240000
        		channel value
        			key 0 0 auto
        			key 60000 3 auto # the peak
        			key 120000 4 bezier 2 -1 weights 0.25 0.75 teleport
        			key 180000 1 linear
        """;

    static CutsceneFile Parse() => CutsceneFile.Parse(Text.ReplaceLineEndings("\n")).File!;

    static string Key(CutsceneFile file, int index) => file.Find($"section:1/channel:value/key:{index}")!.LineTexts.Last().Trim();

    [Fact]
    public void EachTangentCommandWritesItsText()
    {
        // The auto key at 60000 has the slope through its neighbours, 4 over 2 seconds: 2 a second, which three times the
        // gentler side, 3 × 1 a second, does not limit.
        var cases = new (TangentMode Mode, string Line)[]
        {
            (TangentMode.Flatten, "key 60000 3 bezier 0 # the peak"),
            (TangentMode.Break, "key 60000 3 bezier 2 2 # the peak"),
            (TangentMode.Unify, "key 60000 3 bezier 2 # the peak"),
            (TangentMode.Linear, "key 60000 3 linear # the peak"),
            (TangentMode.Constant, "key 60000 3 constant # the peak"),
        };
        foreach (var (mode, line) in cases)
        {
            var file = Parse();
            Assert.True(CutsceneCurveEdits.SetTangents(file, ["section:1/channel:value/key:1"], mode));
            Assert.Equal(line, Key(file, 1));
        }
        // A key that is already so changes nothing, and Auto drops a Bezier key's slopes.
        var auto = Parse();
        Assert.False(CutsceneCurveEdits.SetTangents(auto, ["section:1/channel:value/key:1"], TangentMode.Auto));
        Assert.True(CutsceneCurveEdits.SetTangents(auto, ["section:1/channel:value/key:2"], TangentMode.Auto));
        Assert.Equal("key 120000 4 auto teleport", Key(auto, 2));
    }

    [Fact]
    public void ABezierKeyKeepsItsWeightsAndTeleportUntilItsTangentsGo()
    {
        const string Path = "section:1/channel:value/key:2";
        var file = Parse();
        CutsceneCurveEdits.SetTangents(file, [Path], TangentMode.Flatten);
        Assert.Equal("key 120000 4 bezier 0 0 weights 0.25 0.75 teleport", Key(file, 2));
        CutsceneCurveEdits.SetTangents(file, [Path], TangentMode.Unify);
        Assert.Equal("key 120000 4 bezier 0 weights 0.25 0.75 teleport", Key(file, 2));
        file = Parse();
        CutsceneCurveEdits.SetTangents(file, [Path], TangentMode.Unify);
        Assert.Equal("key 120000 4 bezier 0.5 weights 0.25 0.75 teleport", Key(file, 2));
        CutsceneCurveEdits.SetTangents(file, [Path], TangentMode.Linear);
        Assert.Equal("key 120000 4 linear teleport", Key(file, 2));
    }

    [Fact]
    public void AHandleSetsBothSlopesOfAnUnbrokenKeyAndOneOfABrokenKey()
    {
        var file = Parse();
        CutsceneCurveEdits.SetSlope(file, "section:1/channel:value/key:1", TangentSide.Out, 1.5);
        Assert.Equal("key 60000 3 bezier 1.5 # the peak", Key(file, 1));
        CutsceneCurveEdits.SetSlope(file, "section:1/channel:value/key:2", TangentSide.In, 0.25);
        Assert.Equal("key 120000 4 bezier 0.25 -1 weights 0.25 0.75 teleport", Key(file, 2));
        CutsceneCurveEdits.SetSlope(file, "section:1/channel:value/key:2", TangentSide.Out, double.NaN);
        Assert.Equal("key 120000 4 bezier 0.25 -1 weights 0.25 0.75 teleport", Key(file, 2));
    }

    [Fact]
    public void AMoveChangesValuesAndKeepsTimesInTheSection()
    {
        var file = Parse();
        var moved = CutsceneCurveEdits.MoveKeys(file, ["section:1/channel:value/key:3"], 90000, 0.5);
        // The section is 180000 long, so the last key stops at its end.
        Assert.Equal(["section:1/channel:value/key:3"], moved);
        Assert.Equal("key 180000 1.5 linear", Key(file, 3));
        // A key that passes another changes its path.
        moved = CutsceneCurveEdits.MoveKeys(file, ["section:1/channel:value/key:0"], 70000, 0);
        Assert.Equal(["section:1/channel:value/key:1"], moved);
        Assert.Equal("key 70000 0 auto", Key(file, 1));
    }

    [Fact]
    public void ANewKeyTakesTheCurvesValueThere()
    {
        var file = Parse();
        var curve = CutsceneCurveEdits.CurveOf(file.Find("section:1/channel:value")!)!;
        var path = CutsceneCurveEdits.AddKey(file, "section:1/channel:value", 30000);
        Assert.Equal("section:1/channel:value/key:1", path);
        Assert.Equal($"key 30000 {CutsceneKeying.Format(CutsceneCurve.Value(curve, 30000, CurveInfinity.Constant, CurveInfinity.Constant))} auto", Key(file, 1));
        // A key already there stays as it is.
        Assert.Equal("section:1/channel:value/key:2", CutsceneCurveEdits.AddKey(file, "section:1/channel:value", 60000));
        // A stepped field's new key is constant and whole.
        file = Parse();
        CutsceneCurveEdits.AddKey(file, "section:1/channel:value", 150000, stepped: true);
        Assert.Equal("key 150000 4 constant", Key(file, 3));
        // After a linear key, a new key is linear, so the line stays straight: 3 at 60000 to 4 at 120000 is 3.5 at 90000.
        file = Parse();
        CutsceneCurveEdits.SetTangents(file, ["section:1/channel:value/key:1"], TangentMode.Linear);
        CutsceneCurveEdits.AddKey(file, "section:1/channel:value", 90000);
        Assert.Equal("key 90000 3.5 linear", Key(file, 2));
        // A locked track takes no key.
        Assert.Null(CutsceneCurveEdits.AddKey(Parse(), "section:1/channel:value", 30000, locked: new HashSet<int> { 1 }));
    }

    [Fact]
    public void ASplitTakesTheRuntimesValueOfABezierCurveAtTheCut()
    {
        var file = Parse();
        var curve = CutsceneCurveEdits.CurveOf(file.Find("section:1/channel:value")!)!;
        CutsceneEdits.Split(file, ["section:1"], 60000 + 90000);
        Assert.Equal($"key 90000 {CutsceneKeying.Format(CutsceneCurve.Value(curve, 90000, CurveInfinity.Constant, CurveInfinity.Constant))} auto", file.Find("section:1/channel:value/key:2")!.LineTexts.Last().Trim());
        Assert.NotEqual("3.5", CutsceneKeying.Format(CutsceneCurve.Value(curve, 90000, CurveInfinity.Constant, CurveInfinity.Constant)));
    }

    [Fact]
    public void AnInfinityIsAChannelSettingBeforeItsKeysAndConstantHasNone()
    {
        var file = Parse();
        Assert.Equal((CurveInfinity.Constant, CurveInfinity.Constant), CutsceneCurveEdits.InfinityOf(file.Find("section:1/channel:value")!));
        Assert.True(CutsceneCurveEdits.SetInfinity(file, ["section:1/channel:value"], InfinitySide.Post, CurveInfinity.CycleOffset));
        Assert.True(CutsceneCurveEdits.SetInfinity(file, ["section:1/channel:value"], InfinitySide.Pre, CurveInfinity.Oscillate));
        var set = Text.ReplaceLineEndings("\n").Replace("\t\tchannel value\n", "\t\tchannel value\n\t\t\tpost_infinity = cycle_offset\n\t\t\tpre_infinity = oscillate\n");
        Assert.Equal(set, file.Text);
        Assert.Equal((CurveInfinity.Oscillate, CurveInfinity.CycleOffset), CutsceneCurveEdits.InfinityOf(file.Find("section:1/channel:value")!));
        // The same mode again changes nothing, and constant takes the setting away.
        Assert.False(CutsceneCurveEdits.SetInfinity(file, ["section:1/channel:value"], InfinitySide.Pre, CurveInfinity.Oscillate));
        Assert.True(CutsceneCurveEdits.SetInfinity(file, ["section:1/channel:value"], InfinitySide.Pre, CurveInfinity.Constant));
        Assert.True(CutsceneCurveEdits.SetInfinity(file, ["section:1/channel:value"], InfinitySide.Post, CurveInfinity.Constant));
        Assert.Equal(Text.ReplaceLineEndings("\n"), file.Text);
        // A locked track keeps its own.
        Assert.False(CutsceneCurveEdits.SetInfinity(file, ["section:1/channel:value"], InfinitySide.Post, CurveInfinity.Cycle, new HashSet<int> { 1 }));
    }

    [Fact]
    public void APitchAndAChannelOfAssetsTakeOnlyTheModesThatTheCookerTakes()
    {
        var file = CutsceneFile.Parse("""
            cutscene 1
            length = 60000
            track 1 audio "Music"
            	section 1 0 60000
            		asset = $0123456789abcdef0123456789abcdef
            		channel pitch
            			key 0 1 linear
            		channel gain
            			key 0 1 linear
            track 2 property "Swap"
            	binding = 1
            	component = 7
            	field = "material"
            	section 2 0 60000
            		channel value
            			key 0 $0123456789abcdef0123456789abcdef constant
            """.ReplaceLineEndings("\n")).File!;
        var pitch = file.Find("section:1/channel:pitch")!;
        var assets = file.Find("section:2/channel:value")!;
        Assert.False(CutsceneCurveEdits.TakesInfinity(pitch, CurveInfinity.Cycle));
        Assert.True(CutsceneCurveEdits.TakesInfinity(pitch, CurveInfinity.Constant));
        Assert.True(CutsceneCurveEdits.TakesInfinity(file.Find("section:1/channel:gain")!, CurveInfinity.Linear));
        Assert.False(CutsceneCurveEdits.TakesInfinity(assets, CurveInfinity.Linear));
        Assert.False(CutsceneCurveEdits.TakesInfinity(assets, CurveInfinity.CycleOffset));
        Assert.True(CutsceneCurveEdits.TakesInfinity(assets, CurveInfinity.Oscillate));
        // Set on all three, the gain takes linear, and the others keep constant.
        Assert.True(CutsceneCurveEdits.SetInfinity(file, ["section:1/channel:pitch", "section:1/channel:gain", "section:2/channel:value"], InfinitySide.Post, CurveInfinity.Linear));
        Assert.Null(pitch.Get("post_infinity"));
        Assert.Null(assets.Get("post_infinity"));
        Assert.Equal("linear", file.Find("section:1/channel:gain")!.Get("post_infinity"));
    }

    [Fact]
    public void WeightingAKeyGivesItItsSlopesAndAThirdOnEachSideAndKeepsTheCurve()
    {
        var file = Parse();
        var before = CutsceneCurveEdits.CurveOf(file.Find("section:1/channel:value")!)!;
        Assert.True(CutsceneCurveEdits.SetWeighted(file, ["section:1/channel:value/key:1", "section:1/channel:value/key:3"], true));
        // The auto key takes its computed slope, 2 a second; the linear key has no handles and stays.
        Assert.Equal("key 60000 3 bezier 2 weights 0.33333334 0.33333334 # the peak", Key(file, 1));
        Assert.Equal("key 180000 1 linear", Key(file, 3));
        var after = CutsceneCurveEdits.CurveOf(file.Find("section:1/channel:value")!)!;
        for (var t = 0; t <= 180000; t += 1000)
        {
            Assert.Equal(CutsceneCurve.Value(before, t, CurveInfinity.Constant, CurveInfinity.Constant),
                CutsceneCurve.Value(after, t, CurveInfinity.Constant, CurveInfinity.Constant), 4);
        }
        // Without weights, a key keeps its slopes and its teleport.
        Assert.True(CutsceneCurveEdits.SetWeighted(file, ["section:1/channel:value/key:2"], false));
        Assert.Equal("key 120000 4 bezier 2 -1 teleport", Key(file, 2));
        Assert.False(CutsceneCurveEdits.SetWeighted(file, ["section:1/channel:value/key:2"], false));
    }

    [Fact]
    public void AHandlesWeightIsItsSidesOnlyAndAKeyWithoutWeightsIgnoresIt()
    {
        var file = Parse();
        CutsceneCurveEdits.SetSlope(file, "section:1/channel:value/key:2", TangentSide.Out, -1.5, weight: 0.5);
        Assert.Equal("key 120000 4 bezier 2 -1.5 weights 0.25 0.5 teleport", Key(file, 2));
        CutsceneCurveEdits.SetSlope(file, "section:1/channel:value/key:2", TangentSide.In, 1, weight: 7);
        Assert.Equal("key 120000 4 bezier 1 -1.5 weights 1 0.5 teleport", Key(file, 2));
        CutsceneCurveEdits.SetSlope(file, "section:1/channel:value/key:0", TangentSide.Out, 1, weight: 0.5);
        Assert.Equal("key 0 0 bezier 1", Key(file, 0));
    }
}
