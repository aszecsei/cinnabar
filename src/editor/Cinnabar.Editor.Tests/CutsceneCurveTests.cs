using System.Globalization;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Tests;

/// <summary>The editor's curve evaluator, which gives the runtime's bits, and the key line's reader and writer.</summary>
public sealed class CutsceneCurveTests
{
    // The shared test curve that lib/core/math/key_test.odin writes and checks.
    static string[] Golden() =>
        File.ReadAllLines(Path.Combine(EditorOptions.RepositoryRoot(), "lib", "core", "math", "testdata", "curve.txt"));

    // A golden key line: time, value, interpolation, flags, in slope, in weight, out slope, out weight.
    static CurveKey GoldenKey(string[] w)
    {
        float F(string s) => float.Parse(s, CultureInfo.InvariantCulture);
        var flags = w[4] == "-" ? [] : w[4].Split(',');
        var interp = w[3] switch
        {
            "constant" => CurveInterp.Constant,
            "linear" => CurveInterp.Linear,
            "bezier" => CurveInterp.Bezier,
            _ => CurveInterp.Auto,
        };
        return new CurveKey(int.Parse(w[1], CultureInfo.InvariantCulture), F(w[2]), interp,
            Broken: flags.Contains("broken"), Weighted: flags.Contains("weighted"),
            InSlope: F(w[5]), InWeight: F(w[6]), OutSlope: F(w[7]), OutWeight: F(w[8]));
    }

    static CurveInfinity Mode(string name) => (CurveInfinity)Array.IndexOf(CutsceneCurveEdits.InfinityNames, name);

    [Fact]
    public void TheCurveGivesTheRuntimesBitsAtEveryTick()
    {
        var keys = new List<CurveKey>();
        var count = 0;
        // Each infinity block's modes and keys, and how many ticks it has.
        var blocks = new List<(CurveInfinity Pre, CurveInfinity Post, int Count)>();
        IReadOnlyList<CurveKey> curve = keys;
        var (pre, post) = (CurveInfinity.Constant, CurveInfinity.Constant);
        foreach (var line in Golden())
        {
            var w = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (w.Length == 0 || w[0].StartsWith('#'))
            {
                continue;
            }
            if (w[0] == "key")
            {
                keys.Add(GoldenKey(w));
                continue;
            }
            if (w[0] == "infinity")
            {
                // infinity <pre> <post> <from> <to>: the at lines after it are of those keys, with those modes.
                (pre, post) = (Mode(w[1]), Mode(w[2]));
                curve = keys[int.Parse(w[3], CultureInfo.InvariantCulture)..int.Parse(w[4], CultureInfo.InvariantCulture)];
                blocks.Add((pre, post, 0));
                continue;
            }
            Assert.Equal("at", w[0]);
            var tick = int.Parse(w[1], CultureInfo.InvariantCulture);
            var want = uint.Parse(w[2], NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            var got = BitConverter.SingleToUInt32Bits(CutsceneCurve.Value(curve, tick, pre, post));
            Assert.True(got == want, $"at {tick} ({pre}, {post}): {got:x8}, not {want:x8}");
            if (blocks.Count == 0)
            {
                count++;
            }
            else
            {
                blocks[^1] = blocks[^1] with { Count = blocks[^1].Count + 1 };
            }
        }
        // Each mode but constant is on each side, and every block has its ticks.
        foreach (var mode in Enum.GetValues<CurveInfinity>().Where(m => m != CurveInfinity.Constant))
        {
            Assert.Contains(blocks, b => b.Pre == mode);
            Assert.Contains(blocks, b => b.Post == mode);
        }
        Assert.All(blocks, b => Assert.Equal((180000 + 60000) / 250 + 1 + 12, b.Count));
        // Every interpolation and both tangent options are in the curve.
        Assert.Equal(10, keys.Count);
        Assert.Contains(keys, k => k.Interp == CurveInterp.Constant);
        Assert.Contains(keys, k => k.Interp == CurveInterp.Linear);
        Assert.Contains(keys, k => k is { Interp: CurveInterp.Bezier, Broken: true });
        Assert.Contains(keys, k => k is { Interp: CurveInterp.Bezier, Weighted: true });
        Assert.Equal(120000 / 250 + 3, count);
    }

    [Fact]
    public void AKeyLineReadsAsTheCookerReadsIt()
    {
        Assert.Equal(new CurveKey(0, 0, CurveInterp.Auto), CurveKey.Parse(0, "0", "auto"));
        Assert.Equal(new CurveKey(30000, 2, CurveInterp.Bezier, InSlope: 0.5f, OutSlope: 0.5f), CurveKey.Parse(30000, "2", "bezier 0.5"));
        Assert.Equal(
            new CurveKey(45000, 1, CurveInterp.Bezier, Broken: true, Weighted: true, InSlope: 2, OutSlope: -1, InWeight: 0.25f, OutWeight: 0.75f),
            CurveKey.Parse(45000, "1", "bezier 2 -1 weights 0.25 0.75"));
        Assert.Equal(new CurveKey(50000, 3, CurveInterp.Linear, Teleport: true), CurveKey.Parse(50000, "3", "linear teleport"));
        // A value is read as an f64 and then made an f32, as the cooker does.
        Assert.Equal((float)0.1, CurveKey.Parse(0, "0.1", "auto")!.Value.Value);
        // What the cooker refuses, and an asset's key, give no key.
        Assert.Null(CurveKey.Parse(0, "$0d9b84a2116a5529c2cd33741edd33a4", "constant"));
        Assert.Null(CurveKey.Parse(0, "1", "linear 2"));
        Assert.Null(CurveKey.Parse(0, "1", "bezier"));
        Assert.Null(CurveKey.Parse(0, "1", "bezier 1 2 3"));
        Assert.Null(CurveKey.Parse(0, "1", "bezier 1 weights 2 0"));
        Assert.Null(CurveKey.Parse(0, "1", "spline"));
        Assert.Null(CurveKey.Parse(0, "1e39", "auto"));
    }

    [Theory]
    [InlineData("auto")]
    [InlineData("constant teleport")]
    [InlineData("bezier 0.5")]
    [InlineData("bezier 2 -1")]
    [InlineData("bezier 2 -1 weights 0.25 0.75")]
    [InlineData("bezier 0 weights 0.5 0.5 teleport")]
    public void AKeyWritesBackAsItReads(string interpolation) =>
        Assert.Equal(interpolation, CurveKey.Parse(0, "1", interpolation)!.Value.Interpolation());
}
