using System.Text.Json;
using System.Text.Json.Serialization;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Model;

/// <summary>An image that a capture wrote: the file, the debug view it shows or null for the lit frame, and what the host said of it.</summary>
public sealed record CaptureImage(string File, string? View, ulong Frame, uint Width, uint Height, string Output, uint Frames, float DurationMs);

/// <summary>What a capture made: its files, the sidecar among them, or why it failed.</summary>
public sealed record CaptureOutcome(bool Ok, string? Error, IReadOnlyList<string> Files, string? Sidecar);

/// <summary>The editor's camera at a capture: a raw World_Position and the same in meters, the angles in radians.</summary>
public sealed record CameraInfo(long[] Position, double[] PositionMeters, double Yaw, double Pitch, double VerticalFov, double Near);

/// <summary>Everything the sidecar records of the editor's state at a capture (see docs/editor/capture.md#sidecar).</summary>
public sealed record CaptureContext(
    string Mode,
    bool FreeCamera,
    string? Scene,
    CameraInfo Camera,
    ViewportSettings Settings,
    HostStats? HostStats,
    GameStats? GameStats,
    string? Game,
    int? HostPid,
    string[] HostArguments,
    int EditorPid);

/// <summary>
/// A capture in the editor (see docs/editor/capture.md#capture): it asks the host for a screenshot or a GIF, then for
/// a screenshot of each debug view asked for, with the viewport's settings switched to the view and put back after,
/// and writes a JSON sidecar beside the images. It lives in the shell, and sends through it, so it has no UI and no
/// host of its own.
/// </summary>
public sealed class CaptureModel
{
    /// <summary>Frames the viewport shows after a debug view is sent before the capture, so the view is on screen.</summary>
    public const int SettleFrames = 3;

    /// <summary>How long a host has to answer a request.</summary>
    public static readonly TimeSpan ResultTimeout = TimeSpan.FromSeconds(15);

    public static readonly JsonSerializerOptions SidecarJson = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter() },
    };

    readonly Action<ILinkMessage> _send;
    readonly Func<int, CancellationToken, Task> _awaitFrames;
    readonly Dictionary<uint, TaskCompletionSource<CaptureResult>> _waiting = [];
    uint _nextId;
    int _sequence;

    /// <param name="send">Sends a message to the host.</param>
    /// <param name="awaitFrames">Completes once the viewport has shown that many new frames, or soon after if it shows none.</param>
    public CaptureModel(Action<ILinkMessage> send, Func<int, CancellationToken, Task> awaitFrames)
    {
        _send = send;
        _awaitFrames = awaitFrames;
    }

    /// <summary>A capture is under way. Only one runs at a time.</summary>
    public bool Busy { get; private set; }

    public event Action? Changed;

    /// <summary>The debug views' names as requests spell them, in <see cref="DebugView"/>'s order: <c>entity_ids</c>.</summary>
    public static IReadOnlyList<string> ViewNames { get; } = [.. Enum.GetValues<DebugView>().Select(ViewName)];

    public static string ViewName(DebugView view) => SnakeCase(view.ToString());

    /// <summary>Reads a view's name in any spelling: <c>depth</c>, <c>Entity_Ids</c>, <c>entityIds</c>, <c>entity ids</c>.</summary>
    public static bool TryParseView(string text, out DebugView view)
    {
        var wanted = SnakeCase(text.Trim().Replace(' ', '_').Replace('-', '_'));
        foreach (var candidate in Enum.GetValues<DebugView>())
        {
            if (ViewName(candidate) == wanted)
            {
                view = candidate;
                return true;
            }
        }
        view = default;
        return false;
    }

    /// <summary>The files' base name: the time and a sequence number, so two captures in a second differ.</summary>
    public static string BaseName(DateTime utc, int sequence) => $"{utc:yyyyMMdd-HHmmss}-{sequence:00}";

    /// <summary>
    /// Captures a screenshot or a GIF into <paramref name="directory"/>, or at <paramref name="path"/> when given, with
    /// a screenshot of each view beside it and the sidecar. The views need <paramref name="current"/>, the viewport's
    /// settings, which they change and put back. <paramref name="context"/> is read when the sidecar is written.
    /// </summary>
    public async Task<CaptureOutcome> CaptureAsync(CaptureKind kind, IReadOnlyList<DebugView> views, string directory, string? path,
        ViewportSettings current, Func<CaptureContext> context, CancellationToken cancel)
    {
        if (Busy)
        {
            return new CaptureOutcome(false, "a capture is already under way", [], null);
        }
        Busy = true;
        Changed?.Invoke();
        var started = DateTime.UtcNow;
        var extension = kind == CaptureKind.Gif ? ".gif" : ".png";
        string primary;
        if (!string.IsNullOrEmpty(path))
        {
            primary = Path.GetFullPath(path);
            if (!primary.EndsWith(extension, StringComparison.OrdinalIgnoreCase))
            {
                primary += extension;
            }
        }
        else
        {
            primary = Path.Combine(Path.GetFullPath(directory), BaseName(started, ++_sequence) + extension);
        }
        var stem = primary[..^extension.Length];
        List<CaptureImage> images = [];
        List<string> failures = [];
        var sentView = false;
        try
        {
            var result = await RequestAsync(kind, primary, cancel);
            if (result.Ok)
            {
                images.Add(Image(result, null));
            }
            else
            {
                failures.Add($"{kind}: {result.Reason}");
            }
            foreach (var view in views.Distinct())
            {
                if (view == DebugView.Lit)
                {
                    continue;
                }
                _send(current with { DebugView = view });
                sentView = true;
                await _awaitFrames(SettleFrames, cancel);
                var viewResult = await RequestAsync(CaptureKind.Screenshot, $"{stem}.{ViewName(view)}.png", cancel);
                if (viewResult.Ok)
                {
                    images.Add(Image(viewResult, ViewName(view)));
                }
                else
                {
                    failures.Add($"{ViewName(view)}: {viewResult.Reason}");
                }
            }
        }
        catch (OperationCanceledException)
        {
            failures.Add("the capture was cancelled");
        }
        finally
        {
            if (sentView)
            {
                _send(current);
            }
        }

        string? sidecar = null;
        try
        {
            sidecar = stem + ".json";
            Directory.CreateDirectory(Path.GetDirectoryName(sidecar)!);
            var document = new
            {
                Schema = 1,
                Time = started,
                Kind = kind,
                Views = views.Select(ViewName).ToArray(),
                Images = images,
                Failures = failures,
                Context = context(),
            };
            await File.WriteAllTextAsync(sidecar, JsonSerializer.Serialize(document, SidecarJson), CancellationToken.None);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            failures.Add($"sidecar: {e.Message}");
            sidecar = null;
        }
        Busy = false;
        Changed?.Invoke();
        var files = images.Select(i => i.File).ToList();
        if (sidecar != null)
        {
            files.Add(sidecar);
        }
        var ok = images.Count > 0 && images[0].View == null && failures.Count == 0;
        return new CaptureOutcome(ok, failures.Count > 0 ? string.Join("; ", failures) : null, files, sidecar);
    }

    /// <summary>Completes the request that the result answers. False for a result nothing waits for.</summary>
    public bool Apply(CaptureResult result)
    {
        if (!_waiting.Remove(result.Id, out var waiting))
        {
            return false;
        }
        waiting.TrySetResult(result);
        return true;
    }

    async Task<CaptureResult> RequestAsync(CaptureKind kind, string path, CancellationToken cancel)
    {
        var id = ++_nextId;
        var waiting = new TaskCompletionSource<CaptureResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        _waiting[id] = waiting;
        _send(new CaptureRequest(id, kind, path));
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        timeout.CancelAfter(ResultTimeout);
        try
        {
            return await waiting.Task.WaitAsync(timeout.Token);
        }
        catch (OperationCanceledException) when (!cancel.IsCancellationRequested)
        {
            _waiting.Remove(id);
            return new CaptureResult(id, kind, false, $"the host did not answer within {ResultTimeout.TotalSeconds} s", path, 0, 0, 0, 0, 0, OutputMode.Sdr);
        }
        catch (OperationCanceledException)
        {
            _waiting.Remove(id);
            throw;
        }
    }

    static CaptureImage Image(CaptureResult r, string? view) => new(r.Path, view, r.Frame, r.Width, r.Height, r.Output.ToString(), r.Frames, r.DurationMs);

    static string SnakeCase(string pascal)
    {
        var chars = new List<char>(pascal.Length + 4);
        for (var i = 0; i < pascal.Length; i++)
        {
            var c = pascal[i];
            if (char.IsUpper(c) && i > 0 && pascal[i - 1] != '_')
            {
                chars.Add('_');
            }
            chars.Add(char.ToLowerInvariant(c));
        }
        return new string(chars.ToArray());
    }
}
