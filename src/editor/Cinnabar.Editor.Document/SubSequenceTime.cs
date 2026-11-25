using System.Globalization;

namespace Cinnabar.Editor.Document;

/// <summary>
/// How a sub-sequence section maps its parent's time to its child's (see docs/cinematics/tracks.md#sub-sequence-tracks):
/// the section's span on the parent's time, its trim in the child's range, its scale and whether it loops. It is the
/// editor's copy of the runtime's <c>trim_of</c> and <c>child_time</c> (lib/engine/cutscene/sub_sequence.odin), so the
/// editor shows a child at the time that the preview plays it.
/// </summary>
public sealed record SubSequenceMap(int Start, int End, int TrimStart, int TrimEnd, float Scale, bool Loop)
{
    /// <summary>
    /// The map of a sub-sequence section into its child, as the cooker writes it and <c>trim_of</c> reads it: the trim's
    /// start clamped into the child's range, and its end, or the range's end without one, clamped between them. Null
    /// for a block that is not a section with a span.
    /// </summary>
    public static SubSequenceMap? Of(CutsceneBlock section, CutsceneFile child)
    {
        if (section is not { Kind: CutsceneBlockKind.Section, Start: { } start, End: { } end })
        {
            return null;
        }
        var range = CutsceneEdits.RangeOf(child);
        var words = section.Get("trim")?.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries) ?? [];
        var trimStart = words.Length > 0 && CutsceneFile.TryParseTicks(words[0], out var a) ? a : range.Start;
        var trimEnd = words.Length > 1 && CutsceneFile.TryParseTicks(words[1], out var b) && b != 0 ? b : range.End;
        trimStart = Math.Clamp(trimStart, range.Start, Math.Max(range.Start, range.End));
        trimEnd = Math.Clamp(trimEnd, trimStart, Math.Max(trimStart, range.End));
        var scale = section.Get("scale") is { } text && float.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var s) && s > 0 ? s : 1f;
        var loop = section.Get("loop")?.Trim() == "true";
        return new SubSequenceMap(start, end, trimStart, trimEnd, scale, loop);
    }

    /// <summary>
    /// A parent's time on the child's time, and how many times the trim wrapped before it, as <c>child_time</c> gives
    /// them: <c>trim.start + (t − start) × scale</c> in whole ticks, wrapped into the trim when the section loops and held
    /// at its end when it does not. A time before the section maps to its start, and one after it to its end.
    /// </summary>
    public (int Child, int Loops) ToChild(int t)
    {
        var local = (long)Math.Clamp(t, Start, End) - Start;
        var span = (long)Math.Floor(local * (double)Scale);
        var length = (long)TrimEnd - TrimStart;
        if (length <= 0)
        {
            return (TrimStart, 0);
        }
        if (!Loop)
        {
            return ((int)Math.Min(TrimStart + span, TrimEnd), 0);
        }
        var loops = span / length;
        var child = TrimStart + span % length;
        // At the section's end, a loop that ends there shows the trim's end, not its start.
        if (loops > 0 && span % length == 0 && t >= End)
        {
            return (TrimEnd, (int)(loops - 1));
        }
        return ((int)child, (int)loops);
    }

    /// <summary>
    /// The earliest parent's time in the section that the child's time reaches on a pass of the trim: the way back from
    /// <see cref="ToChild"/>. A time that the pass does not reach, past a hold's end or before the trim, is the section's
    /// end or start. With a scale above 1, the child skips ticks, so this is the parent's time where it first reaches
    /// the child's time or passes it.
    /// </summary>
    public int ToParent(int child, int loops = 0)
    {
        var length = (long)TrimEnd - TrimStart;
        if (length <= 0 || child <= TrimStart && loops <= 0)
        {
            return Start;
        }
        var span = (long)child - TrimStart + (Loop ? Math.Max(loops, 0) * length : 0);
        var t = (long)Start + (long)Math.Ceiling(span / (double)Scale);
        t = Math.Clamp(t, Start, End);
        var target = (Child: child, Loops: Loop ? Math.Max(loops, 0) : 0);
        // The float's rounding can put the guess a tick either side.
        while (t > Start && !Before(ToChild((int)(t - 1)), target))
        {
            t--;
        }
        while (t < End && Before(ToChild((int)t), target))
        {
            t++;
        }
        return (int)t;
    }

    static bool Before((int Child, int Loops) a, (int Child, int Loops) b) => a.Loops < b.Loops || (a.Loops == b.Loops && a.Child < b.Child);

    /// <summary>
    /// The span of the child's time that the section plays: from the trim's start to the trim's end when it loops, or to
    /// where the section's end holds when it does not. The editor shades the child's time outside it.
    /// </summary>
    public (int Start, int End) Span => Loop ? (TrimStart, TrimEnd) : (TrimStart, ToChild(End).Child);
}
