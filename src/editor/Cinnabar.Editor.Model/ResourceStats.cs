using Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Model;

/// <summary>A point of the frame time history: the average and the longest frame of an interval, in milliseconds.</summary>
public readonly record struct FrameSample(double AverageMs, double MaxMs, double WorkMs);

/// <summary>
/// What the resource monitor shows (see docs/editor.md#resource-monitor): the host's and the game's latest stats, and
/// the frame times of the last minute. It changes only from link messages.
/// </summary>
public sealed class ResourceStats
{
    /// <summary>Four samples a second for a minute.</summary>
    public const int HistoryLength = 240;

    readonly Queue<FrameSample> _history = new();

    public HostStats? Host { get; private set; }

    public GameStats? Game { get; private set; }

    public IReadOnlyCollection<FrameSample> History => _history;

    public event Action? Changed;

    public void Apply(HostStats stats)
    {
        Host = stats;
        _history.Enqueue(new FrameSample(stats.FrameMsAverage, stats.FrameMsMax, stats.WorkMsAverage));
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
