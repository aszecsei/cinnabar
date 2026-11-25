using System.Buffers.Binary;
using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Tools;

/// <summary>
/// A sound's peak file, which the cook daemon writes (see docs/content/daemon-and-operations.md#peaks): the lowest and
/// highest sample of any channel in each run of <see cref="FramesPerPeak"/> frames at 48 kHz. Coarser levels, each with
/// half the peaks of the one before, let a column at any zoom read at most a few peaks.
/// </summary>
public sealed class PeakFile
{
    public const int Version = 1;
    public const int HeaderSize = 24;

    /// <summary>A coarser level stops at about this many peaks.</summary>
    const int LeastLevel = 64;

    // Each level's lows and highs, from the file's own peaks up.
    readonly List<(short[] Low, short[] High)> _levels = [];

    public int FramesPerPeak { get; }

    public long Frames { get; }

    public int Count => _levels[0].Low.Length;

    /// <summary>The levels, for tests: 0 is the file's.</summary>
    public int Levels => _levels.Count;

    PeakFile(int framesPerPeak, long frames, short[] low, short[] high)
    {
        FramesPerPeak = framesPerPeak;
        Frames = frames;
        _levels.Add((low, high));
        while (_levels[^1].Low.Length > LeastLevel)
        {
            var (l, h) = _levels[^1];
            var n = (l.Length + 1) / 2;
            var nl = new short[n];
            var nh = new short[n];
            for (var i = 0; i < n; i++)
            {
                var j = Math.Min(2 * i + 1, l.Length - 1);
                nl[i] = Math.Min(l[2 * i], l[j]);
                nh[i] = Math.Max(h[2 * i], h[j]);
            }
            _levels.Add((nl, nh));
        }
    }

    /// <summary>A peak file's contents, or null for one that is not a whole peak file of this version.</summary>
    public static PeakFile? Parse(ReadOnlySpan<byte> data)
    {
        if (data.Length < HeaderSize || !data[..4].SequenceEqual("PEAK"u8)
            || BinaryPrimitives.ReadUInt32LittleEndian(data[4..]) != Version)
        {
            return null;
        }
        var framesPerPeak = BinaryPrimitives.ReadUInt32LittleEndian(data[8..]);
        var frames = BinaryPrimitives.ReadUInt64LittleEndian(data[12..]);
        var count = BinaryPrimitives.ReadUInt32LittleEndian(data[20..]);
        if (framesPerPeak == 0 || frames > long.MaxValue || count != (frames + framesPerPeak - 1) / framesPerPeak
            || data.Length != HeaderSize + (long)count * 4)
        {
            return null;
        }
        var low = new short[count];
        var high = new short[count];
        for (var i = 0; i < count; i++)
        {
            low[i] = BinaryPrimitives.ReadInt16LittleEndian(data[(HeaderSize + i * 4)..]);
            high[i] = BinaryPrimitives.ReadInt16LittleEndian(data[(HeaderSize + i * 4 + 2)..]);
        }
        return new PeakFile((int)framesPerPeak, (long)frames, low, high);
    }

    /// <summary>
    /// The lowest and highest sample from frame <paramref name="from"/> to <paramref name="to"/>, from 0 to
    /// <see cref="Frames"/>, as fractions of full scale, read from the coarsest level that still has two peaks across the
    /// span. Null for a span with no frames.
    /// </summary>
    public (double Low, double High)? Range(double from, double to) =>
        TryRange(LevelFor(to - from), from, to, out var low, out var high) ? (low, high) : null;

    /// <summary>The coarsest level that still has two peaks across a span of this many frames.</summary>
    public int LevelFor(double frames)
    {
        var level = 0;
        while (level + 1 < _levels.Count && FramesPerPeak * (double)(1L << (level + 1)) * 2 <= frames)
        {
            level++;
        }
        return level;
    }

    /// <summary>
    /// <see cref="Range"/> from one level, which a waveform finds once for all of its columns, as they are each as wide.
    /// False for a span with no frames.
    /// </summary>
    public bool TryRange(int level, double from, double to, out double low, out double high)
    {
        from = Math.Max(from, 0);
        to = Math.Min(to, Frames);
        low = high = 0;
        if (to <= from || Count == 0)
        {
            return false;
        }
        var span = (double)FramesPerPeak * (1L << level);
        var (lows, highs) = _levels[level];
        var first = Math.Clamp((int)(from / span), 0, lows.Length - 1);
        var last = Math.Clamp((int)Math.Ceiling(to / span) - 1, first, lows.Length - 1);
        int lo = short.MaxValue, hi = short.MinValue;
        for (var i = first; i <= last; i++)
        {
            lo = Math.Min(lo, lows[i]);
            hi = Math.Max(hi, highs[i]);
        }
        low = lo / 32768.0;
        high = hi / 32768.0;
        return true;
    }
}

/// <summary>
/// An audio section's gain as its waveform shows it: the track's <c>gain</c>, times the section's <c>weight</c>, times
/// its <c>gain</c> channel at a tick of the section, as the runtime reads them (see docs/cinematics/tracks.md#audio-tracks).
/// The eases are left out, as their ramps draw over the bar.
/// </summary>
public sealed record CutsceneGain(double Scale, IReadOnlyList<CurveKey>? Curve, CurveInfinity Pre, CurveInfinity Post)
{
    public static readonly CutsceneGain One = new(1, null, CurveInfinity.Constant, CurveInfinity.Constant);

    public double At(int local) => Math.Max(Scale * (Curve is { Count: > 0 } curve ? CutsceneCurve.Value(curve, local, Pre, Post) : 1), 0);

    /// <summary>An audio section's gain, from its track and its own settings and channel.</summary>
    public static CutsceneGain Of(CutsceneBlock track, CutsceneBlock section)
    {
        static double Number(CutsceneBlock block, string key) =>
            block.Get(key) is { } text && double.TryParse(text, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var value)
                ? Math.Max(value, 0)
                : 1;
        var scale = Number(track, "gain") * Number(section, "weight");
        if (section.Children.FirstOrDefault(c => c.Kind == CutsceneBlockKind.Channel && c.Name == "gain") is { } channel
            && CutsceneCurveEdits.CurveOf(channel) is { Count: > 0 } curve)
        {
            var (pre, post) = CutsceneCurveEdits.InfinityOf(channel);
            return new CutsceneGain(scale, curve, pre, post);
        }
        return scale == 1 ? One : One with { Scale = scale };
    }
}

/// <summary>One pixel's column of a waveform: its x in the time area, and its lowest and highest value, from -1 to 1, after the gain.</summary>
public readonly record struct CutsceneWaveColumn(double X, double Low, double High);

/// <summary>A clip event in a section's bar: its x in the time area, and its name.</summary>
public readonly record struct CutsceneEventTick(double X, string Name);

public static class CutsceneWaveform
{
    /// <summary>Frames of the sound for each tick of the cutscene: 48 kHz at 60,000 ticks a second.</summary>
    public const double FramesPerTick = 48000.0 / CutsceneFile.TicksPerSecond;

    /// <summary>The most loops of a clip whose events a bar shows, so a long bar of a short loop costs a bounded draw.</summary>
    public const int MaxEventLoops = 256;

    /// <summary>The pixels between two reads of a sound's gain curve, which its waveform lerps between.</summary>
    public const double GainStep = 8;

    /// <summary>
    /// A sound section's waveform in view (see docs/editor/cutscene-editor.md#waveforms): a column for each pixel of the
    /// bar's visible part, of the sound from <c>offset + (t - start)</c>, again from its start where the section loops,
    /// and none past its end where it does not. Each column is scaled by the gain at its middle and clamped to full scale.
    /// </summary>
    public static List<CutsceneWaveColumn> Columns(CutsceneTimelineItem bar, CutsceneClipSpan clip, CutsceneGain gain, PeakFile peaks, TimelineView view, double width)
    {
        var columns = new List<CutsceneWaveColumn>();
        var x0 = Math.Max(Math.Floor(view.X(bar.Start)), 0);
        var x1 = Math.Min(Math.Ceiling(view.X(bar.End)), width);
        var frames = (double)peaks.Frames;
        if (frames <= 0)
        {
            return columns;
        }
        // A gain curve is read every GainStep pixels, and lerped between: its keys are far apart beside a pixel, and a
        // read of each column would cost as much as the rest of the column.
        var step = GainStep * view.PerPixel;
        double from = double.NaN, to = double.NaN, gainFrom = 1, gainTo = 1;
        double Gain(double local)
        {
            if (!double.IsNaN(from) && local > to && local <= to + step)
            {
                // The next step, from the columns' left to right, reads the curve once.
                (from, gainFrom) = (to, gainTo);
                to = from + step;
                gainTo = gain.At((int)Math.Round(to));
            }
            else if (double.IsNaN(from) || local < from || local > to)
            {
                from = Math.Floor(local / step) * step;
                to = from + step;
                gainFrom = gain.At((int)Math.Round(from));
                gainTo = gain.At((int)Math.Round(to));
            }
            return gainFrom + (gainTo - gainFrom) * ((local - from) / step);
        }
        var level = peaks.LevelFor(view.PerPixel * FramesPerTick);
        var constant = gain.Curve == null ? gain.At(0) : 0;
        for (var x = x0; x < x1; x++)
        {
            var t0 = Math.Max(view.At(x), bar.Start);
            var t1 = Math.Min(view.At(x + 1), bar.End);
            if (t1 <= t0)
            {
                continue;
            }
            var f0 = (clip.Offset + t0 - bar.Start) * FramesPerTick;
            var f1 = (clip.Offset + t1 - bar.Start) * FramesPerTick;
            double low, high;
            bool found;
            if (!clip.Loop)
            {
                found = peaks.TryRange(level, f0, f1, out low, out high);
            }
            else if (f1 - f0 >= frames)
            {
                found = peaks.TryRange(peaks.LevelFor(frames), 0, frames, out low, out high);
            }
            else
            {
                var w0 = f0 - Math.Floor(f0 / frames) * frames;
                var w1 = w0 + (f1 - f0);
                found = peaks.TryRange(level, w0, Math.Min(w1, frames), out low, out high);
                if (w1 > frames && peaks.TryRange(level, 0, w1 - frames, out var wrappedLow, out var wrappedHigh))
                {
                    (low, high) = found ? (Math.Min(low, wrappedLow), Math.Max(high, wrappedHigh)) : (wrappedLow, wrappedHigh);
                    found = true;
                }
            }
            if (!found)
            {
                continue;
            }
            var g = gain.Curve == null ? constant : Gain((t0 + t1) / 2 - bar.Start);
            columns.Add(new CutsceneWaveColumn(x, Math.Clamp(low * g, -1, 1), Math.Clamp(high * g, -1, 1)));
        }
        return columns;
    }

    /// <summary>
    /// An animation section's clip events in view (see docs/editor/cutscene-editor.md#clip-events): each event at
    /// <c>start + (time - offset) / speed</c>, in each pass of a clip that loops, up to <see cref="MaxEventLoops"/> of
    /// them in view. A clip that does not loop shows the events of its one pass that are inside the section.
    /// </summary>
    public static List<CutsceneEventTick> EventTicks(CutsceneTimelineItem bar, CutsceneClipSpan clip, IReadOnlyList<CutsceneClipEvent> events, TimelineView view, double width)
    {
        var ticks = new List<CutsceneEventTick>();
        if (events.Count == 0)
        {
            return ticks;
        }
        var from = Math.Max(bar.Start, view.At(0));
        var to = Math.Min(bar.End, view.At(width));
        if (to < from)
        {
            return ticks;
        }
        double length = clip.Length, offset = clip.Offset, speed = clip.Speed;
        double At(double u) => bar.Start + (u - offset) / speed;
        void Add(double u, string name)
        {
            var t = At(u);
            if (t >= from && t <= to && t >= bar.Start && t <= bar.End)
            {
                ticks.Add(new CutsceneEventTick(view.X(t), name));
            }
        }
        if (!clip.Loop)
        {
            foreach (var e in events)
            {
                if (e.Tick >= offset && e.Tick <= length)
                {
                    Add(e.Tick, e.Name);
                }
            }
            return ticks;
        }
        var k0 = Math.Floor(((from - bar.Start) * speed + offset) / length);
        var k1 = Math.Min(Math.Floor(((to - bar.Start) * speed + offset) / length), k0 + MaxEventLoops - 1);
        for (var k = k0; k <= k1; k++)
        {
            foreach (var e in events)
            {
                if (e.Tick < length)
                {
                    Add(k * length + e.Tick, e.Name);
                }
            }
        }
        return ticks;
    }
}

/// <summary>An event of a clip in its bound <c>Animator</c>'s graph: its time in the clip, in ticks, and its name.</summary>
public sealed record CutsceneClipEvent(int Tick, string Name);
