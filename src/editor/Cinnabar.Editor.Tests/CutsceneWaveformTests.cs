using System.Buffers.Binary;
using System.Collections.Concurrent;
using Cinnabar.Editor.Cutscenes;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Tests;

/// <summary>Sounds' peak files and the waveforms that audio sections draw from them.</summary>
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
    }
}
