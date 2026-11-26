using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Threading.Channels;
using Cinnabar.Editor.Content;
using Cinnabar.Editor.Host;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Cook;
using HostHello = Cinnabar.Editor.Link.Protocol.Hello;
using HostRefused = Cinnabar.Editor.Link.Protocol.Refused;
using HostWelcome = Cinnabar.Editor.Link.Protocol.Welcome;
using LinkMessages = Cinnabar.Editor.Link.Protocol.LinkMessages;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// The cook and host sessions' states (see docs/editor/processes-and-projects.md#crash-recovery): a refusal, a timeout
/// and a lost link each end in a state that names it. A fake process and a fake daemon or host stand in for the real
/// ones, so the tests need neither built. The timeouts and the base that both sessions share are the cook session's
/// tests; the host's are its own protocol's refusal and its link that comes back.
/// </summary>
public sealed class SessionStateTests : IDisposable
{
    // Long enough that no deadline passes by itself: a test that wants a timeout ends the deadline itself.
    static readonly TimeSpan Long = TimeSpan.FromSeconds(30);
    static readonly TimeSpan Wait = TimeSpan.FromSeconds(10);

    readonly TempDirectory _temp = new("session-state");
    readonly SerialContext _context = new();
    readonly ConcurrentQueue<FakeProcess> _started = new();

    IChildProcess StartFake(string path, IEnumerable<string> args, string workingDirectory)
    {
        var process = new FakeProcess([.. args]);
        _started.Enqueue(process);
        return process;
    }

    // A cook session started on the context, the states that it went through, and its process.
    (CookSession Session, List<CookState> States, FakeProcess Process) StartCook(AssetIndex index)
    {
        Directory.CreateDirectory(_temp.Path);
        File.WriteAllText(_temp.Combine("cook.exe"), "");
        var states = new List<CookState>();
        var session = _context.Run(() =>
        {
            var session = new CookSession(new CookOptions("cook.exe", "cache", null, [], _temp.Path), index, StartFake, Long);
            session.StateChanged += () => states.Add(session.State);
            session.Start();
            return session;
        });
        Assert.True(_started.TryDequeue(out var process));
        return (session, states, process);
    }

    (HostSession Session, List<HostState> States, FakeProcess Process) StartHost()
    {
        var states = new List<HostState>();
        var session = _context.Run(() =>
        {
            var session = new HostSession(new EditorOptions("host.exe", "game.dll"), StartFake, Long);
            session.StateChanged += _ => states.Add(session.State);
            session.Start(adapter: 1);
            return session;
        });
        Assert.True(_started.TryDequeue(out var process));
        return (session, states, process);
    }

    // Ends the deadline of the connect and handshake that the session waits on, as its timer does when it passes.
    void PassDeadline(CookSession session) => _context.Run(() =>
    {
        session.State.Deadline!.Cancel();
        return true;
    });

    [Fact]
    public async Task TheCookDaemonsRefusalStopsItWithItsReason()
    {
        var (session, _, process) = StartCook(new AssetIndex());
        using var peer = new FakePeer(process.Port, CookMessages.Read);
        await using var daemon = await peer.Accept();
        await daemon.Next<Hello>();

        daemon.Send(new Refused("the editor's protocol is old", 2));

        var refused = await Until<CookState.Refused>(() => session.State);
        Assert.Equal("the editor's protocol is old", refused.Reason);
        Assert.Contains(refused.Reason, refused.Describe());
        Assert.True(process.Disposed);
        Assert.Empty(_context.Errors);
    }

    [Fact]
    public async Task ACookDaemonThatDoesNotListenTimesOut()
    {
        var (session, _, process) = StartCook(new AssetIndex());
        Assert.IsType<CookState.Connecting>(_context.Run(() => session.State));

        PassDeadline(session);

        var timedOut = await Until<CookState.TimedOut>(() => session.State);
        Assert.Equal(Long, timedOut.After);
        Assert.Contains("30 s", timedOut.Describe());
        Assert.True(process.Disposed);
        Assert.Empty(_context.Errors);
    }

    [Fact]
    public async Task ACookDaemonThatDoesNotAnswerTheHelloTimesOut()
    {
        var (session, states, process) = StartCook(new AssetIndex());
        using var peer = new FakePeer(process.Port, CookMessages.Read);
        await using var daemon = await peer.Accept();
        await daemon.Next<Hello>();
        await Until<CookState.Handshaking>(() => session.State);

        PassDeadline(session);

        await Until<CookState.TimedOut>(() => session.State);
        Assert.True(process.Disposed);
        Assert.Equal(["Connecting", "Handshaking", "TimedOut"], _context.Run(() => states.Select(Name).ToList()));
        Assert.Empty(_context.Errors);
    }

    [Fact]
    public async Task ALostCookLinkConnectsAgainAndTheIndexIsLinkedOnlyOnceItsSnapshotComes()
    {
        var index = new AssetIndex();
        var (session, states, process) = StartCook(index);
        using var peer = new FakePeer(process.Port, CookMessages.Read);
        var daemon = await peer.Accept();
        await Link(daemon, index, session, "game");

        // The daemon closes the link and keeps running.
        await daemon.DisposeAsync();
        await using var again = await peer.Accept();
        await Link(again, index, session, "again");

        var seen = _context.Run(() => states.ToList());
        Assert.Equal(["Connecting", "Handshaking", "Linked", "LinkLost", "Handshaking", "Linked"], seen.Select(Name));
        var lost = Assert.IsType<CookState.LinkLost>(seen[3]);
        Assert.Contains(lost.Reason, lost.Describe());
        Assert.False(process.Disposed);
        // The index keeps its assets while the link is down.
        Assert.Single(index.Assets);
        Assert.Empty(_context.Errors);
    }

    // Welcome and the snapshot. Between them the session is still handshaking, and the index is not linked.
    async Task Link(PeerConnection daemon, AssetIndex index, CookSession session, string root)
    {
        await daemon.Next<Hello>();
        daemon.Send(new Welcome(CookMessages.ProtocolVersion, "dev", [new Root(root, _temp.Path)], [], [], []));
        await Until(() => index.FindRoot(root) != null);
        await Until<CookState.Handshaking>(() => session.State);
        Assert.False(_context.Run(() => index.Linked));

        daemon.Send(new AssetSnapshot([TestAssets.Make("01", AssetKind.Script, "a.luau")], []));
        await Until<CookState.Linked>(() => session.State);
        Assert.True(_context.Run(() => index.Linked && session.Linked && session.Index.Find("01") != null));
    }

    [Fact]
    public void AHostThatCannotStartFailsWithItsReason()
    {
        var output = new List<string>();
        var session = _context.Run(() =>
        {
            var session = new HostSession(new EditorOptions("host.exe", "game.dll"), (_, _, _) => throw new FileNotFoundException("host.exe is not there"), Long);
            session.Output += output.Add;
            session.Start(adapter: 1);
            return session;
        });

        var failed = Assert.IsType<HostState.FailedToStart>(_context.Run(() => session.State));
        Assert.Contains("host.exe", failed.Reason);
        Assert.Contains(_context.Run(() => output.ToList()), line => line.Contains("cannot start"));
        Assert.Empty(_context.Errors);
    }

    [Fact]
    public async Task TheHostsRefusalStopsItWithItsReason()
    {
        var (session, _, process) = StartHost();
        using var peer = new FakePeer(process.Port, LinkMessages.Read);
        await using var host = await peer.Accept();
        await host.Next<HostHello>();

        host.Send(new HostRefused("the editor's protocol is old", 2));

        var refused = await Until<HostState.Refused>(() => session.State);
        Assert.Equal("the editor's protocol is old", refused.Reason);
        Assert.Contains(refused.Reason, refused.Describe());
        Assert.True(process.Disposed);
        Assert.Null(_context.Run(() => session.SharedName));
        Assert.Empty(_context.Errors);
    }

    [Fact]
    public async Task ALostEditorLinkConnectsAgain()
    {
        var (session, states, process) = StartHost();
        using var peer = new FakePeer(process.Port, LinkMessages.Read);
        var host = await peer.Accept();
        await host.Next<HostHello>();
        host.Send(new HostWelcome(LinkMessages.ProtocolVersion, "mygame", 0));
        await Until<HostState.Linked>(() => session.State);
        Assert.Equal("mygame", _context.Run(() => session.Game));

        await host.DisposeAsync();
        await using var again = await peer.Accept();
        await again.Next<HostHello>();
        again.Send(new HostWelcome(LinkMessages.ProtocolVersion, "mygame", 0));
        await Until<HostState.Linked>(() => session.State);

        var seen = _context.Run(() => states.ToList());
        Assert.Equal(["Connecting", "Handshaking", "Linked", "LinkLost", "Handshaking", "Linked"], seen.Select(s => s.Name));
        var lost = Assert.IsType<HostState.LinkLost>(seen[3]);
        Assert.Contains(lost.Reason, lost.Describe());
        Assert.False(process.Disposed);
        Assert.NotNull(_context.Run(() => session.SharedName));
        Assert.Empty(_context.Errors);
    }

    static string Name(CookState state) => state.GetType().Name;

    // Waits until the state, read on the context, is a T, and gives it.
    async Task<T> Until<T>(Func<object> state) where T : class
    {
        T? found = null;
        await Until(() => (found = state() as T) != null, () => $"a {typeof(T).Name}, but the state is {state()}");
        return found!;
    }

    Task Until(Func<bool> condition) => Until(condition, () => "the condition");

    // The sessions change only on the context, so the condition is read again after each turn that the context runs.
    // The time limit only ends a test that would otherwise hang.
    async Task Until(Func<bool> condition, Func<string> what)
    {
        var deadline = DateTime.UtcNow + Wait;
        while (!_context.Run(condition))
        {
            var left = deadline - DateTime.UtcNow;
            if (left <= TimeSpan.Zero || !await _context.Turns.WaitAsync(left, TestContext.Current.CancellationToken))
            {
                Assert.Fail($"timed out waiting for {_context.Run(what)}. Errors: {string.Join("\n", _context.Errors)}");
            }
        }
    }

    public void Dispose()
    {
        _context.Dispose();
        _temp.Dispose();
    }

    /// <summary>
    /// Runs what is posted on one thread, in order, as the UI thread does, and keeps what threw. Each turn that it runs
    /// for the sessions, and not for the test's own reads, releases <see cref="Turns"/>.
    /// </summary>
    sealed class SerialContext : SynchronizationContext, IDisposable
    {
        readonly BlockingCollection<(SendOrPostCallback Callback, object? State, bool Read)> _queue = [];

        public ConcurrentQueue<Exception> Errors { get; } = new();

        public SemaphoreSlim Turns { get; } = new(0);

        public SerialContext()
        {
            var thread = new Thread(() =>
            {
                SetSynchronizationContext(this);
                foreach (var (callback, state, read) in _queue.GetConsumingEnumerable())
                {
                    try
                    {
                        callback(state);
                    }
                    catch (Exception e)
                    {
                        Errors.Enqueue(e);
                    }
                    if (!read)
                    {
                        Turns.Release();
                    }
                }
            })
            { IsBackground = true, Name = "session-state-tests" };
            thread.Start();
        }

        public override void Post(SendOrPostCallback d, object? state) => Add(d, state, read: false);

        void Add(SendOrPostCallback d, object? state, bool read)
        {
            try
            {
                _queue.Add((d, state, read));
            }
            catch (InvalidOperationException)
            {
                // Disposed: the test is over.
            }
        }

        public T Run<T>(Func<T> function)
        {
            var done = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
            Add(_ =>
            {
                try
                {
                    done.SetResult(function());
                }
                catch (Exception e)
                {
                    done.SetException(e);
                }
            }, null, read: true);
            return done.Task.WaitAsync(SessionStateTests.Wait).GetAwaiter().GetResult();
        }

        public void Dispose() => _queue.CompleteAdding();
    }

    /// <summary>A process that runs until the session disposes it.</summary>
    sealed class FakeProcess(IReadOnlyList<string> args) : IChildProcess
    {
        volatile bool _disposed;

        public int Port => int.Parse(args[args.ToList().IndexOf("--link") + 1]);

        public bool Disposed => _disposed;

        public int Id => 42;

        public event Action<string>? Output
        {
            add { }
            remove { }
        }

        public event Action<int>? Exited
        {
            add { }
            remove { }
        }

        public void Dispose() => _disposed = true;
    }

    /// <summary>The daemon's or the host's end of the link: it listens on the session's port.</summary>
    sealed class FakePeer : IDisposable
    {
        readonly TcpListener _listener;
        readonly MessageReader _read;

        public FakePeer(int port, MessageReader read)
        {
            _read = read;
            _listener = new TcpListener(IPAddress.Loopback, port);
            _listener.Start();
        }

        public async Task<PeerConnection> Accept()
        {
            using var timeout = new CancellationTokenSource(Wait);
            var tcp = await _listener.AcceptTcpClientAsync(timeout.Token);
            return new PeerConnection(LinkClient.Accept(tcp, _read));
        }

        public void Dispose() => _listener.Stop();
    }

    sealed class PeerConnection : IAsyncDisposable
    {
        readonly LinkClient _link;
        readonly Channel<ILinkMessage> _received = Channel.CreateUnbounded<ILinkMessage>();

        public PeerConnection(LinkClient link)
        {
            _link = link;
            link.Received += (message, _) => _received.Writer.TryWrite(message);
            link.Closed += _ => _received.Writer.TryComplete();
            link.Start();
        }

        public void Send(ILinkMessage message) => _link.Send(message);

        public async Task<T> Next<T>() where T : ILinkMessage
        {
            using var timeout = new CancellationTokenSource(Wait);
            await foreach (var message in _received.Reader.ReadAllAsync(timeout.Token))
            {
                if (message is T t)
                {
                    return t;
                }
            }
            throw new InvalidOperationException($"the link closed before a {typeof(T).Name} came");
        }

        public ValueTask DisposeAsync() => _link.DisposeAsync();
    }
}
