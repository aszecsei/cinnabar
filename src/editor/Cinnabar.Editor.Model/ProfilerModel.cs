using Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Model;

/// <summary>A cost table's columns, which its rows sort by.</summary>
public enum CostColumn
{
    Name,
    Calls,
    Average,
    Max,
    Percent,
}

/// <summary>
/// A row of a cost table: a system, a behaviour class's callback or a pass, per frame over the last stats interval.
/// Percent is of the frame's CPU time for systems and scripts, and of its GPU time for passes.
/// </summary>
public sealed record CostRow(string Name, string Detail, double Calls, double AverageMs, double MaxMs, double Percent);

/// <summary>What the profiler panel shows of the capture it waits for, or why it has none.</summary>
public enum CaptureStatus
{
    None,
    Waiting,
    Captured,
    Unavailable,
}

/// <summary>
/// The profiler's state in the editor (see docs/editor/shell-and-panels.md#profiler): the host's latest summary, sorted
/// cost tables, and the captured frame. It lives in the shell, so a panel that docking rebuilds finds it as it was.
/// </summary>
public sealed class ProfilerModel
{
    readonly Dictionary<ProfileCostKind, (CostColumn Column, bool Descending)> _sort = new()
    {
        [ProfileCostKind.System] = (CostColumn.Average, true),
        [ProfileCostKind.Script] = (CostColumn.Average, true),
        [ProfileCostKind.Pass] = (CostColumn.Average, true),
    };
    uint _nextId;
    uint _waitingFor;

    public ProfileSummary? Summary { get; private set; }

    public FrameCapture? Capture { get; private set; }

    public CaptureStatus Status { get; private set; }

    /// <summary>Why the last capture failed.</summary>
    public string Reason { get; private set; } = "";

    /// <summary>A name that a cost table selected, which the timeline highlights.</summary>
    public string? Highlight { get; private set; }

    /// <summary>The host records zones. It starts on, and each summary says.</summary>
    public bool Recording => Summary?.Recording ?? true;

    /// <summary>The summary or the tables' order changed.</summary>
    public event Action? SummaryChanged;

    /// <summary>The capture, its status or the highlight changed.</summary>
    public event Action? CaptureChanged;

    public void Apply(ProfileSummary summary)
    {
        Summary = summary;
        SummaryChanged?.Invoke();
    }

    /// <summary>Makes a capture request, and waits for its answer. An answer to an earlier request is ignored.</summary>
    public ProfileCaptureRequest Request(ProfileCaptureMode mode, ulong frame = 0, uint count = 0)
    {
        _waitingFor = ++_nextId;
        Status = CaptureStatus.Waiting;
        Reason = "";
        CaptureChanged?.Invoke();
        return new ProfileCaptureRequest(_waitingFor, mode, frame, count);
    }

    public void Apply(ProfileCapture capture)
    {
        if (capture.Id != _waitingFor || Status != CaptureStatus.Waiting)
        {
            return;
        }
        if (capture.Available)
        {
            Capture = FrameCapture.From(capture);
            Status = CaptureStatus.Captured;
        }
        else
        {
            Status = CaptureStatus.Unavailable;
            Reason = capture.Reason;
        }
        CaptureChanged?.Invoke();
    }

    public void SetHighlight(string? name)
    {
        if (Highlight != name)
        {
            Highlight = name;
            CaptureChanged?.Invoke();
        }
    }

    public (CostColumn Column, bool Descending) SortOf(ProfileCostKind kind) => _sort[kind];

    /// <summary>Sorts a table by a column: the same column again turns the order around.</summary>
    public void SortBy(ProfileCostKind kind, CostColumn column)
    {
        var (current, descending) = _sort[kind];
        _sort[kind] = current == column ? (column, !descending) : (column, column != CostColumn.Name);
        SummaryChanged?.Invoke();
    }

    /// <summary>A table's rows of the latest summary, in its order.</summary>
    public IReadOnlyList<CostRow> Rows(ProfileCostKind kind)
    {
        if (Summary is not { } s)
        {
            return [];
        }
        var total = kind == ProfileCostKind.Pass ? s.GpuMsAverage : s.CpuMsAverage;
        var rows = s.Costs.Where(c => c.Kind == kind)
            .Select(c => new CostRow(c.Name, Detail(c), c.Calls, c.MsAverage, c.MsMax, total > 0 ? 100 * c.MsAverage / total : 0));
        var (column, descending) = _sort[kind];
        Func<CostRow, IComparable> key = column switch
        {
            CostColumn.Name => r => r.Name + " " + r.Detail,
            CostColumn.Calls => r => r.Calls,
            CostColumn.Max => r => r.MaxMs,
            CostColumn.Percent => r => r.Percent,
            _ => r => r.AverageMs,
        };
        return [.. descending ? rows.OrderByDescending(key) : rows.OrderBy(key)];
    }

    static string Detail(ProfileCost c) => c.Kind switch
    {
        ProfileCostKind.Script => CallbackName(c.Callback),
        ProfileCostKind.Pass => c.Queue == 0 ? "graphics" : "compute",
        _ => "",
    };

    /// <summary>A callback as scripts name it: OnEnable is on_enable.</summary>
    public static string CallbackName(ProfileCallback callback) => callback switch
    {
        ProfileCallback.None => "",
        ProfileCallback.Event => "event",
        ProfileCallback.Coroutine => "coroutine",
        _ => string.Concat(callback.ToString().Select((ch, i) => char.IsUpper(ch) ? (i > 0 ? "_" : "") + char.ToLowerInvariant(ch) : ch.ToString())),
    };

    /// <summary>Forgets everything, as when the link closes.</summary>
    public void Clear()
    {
        Summary = null;
        Capture = null;
        Status = CaptureStatus.None;
        Reason = "";
        Highlight = null;
        SummaryChanged?.Invoke();
        CaptureChanged?.Invoke();
    }
}
