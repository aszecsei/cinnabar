using System.Diagnostics;
using System.Net.Sockets;
using Cinnabar.Editor.Content;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Host;

/// <summary>
/// Where the host session is (see docs/editor/processes-and-projects.md#crash-recovery). Each state carries what belongs
/// to it: the running ones their process, the linked ones their link and game, and the failed ones their reason or
/// code. Only <see cref="HostSession"/> makes them.
/// </summary>
public abstract record HostState
{
    private protected HostState()
    {
    }

    /// <summary>The viewport has not yet found the adapter that the host must render on.</summary>
    public sealed record Waiting : HostState;

    /// <summary>The user stopped the host.</summary>
    public sealed record Stopped : HostState;

    /// <summary>The host could not start, as when it is not built.</summary>
    public sealed record FailedToStart(string Reason) : HostState;

    /// <summary>The host refused the editor link, as when its protocol is another. The editor stopped it.</summary>
    public sealed record Refused(string Reason) : HostState;

    /// <summary>The host did not link within the time. The editor stopped it.</summary>
    public sealed record TimedOut(TimeSpan After) : HostState;

    /// <summary>The host exited by itself: it crashed or quit.</summary>
    public sealed record Exited(int Code) : HostState;

    /// <summary>The host runs. Only the tests' link has no run.</summary>
    public abstract record Running : HostState
    {
        private protected Running(HostRun? run) => Run = run;

        internal override HostRun? Run { get; }
    }

    /// <summary>The host runs, and the editor connects to its editor link.</summary>
    public sealed record Connecting : Running
    {
        internal Connecting(HostRun run, CancellationTokenSource deadline) : base(run) => Deadline = deadline;

        internal override CancellationTokenSource Deadline { get; }
    }

    /// <summary>The editor is connected and waits for the host's Welcome.</summary>
    public sealed record Handshaking : Running
    {
        internal Handshaking(HostRun run, CancellationTokenSource deadline, LinkClient link) : base(run) => (Deadline, Link) = (deadline, link);

        internal override CancellationTokenSource Deadline { get; }

        internal override LinkClient Link { get; }
    }

    /// <summary>The host sent its Welcome, and runs a game.</summary>
    public sealed record Linked : Running
    {
        internal Linked(HostRun? run, LinkClient? link, Action<ILinkMessage> send, string game) : base(run) => (Link, Send, Game) = (link, send, game);

        public string Game { get; }

        // Null only for the tests' link.
        internal override LinkClient? Link { get; }

        internal Action<ILinkMessage> Send { get; }
    }

    /// <summary>The editor link closed while the host runs, and the editor connects again.</summary>
    public sealed record LinkLost : Running
    {
        internal LinkLost(HostRun run, CancellationTokenSource deadline, string reason) : base(run) => (Deadline, Reason) = (deadline, reason);

        public string Reason { get; }

        internal override CancellationTokenSource Deadline { get; }
    }

    internal virtual HostRun? Run => null;

    internal virtual LinkClient? Link => null;

    // Ends the connect and the handshake.
    internal virtual CancellationTokenSource? Deadline => null;

    /// <summary>The state's name, for the automation status.</summary>
    public string Name => GetType().Name;

    /// <summary>What the status bar says, with the game, the reason or the exit code.</summary>
    public string Describe() => this switch
    {
        Waiting => "waiting for the viewport",
        Stopped => "stopped",
        FailedToStart failed => $"cannot start: {failed.Reason}",
        Refused refused => $"refused the editor link: {refused.Reason}",
        TimedOut timedOut => $"did not open the editor link within {timedOut.After.TotalSeconds:0.#} s",
        Exited exited => $"exited with code {exited.Code}",
        Connecting => "starting",
        Handshaking => "linking",
        Linked linked => $"running {linked.Game}, linked",
        LinkLost lost => $"lost the editor link ({lost.Reason}), linking again",
        _ => throw new UnreachableException(),
    };
}

/// <summary>A run of the host: its process, the port of its link, and the shared target name that it renders under.</summary>
internal sealed class HostRun(IChildProcess process, int port, string sharedName)
{
    public IChildProcess Process => process;

    public int Port => port;

    public string SharedName => sharedName;
}

/// <summary>
/// The host's lifetime and its editor link (see docs/editor/processes-and-projects.md#processes): start, stop, restart, crashes, and the
/// connection to the running host. Events are raised on the synchronization context that the session was made on,
/// which is the UI thread in the editor.
/// </summary>
public sealed class HostSession : IDisposable
{
    // The host listens soon after it starts, but loading the game can take a while on a cold disk.
    static readonly TimeSpan DefaultConnectTimeout = TimeSpan.FromSeconds(30);
    static readonly TimeSpan ConnectRetry = TimeSpan.FromMilliseconds(100);

    readonly EditorOptions _options;
    readonly SynchronizationContext? _context;
    readonly StartProcess _start;
    readonly TimeSpan _connectTimeout;
    ulong _adapter;
    int _starts;

    internal HostSession(EditorOptions options) : this(options, ChildProcess.Start, DefaultConnectTimeout)
    {
    }

    /// <summary>For tests: starts the host with <paramref name="start"/>, and waits <paramref name="connectTimeout"/> for its link.</summary>
    internal HostSession(EditorOptions options, StartProcess start, TimeSpan connectTimeout)
    {
        _options = options;
        _start = start;
        _connectTimeout = connectTimeout;
        _context = SynchronizationContext.Current;
    }

    public HostState State { get; private set; } = new HostState.Waiting();

    /// <summary>The host sent its Welcome, and the link is up.</summary>
    public bool Linked => State is HostState.Linked;

    /// <summary>The game that the linked host runs.</summary>
    public string? Game => (State as HostState.Linked)?.Game;

    /// <summary>The shared target name that the running host renders under. Each start gets a new one.</summary>
    public string? SharedName => State.Run?.SharedName;

    /// <summary>The running host's process id, for the capture sidecar and the automation status.</summary>
    public int? ProcessId => State.Run?.Process.Id;

    /// <summary>The host can start once the viewport has found the adapter.</summary>
    public bool CanStart => _adapter != 0;

    /// <summary><see cref="State"/> changed, from the state that it gives. It is raised once for each change.</summary>
    public event Action<HostState>? StateChanged;

    /// <summary>A line of the host's output that did not come through its logger, or a line about the host from the editor.</summary>
    public event Action<string>? Output;

    /// <summary>A line of the host's or the game's log, over the link.</summary>
    public event Action<Log>? LogReceived;

    public event Action<FrameTarget>? FrameTargetChanged;

    public event Action<ReloadKind>? GameReloaded;

    /// <summary>A message from the game's side of the link, such as the entity list.</summary>
    public event Action<ILinkMessage>? GameMessage;

    /// <summary>Starts the host on the adapter whose LUID the viewport found.</summary>
    public void Start(ulong adapter)
    {
        _adapter = adapter;
        Restart();
    }

    public void Restart()
    {
        if (!CanStart)
        {
            return;
        }
        Stop();
        var name = $"cinnabar-editor-{Environment.ProcessId}-{++_starts}";
        var port = LinkClient.FreePort();
        IChildProcess process;
        try
        {
            process = _start(_options.HostPath,
                _options.HostArguments("--shared", name, "--adapter", _adapter.ToString("x16"), "--link", port.ToString()),
                _options.HostDirectory);
        }
        catch (Exception e)
        {
            Output?.Invoke($"editor: cannot start {_options.HostPath}: {e.Message}");
            Become(new HostState.FailedToStart($"{_options.HostPath}: {e.Message}"));
            return;
        }
        var run = new HostRun(process, port, name);
        process.Output += line => Post(() => Output?.Invoke(line));
        process.Exited += code => Post(() => OnExited(run, code));
        var deadline = NewDeadline();
        Become(new HostState.Connecting(run, deadline));
        _ = ConnectAsync(run, deadline);
    }

    public void Stop()
    {
        if (State is HostState.Running)
        {
            Become(new HostState.Stopped());
        }
    }

    /// <summary>Sends a message to the host, if it is linked.</summary>
    public void Send(ILinkMessage message)
    {
        if (State is HostState.Linked linked)
        {
            linked.Send(message);
        }
    }

    /// <summary>For tests: links to no host, as a <c>Welcome</c> does, and gives what the editor sends to <paramref name="send"/>.</summary>
    internal void LinkForTests(Action<ILinkMessage> send) => Become(new HostState.Linked(null, null, send, "test"));

    // A deadline for one connect and its handshake. When it passes, the session times out if it still waits on it.
    CancellationTokenSource NewDeadline()
    {
        var deadline = new CancellationTokenSource(_connectTimeout);
        deadline.Token.Register(() => Post(() => OnTimedOut(deadline)));
        return deadline;
    }

    // Connects until the deadline. The state may change meanwhile, so OnConnected checks that it still waits.
    async Task ConnectAsync(HostRun run, CancellationTokenSource deadline)
    {
        while (!deadline.IsCancellationRequested)
        {
            try
            {
                var link = await LinkClient.ConnectAsync(run.Port, LinkMessages.Read, deadline.Token);
                Post(() => OnConnected(run, deadline, link));
                return;
            }
            catch (SocketException)
            {
                // The host is not listening yet.
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

    void OnConnected(HostRun run, CancellationTokenSource deadline, LinkClient link)
    {
        if (State is not (HostState.Connecting or HostState.LinkLost) || State.Run != run || State.Deadline != deadline)
        {
            _ = link.DisposeAsync();
            return;
        }
        link.Received += (message, _) => Post(() => OnReceived(link, message));
        link.Closed += error => Post(() => OnLinkClosed(link, error));
        Become(new HostState.Handshaking(run, deadline, link));
        link.Start();
        link.Send(new Hello(LinkMessages.ProtocolVersion, "cinnabar editor"));
    }

    void OnTimedOut(CancellationTokenSource deadline)
    {
        if (State.Deadline != deadline)
        {
            return;
        }
        Output?.Invoke($"editor: the host did not open the editor link on port {State.Run!.Port} within {_connectTimeout.TotalSeconds:0.#} s");
        Become(new HostState.TimedOut(_connectTimeout));
    }

    void OnReceived(LinkClient link, ILinkMessage message)
    {
        if (State.Link == link)
        {
            Receive(message);
        }
    }

    /// <summary>Handles a message from the linked host. Tests call it in place of the link.</summary>
    internal void Receive(ILinkMessage message)
    {
        switch (message)
        {
            case Welcome welcome:
                if (State is HostState.Handshaking handshaking)
                {
                    var link = handshaking.Link;
                    Output?.Invoke($"editor: linked to the host, which runs {welcome.Game}");
                    Become(new HostState.Linked(handshaking.Run, link, m => link.Send(m), welcome.Game));
                }
                break;
            case Refused refused:
                Output?.Invoke($"editor: the host refused the editor link: {refused.Reason}");
                if (State is HostState.Handshaking)
                {
                    Become(new HostState.Refused(refused.Reason));
                }
                break;
            case Log log:
                LogReceived?.Invoke(log);
                break;
            case FrameTarget target:
                FrameTargetChanged?.Invoke(target);
                break;
            case GameReloaded reloaded:
                GameReloaded?.Invoke(reloaded.Kind);
                break;
            case Hello or ViewportSize or FrameAcknowledged or WatchEntity or UnwatchEntity:
                Output?.Invoke($"editor: the host sent a message that only the editor sends: {message.GetType().Name}");
                break;
            default:
                GameMessage?.Invoke(message);
                break;
        }
    }

    void OnLinkClosed(LinkClient link, Exception? error)
    {
        if (State.Link != link)
        {
            return;
        }
        var reason = error?.Message ?? "the host closed it";
        Output?.Invoke($"editor: the editor link closed: {reason}. Connecting again.");
        var run = State.Run!;
        // A link that closes during its handshake keeps its deadline, so a host that keeps closing it times out.
        var deadline = State is HostState.Handshaking handshaking ? handshaking.Deadline : NewDeadline();
        Become(new HostState.LinkLost(run, deadline, reason));
        _ = ConnectAsync(run, deadline);
    }

    void OnExited(HostRun run, int code)
    {
        // A process that the editor stopped or replaced has already been dealt with.
        if (State.Run != run)
        {
            return;
        }
        Output?.Invoke($"editor: the host exited with code {code}");
        Become(new HostState.Exited(code));
    }

    static bool Allowed(HostState from, HostState to) => (from, to) switch
    {
        (not HostState.Running, HostState.Connecting or HostState.FailedToStart) => true,
        (HostState.Connecting, HostState.Handshaking or HostState.TimedOut) => true,
        (HostState.Handshaking, HostState.Linked or HostState.Refused or HostState.TimedOut or HostState.LinkLost) => true,
        (HostState.Linked, HostState.LinkLost) => true,
        (HostState.LinkLost, HostState.Handshaking or HostState.TimedOut) => true,
        (HostState.Running, HostState.Exited or HostState.Stopped) => true,
        // The tests' link, which has no host.
        (not HostState.Linked, HostState.Linked { Run: null }) => true,
        _ => false,
    };

    // The one writer of State. It ends what the old state had and the new one does not carry: the deadline, the link
    // and the process.
    void Become(HostState next)
    {
        var previous = State;
        if (!Allowed(previous, next))
        {
            throw new InvalidOperationException($"the host session cannot go from {previous.Name} to {next.Name}");
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
            // Closing the job kills the host.
            run.Process.Dispose();
        }
        StateChanged?.Invoke(previous);
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
