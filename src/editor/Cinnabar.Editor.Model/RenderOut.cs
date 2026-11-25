using System.Diagnostics;
using System.Text.Json;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Model;

/// <summary>
/// What a render out renders (see docs/editor/cutscene-editor.md#render-out): the cutscene's saved blob, by its GUID and
/// its name, from <see cref="RangeStart"/> to <see cref="RangeEnd"/> on its time, in ticks, at <see cref="Rate"/>
/// frames a second, each <see cref="Width"/> by <see cref="Height"/>, through the cut track or the camera of a binding,
/// after <see cref="Warmup"/> frames that are drawn and not written. The frames go to <see cref="Folder"/>, named by
/// <see cref="Pattern"/>, with the sound with <see cref="Audio"/>, and an MP4 of both with <see cref="Video"/>.
/// </summary>
public sealed record RenderOutSettings(
    byte[] Cutscene,
    string Name,
    int RangeStart,
    int RangeEnd,
    uint Rate,
    uint Width,
    uint Height,
    RenderOutFormat Format,
    uint CameraBinding,
    uint Warmup,
    string Folder,
    string Pattern,
    bool Audio,
    bool Video)
{
    public const int TicksPerSecond = 60000;

    /// <summary>The default pattern: the cutscene's name and the frame's number, six digits wide.</summary>
    public const string DefaultPattern = "{name}.{frame}.png";

    /// <summary>The frames from the start to the end, at the rate: the last frame is the one that the end falls in.</summary>
    public int FrameCount => (int)Math.Max(0, ((long)(RangeEnd - RangeStart) * Rate + TicksPerSecond - 1) / TicksPerSecond);

    /// <summary>The number of the first frame, at the rate from the cutscene's 0, which the file names count from.</summary>
    public int FirstFrame => (int)((long)RangeStart * Rate / TicksPerSecond);

    /// <summary>Why the settings cannot render, or null.</summary>
    public string? Refusal =>
        Rate < 15 ? $"a rate of {Rate} is below 15 frames a second"
        : FrameCount <= 0 ? "the range has no frame"
        : Width == 0 || Height == 0 || Width > 8192 || Height > 8192 ? $"a size of {Width}x{Height} is not 1 to 8192 on a side"
        : Format == RenderOutFormat.Exr ? "EXR frames need an HDR target, which the renderer does not have yet"
        : string.IsNullOrWhiteSpace(Folder) ? "the render out has no folder"
        : !Pattern.Contains("{frame}") ? "the file name pattern has no {frame}"
        : Video && Format != RenderOutFormat.Png ? "video needs PNG frames"
        : null;
}

/// <summary>How far a run is: the frames drawn and written of the total, and the time that each took.</summary>
public sealed record RenderOutProgressInfo(RenderOutStage Stage, int Drawn, int Written, int Total, double MsPerFrame)
{
    /// <summary>The time left at the rate so far, or null before the first frame.</summary>
    public TimeSpan? Left => Drawn == 0 ? null : TimeSpan.FromMilliseconds(MsPerFrame * (Total - Drawn));
}

/// <summary>How a run ended: its files, the sound's, and the video's.</summary>
public sealed record RenderOutResult(
    RenderOutOutcome Outcome,
    string? Reason,
    int Frames,
    string Folder,
    IReadOnlyList<string> Files,
    string? Audio,
    string? Video);

/// <summary>What the sidecar records of a frame's time: its timecode, its frame at the cutscene's rate, and its shot.</summary>
public sealed record RenderOutFrameTime(string Timecode, int CutsceneFrame, string Shot);

/// <summary>
/// The render out's state (see docs/overview/conventions.md#state-with-a-lifecycle). <see cref="RenderOutModel.Become"/>
/// is its one writer, and <see cref="RenderOutModel.Allowed"/> says which changes it makes.
/// </summary>
public abstract record RenderOutState
{
    /// <summary>No run, and how the last one ended.</summary>
    public sealed record Idle(RenderOutResult? Last) : RenderOutState;

    /// <summary>A run that the game has not answered yet.</summary>
    public sealed record Starting(RenderOutRun Run) : RenderOutState;

    /// <summary>A run that the game draws.</summary>
    public sealed record Running(RenderOutRun Run, RenderOutProgressInfo Progress) : RenderOutState;

    /// <summary>A run that was cancelled, until the game says that it ended.</summary>
    public sealed record Cancelling(RenderOutRun Run) : RenderOutState;

    /// <summary>A run that ended, whose frames and sound ffmpeg makes a video of.</summary>
    public sealed record Muxing(RenderOutRun Run, RenderOutResult Result, CancellationTokenSource Cancel) : RenderOutState;
}

/// <summary>
/// One run: its ticket, what it renders, the tab that owns it, and what came back of it. Its lists grow as the host
/// writes; only the model's handlers touch them.
/// </summary>
public sealed class RenderOutRun(ulong ticket, RenderOutSettings settings, object owner, string? ffmpeg,
    Func<int, RenderOutFrameTime>? describe, TaskCompletionSource<RenderOutResult> done)
{
    public ulong Ticket { get; } = ticket;
    public RenderOutSettings Settings { get; } = settings;
    public object Owner { get; } = owner;
    public string? Ffmpeg { get; } = ffmpeg;
    internal Func<int, RenderOutFrameTime>? Describe { get; } = describe;
    internal TaskCompletionSource<RenderOutResult> Done { get; } = done;
    internal Dictionary<int, RenderOutFrame> Drawn { get; } = [];
    internal List<string> Files { get; } = [];
    internal List<string> Failures { get; } = [];
    internal string? Audio { get; set; }
}

/// <summary>
/// A render out in the editor (see docs/editor/cutscene-editor.md#render-out): it asks the game to render a cutscene,
/// follows its progress, writes a sidecar beside each frame that the host writes, and makes a video of the frames and
/// the sound with ffmpeg when asked. It has no UI; the shell gives it the link and tells it of the link's end.
/// </summary>
public sealed class RenderOutModel(Action<ILinkMessage> send)
{
    ulong _last;

    public RenderOutState State { get; private set; } = new RenderOutState.Idle(null);

    /// <summary>The state changed.</summary>
    public event Action? Changed;

    /// <summary>The game ended a run, and the world is no longer the document's: the shell gives it back, as Stop does.</summary>
    public event Action? GameEnded;

    /// <summary>A run is under way, from its start to the end of its video.</summary>
    public bool Busy => State is not RenderOutState.Idle;

    /// <summary>Whether the state may go from one kind to another.</summary>
    public static bool Allowed(RenderOutState from, RenderOutState to) => (from, to) switch
    {
        (RenderOutState.Idle, RenderOutState.Starting) => true,
        (RenderOutState.Starting s, RenderOutState.Running r) => s.Run == r.Run,
        (RenderOutState.Running a, RenderOutState.Running b) => a.Run == b.Run,
        (RenderOutState.Starting s, RenderOutState.Cancelling c) => s.Run == c.Run,
        (RenderOutState.Running r, RenderOutState.Cancelling c) => r.Run == c.Run,
        (RenderOutState.Running r, RenderOutState.Muxing m) => r.Run == m.Run,
        (RenderOutState.Starting or RenderOutState.Running or RenderOutState.Cancelling or RenderOutState.Muxing, RenderOutState.Idle) => true,
        _ => false,
    };

    void Become(RenderOutState to)
    {
        if (!Allowed(State, to))
        {
            throw new InvalidOperationException($"a render out cannot go from {State.GetType().Name} to {to.GetType().Name}");
        }
        State = to;
        Changed?.Invoke();
    }

    RenderOutRun? Live => State switch
    {
        RenderOutState.Starting s => s.Run,
        RenderOutState.Running r => r.Run,
        RenderOutState.Cancelling c => c.Run,
        _ => null,
    };

    /// <summary>
    /// Renders out, and gives how it ended once the game has ended it, and ffmpeg has made its video when asked.
    /// <paramref name="owner"/> is the tab whose close cancels it, <paramref name="ffmpeg"/> the encoder, or null, and
    /// <paramref name="describe"/> gives the sidecar a tick's timecode and shot.
    /// </summary>
    public Task<RenderOutResult> RunAsync(RenderOutSettings settings, object owner, string? ffmpeg = null,
        Func<int, RenderOutFrameTime>? describe = null)
    {
        var refusal = Busy ? "a render out is under way" : settings.Refusal ?? (settings.Video && ffmpeg == null ? VideoRefusal(null) : null);
        if (refusal != null)
        {
            return Task.FromResult(new RenderOutResult(RenderOutOutcome.Failed, refusal, 0, settings.Folder, [], null, null));
        }
        var done = new TaskCompletionSource<RenderOutResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var run = new RenderOutRun(++_last, settings, owner, ffmpeg, describe, done);
        Directory.CreateDirectory(settings.Folder);
        Become(new RenderOutState.Starting(run));
        send(new RenderOutBegin(run.Ticket, settings.Cutscene, settings.Name, settings.RangeStart, settings.FrameCount,
            settings.Rate, settings.Width, settings.Height, settings.Format, settings.CameraBinding, settings.Warmup,
            settings.Folder, settings.Pattern, settings.Audio || settings.Video));
        return done.Task;
    }

    /// <summary>Why the video option is off: no encoder, or null when it can be on.</summary>
    public static string? VideoRefusal(string? ffmpeg) => ffmpeg == null ? "Set ffmpeg in the settings to make videos" : null;

    /// <summary>Stops the run after the frame that it is on, or the video that ffmpeg makes.</summary>
    public void Cancel()
    {
        switch (State)
        {
            case RenderOutState.Starting s:
                send(new RenderOutCancel(s.Run.Ticket));
                Become(new RenderOutState.Cancelling(s.Run));
                break;
            case RenderOutState.Running r:
                send(new RenderOutCancel(r.Run.Ticket));
                Become(new RenderOutState.Cancelling(r.Run));
                break;
            case RenderOutState.Muxing m:
                m.Cancel.Cancel();
                break;
        }
    }

    /// <summary>The tab that owns the run closed: the run stops.</summary>
    public void OnOwnerClosed(object owner)
    {
        if (Live?.Owner == owner || (State is RenderOutState.Muxing m && m.Run.Owner == owner))
        {
            Cancel();
        }
    }

    /// <summary>The link went, or the game restarted: the run is over, with what the host wrote.</summary>
    public void OnLinkLost(string reason)
    {
        if (Live is { } run)
        {
            Finish(run, new RenderOutResult(RenderOutOutcome.Failed, reason, run.Drawn.Count, run.Settings.Folder,
                [.. run.Files], run.Audio, null));
        }
    }

    /// <summary>Takes a message of the run. False for one of no run, or of another.</summary>
    public bool Apply(ILinkMessage message)
    {
        switch (message)
        {
            case RenderOutProgress p when Live is { } run && run.Ticket == p.Ticket:
                Progress(run, p.Stage);
                return true;
            case RenderOutFrame f when Live is { } run && run.Ticket == f.Ticket:
                run.Drawn[f.Frame] = f;
                Progress(run, RenderOutStage.Rendering);
                return true;
            case RenderOutWritten w when Live is { } run && run.Ticket == w.Ticket:
                Written(run, w);
                Progress(run, RenderOutStage.Rendering);
                return true;
            case RenderOutEnded e when Live is { } run && run.Ticket == e.Ticket:
                Ended(run, e);
                return true;
        }
        return false;
    }

    void Progress(RenderOutRun run, RenderOutStage stage)
    {
        if (State is not (RenderOutState.Starting or RenderOutState.Running))
        {
            return;
        }
        var frames = run.Drawn.Values;
        var ms = frames.Count == 0 ? 0 : frames.Average(f => f.Ms);
        var written = run.Files.Count - (run.Audio != null ? 1 : 0);
        Become(new RenderOutState.Running(run, new RenderOutProgressInfo(stage, frames.Count, written, run.Settings.FrameCount, ms)));
    }

    void Written(RenderOutRun run, RenderOutWritten w)
    {
        if (!w.Ok)
        {
            run.Failures.Add(w.Frame < 0 ? $"sound: {w.Reason}" : $"frame {w.Frame}: {w.Reason}");
            return;
        }
        run.Files.Add(w.Path);
        if (w.Frame < 0)
        {
            run.Audio = w.Path;
            return;
        }
        try
        {
            var sidecar = Path.ChangeExtension(w.Path, ".json");
            File.WriteAllText(sidecar, JsonSerializer.Serialize(Sidecar(run, w), CaptureModel.SidecarJson));
            run.Files.Add(sidecar);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            run.Failures.Add($"sidecar of frame {w.Frame}: {e.Message}");
        }
    }

    /// <summary>The sidecar of a frame (see docs/editor/capture.md#sidecar).</summary>
    static object Sidecar(RenderOutRun run, RenderOutWritten w)
    {
        var s = run.Settings;
        run.Drawn.TryGetValue(w.Frame, out var drawn);
        var tick = drawn?.Tick ?? s.RangeStart + (int)((long)w.Frame * RenderOutSettings.TicksPerSecond / s.Rate);
        var time = run.Describe?.Invoke(tick);
        return new
        {
            Schema = 1,
            Kind = "render_out",
            Cutscene = s.Name,
            Frame = s.FirstFrame + w.Frame,
            Tick = tick,
            time?.Timecode,
            time?.CutsceneFrame,
            time?.Shot,
            w.Width,
            w.Height,
            s.Rate,
            SettleDraws = drawn?.SettleDraws ?? 0,
            Ms = drawn?.Ms ?? 0,
        };
    }

    void Ended(RenderOutRun run, RenderOutEnded e)
    {
        var reason = e.Reason == "" ? null : e.Reason;
        if (run.Failures.Count > 0)
        {
            reason = string.Join("; ", reason == null ? run.Failures : run.Failures.Prepend(reason));
        }
        var result = new RenderOutResult(e.Outcome, reason, e.Frames, run.Settings.Folder, [.. run.Files], run.Audio, null);
        GameEnded?.Invoke();
        if (e.Outcome == RenderOutOutcome.Done && run.Settings.Video && run.Ffmpeg != null && State is RenderOutState.Running)
        {
            var cancel = new CancellationTokenSource();
            Become(new RenderOutState.Muxing(run, result, cancel));
            _ = MuxAsync(run, result, cancel.Token);
            return;
        }
        Finish(run, result);
    }

    async Task MuxAsync(RenderOutRun run, RenderOutResult result, CancellationToken cancel)
    {
        var s = run.Settings;
        var video = Path.Combine(s.Folder, $"{s.Name}.mp4");
        var (ok, error) = await EncodeAsync(run.Ffmpeg!, FfmpegArguments(s, result.Audio, video + ".tmp.mp4"), cancel);
        if (ok)
        {
            File.Move(video + ".tmp.mp4", video, overwrite: true);
            result = result with { Video = video, Files = [.. result.Files, video] };
        }
        else
        {
            File.Delete(video + ".tmp.mp4");
            result = result with
            {
                Outcome = cancel.IsCancellationRequested ? RenderOutOutcome.Cancelled : RenderOutOutcome.Failed,
                Reason = cancel.IsCancellationRequested ? "the video was cancelled" : $"ffmpeg: {error}",
            };
        }
        Finish(run, result);
    }

    void Finish(RenderOutRun run, RenderOutResult result)
    {
        Become(new RenderOutState.Idle(result));
        run.Done.TrySetResult(result);
    }

    /// <summary>
    /// ffmpeg's arguments for an MP4 of a run's PNG frames at its rate, from its first frame, with its sound when it has
    /// one: H.264 in 4:2:0, which players take, and AAC, to the shorter of the two.
    /// </summary>
    public static IReadOnlyList<string> FfmpegArguments(RenderOutSettings s, string? audio, string output)
    {
        var frames = Path.Combine(s.Folder, s.Pattern.Replace("{name}", s.Name).Replace("{frame}", "%06d"));
        List<string> args = ["-y", "-hide_banner", "-loglevel", "error", "-framerate", s.Rate.ToString(),
            "-start_number", s.FirstFrame.ToString(), "-i", frames];
        if (audio != null)
        {
            args.AddRange(["-i", audio]);
        }
        args.AddRange(["-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18"]);
        if (audio != null)
        {
            args.AddRange(["-c:a", "aac", "-b:a", "192k", "-shortest"]);
        }
        args.Add(output);
        return args;
    }

    /// <summary>Runs ffmpeg, and gives whether it made the file, with the end of what it wrote when it did not.</summary>
    public static async Task<(bool Ok, string? Error)> EncodeAsync(string ffmpeg, IReadOnlyList<string> arguments, CancellationToken cancel)
    {
        var info = new ProcessStartInfo(ffmpeg, arguments)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
        };
        try
        {
            using var process = Process.Start(info)!;
            var errors = process.StandardError.ReadToEndAsync(CancellationToken.None);
            _ = process.StandardOutput.ReadToEndAsync(CancellationToken.None);
            try
            {
                await process.WaitForExitAsync(cancel);
            }
            catch (OperationCanceledException)
            {
                process.Kill(entireProcessTree: true);
                return (false, "cancelled");
            }
            var text = (await errors).Trim();
            return process.ExitCode == 0 ? (true, null) : (false, text.Length > 400 ? text[^400..] : text);
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or IOException)
        {
            return (false, e.Message);
        }
    }
}
