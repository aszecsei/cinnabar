using Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Model;

/// <summary>The flags of a captured zone, as profile.Zone_Flags has them.</summary>
[Flags]
public enum ZoneFlags : byte
{
    None = 0,
    /// <summary>The segment ends where its fiber suspended. The zone goes on in a Resumed segment.</summary>
    Suspended = 1,
    /// <summary>The segment starts where its fiber resumed, maybe on another thread.</summary>
    Resumed = 2,
    /// <summary>The whole of a job, named after the zone that started it.</summary>
    Job = 4,
    /// <summary>The zone was still open when its code ended, so the profiler closed it.</summary>
    Unbalanced = 8,
}

/// <summary>A zone's segment on a thread, or a GPU span on a GPU lane. Times are nanoseconds from the frame's start.</summary>
public sealed record CapturedZone(
    long Start,
    long Duration,
    string Name,
    ProfileCategory Category,
    ushort Detail,
    int Lane,
    int Depth,
    ZoneFlags Flags,
    int Fiber)
{
    public long End => Start + Duration;

    /// <summary>The time without the zones nested in it on its lane.</summary>
    public long Self { get; internal set; }

    /// <summary>A Script zone's callback, from its detail.</summary>
    public ProfileCallback Callback => Category == ProfileCategory.Script ? (ProfileCallback)Detail : ProfileCallback.None;

    /// <summary>The zone has other segments on its fiber: it waited inside.</summary>
    public bool Split => Fiber != 0 && (Flags & (ZoneFlags.Suspended | ZoneFlags.Resumed)) != 0;
}

/// <summary>A lane of a capture: a thread, or a GPU queue. Its zones are in rows by depth, each sorted by start.</summary>
public sealed class CaptureLane(string name, ProfileLaneKind kind)
{
    readonly List<List<CapturedZone>> _rows = [];

    public string Name { get; } = name;

    public ProfileLaneKind Kind { get; } = kind;

    public IReadOnlyList<IReadOnlyList<CapturedZone>> Rows => _rows;

    /// <summary>The part of the frame that the lane's outermost zones cover, from 0 to 1.</summary>
    public double Busy { get; internal set; }

    public bool IsGpu => Kind != ProfileLaneKind.Thread;

    readonly List<long[]> _reach = [];

    /// <summary>
    /// For each row, the latest end of its zones up to each index. It never decreases, so a binary search finds the
    /// first zone that can reach a time, even where zones overlap, as GPU passes do.
    /// </summary>
    internal IReadOnlyList<long[]> Reach => _reach;

    internal void Sort()
    {
        _reach.Clear();
        foreach (var row in _rows)
        {
            row.Sort((a, b) => a.Start.CompareTo(b.Start));
            var reach = new long[row.Count];
            var latest = long.MinValue;
            for (var i = 0; i < row.Count; i++)
            {
                latest = Math.Max(latest, row[i].End);
                reach[i] = latest;
            }
            _reach.Add(reach);
        }
    }

    /// <summary>The index of the first zone of a row that can still be running at time.</summary>
    public int FirstReaching(int depth, long time)
    {
        var reach = _reach[depth];
        int lo = 0, hi = reach.Length;
        while (lo < hi)
        {
            var mid = (lo + hi) / 2;
            if (reach[mid] <= time)
            {
                lo = mid + 1;
            }
            else
            {
                hi = mid;
            }
        }
        return lo;
    }

    /// <summary>The shortest zone of a row that covers a time, if any.</summary>
    public CapturedZone? At(int depth, long time)
    {
        var row = _rows[depth];
        CapturedZone? found = null;
        for (var i = FirstReaching(depth, time); i < row.Count && row[i].Start <= time; i++)
        {
            if (row[i].End > time && (found == null || row[i].Duration < found.Duration))
            {
                found = row[i];
            }
        }
        return found;
    }

    internal List<CapturedZone> Row(int depth)
    {
        while (_rows.Count <= depth)
        {
            _rows.Add([]);
        }
        return _rows[depth];
    }
}

/// <summary>
/// A frame that the host captured (see docs/editor/shell-and-panels.md#profiler): its times, and its zones by lane and
/// depth. Built once from the message, so drawing and hit testing only read it.
/// </summary>
public sealed class FrameCapture
{
    FrameCapture(ProfileCapture message, List<CaptureLane> lanes, List<CapturedZone> zones)
    {
        Message = message;
        Lanes = lanes;
        Zones = zones;
    }

    public ProfileCapture Message { get; }

    public ulong Frame => Message.Frame;

    public long FrameNs => (long)Message.FrameNs;

    public double FrameMs => Message.FrameNs / 1e6;

    public double CpuMs => Message.CpuNs / 1e6;

    public double WaitMs => Message.WaitNs / 1e6;

    public double GpuMs => Message.GpuNs / 1e6;

    public bool HasGpu => Message.GpuEnd > Message.GpuBegin;

    public IReadOnlyList<CaptureLane> Lanes { get; }

    public IReadOnlyList<CapturedZone> Zones { get; }

    /// <summary>The earliest start and the latest end of the zones and the frame, for fitting the view.</summary>
    public (long Start, long End) Extent
    {
        get
        {
            var start = Math.Min(0, Zones.Count == 0 ? 0 : Zones.Min(z => z.Start));
            var end = Math.Max(FrameNs, Zones.Count == 0 ? 0 : Zones.Max(z => z.End));
            return (start, Math.Max(end, start + 1));
        }
    }

    public static FrameCapture From(ProfileCapture message)
    {
        var lanes = message.Lanes.Select(l => new CaptureLane(l.Name, l.Kind)).ToList();
        var zones = new List<CapturedZone>(message.Zones.Length);
        foreach (var z in message.Zones)
        {
            if (z.Lane >= lanes.Count)
            {
                continue;
            }
            var name = z.Name < message.Names.Length ? message.Names[z.Name] : new ProfileName("?", ProfileCategory.Frame);
            var zone = new CapturedZone(z.Start, z.Duration, name.Text, name.Category, z.Detail, z.Lane, z.Depth, (ZoneFlags)z.Flags, z.Fiber);
            zones.Add(zone);
            lanes[z.Lane].Row(z.Depth).Add(zone);
        }
        foreach (var lane in lanes)
        {
            lane.Sort();
            ComputeSelf(lane);
            lane.Busy = Covered(lane, message.FrameNs);
        }
        return new FrameCapture(message, lanes, zones);
    }

    /// <summary>A zone's time without the zones on the next row of its lane that start inside it.</summary>
    static void ComputeSelf(CaptureLane lane)
    {
        for (var d = 0; d < lane.Rows.Count; d++)
        {
            var row = lane.Rows[d];
            var children = d + 1 < lane.Rows.Count ? lane.Rows[d + 1] : [];
            var c = 0;
            foreach (var zone in row)
            {
                while (c < children.Count && children[c].Start < zone.Start)
                {
                    c++;
                }
                long nested = 0;
                for (var i = c; i < children.Count && children[i].Start < zone.End; i++)
                {
                    nested += Math.Min(children[i].End, zone.End) - children[i].Start;
                }
                zone.Self = Math.Max(zone.Duration - nested, 0);
            }
        }
    }

    /// <summary>The part of [0, frame) that a lane's outermost zones cover.</summary>
    static double Covered(CaptureLane lane, ulong frame)
    {
        if (frame == 0 || lane.Rows.Count == 0)
        {
            return 0;
        }
        long covered = 0;
        long reached = 0;
        foreach (var z in lane.Rows[0])
        {
            var start = Math.Max(z.Start, reached);
            var end = Math.Min(z.End, (long)frame);
            if (end > start)
            {
                covered += end - start;
            }
            reached = Math.Max(reached, z.End);
        }
        return Math.Clamp(covered / (double)frame, 0, 1);
    }

    /// <summary>The other segments of a zone that waited, on any lane: the same fiber, name and depth.</summary>
    public IEnumerable<CapturedZone> Segments(CapturedZone zone) =>
        zone.Split ? Zones.Where(z => z.Fiber == zone.Fiber && z.Depth == zone.Depth && z.Name == zone.Name && z.Split) : [zone];

    /// <summary>How many zones of a name the frame has, not counting resumed segments, and their time.</summary>
    public (int Count, long Total) Occurrences(string name, int lane = -1)
    {
        var count = 0;
        long total = 0;
        foreach (var z in Zones)
        {
            if (z.Name == name && (lane < 0 || z.Lane == lane))
            {
                total += z.Duration;
                count += (z.Flags & ZoneFlags.Resumed) == 0 ? 1 : 0;
            }
        }
        return (count, total);
    }
}
