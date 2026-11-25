using System.Text.Json;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Tests;

// The editor's side of render out (see docs/editor/cutscene-editor.md#render-out): the run's states and their one writer,
// the tickets that answers are matched by, and what a run writes beside the host's frames.
public sealed class RenderOutModelTests : IDisposable
{
    readonly List<ILinkMessage> _sent = [];
    readonly string _folder = Path.Combine(Path.GetTempPath(), $"cinnabar-render-model-{Guid.NewGuid():N}");

    public void Dispose()
    {
        if (Directory.Exists(_folder))
        {
            Directory.Delete(_folder, true);
        }
    }

    RenderOutSettings Settings(bool video = false) => new(new byte[16], "intro", 120000, 180000, 30, 320, 180, RenderOutFormat.Png, 0, 2,
        _folder, RenderOutSettings.DefaultPattern, true, video);

    [Fact]
    public void TheFramesAndTheFirstFrameComeFromTheRangeAtTheRate()
    {
        var s = Settings();
        Assert.Equal(30, s.FrameCount);
        Assert.Equal(60, s.FirstFrame);
        // A range that ends inside a frame has that frame.
        Assert.Equal(31, (s with { RangeEnd = 180001 }).FrameCount);
        Assert.Equal(25, (s with { Rate = 25, RangeEnd = 180000 }).FrameCount);
        Assert.Contains("below 15", (s with { Rate = 10 }).Refusal);
        Assert.Contains("{frame}", (s with { Pattern = "{name}.png" }).Refusal);
        Assert.Contains("HDR", (s with { Format = RenderOutFormat.Exr }).Refusal);
        Assert.Null(s.Refusal);
    }

    [Fact]
    public async Task ARunGoesFromStartingToRunningToIdleAndAnswersOnlyItsTicket()
    {
        var model = new RenderOutModel(_sent.Add);
        var owner = new object();
        var run = model.RunAsync(Settings(), owner, describe: tick => new RenderOutFrameTime($"t{tick}", tick / 2000, "Wide"));
        var begin = Assert.IsType<RenderOutBegin>(Assert.Single(_sent));
        Assert.Equal((30, 120000, true), (begin.FrameCount, begin.RangeStart, begin.Audio));
        Assert.IsType<RenderOutState.Starting>(model.State);
        // A second run waits for the first.
        var refused = await model.RunAsync(Settings(), owner);
        Assert.Equal(RenderOutOutcome.Failed, refused.Outcome);

        // An answer of another ticket is not this run's.
        Assert.False(model.Apply(new RenderOutProgress(begin.Ticket + 1, RenderOutStage.Rendering, 0)));
        Assert.True(model.Apply(new RenderOutProgress(begin.Ticket, RenderOutStage.Warming, 0)));
        Assert.IsType<RenderOutState.Running>(model.State);

        Directory.CreateDirectory(_folder);
        var frame = Path.Combine(_folder, "intro.000060.png");
        File.WriteAllBytes(frame, [1]);
        model.Apply(new RenderOutFrame(begin.Ticket, 0, 120000, 5, 40));
        model.Apply(new RenderOutWritten(begin.Ticket, 0, true, "", frame, 320, 180));
        var running = Assert.IsType<RenderOutState.Running>(model.State);
        Assert.Equal((1, 1, 30), (running.Progress.Drawn, running.Progress.Written, running.Progress.Total));
        Assert.Equal(TimeSpan.FromMilliseconds(40 * 29), running.Progress.Left);

        // The frame's sidecar has its number from the cutscene's start, its time and shot, and how long it waited.
        using (var sidecar = JsonDocument.Parse(File.ReadAllText(Path.ChangeExtension(frame, ".json"))))
        {
            var root = sidecar.RootElement;
            Assert.Equal("render_out", root.GetProperty("kind").GetString());
            Assert.Equal(60, root.GetProperty("frame").GetInt32());
            Assert.Equal(120000, root.GetProperty("tick").GetInt32());
            Assert.Equal("t120000", root.GetProperty("timecode").GetString());
            Assert.Equal("Wide", root.GetProperty("shot").GetString());
            Assert.Equal(5u, root.GetProperty("settleDraws").GetUInt32());
        }

        var ended = 0;
        model.GameEnded += () => ended++;
        model.Apply(new RenderOutWritten(begin.Ticket, -1, true, "", Path.Combine(_folder, "intro.wav"), 0, 0));
        model.Apply(new RenderOutEnded(begin.Ticket, RenderOutOutcome.Done, "", 1));
        var result = await run;
        Assert.Equal(1, ended);
        Assert.Equal((RenderOutOutcome.Done, 1), (result.Outcome, result.Frames));
        Assert.Equal(Path.Combine(_folder, "intro.wav"), result.Audio);
        Assert.Equal(RenderOutOutcome.Done, Assert.IsType<RenderOutState.Idle>(model.State).Last!.Outcome);
        // The run is over, so its messages are no one's.
        Assert.False(model.Apply(new RenderOutEnded(begin.Ticket, RenderOutOutcome.Done, "", 1)));
    }

    [Fact]
    public async Task ClosingTheOwnerCancelsAndALostLinkEndsTheRun()
    {
        var model = new RenderOutModel(_sent.Add);
        var owner = new object();
        var first = model.RunAsync(Settings(), owner);
        var ticket = Assert.IsType<RenderOutBegin>(_sent[^1]).Ticket;
        model.OnOwnerClosed(new object());
        Assert.IsType<RenderOutState.Starting>(model.State);
        model.OnOwnerClosed(owner);
        Assert.Equal(new RenderOutCancel(ticket), _sent[^1]);
        Assert.IsType<RenderOutState.Cancelling>(model.State);
        model.Apply(new RenderOutEnded(ticket, RenderOutOutcome.Cancelled, "", 3));
        Assert.Equal(RenderOutOutcome.Cancelled, (await first).Outcome);

        var second = model.RunAsync(Settings(), owner);
        var next = Assert.IsType<RenderOutBegin>(_sent[^1]).Ticket;
        Assert.True(next > ticket, "tickets only go up");
        model.OnLinkLost("the link to the game was lost");
        var lost = await second;
        Assert.Equal((RenderOutOutcome.Failed, "the link to the game was lost"), (lost.Outcome, lost.Reason));
        Assert.False(model.Busy);
    }

    [Fact]
    public void EveryChangeOfTheStateIsOneThatTheTableAllows()
    {
        var run = new RenderOutRun(1, Settings(), new object(), null, null, new TaskCompletionSource<RenderOutResult>());
        var other = new RenderOutRun(2, Settings(), new object(), null, null, new TaskCompletionSource<RenderOutResult>());
        var progress = new RenderOutProgressInfo(RenderOutStage.Rendering, 0, 0, 30, 0);
        var result = new RenderOutResult(RenderOutOutcome.Done, null, 30, _folder, [], null, null);
        RenderOutState idle = new RenderOutState.Idle(null), starting = new RenderOutState.Starting(run),
            running = new RenderOutState.Running(run, progress), cancelling = new RenderOutState.Cancelling(run),
            muxing = new RenderOutState.Muxing(run, result, new CancellationTokenSource());
        Assert.True(RenderOutModel.Allowed(idle, starting));
        Assert.True(RenderOutModel.Allowed(starting, running));
        Assert.True(RenderOutModel.Allowed(running, muxing));
        Assert.True(RenderOutModel.Allowed(cancelling, idle));
        Assert.False(RenderOutModel.Allowed(idle, running));
        Assert.False(RenderOutModel.Allowed(cancelling, running));
        Assert.False(RenderOutModel.Allowed(muxing, running));
        Assert.False(RenderOutModel.Allowed(starting, new RenderOutState.Running(other, progress)));
    }

    [Fact]
    public void FfmpegMakesAnH264AndAacFileFromTheFramesAndTheSound()
    {
        var s = Settings(video: true);
        var args = RenderOutModel.FfmpegArguments(s, Path.Combine(_folder, "intro.wav"), "out.mp4");
        Assert.Equal(Path.Combine(_folder, "intro.%06d.png"), args[args.ToList().IndexOf("-i") + 1]);
        Assert.Equal("60", args[args.ToList().IndexOf("-start_number") + 1]);
        Assert.Equal("30", args[args.ToList().IndexOf("-framerate") + 1]);
        Assert.Contains("libx264", args);
        Assert.Contains("yuv420p", args);
        Assert.Contains("aac", args);
        Assert.Equal("out.mp4", args[^1]);
        // Without sound, a video of the frames alone.
        Assert.DoesNotContain("aac", RenderOutModel.FfmpegArguments(s, null, "out.mp4"));
        Assert.NotNull(RenderOutModel.VideoRefusal(null));
    }
}
