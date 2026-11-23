using System.Globalization;

namespace Cinnabar.Editor.Document;

/// <summary>
/// What a channel's curve does before its first key or after its last: <c>Cutscene_Infinity</c>, and a channel's
/// <c>pre_infinity</c> and <c>post_infinity</c> (see docs/cinematics/tracks.md#curves).
/// </summary>
public enum CurveInfinity { Constant, Linear, Cycle, CycleOffset, Oscillate }

/// <summary>A key's interpolation: how its value goes to the next key's (see docs/cinematics/tracks.md#curves).</summary>
public enum CurveInterp
{
    Constant,
    Linear,
    Bezier,
    Auto,
}

/// <summary>
/// A key of a curve as the runtime holds it (<c>Cutscene_Key</c> in lib/engine/asset/format/cutscene.odin): a time in
/// ticks from its section's start, an f32 value, and, for a Bezier key only, slopes in value per second, which are one
/// unless the key is broken, and weights from 0 to 1 when it is weighted. Teleport changes no value.
/// </summary>
public readonly record struct CurveKey(
    int Time,
    float Value,
    CurveInterp Interp,
    bool Broken = false,
    bool Weighted = false,
    bool Teleport = false,
    float InSlope = 0,
    float InWeight = 0,
    float OutSlope = 0,
    float OutWeight = 0)
{
    /// <summary>
    /// A key line's words after <c>key</c>, read as the cooker reads them (tools/cook/cutscenes.odin,
    /// <c>cutscene_key</c>): each number as an f64 that must be finite and fit an f32, then made an f32. Null for a
    /// line that the cooker refuses or for an asset's key, <c>$&lt;guid&gt;</c>, which has no curve.
    /// </summary>
    public static CurveKey? Parse(CutsceneBlock key)
    {
        if (key.Kind != CutsceneBlockKind.Key || key.Start is not { } time || key.KeyValue is not { } valueText || key.KeyInterpolation is not { } rest)
        {
            return null;
        }
        return Parse(time, valueText, rest);
    }

    /// <summary>A key from its time, its value's text and the text after it, such as <c>bezier 2 -1 weights 0.25 0.75</c>.</summary>
    public static CurveKey? Parse(int time, string valueText, string interpolation)
    {
        var words = interpolation.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).ToList();
        var teleport = words.Count > 1 && words[^1] == "teleport";
        if (teleport)
        {
            words.RemoveAt(words.Count - 1);
        }
        if (words.Count == 0 || valueText.StartsWith('$') || Finite(valueText) is not { } value)
        {
            return null;
        }
        CurveInterp? interp = words[0] switch
        {
            "constant" => CurveInterp.Constant,
            "linear" => CurveInterp.Linear,
            "bezier" => CurveInterp.Bezier,
            "auto" => CurveInterp.Auto,
            _ => null,
        };
        if (interp is not { } kind)
        {
            return null;
        }
        var tail = words.Skip(1).ToList();
        if (kind != CurveInterp.Bezier)
        {
            return tail.Count == 0 ? new CurveKey(time, value, kind, Teleport: teleport) : null;
        }
        var weightsAt = tail.IndexOf("weights");
        var slopes = weightsAt < 0 ? tail : tail[..weightsAt];
        var weights = weightsAt < 0 ? null : tail[(weightsAt + 1)..];
        if (weights is { Count: not 2 })
        {
            return null;
        }
        var key = new CurveKey(time, value, kind, Teleport: teleport);
        switch (slopes.Count)
        {
            case 1 when Finite(slopes[0]) is { } s:
                key = key with { InSlope = s, OutSlope = s };
                break;
            case 2 when Finite(slopes[0]) is { } i && Finite(slopes[1]) is { } o:
                key = key with { InSlope = i, OutSlope = o, Broken = true };
                break;
            default:
                return null;
        }
        if (weights != null)
        {
            if (Finite(weights[0]) is not { } wi || Finite(weights[1]) is not { } wo || !(wi >= 0 && wi <= 1) || !(wo >= 0 && wo <= 1))
            {
                return null;
            }
            key = key with { Weighted = true, InWeight = wi, OutWeight = wo };
        }
        return key;
    }

    // A number as the cooker's finite reads it: an f64 no larger than the largest f32, then an f32.
    static float? Finite(string text) =>
        double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) && Math.Abs(v) <= float.MaxValue ? (float)v : null;

    /// <summary>
    /// The key line's text after its value, as <see cref="CutsceneBlock.SetKeyInterpolation"/> takes it: the
    /// interpolation, a Bezier key's one slope or its in and out slopes when broken, its weights when weighted, and
    /// <c>teleport</c>. Numbers are as <see cref="CutsceneKeying.Format"/> writes them.
    /// </summary>
    public string Interpolation()
    {
        var words = new List<string>
        {
            Interp switch
            {
                CurveInterp.Constant => "constant",
                CurveInterp.Linear => "linear",
                CurveInterp.Bezier => "bezier",
                _ => "auto",
            },
        };
        if (Interp == CurveInterp.Bezier)
        {
            words.Add(CutsceneKeying.Format(InSlope));
            if (Broken)
            {
                words.Add(CutsceneKeying.Format(OutSlope));
            }
            if (Weighted)
            {
                words.AddRange(["weights", CutsceneKeying.Format(InWeight), CutsceneKeying.Format(OutWeight)]);
            }
        }
        if (Teleport)
        {
            words.Add("teleport");
        }
        return string.Join(' ', words);
    }
}

/// <summary>
/// The runtime's curve evaluator in the editor (see docs/cinematics/tracks.md#curves): a line-for-line copy of
/// lib/engine/cutscene/curve.odin, with its f64 arithmetic in the same order and no fused multiply-adds, so that it
/// gives the same f32 bits at every tick. The shared test curve, lib/engine/cutscene/testdata/curve.txt, checks both.
/// </summary>
public static class CutsceneCurve
{
    /// <summary>The ticks in a second, <c>CUTSCENE_TICKS_PER_SECOND</c>.</summary>
    public const double TicksPerSecond = CutsceneFile.TicksPerSecond;

    /// <summary>The weight of a handle that is not weighted, <c>CUTSCENE_TANGENT_WEIGHT</c>.</summary>
    public const double TangentWeight = 1.0 / 3.0;

    /// <summary>How many halvings find a weighted segment's parameter, <c>CURVE_SOLVE_STEPS</c>.</summary>
    public const int SolveSteps = 48;

    /// <summary>
    /// The curve's value at a tick on its own time: <c>curve_value</c>. Before the first key, <paramref name="pre"/>
    /// decides, and after the last, <paramref name="post"/> does (see <see cref="Wrap"/>). Between keys, the first key's
    /// interpolation decides. An empty curve is 0.
    /// </summary>
    public static float Value(IReadOnlyList<CurveKey> keys, int t, CurveInfinity pre, CurveInfinity post)
    {
        var n = keys.Count;
        if (n == 0)
        {
            return 0;
        }
        if (t >= keys[0].Time && t <= keys[n - 1].Time)
        {
            return Inside(keys, t);
        }
        var before = t < keys[0].Time;
        if ((before ? pre : post) == CurveInfinity.Linear && n > 1)
        {
            return (float)Extend(keys, t, before);
        }
        var (local, cycles) = Wrap(keys, t, pre, post);
        return Offset(keys, Inside(keys, local), cycles);
    }

    /// <summary>
    /// The curve's value at a tick as if each key were constant: <c>curve_step</c>, for fields that step. Its infinity
    /// is as <see cref="Value"/>'s, except that linear holds.
    /// </summary>
    public static float Step(IReadOnlyList<CurveKey> keys, int t, CurveInfinity pre, CurveInfinity post)
    {
        var n = keys.Count;
        if (n == 0)
        {
            return 0;
        }
        if (t >= keys[0].Time && t <= keys[n - 1].Time)
        {
            return StepInside(keys, t);
        }
        var (local, cycles) = Wrap(keys, t, pre, post);
        return Offset(keys, StepInside(keys, local), cycles);
    }

    /// <summary>
    /// <c>curve_wrap</c>: the tick inside a non-empty curve's keys that gives a tick's value outside them, by the mode of
    /// its side, and how many spans a cycle with offset moves the value by. Constant and linear hold the end key's tick.
    /// The division is floored, written out, since % truncates toward 0.
    /// </summary>
    public static (int Local, long Cycles) Wrap(IReadOnlyList<CurveKey> keys, int t, CurveInfinity pre, CurveInfinity post)
    {
        int first = keys[0].Time, last = keys[keys.Count - 1].Time;
        if (t >= first && t <= last)
        {
            return (t, 0);
        }
        var mode = t < first ? pre : post;
        var span = (long)last - (long)first;
        if (span == 0 || mode == CurveInfinity.Constant || mode == CurveInfinity.Linear)
        {
            return (Math.Clamp(t, first, last), 0);
        }
        var d = (long)t - (long)first;
        var whole = d / span;
        var r = d - whole * span;
        if (r < 0)
        {
            r += span;
            whole -= 1;
        }
        return mode switch
        {
            CurveInfinity.Cycle => (first + (int)r, 0),
            CurveInfinity.CycleOffset => (first + (int)r, whole),
            CurveInfinity.Oscillate when whole % 2 != 0 => (first + (int)(span - r), 0),
            CurveInfinity.Oscillate => (first + (int)r, 0),
            _ => (Math.Clamp(t, first, last), 0),
        };
    }

    // curve_offset: a value moved by cycles times the change from the first key's value to the last's.
    static float Offset(IReadOnlyList<CurveKey> keys, float v, long cycles) =>
        cycles == 0 ? v : (float)((double)v + (double)cycles * ((double)keys[keys.Count - 1].Value - (double)keys[0].Value));

    // curve_extend: a linear side's value, on along the curve's slope at its end key. At least two keys.
    static double Extend(IReadOnlyList<CurveKey> keys, int t, bool before)
    {
        var n = keys.Count;
        var (end, a, b) = before ? (0, 0, 1) : (n - 1, n - 2, n - 1);
        var slope = 0.0;
        switch (keys[a].Interp)
        {
            case CurveInterp.Constant:
                break;
            case CurveInterp.Linear:
                slope = ((double)keys[b].Value - (double)keys[a].Value) / ((double)(keys[b].Time - keys[a].Time) / TicksPerSecond);
                break;
            default:
                slope = before ? OutSlope(keys, 0) : InSlope(keys, n - 1);
                break;
        }
        return (double)keys[end].Value + slope * ((double)((long)t - (long)keys[end].Time) / TicksPerSecond);
    }

    // curve_inside: the value at a tick from the first key's to the last's.
    static float Inside(IReadOnlyList<CurveKey> keys, int t)
    {
        var n = keys.Count;
        if (t <= keys[0].Time)
        {
            return keys[0].Value;
        }
        if (t >= keys[n - 1].Time)
        {
            return keys[n - 1].Value;
        }
        var i = Segment(keys, t);
        CurveKey k0 = keys[i], k1 = keys[i + 1];
        if (t == k0.Time)
        {
            return k0.Value;
        }
        var s = (double)(t - k0.Time) / (double)(k1.Time - k0.Time);
        return k0.Interp switch
        {
            CurveInterp.Constant => k0.Value,
            CurveInterp.Linear => (float)((double)k0.Value + ((double)k1.Value - (double)k0.Value) * s),
            _ => (float)Bezier(keys, i, s),
        };
    }

    // curve_step_inside: the stepped value at a tick from the first key's to the last's.
    static float StepInside(IReadOnlyList<CurveKey> keys, int t)
    {
        var n = keys.Count;
        if (t <= keys[0].Time)
        {
            return keys[0].Value;
        }
        if (t >= keys[n - 1].Time)
        {
            return keys[n - 1].Value;
        }
        return keys[Segment(keys, t)].Value;
    }

    /// <summary>The index i of the segment that holds a tick after the first key and before the last: keys[i].Time &lt;= t &lt; keys[i + 1].Time.</summary>
    public static int Segment(IReadOnlyList<CurveKey> keys, int t)
    {
        int lo = 0, hi = keys.Count - 1;
        while (hi - lo > 1)
        {
            var mid = lo + (hi - lo) / 2;
            if (keys[mid].Time <= t)
            {
                lo = mid;
            }
            else
            {
                hi = mid;
            }
        }
        return lo;
    }

    // curve_bezier: the segment from keys[i] to keys[i + 1] at s, from 0 to 1 of its duration.
    static double Bezier(IReadOnlyList<CurveKey> keys, int i, double s)
    {
        CurveKey k0 = keys[i], k1 = keys[i + 1];
        var duration = (double)(k1.Time - k0.Time) / TicksPerSecond;
        double v0 = k0.Value, v1 = k1.Value;
        var m0 = OutSlope(keys, i) * duration;
        var m1 = InSlope(keys, i + 1) * duration;
        double w0 = TangentWeight, w1 = TangentWeight;
        var weighted = false;
        if (k0.Interp == CurveInterp.Bezier && k0.Weighted)
        {
            (w0, weighted) = (k0.OutWeight, true);
        }
        if (k1.Interp == CurveInterp.Bezier && k1.Weighted)
        {
            (w1, weighted) = (k1.InWeight, true);
        }
        if (!weighted)
        {
            var s2 = s * s;
            var s3 = s2 * s;
            return (2 * s3 - 3 * s2 + 1) * v0
                + (s3 - 2 * s2 + s) * m0
                + (-2 * s3 + 3 * s2) * v1
                + (s3 - s2) * m1;
        }
        double x1 = w0, x2 = 1 - w1;
        double y1 = v0 + m0 * w0, y2 = v1 - m1 * w1;
        double lo = 0.0, hi = 1.0;
        for (var step = 0; step < SolveSteps; step++)
        {
            var mid = (lo + hi) / 2;
            if (Cubic(0, x1, x2, 1, mid) < s)
            {
                lo = mid;
            }
            else
            {
                hi = mid;
            }
        }
        return Cubic(v0, y1, y2, v1, (lo + hi) / 2);
    }

    /// <summary>A cubic Bezier's coordinate at u from its four control points' coordinates: <c>curve_cubic</c>.</summary>
    public static double Cubic(double p0, double p1, double p2, double p3, double u)
    {
        var r = 1 - u;
        return r * r * r * p0 + 3 * r * r * u * p1 + 3 * r * u * u * p2 + u * u * u * p3;
    }

    /// <summary>The slope that leaves a key, in value per second: a Bezier key's own, and the automatic one for any other.</summary>
    public static double OutSlope(IReadOnlyList<CurveKey> keys, int i) =>
        keys[i].Interp == CurveInterp.Bezier ? keys[i].OutSlope : AutoSlope(keys, i);

    /// <summary>The slope that reaches a key, in value per second: a Bezier key's own, and the automatic one for any other.</summary>
    public static double InSlope(IReadOnlyList<CurveKey> keys, int i) =>
        keys[i].Interp == CurveInterp.Bezier ? keys[i].InSlope : AutoSlope(keys, i);

    /// <summary>
    /// An automatic key's slope in value per second: <c>curve_auto_slope</c>. The first and last keys, and a peak, a
    /// trough or a key level with a neighbour, are flat. Otherwise it is the slope through the neighbours, limited to
    /// three times the gentler of its two segments' slopes, so the curve does not overshoot.
    /// </summary>
    public static double AutoSlope(IReadOnlyList<CurveKey> keys, int i)
    {
        if (i <= 0 || i >= keys.Count - 1)
        {
            return 0;
        }
        CurveKey a = keys[i - 1], k = keys[i], b = keys[i + 1];
        const double Ticks = TicksPerSecond;
        var before = ((double)k.Value - (double)a.Value) / ((double)(k.Time - a.Time) / Ticks);
        var after = ((double)b.Value - (double)k.Value) / ((double)(b.Time - k.Time) / Ticks);
        if (before * after <= 0)
        {
            return 0;
        }
        var slope = ((double)b.Value - (double)a.Value) / ((double)(b.Time - a.Time) / Ticks);
        var limit = 3 * Math.Min(Math.Abs(before), Math.Abs(after));
        return Math.Clamp(slope, -limit, limit);
    }
}
