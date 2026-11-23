namespace Cinnabar.Editor.Document;

/// <summary>What a tangent command makes of a key (see docs/editor/cutscene-editor.md#tangents).</summary>
public enum TangentMode
{
    /// <summary><c>auto</c>: smooth, with the evaluator's slope, and no overshoot.</summary>
    Auto,
    /// <summary><c>bezier &lt;slope&gt;</c>: one slope, the mean of the key's in and out slopes.</summary>
    Unify,
    /// <summary><c>bezier &lt;in&gt; &lt;out&gt;</c>: the key's slopes as they are, which its handles then move apart.</summary>
    Break,
    /// <summary><c>linear</c>: a straight line to the next key.</summary>
    Linear,
    /// <summary><c>constant</c>: the value holds until the next key.</summary>
    Constant,
    /// <summary><c>bezier 0</c>: flat slopes, broken or not as they were.</summary>
    Flatten,
}

/// <summary>The side of a curve that an infinity mode is for: before its first key, or after its last.</summary>
public enum InfinitySide { Pre, Post }

/// <summary>A side of a key: its in tangent, from the key before, or its out tangent, to the key after.</summary>
public enum TangentSide
{
    In,
    Out,
}

/// <summary>
/// The curve editor's edits of a cutscene's keys (see docs/editor/cutscene-editor.md#curves): their tangents, a
/// handle's slope, a move in time and value, and a new key on a curve. Each changes a key line's interpolation part
/// only through <see cref="CurveKey.Interpolation"/>, so <c>teleport</c> and the line's comment stay. Keys are named by
/// path, as <see cref="CutsceneFile.PathOf"/> names them. A key on a locked track, or one whose line the cooker would
/// refuse, as an asset's key, is left as it is.
/// </summary>
public static class CutsceneCurveEdits
{
    /// <summary>A channel's keys, in order, as blocks and as the runtime reads them, or null when one does not read.</summary>
    public static List<(CutsceneBlock Block, CurveKey Key)>? KeysOf(CutsceneBlock channel)
    {
        var keys = new List<(CutsceneBlock, CurveKey)>();
        foreach (var block in channel.Children.Where(c => c.Kind == CutsceneBlockKind.Key))
        {
            if (CurveKey.Parse(block) is not { } key)
            {
                return null;
            }
            keys.Add((block, key));
        }
        return keys;
    }

    /// <summary>The settings that hold a channel's infinity modes, before its first key and after its last.</summary>
    public static readonly string[] InfinitySettings = ["pre_infinity", "post_infinity"];

    /// <summary>The infinity modes' names, as the settings write them, in <see cref="CurveInfinity"/>'s order.</summary>
    public static readonly string[] InfinityNames = ["constant", "linear", "cycle", "cycle_offset", "oscillate"];

    /// <summary>
    /// A channel's pre and post infinity, as the cooker reads them: constant without the setting, and constant for a
    /// mode that it does not know, which the cooker reports.
    /// </summary>
    public static (CurveInfinity Pre, CurveInfinity Post) InfinityOf(CutsceneBlock channel)
    {
        CurveInfinity Read(string setting) =>
            Array.IndexOf(InfinityNames, channel.Get(setting)) is var i and >= 0 ? (CurveInfinity)i : CurveInfinity.Constant;
        return (Read(InfinitySettings[0]), Read(InfinitySettings[1]));
    }

    /// <summary>
    /// Whether a channel can take an infinity mode, as the cooker checks: a channel of assets has no slope or change of
    /// value, so no linear or offset mode, and an audio track's pitch is constant, since the sound's place is its
    /// integral.
    /// </summary>
    public static bool TakesInfinity(CutsceneBlock channel, CurveInfinity mode)
    {
        if (mode == CurveInfinity.Constant)
        {
            return true;
        }
        if (channel.Name == "pitch" && CutsceneEdits.SectionOf(channel)?.Parent?.TrackKind == "audio")
        {
            return false;
        }
        var assets = channel.Children.Any(c => c.KeyValue?.StartsWith('$') == true);
        return !(assets && mode is CurveInfinity.Linear or CurveInfinity.CycleOffset);
    }

    /// <summary>
    /// Sets one side's infinity on channels: the setting, or none for constant, the default. It skips a channel on a
    /// locked track, and one that does not take the mode (<see cref="TakesInfinity"/>). Whether the text changed.
    /// </summary>
    public static bool SetInfinity(CutsceneFile file, IEnumerable<string> channelPaths, InfinitySide side, CurveInfinity mode, IReadOnlySet<int>? locked = null)
    {
        var changed = false;
        var setting = InfinitySettings[(int)side];
        foreach (var path in channelPaths.Distinct())
        {
            if (file.Find(path) is not { Kind: CutsceneBlockKind.Channel } channel || CutsceneEdits.IsLocked(channel, locked)
                || !TakesInfinity(channel, mode))
            {
                continue;
            }
            var text = mode == CurveInfinity.Constant ? null : InfinityNames[(int)mode];
            if (channel.Get(setting) == text)
            {
                continue;
            }
            channel.Set(setting, text);
            changed = true;
        }
        return changed;
    }

    /// <summary>A channel's keys as the runtime reads them, or null when one does not read.</summary>
    public static List<CurveKey>? CurveOf(CutsceneBlock channel) => KeysOf(channel)?.Select(k => k.Key).ToList();

    // The keys that paths name, each with its channel's curve and its place in it.
    static IEnumerable<(CutsceneBlock Block, List<CurveKey> Curve, int Index)> Resolve(CutsceneFile file, IEnumerable<string> paths, IReadOnlySet<int>? locked)
    {
        foreach (var path in paths.Distinct())
        {
            if (file.Find(path) is not { Kind: CutsceneBlockKind.Key, Parent: { } channel } block || CutsceneEdits.IsLocked(block, locked)
                || KeysOf(channel) is not { } keys)
            {
                continue;
            }
            var index = keys.FindIndex(k => k.Block == block);
            yield return (block, keys.Select(k => k.Key).ToList(), index);
        }
    }

    /// <summary>
    /// A key after a tangent command: Auto, Linear and Constant drop the slopes and the weights; Unify, Break and Flatten
    /// make it a Bezier key from the slopes that the curve has at it now, keeping a Bezier key's weights.
    /// </summary>
    public static CurveKey WithTangents(IReadOnlyList<CurveKey> curve, int index, TangentMode mode)
    {
        var key = curve[index];
        var bezier = key.Interp == CurveInterp.Bezier;
        var inSlope = (float)CutsceneCurve.InSlope(curve, index);
        var outSlope = (float)CutsceneCurve.OutSlope(curve, index);
        var kept = bezier ? key with { Interp = CurveInterp.Bezier } : new CurveKey(key.Time, key.Value, CurveInterp.Bezier, Teleport: key.Teleport);
        return mode switch
        {
            TangentMode.Auto => new CurveKey(key.Time, key.Value, CurveInterp.Auto, Teleport: key.Teleport),
            TangentMode.Linear => new CurveKey(key.Time, key.Value, CurveInterp.Linear, Teleport: key.Teleport),
            TangentMode.Constant => new CurveKey(key.Time, key.Value, CurveInterp.Constant, Teleport: key.Teleport),
            TangentMode.Flatten => kept with { InSlope = 0, OutSlope = 0 },
            TangentMode.Break => kept with { Broken = true, InSlope = inSlope, OutSlope = outSlope },
            _ => kept with { Broken = false, InSlope = (float)(((double)inSlope + outSlope) / 2), OutSlope = (float)(((double)inSlope + outSlope) / 2) },
        };
    }

    /// <summary>Sets the tangents of keys, as one of the tangent commands does. Returns whether a key changed.</summary>
    public static bool SetTangents(CutsceneFile file, IEnumerable<string> paths, TangentMode mode, IReadOnlySet<int>? locked = null)
    {
        var changed = false;
        // Each key reads its curve as the earlier keys left it, so a Break of two neighbours keeps each one's own slopes.
        foreach (var path in paths.Distinct().ToList())
        {
            foreach (var (block, curve, index) in Resolve(file, [path], locked))
            {
                var next = WithTangents(curve, index, mode).Interpolation();
                if (next != block.KeyInterpolation)
                {
                    block.SetKeyInterpolation(next);
                    changed = true;
                }
            }
        }
        return changed;
    }

    /// <summary>
    /// Sets a key's slope on one side, in value per second, as a drag of its handle does. The key becomes a Bezier key. One
    /// that is not broken takes the slope on both sides; a broken one on that side only.
    /// </summary>
    public static void SetSlope(CutsceneFile file, string path, TangentSide side, double slope, IReadOnlySet<int>? locked = null)
    {
        if (!double.IsFinite(slope))
        {
            return;
        }
        foreach (var (block, curve, index) in Resolve(file, [path], locked))
        {
            var key = curve[index];
            var s = (float)Math.Clamp(slope, -float.MaxValue, float.MaxValue);
            var next = key.Interp == CurveInterp.Bezier
                ? key
                : new CurveKey(key.Time, key.Value, CurveInterp.Bezier, Teleport: key.Teleport);
            next = !next.Broken ? next with { InSlope = s, OutSlope = s }
                : side == TangentSide.In ? next with { InSlope = s }
                : next with { OutSlope = s };
            block.SetKeyInterpolation(next.Interpolation());
        }
    }

    /// <summary>
    /// Moves keys by ticks and by a value, as a drag in the curve editor does: the value of each, then their times, which
    /// <see cref="CutsceneEdits.Move"/> keeps inside their sections. Returns the keys' paths after the move.
    /// </summary>
    public static IReadOnlyList<string> MoveKeys(CutsceneFile file, IReadOnlyList<string> paths, int ticks, double value, IReadOnlySet<int>? locked = null)
    {
        if (value != 0)
        {
            foreach (var (block, curve, index) in Resolve(file, paths, locked).ToList())
            {
                var moved = (double)curve[index].Value + value;
                if (double.IsFinite(moved) && Math.Abs(moved) <= float.MaxValue)
                {
                    block.SetKeyValue(CutsceneKeying.Format(moved));
                }
            }
        }
        return CutsceneEdits.Move(file, paths, ticks, locked);
    }

    /// <summary>
    /// Adds a key to a channel at a tick on its section's time, with the value that the curve has there, or with stepped,
    /// the value that the curve holds there, as a constant key. A new key after a linear or a constant key takes its
    /// interpolation, so a straight line or a step stays as it is; any other is <c>auto</c>. A key already at that tick
    /// stays as it is. Returns the key's path, or null when the channel does not read or its track is locked.
    /// </summary>
    public static string? AddKey(CutsceneFile file, string channelPath, int tick, bool stepped = false, IReadOnlySet<int>? locked = null)
    {
        if (file.Find(channelPath) is not { Kind: CutsceneBlockKind.Channel } channel || CutsceneEdits.IsLocked(channel, locked)
            || KeysOf(channel) is not { Count: > 0 } keys || CutsceneEdits.SectionOf(channel) is not { Start: { } start, End: { } end })
        {
            return null;
        }
        tick = Math.Clamp(tick, 0, end - start);
        if (keys.FirstOrDefault(k => k.Key.Time == tick) is { Block: { } there })
        {
            return CutsceneFile.PathOf(there);
        }
        var curve = keys.Select(k => k.Key).ToList();
        var (pre, post) = InfinityOf(channel);
        var value = stepped ? CutsceneCurve.Step(curve, tick, pre, post) : CutsceneCurve.Value(curve, tick, pre, post);
        var text = stepped ? Math.Round(value).ToString(System.Globalization.CultureInfo.InvariantCulture) : CutsceneKeying.Format(value);
        var before = curve.LastOrDefault(k => k.Time < tick);
        var interpolation = stepped ? "constant" : curve.Any(k => k.Time < tick) && before.Interp is CurveInterp.Linear or CurveInterp.Constant
            ? new CurveKey(tick, value, before.Interp).Interpolation()
            : "auto";
        var key = keys[0].Block.KeyLike(tick, text, interpolation);
        file.Insert(channel, channel.Children.Count, key);
        CutsceneFile.SortChildren(channel);
        return CutsceneFile.PathOf(key);
    }
}
