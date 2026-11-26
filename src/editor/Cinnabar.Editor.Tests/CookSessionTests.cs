using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Threading.Channels;
using Cinnabar.Editor.Content;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Cook;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// What the cook session does with the daemon's answers (see docs/content/daemon-and-operations.md#asset-operations): each
/// answer completes the request of its ID, a closed link fails what still waits, and a daemon that exits at once is not
/// started again. A fake process and a fake daemon stand in for cook.exe. The session's states are in
/// <see cref="SessionStateTests"/>.
/// </summary>
public sealed class CookSessionTests : IDisposable
{
    static readonly TimeSpan Wait = TimeSpan.FromSeconds(10);

    readonly TempDirectory _temp = new("cook-session");
    readonly ConcurrentQueue<FakeProcess> _started = new();

    CookSession NewSession(AssetIndex index)
    {
        Directory.CreateDirectory(_temp.Path);
        File.WriteAllText(_temp.Combine("cook.exe"), "");
        return new CookSession(new CookOptions("cook.exe", "cache", null, [("game", "content")], _temp.Path), index, (_, args, _) =>
        {
            var process = new FakeProcess([.. args]);
            _started.Enqueue(process);
            return process;
        }, Wait);
    }

    [Fact]
    public async Task EachAnswerCompletesItsOwnRequestAndAClosedLinkFailsTheRest()
    {
        var index = new AssetIndex();
        using var session = NewSession(index);
        // Without the link, a request fails at once.
        Assert.NotEqual("", (await session.Request(new Reimport([]))).Error);
        Assert.NotEqual("", (await session.CookPreview("01", "")).Error);

        session.Start();
        Assert.True(_started.TryDequeue(out var process));
        using var listener = new FakeDaemon(process.Port);
        var daemon = await listener.Accept();
        await daemon.Next();
        daemon.Send(new Welcome(CookMessages.ProtocolVersion, "dev", [new Root("game", _temp.Path)], [], [], []));
        daemon.Send(new AssetSnapshot([TestAssets.Make("01", AssetKind.Material, "red.material")], []));
        await Until(() => session.Linked);

        // An operation and a preview share one count of IDs, so each answer finds its own, whatever the order.
        var folder = session.Request(new CreateFolder("game", "a"));
        var preview = session.CookPreview("01", "material 1\n");
        var left = session.Request(new CreateFolder("game", "b"));
        var asked = new[] { await daemon.Next(), await daemon.Next(), await daemon.Next() };
        Assert.Equal(3, asked.Select(a => a.Request).Distinct().Count());
        Assert.DoesNotContain(asked, a => a.Request == 0);
        daemon.Send(new PreviewResult("", [], []), asked[1].Request);
        daemon.Send(new OperationResult("", ["02"], [], []), asked[0].Request);
        Assert.Equal(["02"], (await folder.WaitAsync(Wait, TestContext.Current.CancellationToken)).Guids);
        Assert.Equal("", (await preview.WaitAsync(Wait, TestContext.Current.CancellationToken)).Error);
        Assert.False(left.IsCompleted);

        // A cook's end is the session's last cook until the link closes.
        daemon.Send(new CookFinished(1, [new CookedCount(AssetKind.Material, 1)], 0, 5));
        await Until(() => session.LastCook != null);

        await daemon.DisposeAsync();
        Assert.Contains("closed", (await left.WaitAsync(Wait, TestContext.Current.CancellationToken)).Error);
        await Until(() => session.LastCook == null);
    }

    // A daemon that exits soon after it starts, as a second daemon of a cache does, would exit again.
    [Fact]
    public async Task ADaemonThatExitsAtOnceIsNotStartedAgain()
    {
        using var session = NewSession(new AssetIndex());
        session.Start();
        Assert.True(_started.TryDequeue(out var process));

        process.Exit(3);

        await Until(() => session.State is CookState.Exited { Code: 3 });
        Assert.Empty(_started);
    }

    static async Task Until(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow + Wait;
        while (!condition())
        {
            Assert.True(DateTime.UtcNow < deadline, "timed out");
            await Task.Delay(20, TestContext.Current.CancellationToken);
        }
    }

    public void Dispose() => _temp.Dispose();

    /// <summary>A process that runs until the session disposes it, or until the test makes it exit.</summary>
    sealed class FakeProcess(IReadOnlyList<string> args) : IChildProcess
    {
        public int Port => int.Parse(args[args.ToList().IndexOf("--link") + 1]);

        public int Id => 42;

        public event Action<string>? Output
        {
            add { }
            remove { }
        }

        public event Action<int>? Exited;

        public void Exit(int code) => Exited?.Invoke(code);

        public void Dispose()
        {
        }
    }

    /// <summary>The daemon's end of the link: it listens on the session's port.</summary>
    sealed class FakeDaemon : IDisposable
    {
        readonly TcpListener _listener;

        public FakeDaemon(int port)
        {
            _listener = new TcpListener(IPAddress.Loopback, port);
            _listener.Start();
        }

        public async Task<DaemonConnection> Accept()
        {
            using var timeout = new CancellationTokenSource(Wait);
            var tcp = await _listener.AcceptTcpClientAsync(timeout.Token);
            return new DaemonConnection(LinkClient.Accept(tcp, CookMessages.Read));
        }

        public void Dispose() => _listener.Stop();
    }

    sealed class DaemonConnection : IAsyncDisposable
    {
        readonly LinkClient _link;
        readonly Channel<(ILinkMessage Message, uint Request)> _received = Channel.CreateUnbounded<(ILinkMessage, uint)>();

        public DaemonConnection(LinkClient link)
        {
            _link = link;
            link.Received += (message, request) => _received.Writer.TryWrite((message, request));
            link.Closed += _ => _received.Writer.TryComplete();
            link.Start();
        }

        public void Send(ILinkMessage message, uint request = 0) => _link.Send(message, request);

        /// <summary>The next message from the session, with its request ID.</summary>
        public async Task<(ILinkMessage Message, uint Request)> Next()
        {
            using var timeout = new CancellationTokenSource(Wait);
            return await _received.Reader.ReadAsync(timeout.Token);
        }

        public ValueTask DisposeAsync() => _link.DisposeAsync();
    }
}
