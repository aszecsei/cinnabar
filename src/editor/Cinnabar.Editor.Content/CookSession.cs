using System.Diagnostics;
using System.Net.Sockets;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Cook;

namespace Cinnabar.Editor.Content;

public enum CookState
{
    /// <summary>Not started, or stopped by the editor.</summary>
    Stopped,
    /// <summary>Running, and the cook link is not up yet.</summary>
    Starting,
    Linked,
    /// <summary>The daemon exited by itself, too soon after it started to start it again.</summary>
    Exited,
}

/// <summary>
/// How the editor runs the cook daemon: its executable, the loose cache that the game reads, which the daemon writes
/// into as it is, the definition file, the content roots by name, and what it compiles shaders with: DXC and the include
/// directories. Paths are relative to <see cref="WorkingDirectory"/>.
/// </summary>
public sealed record CookOptions(
    string CookPath,
    string CachePath,
    string? DefinitionsPath,
    IReadOnlyList<(string Name, string Dir)> Roots,
    string WorkingDirectory,
    string? DxcPath = null,
    IReadOnlyList<string>? Includes = null);

/// <summary>
/// The cook daemon's lifetime and its cook link (see docs/editor/processes-and-projects.md#processes): start, stop, restart, crashes, and the
/// connection, which fills an <see cref="AssetIndex"/>. Events are raised, and the index changes, on the
/// synchronization context that the session was made on, which is the UI thread in the editor.
/// </summary>
public sealed class CookSession : IDisposable
{
    // The daemon listens soon after it starts.
    static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(30);
    static readonly TimeSpan ConnectRetry = TimeSpan.FromMilliseconds(100);
    // A daemon that exits sooner than this after it starts, as when another cook holds the cache, is not started
    // again, so the editor does not start it over and over.
    static readonly TimeSpan RestartAfter = TimeSpan.FromSeconds(10);

    readonly CookOptions _options;
    readonly SynchronizationContext? _context;
    ChildProcess? _process;
    LinkClient? _link;
    CancellationTokenSource? _connecting;
    readonly Stopwatch _uptime = new();
    // The operations that wait for the daemon's answer, by request ID.
    readonly Dictionary<uint, TaskCompletionSource<OperationResult>> _requests = [];
    readonly Dictionary<uint, TaskCompletionSource<PreviewResult>> _previews = [];
    uint _nextRequest;

    public CookSession(CookOptions options, AssetIndex index)
    {
        _options = options;
        Index = index;
        _context = SynchronizationContext.Current;
    }

    public AssetIndex Index { get; }

    public CookState State { get; private set; } = CookState.Stopped;

    /// <summary>The exit code, when <see cref="State"/> is <see cref="CookState.Exited"/>.</summary>
    public int ExitCode { get; private set; }

    /// <summary>The daemon's last cook since the link came up.</summary>
    public CookFinished? LastCook { get; private set; }

    public event Action? StateChanged;

    /// <summary>A line of the daemon's output that did not come over the link, or a line about the daemon from the editor.</summary>
    public event Action<string>? Output;

    /// <summary>A line of the daemon's log, over the link.</summary>
    public event Action<Log>? LogReceived;

    public event Action<CookFinished>? Cooked;

    public void Start()
    {
        StopProcess();
        if (!File.Exists(Path.Combine(_options.WorkingDirectory, _options.CookPath)))
        {
            Output?.Invoke($"editor: there is no cook daemon at {_options.CookPath}. Build it with just cook.");
            SetState(CookState.Exited, -1);
            return;
        }
        var port = LinkClient.FreePort();
        List<string> args = ["daemon", "--link", port.ToString(), "--cache", _options.CachePath];
        if (_options.DefinitionsPath != null)
        {
            args.AddRange(["--definitions", _options.DefinitionsPath]);
        }
        if (_options.DxcPath != null)
        {
            args.AddRange(["--dxc", _options.DxcPath]);
        }
        foreach (var include in _options.Includes ?? [])
        {
            args.AddRange(["--include", include]);
        }
        foreach (var (name, dir) in _options.Roots)
        {
            args.AddRange(["--root", $"{name}={dir}"]);
        }
        ChildProcess process;
        try
        {
            process = ChildProcess.Start(_options.CookPath, args, _options.WorkingDirectory);
        }
        catch (Exception e)
        {
            Output?.Invoke($"editor: cannot start the cook daemon {_options.CookPath}: {e.Message}");
            SetState(CookState.Exited, -1);
            return;
        }
        process.Output += line => Post(() => Output?.Invoke(line));
        process.Exited += code => Post(() => OnExited(process, code));
        _process = process;
        _uptime.Restart();
        SetState(CookState.Starting);
        _connecting = new CancellationTokenSource(ConnectTimeout);
        _ = ConnectAsync(process, port, _connecting.Token);
    }

    /// <summary>
    /// Asks the daemon for an asset operation (see docs/content/daemon-and-operations.md#asset-operations), and completes with its
    /// answer, which comes after the index's changes. Without the cook link, it fails at once.
    /// </summary>
    public Task<OperationResult> Request(ILinkMessage operation)
    {
        if (_link == null || State != CookState.Linked)
        {
            return Task.FromResult(new OperationResult("The cook daemon is not running, so the content cannot change.", []));
        }
        var request = NextRequest();
        var answer = new TaskCompletionSource<OperationResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        _requests[request] = answer;
        _link.Send(operation, request);
        return answer.Task;
    }

    /// <summary>
    /// Asks the daemon to cook a material's unsaved text into the cache's preview area (see
    /// docs/rendering/materials.md#material-previews), and completes with its answer. Without the cook link, it fails at once.
    /// </summary>
    public Task<PreviewResult> CookPreview(string guid, string text)
    {
        if (_link == null || State != CookState.Linked)
        {
            return Task.FromResult(new PreviewResult("The cook daemon is not running.", []));
        }
        var request = NextRequest();
        var answer = new TaskCompletionSource<PreviewResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        _previews[request] = answer;
        _link.Send(new CookPreview(guid, text), request);
        return answer.Task;
    }

    uint NextRequest()
    {
        var request = ++_nextRequest;
        // Request 0 is a message that wants no answer.
        return request == 0 ? ++_nextRequest : request;
    }

    public void Stop()
    {
        if (_process != null)
        {
            StopProcess();
            SetState(CookState.Stopped);
        }
    }

    async Task ConnectAsync(ChildProcess process, int port, CancellationToken cancel)
    {
        while (process == _process)
        {
            try
            {
                var link = await LinkClient.ConnectAsync(port, CookMessages.Read, cancel);
                if (process != _process)
                {
                    await link.DisposeAsync();
                    return;
                }
                _link = link;
                link.Received += (message, request) => Post(() => OnReceived(link, message, request));
                link.Closed += error => Post(() => OnLinkClosed(link, error));
                link.Start();
                link.Send(new Hello(CookMessages.ProtocolVersion, "cinnabar editor"));
                return;
            }
            catch (SocketException)
            {
                // The daemon is not listening yet.
                await Task.Delay(ConnectRetry, CancellationToken.None);
            }
            catch (OperationCanceledException)
            {
                if (process == _process)
                {
                    Post(() => Output?.Invoke($"editor: the cook daemon did not open the cook link on port {port} within {ConnectTimeout.TotalSeconds} s"));
                }
                return;
            }
        }
    }

    void OnReceived(LinkClient link, ILinkMessage message, uint request)
    {
        if (link != _link)
        {
            return;
        }
        switch (message)
        {
            case Welcome:
                Index.Apply(message);
                SetState(CookState.Linked);
                break;
            case Refused refused:
                Output?.Invoke($"editor: the cook daemon refused the cook link: {refused.Reason}");
                _ = link.DisposeAsync();
                break;
            case Log log:
                LogReceived?.Invoke(log);
                break;
            case CookFinished finished:
                LastCook = finished;
                Cooked?.Invoke(finished);
                break;
            case OperationResult result:
                if (_requests.Remove(request, out var answer))
                {
                    answer.SetResult(result);
                }
                break;
            case PreviewResult preview:
                if (_previews.Remove(request, out var cooked))
                {
                    cooked.SetResult(preview);
                }
                break;
            case Hello:
                Output?.Invoke("editor: the cook daemon sent a message that only the editor sends: Hello");
                break;
            default:
                Index.Apply(message);
                break;
        }
    }

    void OnLinkClosed(LinkClient link, Exception? error)
    {
        if (link != _link)
        {
            return;
        }
        _link = null;
        if (error != null)
        {
            Output?.Invoke($"editor: the cook link failed: {error.Message}");
        }
        FailRequests();
        Index.Unlink();
        if (State == CookState.Linked)
        {
            SetState(CookState.Starting);
        }
    }

    void OnExited(ChildProcess process, int code)
    {
        // A process that the editor stopped or replaced has already been dealt with.
        if (process != _process)
        {
            return;
        }
        var uptime = _uptime.Elapsed;
        StopProcess();
        Output?.Invoke($"editor: the cook daemon exited with code {code}");
        if (uptime >= RestartAfter)
        {
            Output?.Invoke("editor: starting the cook daemon again");
            Start();
            return;
        }
        SetState(CookState.Exited, code);
    }

    void StopProcess()
    {
        _connecting?.Cancel();
        _connecting = null;
        if (_link != null)
        {
            _ = _link.DisposeAsync();
            _link = null;
        }
        FailRequests();
        Index.Unlink();
        LastCook = null;
        // Closing the job kills the daemon.
        _process?.Dispose();
        _process = null;
    }

    // The daemon may have done an operation that it could not answer. Its next snapshot has the content as it is.
    void FailRequests()
    {
        foreach (var answer in _requests.Values)
        {
            answer.TrySetResult(new OperationResult("The cook link closed before the cook daemon answered.", []));
        }
        _requests.Clear();
        foreach (var answer in _previews.Values)
        {
            answer.TrySetResult(new PreviewResult("The cook link closed before the cook daemon answered.", []));
        }
        _previews.Clear();
    }

    void SetState(CookState state, int exitCode = 0)
    {
        State = state;
        ExitCode = exitCode;
        StateChanged?.Invoke();
    }

    void Post(Action action)
    {
        if (_context == null)
        {
            action();
        }
        else
        {
            _context.Post(_ => action(), null);
        }
    }

    public void Dispose() => StopProcess();
}
