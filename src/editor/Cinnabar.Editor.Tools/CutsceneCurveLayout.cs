using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Tools;

/// <summary>
/// The curve editor's value axis: the value at the top edge, and the value per pixel, with values rising upward.
/// Zooming keeps the value under the pointer where it is.
/// </summary>
public readonly record struct ValueAxis(double Top, double PerPixel)
{
    /// <summary>The least and the most value a pixel shows.</summary>
    public const double MinPerPixel = 1e-7;

    public const double MaxPerPixel = 1e7;

    public double Y(double value) => (Top - value) / PerPixel;

    /// <summary>The value at the pixel y.</summary>
    public double At(double y) => Top - y * PerPixel;

    /// <summary>Zooms by factor (above 1 shows more value) around the pixel y.</summary>
    public ValueAxis ZoomAbout(double y, double factor)
    {
        var at = At(y);
        var scale = Math.Clamp(PerPixel * factor, MinPerPixel, MaxPerPixel);
        return new ValueAxis(at + y * scale, scale);
    }

    /// <summary>Moves the axis by dy pixels: a drag down shows higher values.</summary>
    public ValueAxis Pan(double dy) => this with { Top = Top + dy * PerPixel };

    /// <summary>The axis that shows [min, max] across height pixels, with a margin of a tenth of the span on each side. An empty span shows 1 around it.</summary>
    public static ValueAxis Fit(double min, double max, double height, double margin = 0.1)
    {
        var span = max - min;
        if (!(span > 1e-6))
        {
            var mid = (min + max) / 2;
            (min, max, span) = (mid - 0.5, mid + 0.5, 1);
        }
        var pad = span * margin;
        var scale = Math.Clamp((span + 2 * pad) / Math.Max(height, 1), MinPerPixel, MaxPerPixel);
        return new ValueAxis(max + pad, scale);
    }
}

/// <summary>What the curve editor shows: the shared time, its value axis, and whether each curve is scaled to −1..1.</summary>
public readonly record struct CurveView(TimelineView Time, ValueAxis Value, bool Normalized);

/// <summary>
/// One channel's curve in the curve editor: its section's span on the cutscene's time, its keys as the runtime reads
/// them with their paths, and its colour as 0xAARRGGBB. A stepped curve holds each key's value, as a field that steps
/// does. Normalized, a curve's values from Min to Max show from −1 to 1.
/// </summary>
public sealed class CurveRow
{
    public required string Path { get; init; }

    public required string Name { get; init; }

    public required uint Color { get; init; }

    public required int Start { get; init; }

    public required int End { get; init; }

    public required IReadOnlyList<CurveKey> Keys { get; init; }

    public required IReadOnlyList<string> KeyPaths { get; init; }

    public bool Stepped { get; init; }

    public bool Locked { get; init; }

    public double Min { get; init; }

    public double Max { get; init; }

    /// <summary>What the curve does before its first key, inside its section.</summary>
    public CurveInfinity Pre { get; init; }

    /// <summary>What the curve does after its last key, inside its section.</summary>
    public CurveInfinity Post { get; init; }

    /// <summary>
    /// The curve's value at a tick on the cutscene's time, clamped to its section, as the runtime samples it, with its
    /// infinity between the section's edges and its end keys.
    /// </summary>
    public double ValueAt(int tick)
    {
        var local = Math.Clamp(tick, Start, End) - Start;
        return Stepped ? CutsceneCurve.Step(Keys, local, Pre, Post) : CutsceneCurve.Value(Keys, local, Pre, Post);
    }

    /// <summary>A value as it shows: itself, or normalized, from −1 at Min to 1 at Max, and 0 for a flat curve.</summary>
    public double Shown(double value, bool normalized) =>
        !normalized ? value : Max - Min > 1e-9 ? (value - Min) / (Max - Min) * 2 - 1 : 0;

    /// <summary>How much value a shown unit is: 1, or normalized, half the curve's span, and 1 for a flat curve.</summary>
    public double Scale(bool normalized) => normalized && Max - Min > 1e-9 ? (Max - Min) / 2 : 1;

    /// <summary>A key's time on the cutscene's time.</summary>
    public int TickOf(int index) => Start + Keys[index].Time;

    /// <summary>Whether a key shows a handle on a side: a Bezier or an auto key, with a key on that side.</summary>
    public bool HasHandle(int index, TangentSide side) =>
        !Stepped && Keys[index].Interp is CurveInterp.Bezier or CurveInterp.Auto
        && (side == TangentSide.In ? index > 0 : index < Keys.Count - 1);
}

/// <summary>What is under a point of the curve editor.</summary>
public enum CurveHitKind
{
    None,
    Key,
    Handle,
    Curve,
}

/// <summary>A hit in the curve editor: a key or its handle by the key's path, or a curve at a tick, or nothing.</summary>
public sealed record CurveHit(CurveHitKind Kind, CurveRow? Row = null, int Index = -1, TangentSide Side = TangentSide.Out, int Tick = 0)
{
    public static readonly CurveHit Nothing = new(CurveHitKind.None);

    public string? Path => Row != null && Index >= 0 ? Row.KeyPaths[Index] : null;
}

/// <summary>
/// The curve editor's curves and their geometry (see docs/editor/cutscene-editor.md#curves), with no window: the rows
/// of the channels it shows, where their keys and handles are, what a point hits, a box's keys, and the span that F
/// frames. The time area starts at <see cref="CutsceneTimelineLayout.Gutter"/>, as the timeline's does, so the two
/// share their time's pixels.
/// </summary>
public sealed class CutsceneCurveLayout
{
    /// <summary>How near a key or a handle a press grabs it, in pixels.</summary>
    public const double Grab = 6;

    /// <summary>How near a curve a double-click adds a key to it, in pixels.</summary>
    public const double CurveGrab = 5;

    /// <summary>
    /// The length on screen, in pixels, of a handle of a key without weights: it shows the slope's direction, as the
    /// key's reach is the evaluator's third of the segment. A weighted key's handle is its true control point.
    /// </summary>
    public const double HandleLength = 40;

    /// <summary>The shortest a weighted handle shows, in pixels, so that a small weight's handle does not sit on its key.</summary>
    public const double MinHandleLength = 12;

    /// <summary>How many samples set a curve's span for the normalized view and framing.</summary>
    const int SpanSamples = 256;

    // Red, green, blue and grey for x, y, z and w and their colour names, and a palette for the rest.
    const uint Red = 0xFFE5534B, Green = 0xFF6CC644, Blue = 0xFF5B8DEF, Grey = 0xFFA2A2A8;
    static readonly uint[] Palette = [0xFFF1C232, 0xFFC27BA0, 0xFF45B5AA, 0xFFE69138, 0xFF8E7CC3, 0xFF93C47D];

    public IReadOnlyList<CurveRow> Rows { get; }

    CutsceneCurveLayout(IReadOnlyList<CurveRow> rows) => Rows = rows;

    /// <summary>
    /// A channel's colour: X red, Y green, Z blue and W grey, by its last part (<c>position_x</c>, <c>x</c>), and the
    /// colours' names alike (<c>r</c>, <c>g</c>, <c>b</c>, <c>a</c>); any other from the palette by its place.
    /// </summary>
    public static uint ColorOf(string channel, int other) => AxisColor(channel) ?? Palette[other % Palette.Length];

    // The colour of an axis's or a colour's channel, or null for another.
    static uint? AxisColor(string channel) => channel[(channel.LastIndexOf('_') + 1)..] switch
    {
        "x" or "r" => Red,
        "y" or "g" => Green,
        "z" or "b" => Blue,
        "w" or "a" => Grey,
        _ => null,
    };

    /// <summary>
    /// The rows of the channels at paths, in order, without the hidden ones and those whose keys the runtime does not
    /// read as numbers, such as an asset's.
    /// </summary>
    public static CutsceneCurveLayout Build(CutsceneFile file, IEnumerable<string> paths, IReadOnlySet<string>? hidden = null,
        Func<CutsceneBlock, bool>? stepped = null, IReadOnlySet<int>? locked = null)
    {
        var rows = new List<CurveRow>();
        var other = 0;
        foreach (var path in paths)
        {
            if (hidden?.Contains(path) == true || file.Find(path) is not { Kind: CutsceneBlockKind.Channel } channel
                || CutsceneEdits.SectionOf(channel) is not { Start: { } start, End: { } end } section
                || CutsceneCurveEdits.KeysOf(channel) is not { Count: > 0 } keys)
            {
                continue;
            }
            var track = CutsceneEdits.TrackOf(channel);
            var name = channel.Name ?? "";
            var color = ColorOf(name, other);
            if (AxisColor(name) == null)
            {
                other++;
            }
            var sections = track?.Children.Count(c => c.Kind == CutsceneBlockKind.Section) ?? 1;
            var label = $"{track?.Name ?? "track"} · {name}" + (sections > 1 ? $" ({section.Id})" : "");
            List<CurveKey> curve = [.. keys.Select(k => k.Key)];
            var isStepped = stepped?.Invoke(channel) == true;
            var (pre, post) = CutsceneCurveEdits.InfinityOf(channel);
            var (min, max) = SpanOf(curve, isStepped, end - start, pre, post);
            rows.Add(new CurveRow
            {
                Path = path,
                Name = label,
                Color = color,
                Start = start,
                End = end,
                Keys = curve,
                KeyPaths = [.. keys.Select(k => CutsceneFile.PathOf(k.Block))],
                Stepped = isStepped,
                Locked = CutsceneEdits.IsLocked(channel, locked),
                Min = min,
                Max = max,
                Pre = pre,
                Post = post,
            });
        }
        return new CutsceneCurveLayout(rows);
    }

    // A curve's least and most value in its section: at its keys, at even ticks between them, and at even ticks from the
    // section's edges to the end keys on a side whose infinity is not constant.
    static (double Min, double Max) SpanOf(List<CurveKey> keys, bool stepped, int duration, CurveInfinity pre, CurveInfinity post)
    {
        double min = double.MaxValue, max = double.MinValue;
        foreach (var key in keys)
        {
            (min, max) = (Math.Min(min, key.Value), Math.Max(max, key.Value));
        }
        var first = keys[0].Time;
        var last = keys[^1].Time;
        for (var i = 0; i <= SpanSamples && last > first && !stepped; i++)
        {
            double v = CutsceneCurve.Value(keys, first + (int)((long)(last - first) * i / SpanSamples), pre, post);
            (min, max) = (Math.Min(min, v), Math.Max(max, v));
        }
        foreach (var (from, to) in (ReadOnlySpan<(int, int)>)[(pre == CurveInfinity.Constant ? first : 0, first), (last, post == CurveInfinity.Constant ? last : duration)])
        {
            for (var i = 0; i <= SpanSamples && to > from; i++)
            {
                var t = from + (int)((long)(to - from) * i / SpanSamples);
                double v = stepped ? CutsceneCurve.Step(keys, t, pre, post) : CutsceneCurve.Value(keys, t, pre, post);
                (min, max) = (Math.Min(min, v), Math.Max(max, v));
            }
        }
        return (min, max);
    }

    /// <summary>The point of a key in the control, with the time area right of the gutter.</summary>
    public static (double X, double Y) KeyPoint(CurveRow row, int index, CurveView view) =>
        (CutsceneTimelineLayout.Gutter + view.Time.X(row.TickOf(index)), view.Value.Y(row.Shown(row.Keys[index].Value, view.Normalized)));

    /// <summary>
    /// The end of a key's handle on a side, in the control. A weighted key's is its control point, as
    /// <c>curve_bezier</c> builds it: the weight's part of the segment's duration across, and the slope over that time up,
    /// but at least <see cref="MinHandleLength"/> pixels from the key. Any other key's is <see cref="HandleLength"/>
    /// pixels from the key, along the slope that the curve has there as it shows on screen.
    /// </summary>
    public static (double X, double Y) HandlePoint(CurveRow row, int index, TangentSide side, CurveView view)
    {
        var slope = side == TangentSide.In ? CutsceneCurve.InSlope(row.Keys, index) : CutsceneCurve.OutSlope(row.Keys, index);
        if (Weight(row, index, side) is { } weight)
        {
            var (kx, ky) = KeyPoint(row, index, view);
            var sign = side == TangentSide.In ? -1 : 1;
            var reach = weight * SegmentTicks(row, index, side);
            var px = sign * reach / view.Time.PerPixel;
            var py = -sign * slope * (reach / CutsceneCurve.TicksPerSecond) / row.Scale(view.Normalized) / view.Value.PerPixel;
            var length = Math.Sqrt(px * px + py * py);
            if (length >= MinHandleLength && double.IsFinite(length))
            {
                return (kx + px, ky + py);
            }
        }
        return Direction(row, index, side, view, slope, ShownLength(row, index, side));
    }

    // The length of a handle that shows only a direction: the fixed length, or a weighted handle's shortest.
    static double ShownLength(CurveRow row, int index, TangentSide side) => Weight(row, index, side) != null ? MinHandleLength : HandleLength;

    /// <summary>A weighted key's weight on a side, or null for a key without weights.</summary>
    public static double? Weight(CurveRow row, int index, TangentSide side) => row.Keys[index] is { Interp: CurveInterp.Bezier, Weighted: true } key
        ? side == TangentSide.In ? key.InWeight : key.OutWeight
        : null;

    // The ticks of the segment that a key's handle on a side reaches into.
    static int SegmentTicks(CurveRow row, int index, TangentSide side) => side == TangentSide.In
        ? row.Keys[index].Time - row.Keys[index - 1].Time
        : row.Keys[index + 1].Time - row.Keys[index].Time;

    // A point length pixels from a key along a slope as it shows on screen.
    static (double X, double Y) Direction(CurveRow row, int index, TangentSide side, CurveView view, double slope, double handleLength)
    {
        // A second across, and the slope's value over a second up, in pixels.
        var dx = CutsceneCurve.TicksPerSecond / view.Time.PerPixel;
        var dy = -slope / row.Scale(view.Normalized) / view.Value.PerPixel;
        var length = Math.Sqrt(dx * dx + dy * dy);
        var sign = side == TangentSide.In ? -1 : 1;
        var (x, y) = KeyPoint(row, index, view);
        return length > 0 && double.IsFinite(length) ? (x + sign * dx / length * handleLength, y + sign * dy / length * handleLength) : (x + sign * handleLength, y);
    }

    /// <summary>
    /// The weight of a weighted key's handle that a drag puts at a point: how far across the pointer is from the key, as a
    /// part of the segment's duration, from 0 to 1. Null for a key without weights, whose handle sets only a slope.
    /// </summary>
    public static double? WeightAt(CurveRow row, int index, TangentSide side, CurveView view, double x)
    {
        if (Weight(row, index, side) == null)
        {
            return null;
        }
        var (kx, _) = KeyPoint(row, index, view);
        var across = side == TangentSide.In ? kx - x : x - kx;
        return Math.Clamp(across * view.Time.PerPixel / SegmentTicks(row, index, side), 0, 1);
    }

    /// <summary>
    /// The slope, in value per second, of a handle that a drag puts at a point: the line from the key to the point, on
    /// the cutscene's time and values. A point past the key on the wrong side reads as one a pixel to the right side.
    /// </summary>
    public static double SlopeAt(CurveRow row, int index, TangentSide side, CurveView view, double x, double y)
    {
        var (kx, ky) = KeyPoint(row, index, view);
        var dx = side == TangentSide.In ? Math.Min(x - kx, -1) : Math.Max(x - kx, 1);
        var seconds = dx * view.Time.PerPixel / CutsceneCurve.TicksPerSecond;
        var value = -(y - ky) * view.Value.PerPixel * row.Scale(view.Normalized);
        return value / seconds;
    }

    /// <summary>
    /// What a point hits: a selected key's handle, which comes first, then a key, then a curve within
    /// <see cref="CurveGrab"/> pixels, then nothing. Later rows are drawn over earlier ones, so they win.
    /// </summary>
    public CurveHit HitTest(double x, double y, CurveView view, IReadOnlySet<string> selected)
    {
        if (x < CutsceneTimelineLayout.Gutter)
        {
            return CurveHit.Nothing;
        }
        static bool Near((double X, double Y) p, double x, double y, double d) => Math.Abs(p.X - x) <= d && Math.Abs(p.Y - y) <= d;
        for (var r = Rows.Count - 1; r >= 0; r--)
        {
            var row = Rows[r];
            for (var i = 0; i < row.Keys.Count; i++)
            {
                if (!selected.Contains(row.KeyPaths[i]))
                {
                    continue;
                }
                foreach (var side in (TangentSide[])[TangentSide.Out, TangentSide.In])
                {
                    if (row.HasHandle(i, side) && Near(HandlePoint(row, i, side, view), x, y, Grab))
                    {
                        return new CurveHit(CurveHitKind.Handle, row, i, side);
                    }
                }
            }
        }
        for (var r = Rows.Count - 1; r >= 0; r--)
        {
            var row = Rows[r];
            for (var i = row.Keys.Count - 1; i >= 0; i--)
            {
                if (Near(KeyPoint(row, i, view), x, y, Grab))
                {
                    return new CurveHit(CurveHitKind.Key, row, i);
                }
            }
        }
        var tick = (int)Math.Round(view.Time.At(x - CutsceneTimelineLayout.Gutter));
        for (var r = Rows.Count - 1; r >= 0; r--)
        {
            var row = Rows[r];
            if (tick < row.Start || tick > row.End)
            {
                continue;
            }
            var at = view.Value.Y(row.Shown(row.ValueAt(tick), view.Normalized));
            if (Math.Abs(at - y) <= CurveGrab)
            {
                return new CurveHit(CurveHitKind.Curve, row, -1, Tick: tick);
            }
        }
        return CurveHit.Nothing;
    }

    /// <summary>The paths of the keys inside a box, corner to corner, in the control.</summary>
    public IReadOnlyList<string> InBox(double x0, double y0, double x1, double y1, CurveView view)
    {
        var (left, right) = (Math.Min(x0, x1), Math.Max(x0, x1));
        var (top, bottom) = (Math.Min(y0, y1), Math.Max(y0, y1));
        var paths = new List<string>();
        foreach (var row in Rows)
        {
            for (var i = 0; i < row.Keys.Count; i++)
            {
                var (x, y) = KeyPoint(row, i, view);
                if (x >= left && x <= right && y >= top && y <= bottom)
                {
                    paths.Add(row.KeyPaths[i]);
                }
            }
        }
        return paths;
    }

    /// <summary>
    /// What F fits (see docs/editor/cutscene-editor.md#curves): the times and shown values of the selected keys, or with
    /// none of them shown, of every curve over its keys, and to its section's edge on a side whose infinity is not
    /// constant. Null when there is no curve.
    /// </summary>
    public (int Start, int End, double Min, double Max)? FrameSpan(IReadOnlySet<string> selected, bool normalized)
    {
        var keys = Rows.SelectMany(r => Enumerable.Range(0, r.Keys.Count).Where(i => selected.Contains(r.KeyPaths[i])).Select(i => (Row: r, Index: i))).ToList();
        if (keys.Count > 0)
        {
            return (keys.Min(k => k.Row.TickOf(k.Index)), keys.Max(k => k.Row.TickOf(k.Index)),
                keys.Min(k => k.Row.Shown(k.Row.Keys[k.Index].Value, normalized)), keys.Max(k => k.Row.Shown(k.Row.Keys[k.Index].Value, normalized)));
        }
        if (Rows.Count == 0)
        {
            return null;
        }
        return (Rows.Min(r => r.Pre == CurveInfinity.Constant ? r.TickOf(0) : r.Start),
            Rows.Max(r => r.Post == CurveInfinity.Constant ? r.TickOf(r.Keys.Count - 1) : r.End),
            Rows.Min(r => r.Shown(r.Min, normalized)), Rows.Max(r => r.Shown(r.Max, normalized)));
    }

    /// <summary>
    /// A curve's points to draw across the time area's width: one sample at a whole tick for each pixel of its section
    /// that is in view, and one at each end of what is in view, as the runtime would give them. A part, from and to on
    /// the cutscene's time, limits them to it, as the curve editor draws the parts outside the keys apart.
    /// </summary>
    public static IEnumerable<(double X, double Y)> Samples(CurveRow row, CurveView view, double width, (int From, int To)? part = null)
    {
        var from = Math.Max(Math.Max(row.Start, part?.From ?? int.MinValue), (int)Math.Floor(view.Time.At(0)));
        var to = Math.Min(Math.Min(row.End, part?.To ?? int.MaxValue), (int)Math.Ceiling(view.Time.At(width)));
        if (to < from)
        {
            yield break;
        }
        var step = Math.Max(view.Time.PerPixel, 1);
        for (var t = (double)from; ; t += step)
        {
            var tick = (int)Math.Min(Math.Round(t), to);
            yield return (CutsceneTimelineLayout.Gutter + view.Time.X(tick), view.Value.Y(row.Shown(row.ValueAt(tick), view.Normalized)));
            if (tick >= to)
            {
                yield break;
            }
        }
    }
}
