using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using Cinnabar.Editor.Cutscenes;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Tools;
using L = Cinnabar.Editor.Tools.CutsceneTimelineLayout;

namespace Cinnabar.Editor.Tests;

/// <summary>Sounds' peak files, the waveforms that audio sections draw from them, and clips' events in animation sections.</summary>
public sealed class CutsceneWaveformTests
{
    // A tick a pixel per thousand, from 0: tick t is at x = t / 1000 in the time area, 800 frames of sound a pixel.
    static readonly TimelineView Thousand = new(0, 1000, TimelineZoom.Ticks);

    /// <summary>A peak file as the daemon writes it, of these peaks, each of framesPerPeak frames but the last.</summary>
    public static byte[] PeakBytes(long frames, int framesPerPeak, Func<int, (short Low, short High)> peak)
    {
        var count = (int)((frames + framesPerPeak - 1) / framesPerPeak);
        var data = new byte[PeakFile.HeaderSize + count * 4];
        "PEAK"u8.CopyTo(data);
        BinaryPrimitives.WriteUInt32LittleEndian(data.AsSpan(4), PeakFile.Version);
        BinaryPrimitives.WriteUInt32LittleEndian(data.AsSpan(8), (uint)framesPerPeak);
        BinaryPrimitives.WriteUInt64LittleEndian(data.AsSpan(12), (ulong)frames);
        BinaryPrimitives.WriteUInt32LittleEndian(data.AsSpan(20), (uint)count);
        for (var i = 0; i < count; i++)
        {
            var (low, high) = peak(i);
            BinaryPrimitives.WriteInt16LittleEndian(data.AsSpan(PeakFile.HeaderSize + i * 4), low);
            BinaryPrimitives.WriteInt16LittleEndian(data.AsSpan(PeakFile.HeaderSize + i * 4 + 2), high);
        }
        return data;
    }

    [Fact]
    public void APeakFileReadsItsPeaksAndCoarserLevelsGiveTheSameRanges()
    {
        var data = PeakBytes(1000 * 256, 256, i => ((short)-i, (short)i));
        var peaks = PeakFile.Parse(data)!;
        Assert.Equal((256, 256000L, 1000), (peaks.FramesPerPeak, peaks.Frames, peaks.Count));
        // 1000, 500, 250, 125 and 63 peaks.
        Assert.Equal(5, peaks.Levels);

        static (double, double) Full(int low, int high) => (low / 32768.0, high / 32768.0);
        Assert.Equal(Full(0, 0), peaks.Range(0, 256));
        Assert.Equal(Full(-11, 11), peaks.Range(256 * 10, 256 * 12));
        // Eight peaks read two of the third level, which cover the same eight.
        Assert.Equal(Full(-7, 7), peaks.Range(0, 256 * 8));
        Assert.Equal(Full(-999, 999), peaks.Range(-100, 1e9));
        Assert.Null(peaks.Range(256000, 300000));
        Assert.Null(peaks.Range(10, 10));

        // Not a whole peak file of this version.
        Assert.Null(PeakFile.Parse(data.AsSpan(0, data.Length - 1)));
        Assert.Null(PeakFile.Parse(data.AsSpan(0, 10)));
        var magic = (byte[])data.Clone();
        magic[0] = (byte)'X';
        Assert.Null(PeakFile.Parse(magic));
        var version = (byte[])data.Clone();
        BinaryPrimitives.WriteUInt32LittleEndian(version.AsSpan(4), PeakFile.Version + 1);
        Assert.Null(PeakFile.Parse(version));
        var count = (byte[])data.Clone();
        BinaryPrimitives.WriteUInt32LittleEndian(count.AsSpan(20), 999);
        Assert.Null(PeakFile.Parse(count));
        // A sound with no frames has no peaks, and no columns.
        Assert.Equal(0, PeakFile.Parse(PeakBytes(0, 256, _ => (0, 0)))!.Count);
    }

    // A second of sound, silent for its first half and at half scale for its second: at 800 frames a pixel, x = 30 is
    // where it starts to sound and x = 60 where it ends.
    static PeakFile HalfSilent() => PeakFile.Parse(PeakBytes(48000, 256, i => i >= 94 ? ((short)-16384, (short)16384) : ((short)0, (short)0)))!;

    static CutsceneTimelineItem Bar(int start, int end) => new(CutsceneItemKind.Section, start, end, "section:1");

    [Fact]
    public void AWaveformsColumnsFollowTheOffsetTheLoopAndTheGainCurve()
    {
        var peaks = HalfSilent();
        var bar = Bar(0, 120000);
        var clip = new CutsceneClipSpan(0, 1, false, 60000);

        // With no loop, the sound ends at x = 60, and the rest of the bar has no columns.
        var once = CutsceneWaveform.Columns(bar, clip, CutsceneGain.One, peaks, Thousand, 1000);
        Assert.Equal(60, once.Count);
        Assert.Equal((0.0, 0.0), (once[10].Low, once[10].High));
        Assert.Equal((-0.5, 0.5), (once[40].Low, once[40].High));
        Assert.Equal(59, once[^1].X);

        // Looping, it starts again at x = 60: silent at 70, sounding at 90.
        var looped = CutsceneWaveform.Columns(bar, clip with { Loop = true }, CutsceneGain.One, peaks, Thousand, 1000);
        Assert.Equal(120, looped.Count);
        Assert.Equal(0.0, looped[70].High);
        Assert.Equal(0.5, looped[90].High);

        // An offset of half a second starts it where it sounds, and it ends half a second sooner.
        var offset = CutsceneWaveform.Columns(bar, clip with { Offset = 30000 }, CutsceneGain.One, peaks, Thousand, 1000);
        Assert.Equal(30, offset.Count);
        Assert.Equal(0.5, offset[0].High);

        // Only the part of the bar in view has columns.
        var panned = CutsceneWaveform.Columns(bar, clip, CutsceneGain.One, peaks, Thousand with { Start = 50000 }, 5);
        Assert.Equal([0.0, 1, 2, 3, 4], panned.Select(c => c.X));

        // The track's gain times the section's weight times its gain channel at each column's middle, clamped to full scale.
        var file = CutsceneFile.Parse("cutscene 1\nlength = 120000\nrate = 30\ntrack 1 audio\n\tgain = 0.5\n\tsection 1 0 120000\n\t\tasset = $00000000000000000000000000000001\n\t\tweight = 2\n\t\tchannel gain\n\t\t\tkey 0 1 linear\n\t\t\tkey 120000 3 linear\n").File!;
        var track = file.Tracks.Single();
        var gain = CutsceneGain.Of(track, track.Children.First(c => c.Kind == CutsceneBlockKind.Section));
        Assert.Equal(1, gain.At(0), 5);
        Assert.Equal(2, gain.At(60000), 5);
        var loud = CutsceneWaveform.Columns(bar, clip, gain, peaks, Thousand, 1000);
        // At x = 40, the middle is 40,500: a gain of 1 + 2 × 40,500 / 120,000.
        Assert.Equal(0.5 * (1 + 2 * 40500 / 120000.0), loud[40].High, 5);
        Assert.Equal(-loud[40].High, loud[40].Low);
        Assert.Equal(1.0, CutsceneWaveform.Columns(bar, clip, gain with { Scale = 10 }, peaks, Thousand, 1000)[40].High);
    }

    // The intro's music, which loops with a gain channel, and its fox walk clip, by GUID.
    const string Music = "ac87e25625175689bc0e47ad70107ebe";
    const string Walk = "dea303d3f0374a9e56b0bb58f4a85315";

    static readonly IReadOnlyList<CutsceneClipEvent> Steps = [new(12000, "footstep \"right\""), new(61000, "footstep \"left\"")];

    static L Intro() => L.Build(
        CutsceneFile.Parse(CutsceneFileTests.Sample("intro").ReplaceLineEndings("\n")).File!, new HashSet<string>(), null, null,
        guid => guid switch
        {
            Music => new CutsceneClipInfo("ambience", 600000, "cache/peaks/music.peaks"),
            Walk => new CutsceneClipInfo("Walk", 100000, "never read"),
            _ => null,
        },
        (track, clip) => clip == Walk && track.Get("binding") == "1" ? Steps : []);

    [Fact]
    public void ASoundsBarCarriesItsPeakFileAndItsGainAndAnAnimationsItsEvents()
    {
        var layout = Intro();
        var music = layout.Rows.First(r => r.Path == "track:7").Bars.Single();
        Assert.Equal("cache/peaks/music.peaks", music.Peaks);
        // The music's gain channel: 0.6 at its start and 1 at 200,000.
        Assert.Equal(0.6, music.Gain.At(0), 5);
        Assert.Equal(1, music.Gain.At(200000), 5);
        Assert.Empty(music.Events);

        var walk = layout.Rows.First(r => r.Path == "track:2").Bars.Single();
        Assert.Null(walk.Peaks);
        Assert.Equal(Steps, walk.Events);
    }

    [Fact]
    public void AClipsEventsAreTicksInEachLoopAndHoverShowsTheirNames()
    {
        var loop = new CutsceneClipSpan(0, 1, true, 100000);
        double[] Xs(CutsceneClipSpan clip, int width = 1000) => [.. CutsceneWaveform.EventTicks(Bar(0, 250000), clip, Steps, Thousand, width).Select(t => t.X)];

        Assert.Equal([12.0, 61, 112, 161, 212], Xs(loop));
        // An offset of 30,000 moves each pass back, and the first step is before the section.
        Assert.Equal([31.0, 82, 131, 182, 231], Xs(loop with { Offset = 30000 }));
        // Twice as fast, and with no loop, one pass, then the pose holds.
        Assert.Equal([6.0, 30.5], Xs(loop with { Loop = false, Speed = 2 }));
        Assert.Equal([31.0], Xs(loop with { Loop = false, Offset = 30000 }));
        // Only those in view.
        Assert.Equal([12.0, 61], Xs(loop, 100));
        Assert.Equal("footstep \"left\"", CutsceneWaveform.EventTicks(Bar(0, 250000), loop, Steps, Thousand, 1000)[1].Name);

        // A hover in the bottom of the walk's bar, near a step, names it. The intro's walk loops from its start.
        var layout = Intro();
        var row = layout.Rows.First(r => r.Path == "track:2");
        var bottom = L.RulerHeight + row.Top + L.RowHeight - 2;
        var view = new TimelineView(0, 1000, TimelineZoom.Ticks);
        Assert.Equal(["footstep \"right\""], layout.EventsAt(L.Gutter + 13, bottom, view, 0, 1000));
        Assert.Equal(["footstep \"left\""], layout.EventsAt(L.Gutter + 161, bottom, view, 0, 1000));
        Assert.Null(layout.EventsAt(L.Gutter + 30, bottom, view, 0, 1000));
        // Above the band, the point is the section's.
        Assert.Null(layout.EventsAt(L.Gutter + 12, L.RulerHeight + row.Top + L.RowHeight / 2, view, 0, 1000));
        // The music's row has no events.
        var music = layout.Rows.First(r => r.Path == "track:7");
        Assert.Null(layout.EventsAt(L.Gutter + 12, L.RulerHeight + music.Top + L.RowHeight - 2, view, 0, 1000));
    }

    [Fact]
    public void APeakFileReadsOffTheThreadThatAsksAndAFileThatFailsIsNotReadAgain()
    {
        var posted = new BlockingCollection<Action>();
        var release = new ManualResetEventSlim();
        var reads = 0;
        var bytes = PeakBytes(48000, 256, _ => (-1, 1));
        var cache = new WaveformCache(posted.Add, path =>
        {
            Interlocked.Increment(ref reads);
            release.Wait(TimeSpan.FromSeconds(10));
            return path == "bad" ? throw new IOException("gone") : bytes;
        });
        var loaded = new List<string>();
        cache.Loaded += loaded.Add;

        // The read waits on the disk, and the asker does not.
        Assert.Null(cache.Get("good"));
        Assert.Null(cache.Get("good"));
        Assert.Null(cache.Get("bad"));
        release.Set();
        for (var i = 0; i < 2; i++)
        {
            Assert.True(posted.TryTake(out var post, TimeSpan.FromSeconds(10)));
            post();
        }
        Assert.Equal(["bad", "good"], loaded.Order());
        Assert.Equal(48000, cache.Get("good")!.Frames);

        // A file that failed stays failed: no second read.
        Assert.Null(cache.Get("bad"));
        Assert.Null(cache.Get("bad"));
        Assert.Equal(2, reads);
        Assert.False(posted.TryTake(out _, TimeSpan.FromMilliseconds(50)));
    }
}

/// <summary>The cost of 30 audio sections' waveforms. It measures time, so it runs alone.</summary>
[Collection(TimingCollection.Name)]
public sealed class CutsceneWaveformCostTests
{
    [Fact]
    public void ThirtyAudioSectionsDrawTheirWaveformsAsTheTimelineScrolls()
    {
        // Thirty sounds of ten seconds, looping over a minute each, on thirty tracks.
        var text = new StringBuilder("cutscene 1\nlength = 3600000\nrate = 30\n");
        for (var t = 1; t <= 30; t++)
        {
            text.Append($"track {t} audio \"Sound {t}\"\n\tsection {t} {t * 1000} 3600000\n\t\tasset = ${t:x32}\n\t\tloop = true\n\t\tchannel gain\n\t\t\tkey 0 0.5 auto\n\t\t\tkey 1800000 1 auto\n");
        }
        var file = CutsceneFile.Parse(text.ToString()).File!;
        var peaks = PeakFile.Parse(CutsceneWaveformTests.PeakBytes(480000, 256, i => ((short)(-(i * 37 % 30000)), (short)(i * 53 % 30000))))!;
        // Half the files have not read yet, so those sections draw plain.
        var layout = L.Build(file, new HashSet<string>(), clipInfo: guid => new CutsceneClipInfo("sound", 600000, Convert.ToInt32(guid, 16) % 2 == 0 ? "read" : "reading"));

        double Frame(TimelineView view)
        {
            var watch = Stopwatch.StartNew();
            var columns = 0;
            foreach (var row in layout.Visible(view, 1400, 0, 2000))
            {
                foreach (var bar in row.Bars)
                {
                    if (bar.Item is { Peaks: "read", Clip: { } clip })
                    {
                        columns += CutsceneWaveform.Columns(bar.Item, clip, bar.Item.Gain, peaks, view, 1400).Count;
                    }
                }
            }
            watch.Stop();
            Assert.True(columns > 0);
            return watch.Elapsed.TotalMilliseconds;
        }

        // The whole minute in view, then a scroll across it at about ten seconds wide.
        var whole = TimelineView.Fit(0, 3600000, 1400, TimelineZoom.Ticks);
        for (var i = 0; i < 10; i++)
        {
            Frame(whole);
        }
        var times = new List<double>();
        for (var i = 0; i < 20; i++)
        {
            times.Add(Frame(whole));
        }
        var zoomed = TimelineView.Fit(0, 600000, 1400, TimelineZoom.Ticks);
        for (var i = 0; i < 60; i++)
        {
            times.Add(Frame(zoomed.Pan(-i * 100)));
        }
        times.Sort();
        var median = times[times.Count / 2];
        Assert.True(median < 4, $"the median frame of waveforms took {median:F2} ms");
    }
}
