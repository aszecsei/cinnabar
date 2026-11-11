using Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Model;

/// <summary>
/// A render pass's GPU time over the summaries that <c>timing</c> took: the median, the least and the most of each
/// summary's average per frame, in milliseconds, on its queue, <c>graphics</c> or <c>compute</c>. Calls is the median
/// of its calls per frame, which is more than one when several shown viewports draw it. Seen is how many of the
/// summaries had it.
/// </summary>
public sealed record PassTiming(string Name, string Queue, double Calls, double MedianMs, double MinMs, double MaxMs, int Seen);

/// <summary>
/// What <c>timing</c> answers (see docs/editor/capture.md#automation): how many summaries it took, the GPU frame's
/// median time over them, the passes, and the viewports that were shown with the sizes that the game drew them at. A
/// pass's time adds up over every shown viewport. Missing names the passes asked for that no summary had.
/// </summary>
public sealed record AutomationTiming(int Samples, double GpuMedianMs, PassTiming[] Passes, AutomationViewportSize[] Viewports, string[]? Missing = null);

/// <summary>Takes the passes' times from the profiler's summaries, for <c>timing</c>.</summary>
public static class ProfileTiming
{
    /// <summary>
    /// The passes' times over the summaries: those named, in their order, or every pass, the slowest first. A name
    /// matches a pass on either queue.
    /// </summary>
    public static AutomationTiming Measure(IReadOnlyList<ProfileSummary> samples, IReadOnlyList<string>? passes, AutomationViewportSize[] viewports)
    {
        var timed = samples
            .SelectMany(s => s.Costs.Where(c => c.Kind == ProfileCostKind.Pass))
            .GroupBy(c => (c.Name, c.Queue))
            .Select(g => new PassTiming(g.Key.Name, g.Key.Queue == 0 ? "graphics" : "compute",
                Median(g.Select(c => (double)c.Calls)), Median(g.Select(c => (double)c.MsAverage)),
                g.Min(c => (double)c.MsAverage), g.Max(c => (double)c.MsAverage), g.Count()))
            .ToList();
        string[]? missing = null;
        if (passes is { Count: > 0 })
        {
            missing = [.. passes.Where(name => timed.All(t => t.Name != name))];
            timed = [.. passes.SelectMany(name => timed.Where(t => t.Name == name))];
        }
        else
        {
            timed = [.. timed.OrderByDescending(t => t.MedianMs).ThenBy(t => t.Name, StringComparer.Ordinal)];
        }
        return new AutomationTiming(samples.Count, Median(samples.Select(s => (double)s.GpuMsAverage)), [.. timed], viewports,
            missing is { Length: > 0 } ? missing : null);
    }

    /// <summary>The middle value, or the mean of the two in the middle; 0 for none.</summary>
    public static double Median(IEnumerable<double> values)
    {
        var sorted = values.Order().ToArray();
        if (sorted.Length == 0)
        {
            return 0;
        }
        var middle = sorted.Length / 2;
        return sorted.Length % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
    }
}
