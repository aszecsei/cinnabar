using System.Globalization;

namespace Cinnabar.Editor.Document;

/// <summary>Which edge of a section or a range a trim moves.</summary>
public enum CutsceneEdge
{
    Start,
    End,
}

/// <summary>
/// The timeline's edits of a cutscene (see docs/editor/cutscene-editor.md#the-timeline): move, trim, slip, split,
/// delete, markers, copy and paste, on blocks named by path. Each one keeps what the cooker checks: times inside the length, keys inside their
/// section, a section no shorter than its eases, and a track's sections and a channel's keys in start order. Each one
/// leaves alone the blocks of locked tracks, and returns the paths of the blocks that it moved, as they are after it.
/// </summary>
public static class CutsceneEdits
{
    /// <summary>The track that a block is on, or null for a binding or the cutscene.</summary>
    public static CutsceneBlock? TrackOf(CutsceneBlock block)
    {
        for (var at = block; at != null; at = at.Parent)
        {
            if (at.Kind == CutsceneBlockKind.Track)
            {
                return at;
            }
        }
        return null;
    }

    /// <summary>The section that a key or a channel is in, or null.</summary>
    public static CutsceneBlock? SectionOf(CutsceneBlock block)
    {
        for (var at = block; at != null; at = at.Parent)
        {
            if (at.Kind == CutsceneBlockKind.Section)
            {
                return at;
            }
        }
        return null;
    }

    /// <summary>Whether a block is on a locked track.</summary>
    public static bool IsLocked(CutsceneBlock block, IReadOnlySet<int>? locked) =>
        locked != null && TrackOf(block)?.Id is { } id && locked.Contains(id);

    /// <summary>A block's start on the cutscene's time: a key's is its section's start and its own time.</summary>
    public static int? AbsoluteStart(CutsceneBlock block) => block.Kind == CutsceneBlockKind.Key
        ? SectionOf(block)?.Start is { } s && block.Start is { } t ? s + t : null
        : block.Start;

    /// <summary>A block's end on the cutscene's time: a section's or a range's end, or a trigger's or a key's time.</summary>
    public static int? AbsoluteEnd(CutsceneBlock block) => block.End ?? AbsoluteStart(block);

    /// <summary>The cutscene's length, or no limit when the file has none.</summary>
    public static int LengthOf(CutsceneFile file) => file.Length ?? int.MaxValue;

    static List<CutsceneBlock> Resolve(CutsceneFile file, IEnumerable<string> paths, IReadOnlySet<int>? locked) =>
        [.. paths.Distinct().Select(file.Find).OfType<CutsceneBlock>().Where(b => !IsLocked(b, locked))];

    static IEnumerable<CutsceneBlock> Keys(CutsceneBlock block) => block.Descendants().Where(b => b.Kind == CutsceneBlockKind.Key);

    /// <summary>Whether a block is one that the timeline moves, deletes, copies and pastes.</summary>
    public static bool IsTimed(CutsceneBlock block) => block.Kind is CutsceneBlockKind.Section or CutsceneBlockKind.Trigger
        or CutsceneBlockKind.Range or CutsceneBlockKind.Key or CutsceneBlockKind.Marker;

    /// <summary>
    /// Moves sections, triggers, ranges, keys and markers by a delta in ticks, clamped so that each stays inside the
    /// length and each key inside its section. A key whose section moves too moves with it. A subtitle that names a
    /// moved audio section with <c>audio</c> moves with that section, as docs/content/kinds/cutscenes.md says. Markers
    /// are on no track, so no lock holds them.
    /// </summary>
    public static IReadOnlyList<string> Move(CutsceneFile file, IEnumerable<string> paths, int delta, IReadOnlySet<int>? locked = null)
    {
        var blocks = Resolve(file, paths, locked).Where(IsTimed).ToList();
        var sections = blocks.Where(b => b.Kind == CutsceneBlockKind.Section).ToHashSet();
        // A key inside a moving section moves with it.
        blocks.RemoveAll(b => b.Kind == CutsceneBlockKind.Key && SectionOf(b) is { } s && sections.Contains(s));
        var followers = Followers(file, sections, locked);
        var moving = blocks.Concat(followers).ToList();
        if (moving.Count == 0 || delta == 0)
        {
            return [.. blocks.Select(CutsceneFile.PathOf)];
        }
        var length = LengthOf(file);
        long lo = long.MinValue, hi = long.MaxValue;
        foreach (var b in moving)
        {
            if (b.Kind == CutsceneBlockKind.Key)
            {
                var duration = SectionOf(b) is { Start: { } s, End: { } e } ? e - s : int.MaxValue;
                var t = b.Start ?? 0;
                lo = Math.Max(lo, -t);
                hi = Math.Min(hi, (long)duration - t);
            }
            else
            {
                var start = b.Start ?? 0;
                var end = b.End ?? start;
                lo = Math.Max(lo, -start);
                hi = Math.Min(hi, (long)length - end);
            }
        }
        var d = (int)Math.Clamp(delta, Math.Min(lo, 0), Math.Max(hi, 0));
        if (d == 0)
        {
            return [.. blocks.Select(CutsceneFile.PathOf)];
        }
        var parents = new HashSet<CutsceneBlock>();
        foreach (var b in moving)
        {
            switch (b.Kind)
            {
                case CutsceneBlockKind.Section or CutsceneBlockKind.Range when b is { Start: { } s, End: { } e }:
                    b.SetSpan(s + d, e + d);
                    break;
                case CutsceneBlockKind.Trigger or CutsceneBlockKind.Key or CutsceneBlockKind.Marker when b.Start is { } t:
                    b.SetTime(t + d);
                    break;
            }
            parents.Add(b.Parent!);
        }
        foreach (var parent in parents)
        {
            CutsceneFile.SortChildren(parent);
        }
        return [.. blocks.Select(CutsceneFile.PathOf)];
    }

    // The subtitles that belong to audio sections that move, and do not move themselves, which move with them.
    static List<CutsceneBlock> Followers(CutsceneFile file, ICollection<CutsceneBlock> sections, IReadOnlySet<int>? locked)
    {
        var audio = sections.Where(s => TrackOf(s)?.TrackKind == "audio" && s.Id != null).Select(s => s.Id!.Value.ToString(CultureInfo.InvariantCulture)).ToHashSet();
        if (audio.Count == 0)
        {
            return [];
        }
        return [.. file.Blocks.Where(b => b.Kind == CutsceneBlockKind.Section && !sections.Contains(b) && TrackOf(b)?.TrackKind == "presentation"
            && b.Get("audio") is { } id && audio.Contains(id) && !IsLocked(b, locked))];
    }

    // What a section's head can lose or a section can be, from what it has: its keys, its eases and blend, and where
    // its source starts.
    sealed record SectionLimits(int? FirstKey, int? LastKey, int MinDuration, double MinHeadCut, int PreviousEnd, int NextStart, int LaterEnd);

    static SectionLimits Limits(CutsceneFile file, CutsceneBlock section, Func<string, int>? childStart)
    {
        var start = section.Start ?? 0;
        var end = section.End ?? start;
        var keys = Keys(section).Select(k => k.Start).OfType<int>().ToList();
        var frame = CutsceneFile.TicksPerSecond / file.Rate;
        var minimum = Math.Max(frame, Math.Max(Ticks(section, "ease_in") + Ticks(section, "ease_out"), FirstTicks(section, "blend_in")));
        // How far before its start the section's source goes: its offset, or its sub-sequence's trim, in the
        // cutscene's time.
        var minHeadCut = double.NegativeInfinity;
        var kind = TrackOf(section)?.TrackKind;
        if (kind is "animation" or "audio")
        {
            minHeadCut = -Ticks(section, "offset") / (kind == "animation" ? Number(section, "speed", 1) : 1);
        }
        else if (kind == "sub_sequence")
        {
            minHeadCut = -TrimStart(section, childStart) / Number(section, "scale", 1);
        }
        // A camera cut or a sub-sequence section starts at or after the end of the one before it.
        var siblings = section.Parent!.Children.Where(c => c.Kind == CutsceneBlockKind.Section).ToList();
        var index = siblings.IndexOf(section);
        var ordered = kind is "camera_cut" or "sub_sequence";
        var previousEnd = ordered && index > 0 ? siblings[index - 1].End ?? 0 : 0;
        var nextStart = ordered && index < siblings.Count - 1 ? siblings[index + 1].Start ?? int.MaxValue : int.MaxValue;
        var later = siblings.Where(c => c != section && c.Start >= end).ToList();
        return new SectionLimits(keys.Count > 0 ? keys.Min() : null, keys.Count > 0 ? keys.Max() : null, minimum, minHeadCut,
            previousEnd, nextStart, later.Select(c => c.End ?? 0).DefaultIfEmpty(end).Max());
    }

    /// <summary>
    /// Trims an edge of a section or a range by a delta in ticks. Keys keep their times on the cutscene's time, so a
    /// trim of a section's start moves its keys' times, its offset into its clip or sound and its sub-sequence's trim.
    /// With ripple, a section keeps its start: its length changes by the trim, and the sections after it on its track
    /// move by as much. The delta is clamped so that the section keeps its keys, eases and a frame, its source does not
    /// start before its clip's, and every section stays inside the length.
    /// </summary>
    public static IReadOnlyList<string> Trim(CutsceneFile file, string path, CutsceneEdge edge, int delta, bool ripple, IReadOnlySet<int>? locked = null, Func<string, int>? childStart = null)
    {
        if (file.Find(path) is not { } block || IsLocked(block, locked) || block is not { Start: { } start, End: { } end })
        {
            return [];
        }
        var length = LengthOf(file);
        var frame = CutsceneFile.TicksPerSecond / file.Rate;
        if (block.Kind == CutsceneBlockKind.Range)
        {
            if (edge == CutsceneEdge.Start)
            {
                block.SetSpan(Math.Clamp(start + delta, 0, Math.Max(end - frame, 0)), end);
            }
            else
            {
                block.SetSpan(start, Math.Clamp(end + delta, Math.Min(start + frame, length), length));
            }
            CutsceneFile.SortChildren(block.Parent!);
            return [path];
        }
        if (block.Kind != CutsceneBlockKind.Section)
        {
            return [];
        }
        var limits = Limits(file, block, childStart);
        var duration = end - start;
        var later = ripple
            ? block.Parent!.Children.Where(c => c != block && c.Kind == CutsceneBlockKind.Section && c.Start >= end).ToList()
            : [];
        if (edge == CutsceneEdge.Start)
        {
            // The cut from the head: positive takes time off, negative adds it.
            double lo = limits.MinHeadCut, hi = duration - limits.MinDuration;
            if (limits.FirstKey is { } first)
            {
                hi = Math.Min(hi, first);
            }
            if (ripple)
            {
                // The sections after it move back by the cut, and forward by an added head, inside the length.
                if (later.Count > 0)
                {
                    lo = Math.Max(lo, limits.LaterEnd - (double)length);
                }
                lo = Math.Max(lo, end - (double)length);
            }
            else
            {
                lo = Math.Max(lo, Math.Max(limits.PreviousEnd, 0) - (double)start);
            }
            var cut = (int)Math.Round(Math.Clamp(delta, Math.Min(lo, 0), Math.Max(hi, 0)));
            if (cut == 0)
            {
                return [path];
            }
            CutHead(block, cut, childStart);
            if (ripple)
            {
                block.SetSpan(start, end - cut);
                Shift(file, later, -cut, locked);
            }
            else
            {
                block.SetSpan(start + cut, end);
            }
        }
        else
        {
            // The change of the end: positive adds time, negative takes it off.
            double lo = limits.MinDuration - duration, hi = (double)length - end;
            if (limits.LastKey is { } last)
            {
                lo = Math.Max(lo, last - duration);
            }
            if (ripple)
            {
                if (later.Count > 0)
                {
                    hi = Math.Min(hi, (double)length - limits.LaterEnd);
                }
            }
            else
            {
                hi = Math.Min(hi, (double)limits.NextStart - end);
            }
            var change = (int)Math.Round(Math.Clamp(delta, Math.Min(lo, 0), Math.Max(hi, 0)));
            if (change == 0)
            {
                return [path];
            }
            block.SetSpan(start, end + change);
            if (ripple)
            {
                Shift(file, later, change, locked);
            }
        }
        CutsceneFile.SortChildren(block.Parent!);
        return [path];
    }

    // Takes ticks off a section's head, or with a negative cut, adds them: its keys and its source keep their place on
    // the cutscene's time. The caller sets the span.
    static void CutHead(CutsceneBlock section, int cut, Func<string, int>? childStart)
    {
        foreach (var key in Keys(section))
        {
            if (key.Start is { } t)
            {
                key.SetTime(Math.Max(t - cut, 0));
            }
        }
        AdvanceSource(section, cut, childStart);
    }

    // Moves where a section's source starts by ticks of the cutscene's time: an animation's or a sound's offset, or a
    // sub-sequence's trim.
    static void AdvanceSource(CutsceneBlock section, double ticks, Func<string, int>? childStart)
    {
        switch (TrackOf(section)?.TrackKind)
        {
            case "animation" or "audio":
            {
                var speed = TrackOf(section)!.TrackKind == "animation" ? Number(section, "speed", 1) : 1;
                var offset = Math.Max((int)Math.Round(Ticks(section, "offset") + ticks * speed), 0);
                section.Set("offset", offset == 0 ? null : Format(offset));
                break;
            }
            case "sub_sequence" when section.Get("trim") is { } trim:
            {
                var scale = Number(section, "scale", 1);
                var words = trim.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
                if (words.Length == 0 || !CutsceneFile.TryParseTicks(words[0], out var from))
                {
                    break;
                }
                var moved = Math.Max((int)Math.Round(from + ticks * scale), 0);
                section.Set("trim", words.Length > 1 ? $"{Format(moved)} {words[1]}" : Format(moved));
                break;
            }
            case "sub_sequence":
            {
                // With no trim, the section plays from its child's range's start.
                var start = TrimStart(section, childStart);
                var moved = Math.Max((int)Math.Round(start + ticks * Number(section, "scale", 1)), 0);
                if (moved != start)
                {
                    section.Set("trim", Format(moved));
                }
                break;
            }
        }
    }

    // Moves sections by a delta, and the subtitles that follow them, as a ripple does.
    static void Shift(CutsceneFile file, List<CutsceneBlock> sections, int delta, IReadOnlySet<int>? locked)
    {
        foreach (var s in sections.Concat(Followers(file, sections, locked)))
        {
            if (s is { Start: { } a, End: { } b })
            {
                s.SetSpan(a + delta, b + delta);
            }
        }
    }

    /// <summary>
    /// Slips a section: its edges stay, and what it plays moves under them by a delta in ticks, so a drag to the right
    /// shows earlier source. An animation's or a sound's offset or a sub-sequence's trim changes, and never goes below 0.
    /// Sections of the other kinds have no source, and do not change.
    /// </summary>
    public static IReadOnlyList<string> Slip(CutsceneFile file, string path, int delta, IReadOnlySet<int>? locked = null, Func<string, int>? childStart = null)
    {
        if (file.Find(path) is not { Kind: CutsceneBlockKind.Section } section || IsLocked(section, locked))
        {
            return [];
        }
        var kind = TrackOf(section)?.TrackKind;
        if (kind is not ("animation" or "audio" or "sub_sequence"))
        {
            return [path];
        }
        if (kind == "sub_sequence" && section.Get("trim") is { } trim)
        {
            var scale = Number(section, "scale", 1);
            var words = trim.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (words.Length == 0 || !CutsceneFile.TryParseTicks(words[0], out var from))
            {
                return [path];
            }
            // The trim's end moves as far as its start does.
            var moved = Math.Max((int)Math.Round(from - delta * scale), 0);
            var shift = moved - from;
            var end = words.Length > 1 && CutsceneFile.TryParseTicks(words[1], out var to) ? $" {Format(to + shift)}" : "";
            section.Set("trim", Format(moved) + end);
            return [path];
        }
        AdvanceSource(section, -delta, childStart);
        return [path];
    }

    /// <summary>
    /// Splits each section that a time is inside into two at that time. The second half is a copy with the next
    /// section ID, which starts where the first ends: its keys move by the cut, its source starts later, and it takes
    /// the ease and blend out and the post roll, while the first keeps the ease and blend in and the pre roll. Each
    /// channel has a key at the cut in both halves, with the curve's value there as <see cref="CutsceneCurve.Value"/>
    /// gives it, and the interpolation of the key before it, or <c>auto</c> for a Bezier key. Returns both halves' paths.
    /// </summary>
    public static IReadOnlyList<string> Split(CutsceneFile file, IEnumerable<string> paths, int at, IReadOnlySet<int>? locked = null, Func<string, int>? childStart = null)
    {
        var result = new List<string>();
        foreach (var section in Resolve(file, paths, locked).Where(b => b.Kind == CutsceneBlockKind.Section))
        {
            if (section is not { Start: { } start, End: { } end } || at <= start || at >= end || section.Id == null)
            {
                continue;
            }
            var cut = at - start;
            var second = section.Copy();
            var track = section.Parent!;
            file.Insert(track, track.Children.ToList().IndexOf(section) + 1, second);
            second.SetSectionId(file.NextId(CutsceneBlockKind.Section));
            second.SetSpan(at, end);
            section.SetSpan(start, at);
            foreach (var setting in new[] { "ease_out", "blend_out", "post_roll" })
            {
                section.Set(setting, null);
            }
            foreach (var setting in new[] { "ease_in", "blend_in", "pre_roll" })
            {
                second.Set(setting, null);
            }
            AdvanceSource(second, cut, childStart);
            var firstChannels = section.Children.Where(c => c.Kind == CutsceneBlockKind.Channel).ToList();
            var secondChannels = second.Children.Where(c => c.Kind == CutsceneBlockKind.Channel).ToList();
            for (var i = 0; i < firstChannels.Count; i++)
            {
                SplitChannel(file, firstChannels[i], secondChannels[i], cut);
            }
            result.Add(CutsceneFile.PathOf(section));
            result.Add(CutsceneFile.PathOf(second));
        }
        return result;
    }

    // Keeps a channel's keys up to the cut in the first half and from it in the second, with a key at the cut in each.
    static void SplitChannel(CutsceneFile file, CutsceneBlock first, CutsceneBlock second, int cut)
    {
        var keys = first.Children.Where(c => c.Kind == CutsceneBlockKind.Key && c.Start != null).ToList();
        if (keys.Count == 0)
        {
            return;
        }
        var before = keys.LastOrDefault(k => k.Start <= cut);
        var after = keys.FirstOrDefault(k => k.Start > cut);
        var (value, interpolation) = ValueAt(before, after, cut);
        // A channel that the runtime reads takes the runtime's value at the cut.
        if (CutsceneCurveEdits.CurveOf(first) is { } curve && before?.Start != cut)
        {
            var (pre, post) = CutsceneCurveEdits.InfinityOf(first);
            value = CutsceneKeying.Format(CutsceneCurve.Value(curve, cut, pre, post));
        }
        // The first half: the keys before the cut, and one at it.
        foreach (var key in keys.Where(k => k.Start > cut))
        {
            file.Remove(key);
        }
        if (before?.Start != cut)
        {
            var model = before ?? after!;
            file.Insert(first, first.Children.Count, model.KeyLike(cut, value, interpolation));
        }
        // The second half: the keys after the cut, moved back by it, and one at its start.
        var copies = second.Children.Where(c => c.Kind == CutsceneBlockKind.Key && c.Start != null).ToList();
        var secondModel = copies.FirstOrDefault(k => k.Start >= cut) ?? copies[^1];
        foreach (var key in copies)
        {
            if (key.Start < cut)
            {
                file.Remove(key);
            }
            else
            {
                key.SetTime(key.Start!.Value - cut);
            }
        }
        if (before?.Start != cut)
        {
            var index = second.Children.ToList().FindIndex(c => c.Kind == CutsceneBlockKind.Key);
            file.Insert(second, Math.Max(index, 0), secondModel.KeyLike(0, value, interpolation));
        }
    }

    // The value of a channel's curve at a time between two keys, and the interpolation of a key there: a constant key's
    // value holds, and the other kinds are read as a straight line. Split takes the runtime's value instead for a channel
    // that CutsceneCurve reads, so only an asset's keys use this value. A Bezier key's tangents are not kept.
    static (string Value, string Interpolation) ValueAt(CutsceneBlock? before, CutsceneBlock? after, int time)
    {
        if (before == null)
        {
            return (after!.KeyValue ?? "0", Kind(after));
        }
        var kind = Kind(before);
        if (after == null || kind == "constant"
            || !double.TryParse(before.KeyValue, NumberStyles.Float, CultureInfo.InvariantCulture, out var a)
            || !double.TryParse(after.KeyValue, NumberStyles.Float, CultureInfo.InvariantCulture, out var b))
        {
            return (before.KeyValue ?? "0", kind);
        }
        var t0 = before.Start!.Value;
        var t1 = after.Start!.Value;
        var value = a + (b - a) * (time - t0) / Math.Max(t1 - t0, 1);
        return (Math.Round(value, 6).ToString("R", CultureInfo.InvariantCulture), kind);
    }

    static string Kind(CutsceneBlock key) => key.KeyInterpolation?.Split(' ')[0] switch
    {
        "constant" => "constant",
        "linear" => "linear",
        _ => "auto",
    };

    /// <summary>
    /// Deletes sections, triggers, ranges, keys and markers. A channel that loses its last key goes too, since the
    /// cooker wants a key in each, and a subtitle of a deleted audio section loses its <c>audio</c>, even on a locked
    /// track. With ripple, the sections after a deleted section on its track move back by its length, as far as the
    /// sections before it let them.
    /// </summary>
    public static void Delete(CutsceneFile file, IEnumerable<string> paths, bool ripple, IReadOnlySet<int>? locked = null)
    {
        var blocks = Resolve(file, paths, locked).Where(IsTimed).ToList();
        // A subtitle of a deleted sound stays, without the sound, since its audio must name a section that there is.
        foreach (var subtitle in Followers(file, [.. blocks.Where(b => b.Kind == CutsceneBlockKind.Section)], null))
        {
            subtitle.Set("audio", null);
        }
        // Later sections first, so each gap closes from the end of the track.
        foreach (var b in blocks.OrderByDescending(b => AbsoluteStart(b) ?? 0))
        {
            var parent = b.Parent!;
            var removed = b is { Kind: CutsceneBlockKind.Section, Start: { } s, End: { } e } ? (s, e) : ((int, int)?)null;
            file.Remove(b);
            if (b.Kind == CutsceneBlockKind.Key && !parent.Children.Any(c => c.Kind == CutsceneBlockKind.Key) && parent.Parent != null)
            {
                file.Remove(parent);
            }
            if (ripple && removed is { } gap)
            {
                var (start, end) = gap;
                var sections = parent.Children.Where(c => c.Kind == CutsceneBlockKind.Section && c.Start != null).ToList();
                var later = sections.Where(c => c.Start >= end).ToList();
                if (later.Count == 0)
                {
                    continue;
                }
                // The sections that stay before the gap, which a moved section must not start before the end of.
                var floor = sections.Except(later).Select(c => c.End ?? 0).Append(start).Max();
                var shift = Math.Min(end - start, later.Min(c => c.Start!.Value) - floor);
                Shift(file, later, -Math.Max(shift, 0), locked);
            }
        }
    }

    /// <summary>
    /// Sets the cutscene's length, no less than the end of any section, range, trigger, marker or of its range, and no
    /// less than a frame.
    /// </summary>
    public static void SetLength(CutsceneFile file, int length)
    {
        var latest = file.Blocks.Where(b => b.Kind is CutsceneBlockKind.Section or CutsceneBlockKind.Trigger or CutsceneBlockKind.Range or CutsceneBlockKind.Marker)
            .Select(b => b.End ?? b.Start ?? 0)
            .Append(RangeOf(file) is { End: var end } && file.Root.Get("range") != null ? end : 0)
            .Append(CutsceneFile.TicksPerSecond / file.Rate)
            .Max();
        file.Root.Set("length", Format(Math.Max(length, latest)));
    }

    /// <summary>The part of the cutscene that plays: its <c>range</c>, or all of its length.</summary>
    public static (int Start, int End) RangeOf(CutsceneFile file)
    {
        var length = file.Length ?? 0;
        if (file.Root.Get("range") is { } text
            && text.Trim().TrimStart('[').TrimEnd(']').Split(',') is [var a, var b]
            && CutsceneFile.TryParseTicks(a.Trim(), out var start) && CutsceneFile.TryParseTicks(b.Trim(), out var end))
        {
            return (start, end);
        }
        return (0, length);
    }

    /// <summary>Sets the part that plays, inside the length and a frame long at least. All of the length drops the setting.</summary>
    public static void SetRange(CutsceneFile file, int start, int end)
    {
        var length = LengthOf(file);
        var frame = CutsceneFile.TicksPerSecond / file.Rate;
        start = Math.Clamp(start, 0, Math.Max(length - frame, 0));
        end = Math.Clamp(end, Math.Min(start + frame, length), length);
        file.Root.Set("range", start == 0 && end == file.Length ? null : $"[{Format(start)}, {Format(end)}]");
    }

    /// <summary>
    /// Adds a marker at a time inside the length, after the last marker, or with none, before the first binding or
    /// track, so the header's settings stay above it. A marker at that time already is kept, and nothing is added.
    /// Returns the marker's path.
    /// </summary>
    public static string AddMarker(CutsceneFile file, int at, string? name = null)
    {
        at = Math.Clamp(at, 0, LengthOf(file));
        if (file.Markers.FirstOrDefault(m => m.Start == at) is { } there)
        {
            return CutsceneFile.PathOf(there);
        }
        var id = file.NextId(CutsceneBlockKind.Marker);
        var marker = new CutsceneBlock(CutsceneBlockKind.Marker, null);
        marker.Lines.Add(new TextLine($"marker {Format(id)} {Format(at)} {TextQuote.Quote(name ?? $"Marker {id}")}", "", hashInWord: true));
        file.Insert(file.Root, MarkerIndex(file), marker);
        CutsceneFile.SortChildren(file.Root);
        return CutsceneFile.PathOf(marker);
    }

    // Where a new marker goes under the cutscene: after the last marker, or before the first binding or track.
    static int MarkerIndex(CutsceneFile file)
    {
        var children = file.Root.Children.ToList();
        var last = children.FindLastIndex(c => c.Kind == CutsceneBlockKind.Marker);
        var index = last >= 0 ? last + 1 : children.FindIndex(c => c.Kind is CutsceneBlockKind.Binding or CutsceneBlockKind.Track);
        return index >= 0 ? index : children.Count;
    }

    /// <summary>
    /// Copies sections (with their channels and keys), triggers, ranges, keys and markers for <see cref="Paste"/>, or
    /// null when none is named. A key in a copied section goes with its section.
    /// </summary>
    public static CutsceneClip? Copy(CutsceneFile file, IEnumerable<string> paths)
    {
        var blocks = Resolve(file, paths, null).Where(IsTimed).ToList();
        var sections = blocks.Where(b => b.Kind == CutsceneBlockKind.Section).ToHashSet();
        blocks.RemoveAll(b => b.Kind == CutsceneBlockKind.Key && SectionOf(b) is { } s && sections.Contains(s));
        blocks.RemoveAll(b => AbsoluteStart(b) == null);
        if (blocks.Count == 0)
        {
            return null;
        }
        var items = new List<CutsceneClipItem>();
        // In time order, and at one time, in the file's order, so a paste's new IDs do not hang on the order of the clicks.
        var order = file.Blocks.Select((b, i) => (b, i)).ToDictionary(p => p.b, p => p.i);
        foreach (var b in blocks.OrderBy(b => AbsoluteStart(b)).ThenBy(b => order[b]))
        {
            var track = TrackOf(b);
            // A track as a model for one that a paste adds: its keyword line and settings, without its sections.
            CutsceneBlock? model = null;
            if (track != null)
            {
                model = track.Copy();
                foreach (var child in model.Children.ToList())
                {
                    model.ChildList.Remove(child);
                }
            }
            items.Add(new CutsceneClipItem(b.Copy(), AbsoluteStart(b)!.Value, AbsoluteEnd(b) ?? AbsoluteStart(b)!.Value,
                track?.Id, track?.TrackKind, BindingOf(track), b.Kind == CutsceneBlockKind.Key ? b.Parent?.Name : null, model));
        }
        var anchor = items.Min(i => i.Start);
        return new CutsceneClip(items, anchor, items.Max(i => i.End) - anchor);
    }

    /// <summary>The IDs of the bindings that a camera cut section names as its <c>camera</c>.</summary>
    public static HashSet<int> CutCameras(CutsceneFile file) =>
        [.. file.Tracks.Where(t => t.TrackKind == "camera_cut")
            .SelectMany(t => t.Children.Where(c => c.Kind == CutsceneBlockKind.Section))
            .Select(s => s.Get("camera") is { } text && CutsceneFile.TryParseTicks(text.Trim(), out var id) ? id : (int?)null)
            .OfType<int>()];

    /// <summary>The ID of the binding that a track is for, or null for a track of the cutscene's own, such as camera cuts.</summary>
    public static int? BindingOf(CutsceneBlock? track) =>
        track?.Get("binding") is { } text && CutsceneFile.TryParseTicks(text.Trim(), out var id) ? id : null;

    // The kinds of track that the cooker wants with a binding, and those that it wants without one. The others, audio
    // and event tracks, may have one or not.
    static readonly HashSet<string> BoundKinds = ["transform", "property", "animation"];
    static readonly HashSet<string> UnboundKinds = ["camera_cut", "sub_sequence", "presentation"];

    // The binding that a copied track's blocks go to on a paste onto a target: none for a kind that takes none, the
    // target's binding, or the copied track's own for a kind that needs one when the target has none.
    static int? BindingFor(string kind, int? targetBinding, int? sourceBinding) =>
        UnboundKinds.Contains(kind) ? null
        : BoundKinds.Contains(kind) ? targetBinding ?? sourceBinding
        : targetBinding;

    static int? TargetBinding(CutsceneBlock? target) => target?.Kind switch
    {
        CutsceneBlockKind.Binding => target.Id,
        CutsceneBlockKind.Track => BindingOf(target),
        _ => null,
    };

    // The track that each of a clip's tracks pastes onto: with a target, the target track when the clip has one track of
    // its kind, else the track of the clip's track's kind on the binding that BindingFor gives; without one, the track
    // with the clip's track's ID and kind, else one of its kind on its binding. Null when there is none, which a paste
    // can add.
    static Dictionary<(int? Id, string Kind, int? Binding), CutsceneBlock?> Targets(CutsceneFile file, CutsceneClip clip, CutsceneBlock? target)
    {
        var groups = clip.Items.Where(i => i.TrackKind != null).Select(i => (i.TrackId, i.TrackKind!, i.BindingId)).Distinct().ToList();
        var targetBinding = TargetBinding(target);
        var result = new Dictionary<(int?, string, int?), CutsceneBlock?>();
        foreach (var group in groups)
        {
            var (id, kind, binding) = group;
            CutsceneBlock? onto;
            if (target is { Kind: CutsceneBlockKind.Track or CutsceneBlockKind.Binding })
            {
                var to = BindingFor(kind, targetBinding, binding);
                onto = target.Kind == CutsceneBlockKind.Track && target.TrackKind == kind && groups.Count(g => g.Item2 == kind) == 1
                    ? target
                    : file.Tracks.FirstOrDefault(t => t.TrackKind == kind && BindingOf(t) == to && t.Id == id)
                        ?? file.Tracks.FirstOrDefault(t => t.TrackKind == kind && BindingOf(t) == to);
            }
            else
            {
                var bindingThere = binding == null || file.Bindings.Any(b => b.Id == binding);
                onto = file.Tracks.FirstOrDefault(t => t.Id == id && t.TrackKind == kind)
                    ?? (bindingThere ? file.Tracks.FirstOrDefault(t => t.TrackKind == kind && BindingOf(t) == binding) : null);
            }
            result[group] = onto;
        }
        return result;
    }

    /// <summary>
    /// The kinds of the tracks that a paste onto a target would add, as the cutscene has no track of that kind there:
    /// what the editor asks about before it pastes. Empty when the paste needs none.
    /// </summary>
    public static IReadOnlyList<string> MissingTracks(CutsceneFile file, CutsceneClip clip, CutsceneBlock? target) =>
        [.. Targets(file, clip, target).Where(p => p.Value == null).Select(p => p.Key.Kind).Distinct()];

    /// <summary>
    /// Pastes a clip so that its earliest start is at a time, keeping the times of its blocks to each other, onto the
    /// tracks that <see cref="MissingTracks"/> describes. A track that the cutscene lacks is added, like the copied
    /// one, when addTracks says so, and its blocks are left out when not. Pasted sections, triggers, ranges and markers
    /// take new IDs. A subtitle's <c>audio</c> names its pasted sound's new ID, or goes when its sound was not pasted.
    /// A key goes into the section of its track that holds its time, in the channel of its name, in place of a key at
    /// that time, and is left out without one. A kind of track that the cooker wants without a binding goes onto the
    /// cutscene's own track of that kind, and one that needs a binding keeps its own when the target has none. Locked tracks take nothing. The length grows to hold what is pasted. Returns the pasted blocks'
    /// paths.
    /// </summary>
    public static IReadOnlyList<string> Paste(CutsceneFile file, CutsceneClip clip, int at, CutsceneBlock? target, bool addTracks, IReadOnlySet<int>? locked = null)
    {
        var shift = Math.Max(at, 0) - clip.Anchor;
        var targets = Targets(file, clip, target);
        var targetBinding = TargetBinding(target);
        var pasted = new List<CutsceneBlock>();
        var audioIds = new Dictionary<string, string>();
        var parents = new HashSet<CutsceneBlock>();
        var latest = 0;
        foreach (var item in clip.Items)
        {
            var start = item.Start + shift;
            var block = item.Block.Copy();
            if (item.Block.Kind == CutsceneBlockKind.Marker)
            {
                // The marker goes where AddMarker puts one, and keeps its name and color. Each new ID is taken before
                // its block goes in, as the copy's own ID could be the highest.
                var markerId = file.NextId(CutsceneBlockKind.Marker);
                file.Insert(file.Root, MarkerIndex(file), block);
                block.SetId(markerId);
                block.SetTime(start);
                parents.Add(file.Root);
                pasted.Add(block);
                latest = Math.Max(latest, start);
                continue;
            }
            var group = (item.TrackId, item.TrackKind!, item.BindingId);
            var track = targets[group];
            if (track == null)
            {
                if (!addTracks || item.TrackModel == null)
                {
                    continue;
                }
                var binding = target is { Kind: CutsceneBlockKind.Track or CutsceneBlockKind.Binding }
                    ? BindingFor(item.TrackKind!, targetBinding, item.BindingId)
                    : item.BindingId;
                track = AddTrack(file, item.TrackModel, binding);
                targets[group] = track;
            }
            if (IsLocked(track, locked))
            {
                continue;
            }
            switch (block.Kind)
            {
                case CutsceneBlockKind.Key:
                {
                    var section = track.Children.FirstOrDefault(s => s is { Kind: CutsceneBlockKind.Section, Start: { } s0, End: { } s1 } && s0 <= start && start <= s1);
                    var channel = section?.Children.FirstOrDefault(c => c.Kind == CutsceneBlockKind.Channel && c.Name == item.Channel);
                    if (channel == null)
                    {
                        continue;
                    }
                    // A pasted key takes the place of a key at its time, as each key comes after the one before it.
                    if (channel.Children.FirstOrDefault(k => k.Kind == CutsceneBlockKind.Key && k.Start == start - section!.Start!.Value) is { } there)
                    {
                        file.Remove(there);
                    }
                    file.Insert(channel, channel.Children.Count, block);
                    block.SetTime(start - section!.Start!.Value);
                    parents.Add(channel);
                    break;
                }
                case CutsceneBlockKind.Section:
                {
                    var oldId = item.Block.Id;
                    var sectionId = file.NextId(CutsceneBlockKind.Section);
                    file.Insert(track, track.Children.Count, block);
                    block.SetId(sectionId);
                    if (item.TrackKind == "audio" && oldId != null)
                    {
                        audioIds[Format(oldId.Value)] = Format(block.Id!.Value);
                    }
                    block.SetSpan(start, start + (item.End - item.Start));
                    parents.Add(track);
                    break;
                }
                default:
                {
                    var eventId = file.NextId(CutsceneBlockKind.Trigger);
                    file.Insert(track, track.Children.Count, block);
                    block.SetId(eventId);
                    if (block.Kind == CutsceneBlockKind.Range)
                    {
                        block.SetSpan(start, start + (item.End - item.Start));
                    }
                    else
                    {
                        block.SetTime(start);
                    }
                    parents.Add(track);
                    break;
                }
            }
            pasted.Add(block);
            latest = Math.Max(latest, start + (item.End - item.Start));
        }
        foreach (var subtitle in pasted.Where(b => b.Kind == CutsceneBlockKind.Section && b.Get("audio") != null))
        {
            subtitle.Set("audio", audioIds.GetValueOrDefault(subtitle.Get("audio")!.Trim()));
        }
        foreach (var parent in parents)
        {
            CutsceneFile.SortChildren(parent);
        }
        if (pasted.Count > 0 && file.Length is { } length && latest > length)
        {
            file.Root.Set("length", Format(latest));
        }
        return [.. pasted.Select(CutsceneFile.PathOf)];
    }

    // Adds a track like a model, with the next track ID, for a binding or the cutscene, after the binding's last track,
    // or after the last track.
    static CutsceneBlock AddTrack(CutsceneFile file, CutsceneBlock model, int? binding)
    {
        var track = model.Copy();
        var id = file.NextId(CutsceneBlockKind.Track);
        file.Insert(file.Root, InsertAt(file, binding), track);
        track.SetId(id);
        track.Set("binding", binding is { } b ? Format(b) : null);
        return track;
    }

    // Where a new track for a binding goes under the cutscene: after the binding's last track, or after the last track.
    internal static int InsertAt(CutsceneFile file, int? binding)
    {
        var children = file.Root.Children.ToList();
        var last = children.FindLastIndex(c => c.Kind == CutsceneBlockKind.Track && BindingOf(c) == binding);
        if (last < 0)
        {
            last = children.FindLastIndex(c => c.Kind == CutsceneBlockKind.Track);
        }
        return last >= 0 ? last + 1 : children.Count;
    }

    static int Ticks(CutsceneBlock block, string key) => FirstTicks(block, key);

    // Where a sub-sequence section starts in its child's time: its trim's start, or with no trim, the start of the
    // child's range, which childStart gives from the child's GUID, or 0 when it cannot.
    static int TrimStart(CutsceneBlock section, Func<string, int>? childStart) =>
        section.Get("trim") != null ? FirstTicks(section, "trim")
        : section.Get("asset") is { } asset && childStart != null ? childStart(asset.TrimStart('$')) : 0;

    // A setting's first word as ticks, as blend_in's `<ticks> [curve]` and trim's `<start> [<end>]` are, or 0.
    static int FirstTicks(CutsceneBlock block, string key) =>
        block.Get(key)?.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries) is [var first, ..] && CutsceneFile.TryParseTicks(first, out var ticks)
            ? ticks
            : 0;

    static double Number(CutsceneBlock block, string key, double fallback) =>
        block.Get(key) is { } text && double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var value) && value > 0 ? value : fallback;

    static string Format(int ticks) => ticks.ToString(CultureInfo.InvariantCulture);
}

/// <summary>
/// What a copy of a cutscene's timeline holds (see docs/editor/cutscene-editor.md#copy-and-paste): copies of the copied
/// blocks with their times on the cutscene's time, the earliest start, and the span from it to the latest end.
/// </summary>
public sealed record CutsceneClip(IReadOnlyList<CutsceneClipItem> Items, int Anchor, int Span)
{
    /// <summary>
    /// The GUID of the cutscene that the copy came from. Its blocks name that cutscene's bindings by ID, as a camera
    /// cut's camera does, so it pastes only there.
    /// </summary>
    public string? Source { get; init; }
}

/// <summary>
/// A copied block, detached, with its start and end on the cutscene's time, and the track that it was on: its ID, kind,
/// binding and a copy of it without its sections, which a paste that adds a track copies. A key has its channel's name.
/// A marker has no track.
/// </summary>
public sealed record CutsceneClipItem(CutsceneBlock Block, int Start, int End, int? TrackId, string? TrackKind, int? BindingId, string? Channel, CutsceneBlock? TrackModel);
