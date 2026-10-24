using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Threading.Channels;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Viewport;
using Vortice.DXGI;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// The editor link against a real host: build/host.exe running build/mygame.dll in shared mode. The test is skipped
/// when they are not built, and when the host cannot start its GPU device, such as on a machine without one.
/// </summary>
public sealed class HostLinkTests : IAsyncDisposable
{
    static readonly TimeSpan Timeout = TimeSpan.FromSeconds(30);

    readonly Process? _host;
    readonly int _port;
    // The host renders on the adapter that the test names, so the test can open its shared objects.
    readonly ulong _adapter;
    readonly ConcurrentQueue<string> _output = new();

    public HostLinkTests()
    {
        var root = RepositoryRoot();
        var hostPath = Path.Combine(root, "build", "host.exe");
        var gamePath = Path.Combine(root, "build", "mygame.dll");
        if (!File.Exists(hostPath) || !File.Exists(gamePath))
        {
            return;
        }
        _port = FreePort();
        _adapter = HighPerformanceAdapter();
        var info = new ProcessStartInfo(hostPath,
            [gamePath, "--shared", $"cinnabar-test-{Guid.NewGuid():N}", "--link", _port.ToString(), "--adapter", _adapter.ToString("x16")])
        {
            WorkingDirectory = root,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        _host = Process.Start(info)!;
        _host.OutputDataReceived += (_, e) => _output.Enqueue(e.Data ?? "");
        _host.ErrorDataReceived += (_, e) => _output.Enqueue(e.Data ?? "");
        _host.BeginOutputReadLine();
        _host.BeginErrorReadLine();
    }

    [Fact]
    public async Task TheHostWelcomesResizesAndSendsItsLog()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));

        var welcome = await editor.Next<Welcome>();
        Assert.Equal("mygame", welcome.Game);
        Assert.Equal(LinkMessages.ProtocolVersion, welcome.Protocol);
        // The host says that it linked, and that line comes over the link, not its console. It handles the Hello
        // before it sends the frame target of the frame.
        try
        {
            await editor.Next<Log>(l => l.Text.Contains("linked to test"));
        }
        catch (InvalidOperationException e)
        {
            Assert.Fail($"{e.Message}\nThe host's console:\n{string.Join("\n", _output)}");
        }
        var first = await editor.Next<FrameTarget>();
        Assert.Equal(0u, first.Generation);
        Assert.EndsWith(".g0", first.Prefix);

        editor.Link.Send(new ViewportSize(640, 360));
        var resized = await editor.Next<FrameTarget>();
        Assert.Equal(new FrameTarget(first.Prefix[..^1] + "1", 1, 640, 360), resized);
    }

    [Fact]
    public async Task WithoutAcknowledgementsTheHostStopsSharingFrames()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        var target = await editor.Next<FrameTarget>();
        using var device = new ViewportDevice(_adapter);
        using var frames = await Open(device, target.Prefix);

        // Paced from the Hello, the host shares two more frames and then renders into its scratch target.
        await Task.Delay(500, TestContext.Current.CancellationToken);
        var stalled = frames.Completed;
        await Task.Delay(300, TestContext.Current.CancellationToken);
        Assert.Equal(stalled, frames.Completed);

        // An acknowledgement lets exactly two more frames through.
        editor.Link.Send(new FrameAcknowledged(target.Generation, stalled));
        await Task.Delay(500, TestContext.Current.CancellationToken);
        Assert.Equal(stalled + 2, frames.Completed);
    }

    static async Task<SharedFrames> Open(ViewportDevice device, string prefix)
    {
        for (var i = 0; i < 100; i++)
        {
            if (SharedFrames.TryOpen(device, prefix) is { } frames)
            {
                return frames;
            }
            await Task.Delay(50, TestContext.Current.CancellationToken);
        }
        throw new InvalidOperationException($"cannot open {prefix}");
    }

    static ulong HighPerformanceAdapter()
    {
        using var factory = DXGI.CreateDXGIFactory2<IDXGIFactory6>(false);
        using var adapter = factory.EnumAdapterByGpuPreference<IDXGIAdapter1>(0, GpuPreference.HighPerformance);
        var luid = adapter.Description1.Luid;
        return (ulong)luid.LowPart | ((ulong)(uint)luid.HighPart << 32);
    }

    [Fact]
    public async Task TheGameSendsItsWorldAndAWatchedEntitysValues()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));

        var types = await editor.Next<ComponentTypes>();
        var transform = Assert.Single(types.Types, t => t.Name == "Transform");
        Assert.Equal(["position", "rotation", "scale"], transform.Fields.Select(f => f.Name));
        var snapshot = await editor.Next<EntitySnapshot>();
        // The game's own scene has a camera at scale 1.
        var placed = Assert.Single(snapshot.Entities, e => e.Name == "Camera");
        Assert.Contains(transform.Id, placed.Components);

        editor.Link.Send(new WatchEntity(placed.Entity));
        var values = await editor.Next<EntityValues>(v => v.Entity == placed.Entity);
        var data = Assert.Single(values.Components, c => c.Id == transform.Id).Data;
        Assert.Equal((int)transform.Size, data.Length);
        Assert.Equal("(1, 1, 1)", Model.FieldValues.Format(transform.Fields[2], data));
    }

    [Fact]
    public async Task TheEditorsSceneReplacesTheGamesWorld()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        var first = await editor.Next<EntitySnapshot>();
        Assert.Contains(first.Entities, e => e.Name == "Front Triangle");

        var path = Path.Combine(RepositoryRoot(), "samples", "mygame", "content", "scenes", "main.scene");
        var (scene, problems) = Document.SceneFile.Parse(File.ReadAllText(path));
        Assert.NotNull(scene);
        Assert.Empty(problems);
        var front = scene.Entities.Single(e => e.Name == "Front Triangle");
        front.Name = "Renamed";
        scene.Entities.Remove(scene.Entities.Single(e => e.Name == "Back Triangle"));
        scene.Entities.Add(new Document.SceneEntity(0x1234) { Name = "Child", Parent = front.Id });
        editor.Link.Send(Document.SceneSnapshot.ToMessage(scene));

        var loaded = await editor.Next<EntitySnapshot>(s => s.Entities.Any(e => e.Name == "Renamed"));
        Assert.Equal(["Camera", "Child", "Renamed"], loaded.Entities.Select(e => e.Name).Order());
        var renamed = loaded.Entities.Single(e => e.Name == "Renamed");
        Assert.Equal(front.Id, renamed.SceneId);
        Assert.Equal(renamed.Entity, loaded.Entities.Single(e => e.Name == "Child").Parent);
    }

    [Fact]
    public async Task TheGameAppliesEditsAndSendsBackWhatItCannot()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        var path = Path.Combine(RepositoryRoot(), "samples", "mygame", "content", "scenes", "main.scene");
        var document = new Document.SceneDocument(path, Document.SceneFile.Parse(File.ReadAllText(path)).Scene!);
        document.Applied += ops => editor.Link.Send(new ApplyOperations([.. ops.Select(o => o.ToWire())]));
        await editor.Next<EntitySnapshot>();
        var front = document.Scene.Entities.Single(e => e.Name == "Front Triangle");

        document.Apply("Rename", new Document.Rename(front.Id, "Edited"));
        document.Apply("Bad field", new Document.SetField(front.Id, 1001, "no_such_field", Document.SceneValue.Of(true)));

        var problems = await editor.Next<EditProblems>(p => !p.Snapshot);
        var problem = Assert.Single(problems.Problems);
        Assert.Equal(front.Id, problem.Entity);
        Assert.Contains("no_such_field", problem.Message);
        // The rename arrives with the next entity delta.
        await editor.Next<EntityDelta>(d => d.Changed.Any(e => e.SceneId == front.Id && e.Name == "Edited"));
    }

    [Fact]
    public async Task TheGameDrawsFromTheEditorsCameraAndAnswersPicks()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        // The game's world comes before the frame target, in the same poll.
        await editor.Next<EntitySnapshot>();
        var target = await editor.Next<FrameTarget>();

        // The scene's camera: 1 m in front of the front triangle, which is 0.2 m in front of the back one.
        editor.Link.Send(new EditorCamera([2516582400000000000, 0, -16777216], [0, 0, 0, 1], (float)(60 * Math.PI / 180), 0.05f));
        editor.Link.Send(new PickRequest(7, target.Width / 2, target.Height / 2, 1, 1));
        var center = await editor.Next<PickResult>(r => r.Id == 7);
        var hit = Assert.Single(center.Hits);
        Assert.Equal(0x37e9612990eb05d0UL, hit.SceneId);
        Assert.InRange(center.Depth, 1.35f, 1.45f);

        // A box over the whole frame finds both triangles, and nothing at the edge finds nothing.
        editor.Link.Send(new PickRequest(8, 0, 0, target.Width, target.Height));
        editor.Link.Send(new PickRequest(9, 0, 0, 1, 1));
        var all = await editor.Next<PickResult>(r => r.Id == 8);
        Assert.Equal([0x37e9612990eb05d0UL, 0x8c15900f0aab4d79UL], all.Hits.Select(h => h.SceneId).Order());
        var corner = await editor.Next<PickResult>(r => r.Id == 9);
        Assert.Empty(corner.Hits);
        Assert.Equal(0, corner.Depth);
    }

    [Fact]
    public async Task AnotherProtocolVersionIsRefused()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion + 1, "test"));

        var refused = await editor.Next<Refused>();
        Assert.Equal(LinkMessages.ProtocolVersion, refused.Protocol);
        Assert.Contains("protocol", refused.Reason);
    }

    async Task<Editor> Connect()
    {
        if (_host == null)
        {
            Assert.Skip("build/host.exe or build/mygame.dll is not built");
        }
        var deadline = DateTime.UtcNow + Timeout;
        while (true)
        {
            if (_host.HasExited)
            {
                var output = string.Join("\n", _output);
                if (output.Contains("d3d12: no adapter"))
                {
                    Assert.Skip("the host has no GPU here");
                }
                Assert.Fail($"the host exited with code {_host.ExitCode}:\n{output}");
            }
            try
            {
                var link = await LinkClient.ConnectAsync(_port, TestContext.Current.CancellationToken);
                return new Editor(link);
            }
            catch (SocketException) when (DateTime.UtcNow < deadline)
            {
                await Task.Delay(100, TestContext.Current.CancellationToken);
            }
        }
    }

    sealed class Editor : IAsyncDisposable
    {
        readonly Channel<ILinkMessage> _received = Channel.CreateUnbounded<ILinkMessage>();

        public LinkClient Link { get; }

        public Editor(LinkClient link)
        {
            Link = link;
            link.Received += (message, _) => _received.Writer.TryWrite(message);
            link.Closed += _ => _received.Writer.TryComplete();
            link.Start();
        }

        /// <summary>The next message of type T that matches, skipping the others, such as log lines.</summary>
        public async Task<T> Next<T>(Func<T, bool>? match = null) where T : ILinkMessage
        {
            using var timeout = new CancellationTokenSource(Timeout);
            var skipped = new List<ILinkMessage>();
            try
            {
                await foreach (var message in _received.Reader.ReadAllAsync(timeout.Token))
                {
                    if (message is T t && (match == null || match(t)))
                    {
                        return t;
                    }
                    skipped.Add(message);
                }
            }
            catch (OperationCanceledException)
            {
            }
            throw new InvalidOperationException($"no {typeof(T).Name} came. These did:\n{string.Join("\n", skipped)}");
        }

        public ValueTask DisposeAsync() => Link.DisposeAsync();
    }

    static string RepositoryRoot()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
        {
            if (File.Exists(Path.Combine(dir.FullName, "justfile")))
            {
                return dir.FullName;
            }
        }
        throw new InvalidOperationException("the tests do not run inside the repository");
    }

    static int FreePort()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    public async ValueTask DisposeAsync()
    {
        if (_host is { HasExited: false })
        {
            _host.Kill();
            await _host.WaitForExitAsync();
        }
        _host?.Dispose();
    }
}
