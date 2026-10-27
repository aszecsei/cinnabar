using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Model;
using LogLevel = Cinnabar.Editor.Panels.LogLevel;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// Screenshots and GIFs of the viewport (see docs/editor/capture.md#capture): the host writes the images, and the
/// editor writes a sidecar of its own state beside them, and switches the viewport through the debug views asked
/// for.
/// </summary>
public sealed partial class EditorShell
{
    // A viewport that is hidden copies no frames, so a wait for frames ends on its own.
    static readonly TimeSpan FrameWait = TimeSpan.FromMilliseconds(500);

    CaptureModel? _captures;

    public CaptureModel Captures => _captures ??= new CaptureModel(Host.Send, AwaitFramesAsync);

    /// <summary>Writes the next frame as a PNG, and each view as another, to the capture directory.</summary>
    public Task<CaptureOutcome> Screenshot(IReadOnlyList<DebugView>? views = null, string? path = null) =>
        CaptureAsync(CaptureKind.Screenshot, views ?? [], path);

    /// <summary>Writes the host's history ring, the last five seconds, as a GIF to the capture directory.</summary>
    public Task<CaptureOutcome> Gif(string? path = null) => CaptureAsync(CaptureKind.Gif, [], path);

    async Task<CaptureOutcome> CaptureAsync(CaptureKind kind, IReadOnlyList<DebugView> views, string? path)
    {
        if (!Host.Linked)
        {
            var refused = new CaptureOutcome(false, "no host is linked", [], null);
            Console.Add(LogLevel.Warning, $"capture: {refused.Error}");
            return refused;
        }
        var outcome = await Captures.CaptureAsync(kind, views, _options.CaptureDirectory, path, ViewportSettings, BuildCaptureContext, CancellationToken.None);
        Commands.InvalidateAll();
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

    /// <summary>Completes once the viewport has copied <paramref name="frames"/> more frames, or after a moment when it copies none.</summary>
    Task AwaitFramesAsync(int frames, CancellationToken cancel)
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
        Viewport.FrameCopied += OnCopied;
        var timer = new CancellationTokenSource(FrameWait);
        timer.Token.Register(() => done.TrySetResult());
        cancel.Register(() => done.TrySetCanceled(cancel));
        return done.Task.ContinueWith(t =>
        {
            Viewport.FrameCopied -= OnCopied;
            timer.Dispose();
            return t;
        }, TaskScheduler.Default).Unwrap();
    }

    CaptureContext BuildCaptureContext()
    {
        const double unitsPerMeter = 1 << 24;
        var position = Camera.Position;
        var camera = new CameraInfo(
            [.. position],
            [.. position.Select(p => p / unitsPerMeter)],
            Camera.Yaw,
            Camera.Pitch,
            Camera.VerticalFov,
            Camera.Near);
        return new CaptureContext(
            Mode.ToString(),
            FreeCamera,
            Scene?.Path,
            camera,
            ViewportSettings,
            Stats.Host,
            Stats.Game,
            Host.Game,
            Host.ProcessId,
            _options.HostArguments(),
            Environment.ProcessId);
    }
}
