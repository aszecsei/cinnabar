using Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Model;

/// <summary>
/// A point of the frame time history: the average and the longest frame of an interval, in milliseconds. With the
/// profiler's summary of the interval, also the CPU, GPU and wait times, and the frames with the longest CPU and GPU
/// times, which a capture can ask for.
/// </summary>
public readonly record struct FrameSample(
    double AverageMs,
    double MaxMs,
    double WorkMs,
    bool Profiled = false,
    double CpuMs = 0,
    double CpuMaxMs = 0,
    double GpuMs = 0,
    double GpuMaxMs = 0,
    double WaitMs = 0,
    ulong CpuWorstFrame = 0,
    ulong GpuWorstFrame = 0);

/// <summary>
/// What the resource monitor shows (see docs/editor/shell-and-panels.md#resource-monitor): the host's and the game's latest stats, and
/// the frame times of the last minute. It changes only from link messages.
/// </summary>
public sealed class ResourceStats
{
    /// <summary>Four samples a second for a minute.</summary>
    public const int HistoryLength = 240;

    readonly Queue<FrameSample> _history = new();
    // The host sends the profiler's summary right before the Host_Stats of the same interval.
    ProfileSummary? _summary;

    public HostStats? Host { get; private set; }

    public GameStats? Game { get; private set; }

    public IReadOnlyCollection<FrameSample> History => _history;

    public event Action? Changed;

    public void Apply(ProfileSummary summary) => _summary = summary;

    public void Apply(HostStats stats)
    {
        Host = stats;
        var sample = new FrameSample(stats.FrameMsAverage, stats.FrameMsMax, stats.WorkMsAverage);
        if (_summary is { } p)
        {
            sample = sample with
            {
                Profiled = true,
                CpuMs = p.CpuMsAverage,
                CpuMaxMs = p.CpuMsMax,
                GpuMs = p.GpuMsAverage,
                GpuMaxMs = p.GpuMsMax,
                WaitMs = p.WaitMsAverage,
                CpuWorstFrame = p.CpuWorstFrame,
                GpuWorstFrame = p.GpuWorstFrame,
            };
            _summary = null;
        }
        _history.Enqueue(sample);
        while (_history.Count > HistoryLength)
        {
            _history.Dequeue();
        }
        Changed?.Invoke();
    }

    public void Apply(GameStats stats)
    {
        Game = stats;
        Changed?.Invoke();
    }

    /// <summary>Forgets everything, as when the link closes.</summary>
    public void Clear()
    {
        Host = null;
        Game = null;
        _summary = null;
        _history.Clear();
        Changed?.Invoke();
    }

    /// <summary>A size in bytes in the largest unit that keeps it at least 1, such as 12.3 MB.</summary>
    public static string Bytes(ulong bytes)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB"];
        var value = (double)bytes;
        var unit = 0;
        while (value >= 1024 && unit < units.Length - 1)
        {
            value /= 1024;
            unit++;
        }
        return unit == 0 ? $"{bytes} B" : $"{value:0.#} {units[unit]}";
    }
}
