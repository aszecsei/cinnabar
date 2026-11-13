using System.Diagnostics;
using System.Net.Sockets;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Content;

/// <summary>What cooks a document's unsaved text for its preview: the cook session, or a fake one in tests.</summary>
public interface IPreviewCooker
{
    /// <summary>Whether a cook can be sent now.</summary>
    bool Linked { get; }

    /// <summary>
    /// Cooks an asset's unsaved text into the cache's preview area, or checks a decision's and plans its plan query, and
    /// completes with the answer.
    /// </summary>
    Task<PreviewResult> CookPreview(string guid, string text, PlanQuery? plan = null);
}

/// <summary>
/// Where the cook session is (see docs/editor/processes-and-projects.md#crash-recovery). Each state carries what belongs
/// to it: the running ones their process, the linked ones their link, and the failed ones their reason or code. Only
/// <see cref="CookSession"/> makes them.
/// </summary>
public abstract record CookState
{
    private protected CookState()
    {
    }

    /// <summary>Not started, or stopped by the editor.</summary>
    public sealed record Stopped : CookState;

    /// <summary>The daemon could not start, as when it is not built.</summary>
    public sealed record FailedToStart(string Reason) : CookState;

    /// <summary>The daemon refused the cook link, as when its protocol is another. The editor stopped it.</summary>
    public sealed record Refused(string Reason) : CookState;

    /// <summary>The daemon did not link within the time. The editor stopped it.</summary>
    public sealed record TimedOut(TimeSpan After) : CookState;

    /// <summary>The daemon exited by itself, too soon after it started to start it again.</summary>
    public sealed record Exited(int Code) : CookState;

    /// <summary>The daemon runs.</summary>
    public abstract record Running : CookState
    {
        private protected Running(CookRun run) => Run = run;

        internal override CookRun Run { get; }
    }

    /// <summary>The daemon runs, and the editor connects to its cook link.</summary>
    public sealed record Connecting : Running
    {
        internal Connecting(CookRun run, CancellationTokenSource deadline) : base(run) => Deadline = deadline;

        internal override CancellationTokenSource Deadline { get; }
    }

    /// <summary>The editor is connected and waits for the daemon's Welcome and index.</summary>
    public sealed record Handshaking : Running
    {
        internal Handshaking(CookRun run, CancellationTokenSource deadline, LinkClient link) : base(run) => (Deadline, Link) = (deadline, link);

        internal override CancellationTokenSource Deadline { get; }

        internal override LinkClient Link { get; }
    }

    /// <summary>The daemon sent its index, which it keeps up to date.</summary>
    public sealed record Linked : Running
    {
        internal Linked(CookRun run, LinkClient link) : base(run) => Link = link;

        internal override LinkClient Link { get; }
    }

    /// <summary>The cook link closed while the daemon runs, and the editor connects again.</summary>
    public sealed record LinkLost : Running
    {
        internal LinkLost(CookRun run, CancellationTokenSource deadline, string reason) : base(run) => (Deadline, Reason) = (deadline, reason);

        public string Reason { get; }

        internal override CancellationTokenSource Deadline { get; }
    }

    internal virtual CookRun? Run => null;

    internal virtual LinkClient? Link => null;

    // Ends the connect and the handshake.
    internal virtual CancellationTokenSource? Deadline => null;

    /// <summary>What the status bar says, with the reason or the exit code.</summary>
    public string Describe() => this switch
    {
        Stopped => "stopped",
        FailedToStart failed => $"cannot start: {failed.Reason}",
        Refused refused => $"refused the cook link: {refused.Reason}",
        TimedOut timedOut => $"did not open the cook link within {timedOut.After.TotalSeconds:0.#} s",
        Exited exited => $"exited with code {exited.Code}",
        Connecting => "starting",
        Handshaking => "linking",
        Linked => "watching",
        LinkLost lost => $"lost the cook link ({lost.Reason}), linking again",
        _ => throw new UnreachableException(),
    };
}

/// <summary>A run of the daemon: its process, the port of its cook link, and how long it has run.</summary>
internal sealed class CookRun(IChildProcess process, int port)
{
    public IChildProcess Process => process;

    public int Port => port;

    public Stopwatch Uptime { get; } = Stopwatch.StartNew();
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
public sealed class CookSession : IPreviewCooker, IDisposable
{
    // The daemon listens soon after it starts.
    static readonly TimeSpan DefaultConnectTimeout = TimeSpan.FromSeconds(30);
    static readonly TimeSpan ConnectRetry = TimeSpan.FromMilliseconds(100);
    // A daemon that exits sooner than this after it starts, as when another cook holds the cache, is not started
    // again, so the editor does not start it over and over.
    static readonly TimeSpan RestartAfter = TimeSpan.FromSeconds(10);

    readonly CookOptions _options;
    readonly SynchronizationContext? _context;
    readonly StartProcess _start;
    readonly TimeSpan _connectTimeout;
    // The operations that wait for the daemon's answer, by request ID.
    readonly PendingReplies<TaskCompletionSource<OperationResult>> _requests;
    readonly PendingReplies<TaskCompletionSource<PreviewResult>> _previews;

    public CookSession(CookOptions options, AssetIndex index) : this(options, index, ChildProcess.Start, DefaultConnectTimeout)
    {
    }

    /// <summary>For tests: starts the daemon with <paramref name="start"/>, and waits <paramref name="connectTimeout"/> for its link.</summary>
    internal CookSession(CookOptions options, AssetIndex index, StartProcess start, TimeSpan connectTimeout)
    {
        _options = options;
        Index = index;
        _start = start;
        _connectTimeout = connectTimeout;
        _context = SynchronizationContext.Current;
        // Both kinds of request count from one ID. ID 0 is a message that wants no answer.
        var ids = new ReplyIds(skipZero: true);
        _requests = new(ids);
        _previews = new(ids);
    }

    public AssetIndex Index { get; }

    public CookState State { get; private set; } = new CookState.Stopped();

    /// <summary>The daemon sent its index and keeps it up to date.</summary>
    public bool Linked => State is CookState.Linked;

    /// <summary>The daemon's last cook since the link came up.</summary>
    public CookFinished? LastCook { get; private set; }

    /// <summary>How far the daemon's pass has got, while it cooks one that takes a while, or null.</summary>
    public CookProgress? Progress { get; private set; }

    /// <summary><see cref="State"/> changed. It is raised once for each change.</summary>
    public event Action? StateChanged;

    /// <summary>A line of the daemon's output that did not come over the link, or a line about the daemon from the editor.</summary>
    public event Action<string>? Output;

    /// <summary>A line of the daemon's log, over the link.</summary>
    public event Action<Log>? LogReceived;

    public event Action<CookFinished>? Cooked;

    public event Action? ProgressChanged;

    public void Start()
    {
        // The old daemon goes first, as two daemons of one cache cannot both run.
        Stop();
        if (!File.Exists(Path.Combine(_options.WorkingDirectory, _options.CookPath)))
        {
            Fail($"there is no cook daemon at {_options.CookPath}. Build it with just cook.");
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
        IChildProcess process;
        try
        {
            process = _start(_options.CookPath, args, _options.WorkingDirectory);
        }
        catch (Exception e)
        {
            Fail($"{_options.CookPath}: {e.Message}");
            return;
        }
        var run = new CookRun(process, port);
        process.Output += line => Post(() => Output?.Invoke(line));
        process.Exited += code => Post(() => OnExited(run, code));
        var deadline = NewDeadline();
        Become(new CookState.Connecting(run, deadline));
        _ = ConnectAsync(run, deadline);
    }

    /// <summary>
    /// Asks the daemon for an asset operation (see docs/content/daemon-and-operations.md#asset-operations), and completes with its
    /// answer, which comes after the index's changes. Without the cook link, it fails at once.
    /// </summary>
    public Task<OperationResult> Request(ILinkMessage operation)
    {
        if (State is not CookState.Linked linked)
        {
            return Task.FromResult(new OperationResult("The cook daemon is not running, so the content cannot change.", []));
        }
        var answer = new TaskCompletionSource<OperationResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var request = _requests.Add(answer);
        linked.Link.Send(operation, request);
        return answer.Task;
    }

    /// <summary>
    /// Asks the daemon to cook a material's unsaved text into the cache's preview area (see
    /// docs/rendering/materials.md#material-previews), and completes with its answer. Without the cook link, it fails at once.
    /// </summary>
    public Task<PreviewResult> CookPreview(string guid, string text, PlanQuery? plan = null)
    {
        if (State is not CookState.Linked linked)
        {
            return Task.FromResult(new PreviewResult("The cook daemon is not running.", [], []));
        }
        var answer = new TaskCompletionSource<PreviewResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var request = _previews.Add(answer);
        linked.Link.Send(new CookPreview(guid, text, plan == null ? [] : [plan]), request);
        return answer.Task;
    }

    public void Stop()
    {
        if (State is CookState.Running)
        {
            Become(new CookState.Stopped());
        }
    }

    void Fail(string reason)
    {
        Output?.Invoke($"editor: cannot start the cook daemon: {reason}");
        Become(new CookState.FailedToStart(reason));
    }

    // A deadline for one connect and its handshake. When it passes, the session times out if it still waits on it.
    CancellationTokenSource NewDeadline()
    {
        var deadline = new CancellationTokenSource(_connectTimeout);
        deadline.Token.Register(() => Post(() => OnTimedOut(deadline)));
        return deadline;
    }

    // Connects until the deadline. The state may change meanwhile, so OnConnected checks that it still waits.
    async Task ConnectAsync(CookRun run, CancellationTokenSource deadline)
    {
        while (!deadline.IsCancellationRequested)
        {
            try
            {
                var link = await LinkClient.ConnectAsync(run.Port, CookMessages.Read, deadline.Token);
                Post(() => OnConnected(run, deadline, link));
                return;
            }
            catch (SocketException)
            {
                // The daemon is not listening yet.
            }
            catch (OperationCanceledException)
            {
                return;
            }
            try
            {
                await Task.Delay(ConnectRetry, deadline.Token);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    void OnConnected(CookRun run, CancellationTokenSource deadline, LinkClient link)
    {
        if (State is not (CookState.Connecting or CookState.LinkLost) || State.Run != run || State.Deadline != deadline)
        {
            _ = link.DisposeAsync();
            return;
        }
        link.Received += (message, request) => Post(() => OnReceived(link, message, request));
        link.Closed += error => Post(() => OnLinkClosed(link, error));
        Become(new CookState.Handshaking(run, deadline, link));
        link.Start();
        link.Send(new Hello(CookMessages.ProtocolVersion, "cinnabar editor"));
    }

    void OnTimedOut(CancellationTokenSource deadline)
    {
        if (State.Deadline != deadline)
        {
            return;
        }
        Output?.Invoke($"editor: the cook daemon did not open the cook link on port {State.Run!.Port} within {_connectTimeout.TotalSeconds:0.#} s");
        Become(new CookState.TimedOut(_connectTimeout));
    }

    void OnReceived(LinkClient link, ILinkMessage message, uint request)
    {
        if (State.Link != link)
        {
            return;
        }
        switch (message)
        {
            case Welcome:
                Index.Apply(message);
                break;
            case AssetSnapshot:
                Index.Apply(message);
                // The daemon sends its index after the Welcome. From here the index is the daemon's latest.
                if (State is CookState.Handshaking handshaking)
                {
                    Become(new CookState.Linked(handshaking.Run, link));
                }
                break;
            case Refused refused:
                Output?.Invoke($"editor: the cook daemon refused the cook link: {refused.Reason}");
                if (State is CookState.Handshaking)
                {
                    Become(new CookState.Refused(refused.Reason));
                }
                break;
            case Log log:
                LogReceived?.Invoke(log);
                break;
            case CookProgress progress:
                Progress = progress;
                ProgressChanged?.Invoke();
                break;
            case CookFinished finished:
                LastCook = finished;
                Progress = null;
                Cooked?.Invoke(finished);
                break;
            case OperationResult result:
                if (_requests.TryTake(request, out var answer))
                {
                    answer.SetResult(result);
                }
                break;
            case PreviewResult preview:
                if (_previews.TryTake(request, out var cooked))
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
        if (State.Link != link)
        {
            return;
        }
        var reason = error?.Message ?? "the cook daemon closed it";
        Output?.Invoke($"editor: the cook link closed: {reason}. Connecting again.");
        var run = State.Run!;
        // A link that closes during its handshake keeps its deadline, so a daemon that keeps closing it times out.
        var deadline = State is CookState.Handshaking handshaking ? handshaking.Deadline : NewDeadline();
        Become(new CookState.LinkLost(run, deadline, reason));
        _ = ConnectAsync(run, deadline);
    }

    void OnExited(CookRun run, int code)
    {
        // A process that the editor stopped or replaced has already been dealt with.
        if (State.Run != run)
        {
            return;
        }
        Output?.Invoke($"editor: the cook daemon exited with code {code}");
        if (run.Uptime.Elapsed >= RestartAfter)
        {
            Output?.Invoke("editor: starting the cook daemon again");
            Start();
            return;
        }
        Become(new CookState.Exited(code));
    }

    static bool Allowed(CookState from, CookState to) => (from, to) switch
    {
        (not CookState.Running, CookState.Connecting or CookState.FailedToStart) => true,
        (CookState.Connecting, CookState.Handshaking or CookState.TimedOut) => true,
        (CookState.Handshaking, CookState.Linked or CookState.Refused or CookState.TimedOut or CookState.LinkLost) => true,
        (CookState.Linked, CookState.LinkLost) => true,
        (CookState.LinkLost, CookState.Handshaking or CookState.TimedOut) => true,
        (CookState.Running, CookState.Exited or CookState.Stopped) => true,
        _ => false,
    };

    // The one writer of State. It ends what the old state had and the new one does not carry: the deadline, the link
    // and the process, and with the link its requests and its cooks.
    void Become(CookState next)
    {
        var previous = State;
        if (!Allowed(previous, next))
        {
            throw new InvalidOperationException($"the cook session cannot go from {previous.GetType().Name} to {next.GetType().Name}");
        }
        State = next;
        if (previous.Deadline is { } deadline && deadline != next.Deadline)
        {
            deadline.Cancel();
        }
        if (previous.Link is { } link && link != next.Link)
        {
            _ = link.DisposeAsync();
        }
        if (previous.Run is { } run && run != next.Run)
        {
            // Closing the job kills the daemon.
            run.Process.Dispose();
        }
        if (previous is CookState.Linked)
        {
            FailRequests();
            LastCook = null;
            Progress = null;
        }
        Index.SetLinked(next is CookState.Linked);
        StateChanged?.Invoke();
    }

    // The daemon may have done an operation that it could not answer. Its next snapshot has the content as it is.
    void FailRequests()
    {
        _requests.FailAll(answer => answer.TrySetResult(new OperationResult("The cook link closed before the cook daemon answered.", [])));
        _previews.FailAll(answer => answer.TrySetResult(new PreviewResult("The cook link closed before the cook daemon answered.", [], [])));
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

    public void Dispose() => Stop();
}
