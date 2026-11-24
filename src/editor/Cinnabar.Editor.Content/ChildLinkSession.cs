using System.Diagnostics;
using System.Net.Sockets;
using Cinnabar.Editor.Link;

namespace Cinnabar.Editor.Content;

/// <summary>
/// What a link to one kind of child process has once it is up, and the names that its states use. The host's link
/// has its game, and the cook link nothing more than its sender.
/// </summary>
public interface IChildLink
{
    /// <summary>What the child is called in the status and the console, such as "host" or "cook daemon".</summary>
    static abstract string Child { get; }

    /// <summary>What its link is called, such as "editor link" or "cook link".</summary>
    static abstract string LinkName { get; }

    /// <summary>What the status says before the child can start.</summary>
    static abstract string Waiting { get; }

    /// <summary>What the status says while the child is linked.</summary>
    string Describe();
}

/// <summary>
/// Where a session with a child process is (see docs/editor/processes-and-projects.md#crash-recovery). Each state
/// carries what belongs to it: the running ones their process, the linked ones their link and what came with it, and
/// the failed ones their reason or code. Only <see cref="ChildLinkSession{TLink}"/> makes them.
/// </summary>
public abstract record LinkState<TLink> where TLink : IChildLink
{
    private protected LinkState()
    {
    }

    /// <summary>The session waits for what the child needs to start, such as the viewport's adapter.</summary>
    public sealed record Waiting : LinkState<TLink>;

    /// <summary>Not started, or stopped by the editor.</summary>
    public sealed record Stopped : LinkState<TLink>;

    /// <summary>The child could not start, as when it is not built.</summary>
    public sealed record FailedToStart(string Reason) : LinkState<TLink>;

    /// <summary>The child refused the link, as when its protocol is another. The editor stopped it.</summary>
    public sealed record Refused(string Reason) : LinkState<TLink>;

    /// <summary>The child did not link within the time. The editor stopped it.</summary>
    public sealed record TimedOut(TimeSpan After) : LinkState<TLink>;

    /// <summary>The child exited by itself: it crashed or quit.</summary>
    public sealed record Exited(int Code) : LinkState<TLink>;

    /// <summary>The child runs. Only the tests' link has no run.</summary>
    public abstract record Running : LinkState<TLink>
    {
        private protected Running(ChildRun? run) => Run = run;

        internal override ChildRun? Run { get; }
    }

    /// <summary>The child runs, and the editor connects to its link.</summary>
    public sealed record Connecting : Running
    {
        internal Connecting(ChildRun run, CancellationTokenSource deadline) : base(run) => Deadline = deadline;

        internal override CancellationTokenSource Deadline { get; }
    }

    /// <summary>The editor is connected and waits for the child's answer to its Hello.</summary>
    public sealed record Handshaking : Running
    {
        internal Handshaking(ChildRun run, CancellationTokenSource deadline, LinkClient link) : base(run) => (Deadline, Link) = (deadline, link);

        internal override CancellationTokenSource Deadline { get; }

        internal override LinkClient Link { get; }
    }

    /// <summary>The handshake is done, and the link is up.</summary>
    public sealed record Linked : Running
    {
        internal Linked(ChildRun? run, LinkClient? link, TLink info) : base(run) => (Link, Info) = (link, info);

        /// <summary>What the handshake gave, and how to send on the link.</summary>
        public TLink Info { get; }

        // Null only for the tests' link.
        internal override LinkClient? Link { get; }
    }

    /// <summary>The link closed while the child runs, and the editor connects again.</summary>
    public sealed record LinkLost : Running
    {
        internal LinkLost(ChildRun run, CancellationTokenSource deadline, string reason) : base(run) => (Deadline, Reason) = (deadline, reason);

        public string Reason { get; }

        internal override CancellationTokenSource Deadline { get; }
    }

    internal virtual ChildRun? Run => null;

    internal virtual LinkClient? Link => null;

    // Ends the connect and the handshake.
    internal virtual CancellationTokenSource? Deadline => null;

    /// <summary>The state's name, for the automation status.</summary>
    public string Name => GetType().Name;

    /// <summary>What the status bar says, with what the link gave, the reason or the exit code.</summary>
    public string Describe() => this switch
    {
        Waiting => TLink.Waiting,
        Stopped => "stopped",
        FailedToStart failed => $"cannot start: {failed.Reason}",
        Refused refused => $"refused the {TLink.LinkName}: {refused.Reason}",
        TimedOut timedOut => $"did not open the {TLink.LinkName} within {timedOut.After.TotalSeconds:0.#} s",
        Exited exited => $"exited with code {exited.Code}",
        Connecting => "starting",
        Handshaking => "linking",
        Linked linked => linked.Info.Describe(),
        LinkLost lost => $"lost the {TLink.LinkName} ({lost.Reason}), linking again",
        _ => throw new UnreachableException(),
    };

    internal static bool Allowed(LinkState<TLink> from, LinkState<TLink> to) => (from, to) switch
    {
        (not Running, Connecting or FailedToStart) => true,
        (Connecting, Handshaking or TimedOut) => true,
        (Handshaking, Linked or Refused or TimedOut or LinkLost) => true,
        (Linked, LinkLost) => true,
        (LinkLost, Handshaking or TimedOut) => true,
        (Running, Exited or Stopped) => true,
        // The tests' link, which has no child.
        (not Linked, Linked { Run: null }) => true,
        _ => false,
    };
}

/// <summary>A run of a child: its process, the port of its link, how long it has run, and the name it was given, if any.</summary>
internal sealed class ChildRun(IChildProcess process, int port, string? name = null)
{
    public IChildProcess Process => process;

    public int Port => port;

    public string? Name => name;

    public Stopwatch Uptime { get; } = Stopwatch.StartNew();
}

/// <summary>
/// The lifetime of a child process and its link (see docs/editor/processes-and-projects.md#processes): start, stop,
/// connect and connect again, the handshake's deadline, a lost link and an exit. The host's and the cook daemon's
/// sessions derive from it and add their protocol. Events are raised on the synchronization context that the session
/// was made on, which is the UI thread in the editor.
/// </summary>
public abstract class ChildLinkSession<TLink> : IDisposable where TLink : IChildLink
{
    static readonly TimeSpan ConnectRetry = TimeSpan.FromMilliseconds(100);

    /// <summary>The most log lines that wait for the UI thread. The console keeps no more than this.</summary>
    public const int LogBacklog = 5000;

    readonly SynchronizationContext? _context;
    readonly StartProcess _start;
    readonly TimeSpan _connectTimeout;

    protected ChildLinkSession(LinkState<TLink> initial, StartProcess start, TimeSpan connectTimeout)
    {
        State = initial;
        _start = start;
        _connectTimeout = connectTimeout;
        _context = SynchronizationContext.Current;
    }

    public LinkState<TLink> State { get; private set; }

    /// <summary>The handshake is done, and the link is up.</summary>
    public bool Linked => State is LinkState<TLink>.Linked;

    /// <summary>The running child's process id, for the capture sidecar and the automation status.</summary>
    public int? ProcessId => State.Run?.Process.Id;

    /// <summary>A line of the child's output that did not come over the link, or a line about the child from the editor.</summary>
    public event Action<string>? Output;

    /// <summary>The name that the running child was started with, or null.</summary>
    protected string? RunName => State.Run?.Name;

    /// <summary>The link's message reader.</summary>
    protected abstract MessageReader Read { get; }

    /// <summary>The Hello that starts the handshake.</summary>
    protected abstract ILinkMessage MakeHello();

    /// <summary>On the link's thread: takes a log line into the session's batch, and says whether it did.</summary>
    protected abstract bool TakeLog(ILinkMessage message);

    /// <summary>A message from the current link, on the session's context.</summary>
    protected abstract void OnMessage(ILinkMessage message, uint request);

    /// <summary><see cref="State"/> changed from <paramref name="previous"/>. Raised once for each change.</summary>
    protected abstract void OnStateChanged(LinkState<TLink> previous);

    /// <summary>The running child exited by itself. Starts it again and says so, or says no to end in Exited.</summary>
    protected virtual bool StartsAgain(TimeSpan uptime) => false;

    public void Stop()
    {
        if (State is LinkState<TLink>.Running)
        {
            Become(new LinkState<TLink>.Stopped());
        }
    }

    public void Dispose()
    {
        Stop();
        GC.SuppressFinalize(this);
    }

    protected void Say(string line) => Output?.Invoke(line);

    /// <summary>Starts the child with the arguments for a free port, and connects to it.</summary>
    protected void Launch(string path, Func<int, IEnumerable<string>> args, string workingDirectory, string? name = null)
    {
        var port = LinkClient.FreePort();
        IChildProcess process;
        try
        {
            process = _start(path, args(port), workingDirectory);
        }
        catch (Exception e)
        {
            Fail($"{path}: {e.Message}");
            return;
        }
        var run = new ChildRun(process, port, name);
        process.Output += line => Post(() => Output?.Invoke(line));
        process.Exited += code => Post(() => OnExited(run, code));
        var deadline = NewDeadline();
        Become(new LinkState<TLink>.Connecting(run, deadline));
        _ = ConnectAsync(run, deadline);
    }

    protected void Fail(string reason)
    {
        Say($"editor: cannot start the {TLink.Child}: {reason}");
        Become(new LinkState<TLink>.FailedToStart(reason));
    }

    /// <summary>Ends the handshake with what <paramref name="linked"/> makes of its link. It does nothing outside the handshake.</summary>
    protected bool CompleteHandshake(Func<LinkClient, TLink> linked)
    {
        if (State is not LinkState<TLink>.Handshaking handshaking)
        {
            return false;
        }
        Become(new LinkState<TLink>.Linked(handshaking.Run, handshaking.Link, linked(handshaking.Link)));
        return true;
    }

    /// <summary>The child refused the link. That ends the handshake, and only the handshake.</summary>
    protected void Refuse(string reason)
    {
        Say($"editor: the {TLink.Child} refused the {TLink.LinkName}: {reason}");
        if (State is LinkState<TLink>.Handshaking)
        {
            Become(new LinkState<TLink>.Refused(reason));
        }
    }

    /// <summary>For tests: links to no child, as a finished handshake does.</summary>
    protected void LinkWithoutChild(TLink info) => Become(new LinkState<TLink>.Linked(null, null, info));

    // A deadline for one connect and its handshake. When it passes, the session times out if it still waits on it.
    CancellationTokenSource NewDeadline()
    {
        var deadline = new CancellationTokenSource(_connectTimeout);
        deadline.Token.Register(() => Post(() => OnTimedOut(deadline)));
        return deadline;
    }

    // Connects until the deadline. The state may change meanwhile, so OnConnected checks that it still waits.
    async Task ConnectAsync(ChildRun run, CancellationTokenSource deadline)
    {
        while (!deadline.IsCancellationRequested)
        {
            try
            {
                var link = await LinkClient.ConnectAsync(run.Port, Read, deadline.Token);
                Post(() => OnConnected(run, deadline, link));
                return;
            }
            catch (SocketException)
            {
                // The child is not listening yet.
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

    void OnConnected(ChildRun run, CancellationTokenSource deadline, LinkClient link)
    {
        if (State is not (LinkState<TLink>.Connecting or LinkState<TLink>.LinkLost) || State.Run != run || State.Deadline != deadline)
        {
            _ = link.DisposeAsync();
            return;
        }
        link.Received += (message, request) =>
        {
            // A log line waits for the next batch, so a child that logs on each frame costs one post a batch.
            if (!TakeLog(message))
            {
                Post(() => OnReceived(link, message, request));
            }
        };
        link.Closed += error => Post(() => OnLinkClosed(link, error));
        Become(new LinkState<TLink>.Handshaking(run, deadline, link));
        link.Start();
        link.Send(MakeHello());
    }

    void OnTimedOut(CancellationTokenSource deadline)
    {
        if (State.Deadline != deadline)
        {
            return;
        }
        Say($"editor: the {TLink.Child} did not open the {TLink.LinkName} on port {State.Run!.Port} within {_connectTimeout.TotalSeconds:0.#} s");
        Become(new LinkState<TLink>.TimedOut(_connectTimeout));
    }

    void OnReceived(LinkClient link, ILinkMessage message, uint request)
    {
        if (State.Link == link)
        {
            OnMessage(message, request);
        }
    }

    void OnLinkClosed(LinkClient link, Exception? error)
    {
        if (State.Link != link)
        {
            return;
        }
        var reason = error?.Message ?? $"the {TLink.Child} closed it";
        Say($"editor: the {TLink.LinkName} closed: {reason}. Connecting again.");
        var run = State.Run!;
        // A link that closes during its handshake keeps its deadline, so a child that keeps closing it times out.
        var deadline = State is LinkState<TLink>.Handshaking handshaking ? handshaking.Deadline : NewDeadline();
        Become(new LinkState<TLink>.LinkLost(run, deadline, reason));
        _ = ConnectAsync(run, deadline);
    }

    void OnExited(ChildRun run, int code)
    {
        // A process that the editor stopped or replaced has already been dealt with.
        if (State.Run != run)
        {
            return;
        }
        Say($"editor: the {TLink.Child} exited with code {code}");
        if (StartsAgain(run.Uptime.Elapsed))
        {
            return;
        }
        Become(new LinkState<TLink>.Exited(code));
    }

    // The one writer of State. It ends what the old state had and the new one does not carry: the deadline, the link
    // and the process.
    void Become(LinkState<TLink> next)
    {
        var previous = State;
        if (!LinkState<TLink>.Allowed(previous, next))
        {
            throw new InvalidOperationException($"the {TLink.Child} session cannot go from {previous.Name} to {next.Name}");
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
            // Closing the job kills the child.
            run.Process.Dispose();
        }
        OnStateChanged(previous);
    }

    protected void Post(Action action)
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
}
