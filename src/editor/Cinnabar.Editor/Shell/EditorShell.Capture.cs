using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Model;
using LogLevel = Cinnabar.Editor.Model.LogLevel;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// Screenshots and GIFs of a viewport (see docs/editor/capture.md#capture): the host writes the images, and the
/// editor writes a sidecar of its own state beside them, and switches the viewport through the debug views asked
/// for. The viewport is the capture viewport (<see cref="CaptureViewport"/>), or the one that a call names.
/// </summary>
public sealed partial class EditorShell
{
    // A viewport that is not shown copies no frames, so a wait for frames ends on its own.
    static readonly TimeSpan FrameWait = TimeSpan.FromMilliseconds(500);

    CaptureModel? _captures;

    public CaptureModel Captures => _captures ??= new CaptureModel(Host.Send, AwaitFramesAsync);

    /// <summary>Writes the next frame as a PNG, and each view as another, to the capture directory.</summary>
    public Task<CaptureOutcome> Screenshot(IReadOnlyList<DebugView>? views = null, string? path = null, int? viewport = null) =>
        CaptureAsync(CaptureKind.Screenshot, views ?? [], path, viewport);

    /// <summary>Writes the host's history ring, the last five seconds, as a GIF to the capture directory.</summary>
    public Task<CaptureOutcome> Gif(string? path = null, int? viewport = null) => CaptureAsync(CaptureKind.Gif, [], path, viewport);

    async Task<CaptureOutcome> CaptureAsync(CaptureKind kind, IReadOnlyList<DebugView> views, string? path, int? viewport)
    {
        var refusal = !Host.Linked ? "no host is linked"
            : viewport is { } named && (named < 0 || named >= Viewports.Count || !Viewports[named].IsShown) ? $"viewport {named} is not shown"
            : viewport == null && CaptureViewport == null ? "no viewport is shown, so there is nothing to capture"
            : null;
        if (refusal != null)
        {
            var refused = new CaptureOutcome(false, refusal, [], null);
            Console.Add(LogLevel.Warning, $"capture: {refused.Error}");
            return refused;
        }
        var target = viewport is { } index ? Viewports[index] : CaptureViewport!;
        CaptureOutcome outcome;
        try
        {
            // The host reads the viewport that it was last told of, which a capture of a named one changes for its length.
            SendCaptureSource(resend: false, use: target);
            outcome = await Captures.CaptureAsync(kind, views, _options.CaptureDirectory, path, target.Index, target.Settings, () => BuildCaptureContext(target), CancellationToken.None);
        }
        finally
        {
            SendCaptureSource(resend: false);
            // The capture commands follow Busy, which the capture ends however it ends.
            Commands.InvalidateAll();
        }
        if (outcome.Files.Count > 0)
        {
            Console.Add(LogLevel.Info, $"capture: wrote {string.Join(", ", outcome.Files)}");
        }
        if (outcome.Error != null)
        {
            Console.Add(LogLevel.Warning, $"capture: {outcome.Error}");
        }
        return outcome;
    }

    /// <summary>Completes once a viewport has copied <paramref name="frames"/> more frames, or after a moment when it copies none.</summary>
    Task AwaitFramesAsync(int viewport, int frames, CancellationToken cancel)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var left = frames;
        void OnCopied(uint generation, ulong frame)
        {
            if (--left <= 0)
            {
                done.TrySetResult();
            }
        }
        var session = Viewports[viewport].Session;
        session.FrameCopied += OnCopied;
        var timer = new CancellationTokenSource(FrameWait);
        timer.Token.Register(() => done.TrySetResult());
        cancel.Register(() => done.TrySetCanceled(cancel));
        return done.Task.ContinueWith(t =>
        {
            session.FrameCopied -= OnCopied;
            timer.Dispose();
            return t;
        }, TaskScheduler.Default).Unwrap();
    }

    CaptureContext BuildCaptureContext(EditorViewport viewport)
    {
        const double unitsPerMeter = 1 << 24;
        // The Game view draws from the game's camera, which the editor does not know.
        CameraInfo? camera = null;
        if (viewport.HasCamera)
        {
            var view = viewport.Camera;
            var position = view.Position;
            camera = new CameraInfo(
                [.. position],
                [.. position.Select(p => p / unitsPerMeter)],
                view.Yaw,
                view.Pitch,
                view.VerticalFov,
                view.Near,
                view.Projection.ToString(),
                view.OrthographicHeight);
        }
        return new CaptureContext(
            Mode.ToString(),
            viewport.Index,
            viewport.Kind,
            Scene?.Path,
            camera,
            viewport.Settings,
            Stats.Host,
            Stats.Game,
            Profiler.Summary,
            Host.Game,
            Host.ProcessId,
            _options.HostArguments(),
            Environment.ProcessId);
    }
}
