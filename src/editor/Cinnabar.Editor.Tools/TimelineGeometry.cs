namespace Cinnabar.Editor.Tools;

/// <summary>How far a timeline zooms: the least and the most time a pixel shows, in its unit.</summary>
public readonly record struct TimelineZoom(double Min, double Max)
{
    /// <summary>The profiler's, in nanoseconds: from 10 ns a pixel to a second across 1000 pixels.</summary>
    public static readonly TimelineZoom Nanoseconds = new(10, 1e6);

    /// <summary>
    /// The cutscene editor's, in ticks at 60000 a second: from 20 ticks a pixel, a frame at 60 fps across 50 pixels, to
    /// 600000, about 2.8 hours across 1000 pixels.
    /// </summary>
    public static readonly TimelineZoom Ticks = new(20, 600_000);
}

/// <summary>
/// The part of a timeline that a view shows: the time at its left edge and the time per pixel, in the timeline's unit,
/// which is nanoseconds for the profiler and ticks for the cutscene editor. Zooming keeps the time under the pointer
/// where it is, within the zoom's limits.
/// </summary>
public readonly record struct TimelineView(double Start, double PerPixel, TimelineZoom Zoom)
{
    public double X(double time) => (time - Start) / PerPixel;

    /// <summary>The time at the pixel x.</summary>
    public double At(double x) => Start + x * PerPixel;

    public double End(double width) => At(width);

    /// <summary>The view of [start, end) across width pixels, with a margin of a twentieth on each side.</summary>
    public static TimelineView Fit(double start, double end, double width, TimelineZoom zoom)
    {
        var length = Math.Max(end - start, 1);
        var margin = length / 20;
        var scale = Math.Clamp((length + 2 * margin) / Math.Max(width, 1), zoom.Min, zoom.Max);
        return new TimelineView(start - margin, scale, zoom);
    }

    /// <summary>Zooms by factor (above 1 shows more time) around the pixel x.</summary>
    public TimelineView ZoomAbout(double x, double factor)
    {
        var at = At(x);
        var scale = Math.Clamp(PerPixel * factor, Zoom.Min, Zoom.Max);
        return this with { Start = at - x * scale, PerPixel = scale };
    }

    /// <summary>Moves the view by dx pixels: a drag to the right shows earlier time.</summary>
    public TimelineView Pan(double dx) => this with { Start = Start - dx * PerPixel };
}

/// <summary>A run of zones that the timeline draws as one block, because each is too narrow to see alone.</summary>
public readonly record struct TimelineRun(double X0, double X1, int First, int Count);

public static class TimelineGeometry
{
    /// <summary>
    /// Merges the spans of a row, in pixels and sorted by start, into runs: a span at least minWidth wide is a run of
    /// its own, and narrower spans that touch or nearly touch go together, so a row of thousands of tiny zones draws as
    /// a few blocks.
    /// </summary>
    public static List<TimelineRun> Runs(IReadOnlyList<(double X0, double X1)> spans, double minWidth = 1)
    {
        var runs = new List<TimelineRun>();
        var i = 0;
        while (i < spans.Count)
        {
            var (x0, x1) = spans[i];
            if (x1 - x0 >= minWidth)
            {
                runs.Add(new TimelineRun(x0, x1, i, 1));
                i++;
                continue;
            }
            var first = i;
            var end = Math.Max(x1, x0 + minWidth);
            i++;
            while (i < spans.Count && spans[i].X1 - spans[i].X0 < minWidth && spans[i].X0 <= end)
            {
                end = Math.Max(end, Math.Max(spans[i].X1, spans[i].X0 + minWidth));
                i++;
            }
            runs.Add(new TimelineRun(x0, end, first, i - first));
        }
        return runs;
    }

    /// <summary>A time as the timeline labels it: 850 ns, 12.5 µs, 3.20 ms.</summary>
    public static string Duration(double ns) => ns switch
    {
        < 1_000 => $"{ns:0} ns",
        < 1_000_000 => $"{ns / 1e3:0.#} µs",
        _ => $"{ns / 1e6:0.00} ms",
    };

    /// <summary>The spacing of the time ruler's ticks: 1, 2 or 5 times a power of ten, at least minPixels apart.</summary>
    public static double TickSpacing(double perPixel, double minPixels = 80)
    {
        var target = perPixel * minPixels;
        var power = Math.Pow(10, Math.Floor(Math.Log10(target)));
        foreach (var step in new[] { 1.0, 2.0, 5.0, 10.0 })
        {
            if (power * step >= target)
            {
                return power * step;
            }
        }
        return power * 10;
    }

    /// <summary>
    /// The spacing of a cutscene ruler's ticks, in ticks at 60000 a second: <see cref="TickSpacing"/> in seconds, 1, 2 or
    /// 5 times a power of ten, where a second or more fits, and in frames below that, at most a second. So every tick is
    /// on a frame, and timecode labels are round.
    /// </summary>
    public static double FrameSpacing(double ticksPerPixel, int frameTicks, double minPixels = 80)
    {
        const double second = 60000;
        if (ticksPerPixel * minPixels >= second)
        {
            return TickSpacing(ticksPerPixel / second, minPixels) * second;
        }
        var frames = Math.Max(TickSpacing(ticksPerPixel / frameTicks, minPixels), 1);
        return Math.Min(frames * frameTicks, second);
    }
}
