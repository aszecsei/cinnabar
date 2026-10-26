using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Tests;

/// <summary>The profiler without a host: the summary's tables, captures and the timeline's geometry.</summary>
public sealed class ProfilerTests
{
    static ProfileSummary Summary(params ProfileCost[] costs) =>
        new(10, 24, 15, 15, 8, 12, 21, 6, 9, 4, 5, 22, 0, true, costs);

    static ProfileCost Script(string name, ProfileCallback callback, float ms) => new(ProfileCostKind.Script, name, callback, 0, 1, ms, ms * 2);

    static ProfileCost Pass(string name, float ms, byte queue = 0) => new(ProfileCostKind.Pass, name, ProfileCallback.None, queue, 1, ms, ms);

    static ProfileZone Zone(long start, uint duration, ushort name, byte lane = 0, byte depth = 0, ZoneFlags flags = ZoneFlags.None, byte fiber = 0) =>
        new(start, duration, name, 0, lane, depth, (byte)flags, fiber);

    static ProfileCapture Capture(uint id, params ProfileZone[] zones) => new(
        id, 30, true, "", 16_000_000, 10_000_000, 6_000_000, 4_000_000, 1_000_000, 5_000_000, 0,
        [new("Game update", ProfileCategory.Frame), new("spin", ProfileCategory.System), new("Door", ProfileCategory.Script), new("prepass", ProfileCategory.Render)],
        [new("Main", ProfileLaneKind.Thread), new("Worker 1", ProfileLaneKind.Thread), new("Worker 2", ProfileLaneKind.Thread), new("GPU graphics", ProfileLaneKind.GpuGraphics)],
        zones);

    [Fact]
    public void RowsArePerKindAndShareOfTheirFrameTime()
    {
        var model = new ProfilerModel();
        model.Apply(Summary(Script("Door", ProfileCallback.Update, 2), Script("Door", ProfileCallback.OnEnable, 0.5f), Pass("prepass", 1), Pass("ao", 3, 1)));

        var scripts = model.Rows(ProfileCostKind.Script);
        Assert.Equal(["update", "on_enable"], scripts.Select(r => r.Detail));
        // Scripts share the CPU time, 8 ms, and passes the GPU time, 4 ms.
        Assert.Equal(25, scripts[0].Percent, 3);
        var passes = model.Rows(ProfileCostKind.Pass);
        Assert.Equal(["ao", "prepass"], passes.Select(r => r.Name));
        Assert.Equal("compute", passes[0].Detail);
        Assert.Equal(75, passes[0].Percent, 3);
        Assert.Empty(model.Rows(ProfileCostKind.System));
    }

    [Fact]
    public void SortingByAColumnAgainTurnsItAround()
    {
        var model = new ProfilerModel();
        model.Apply(Summary(Pass("b", 1), Pass("a", 3), Pass("c", 2)));
        model.SortBy(ProfileCostKind.Pass, CostColumn.Name);
        Assert.Equal(["a", "b", "c"], model.Rows(ProfileCostKind.Pass).Select(r => r.Name));
        model.SortBy(ProfileCostKind.Pass, CostColumn.Name);
        Assert.Equal(["c", "b", "a"], model.Rows(ProfileCostKind.Pass).Select(r => r.Name));
        // Other tables keep their own order.
        Assert.Equal((CostColumn.Average, true), model.SortOf(ProfileCostKind.Script));
    }

    [Fact]
    public void OnlyTheAnswerToTheLatestRequestCounts()
    {
        var model = new ProfilerModel();
        var first = model.Request(ProfileCaptureMode.Next);
        var second = model.Request(ProfileCaptureMode.WorstRecent, count: 60);
        Assert.NotEqual(first.Id, second.Id);
        Assert.Equal((ProfileCaptureMode.WorstRecent, 60u), (second.Mode, second.Count));

        model.Apply(Capture(first.Id));
        Assert.Equal(CaptureStatus.Waiting, model.Status);
        Assert.Null(model.Capture);
        model.Apply(Capture(second.Id) with { Available = false, Reason = "gone" });
        Assert.Equal((CaptureStatus.Unavailable, "gone"), (model.Status, model.Reason));

        var third = model.Request(ProfileCaptureMode.Frame, frame: 30);
        model.Apply(Capture(third.Id, Zone(0, 100, 0)));
        Assert.Equal(CaptureStatus.Captured, model.Status);
        Assert.Equal(30ul, model.Capture!.Frame);
    }

    [Fact]
    public void ACaptureHasRowsByDepthAndSelfTimes()
    {
        var capture = FrameCapture.From(Capture(1,
            Zone(100, 900, 0),
            Zone(200, 300, 1, depth: 1),
            Zone(600, 100, 2, depth: 1),
            Zone(0, 8_000_000, 1, lane: 1),
            Zone(2_000_000, 1_000_000, 3, lane: 3)));

        var main = capture.Lanes[0];
        Assert.Equal(2, main.Rows.Count);
        var update = main.Rows[0][0];
        Assert.Equal(500, update.Self);
        Assert.Equal(ProfileCategory.Frame, update.Category);
        Assert.Same(main.Rows[1][1], main.At(1, 650));
        Assert.Null(main.At(1, 550));
        Assert.Equal(0.5, capture.Lanes[1].Busy, 3);
        // Worker 2 ran nothing, and the GPU lane has the pass.
        Assert.Empty(capture.Lanes[2].Rows);
        Assert.True(capture.Lanes[3].IsGpu);
        Assert.Equal((2, 8_000_300L), capture.Occurrences("spin"));
        Assert.True(capture.HasGpu);
        Assert.Equal(4, capture.GpuMs, 3);
    }

    [Fact]
    public void AZoneThatWaitedHasLinkedSegments()
    {
        var capture = FrameCapture.From(Capture(1,
            Zone(0, 100, 1, lane: 1, depth: 1, flags: ZoneFlags.Suspended, fiber: 7),
            Zone(500, 200, 1, lane: 2, depth: 1, flags: ZoneFlags.Resumed, fiber: 7),
            Zone(0, 100, 1, lane: 0, depth: 1, fiber: 3)));
        var first = capture.Lanes[1].Rows[1][0];
        Assert.True(first.Split);
        Assert.Equal(2, capture.Segments(first).Count());
        // Resumed segments are the same zone, so they do not count again.
        Assert.Equal(2, capture.Occurrences("spin").Count);
    }

    [Fact]
    public void OverlappingSpansAreFoundAtEveryTime()
    {
        // GPU passes on one queue can overlap: a long one hides under the next starts.
        var capture = FrameCapture.From(Capture(1, Zone(0, 1000, 3, lane: 3), Zone(100, 50, 3, lane: 3), Zone(200, 50, 3, lane: 3)));
        var gpu = capture.Lanes[3];
        Assert.Equal(0, gpu.FirstReaching(0, 500));
        Assert.Equal(1000, gpu.At(0, 500)!.Duration);
        Assert.Equal(50, gpu.At(0, 120)!.Duration);
    }

    [Fact]
    public void ASummaryGoesWithTheNextHostStats()
    {
        var stats = new ResourceStats();
        stats.Apply(new HostStats(0.25f, 15, 16, 20, 9, 12, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0));
        stats.Apply(Summary());
        stats.Apply(new HostStats(0.25f, 15, 16, 20, 9, 12, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0));
        stats.Apply(new HostStats(0.25f, 15, 16, 20, 9, 12, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0));
        var samples = stats.History.ToArray();
        Assert.Equal([false, true, false], samples.Select(s => s.Profiled));
        Assert.Equal((8.0, 4.0, 21ul, 22ul), (samples[1].CpuMs, samples[1].GpuMs, samples[1].CpuWorstFrame, samples[1].GpuWorstFrame));
    }

    [Fact]
    public void TheTimelineZoomsAroundThePointer()
    {
        var view = TimelineView.Fit(0, 16_000_000, 1000);
        Assert.True(view.Start < 0 && view.End(1000) > 16_000_000);
        var at = view.Ns(250);
        var zoomed = view.ZoomAbout(250, 0.5);
        Assert.Equal(at, zoomed.Ns(250), 3);
        Assert.Equal(view.NsPerPixel / 2, zoomed.NsPerPixel, 6);
        Assert.Equal(TimelineView.MinNsPerPixel, view.ZoomAbout(0, 1e-9).NsPerPixel);
        Assert.Equal(view.Start - 10 * view.NsPerPixel, view.Pan(10).Start, 3);
    }

    [Fact]
    public void NarrowZonesMergeIntoRuns()
    {
        var runs = TimelineGeometry.Runs([(0, 10), (10.2, 10.4), (10.5, 10.7), (10.8, 11.0), (50, 50.1), (60, 70)]);
        Assert.Equal([(0, 1), (1, 3), (4, 1), (5, 1)], runs.Select(r => (r.First, r.Count)));
        Assert.True(runs[1].X1 - runs[1].X0 >= 1);
        Assert.Equal("850 ns", TimelineGeometry.Duration(850));
        Assert.Equal("12.5 µs", TimelineGeometry.Duration(12_500));
        Assert.Equal("3.20 ms", TimelineGeometry.Duration(3_200_000));
        Assert.Equal(200_000, TimelineGeometry.TickSpacing(2_000, 80));
    }
}
