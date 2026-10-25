using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
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
        await editor.Next<EntitySnapshot>();
        var snapshot = await Load(editor, Scene(Entity(1, "Placed", scale: 2)));
        var placed = Assert.Single(snapshot.Entities);
        Assert.Contains(transform.Id, placed.Components);

        editor.Link.Send(new WatchEntity(placed.Entity));
        var values = await editor.Next<EntityValues>(v => v.Entity == placed.Entity);
        var data = Assert.Single(values.Components, c => c.Id == transform.Id).Data;
        Assert.Equal((int)transform.Size, data.Length);
        Assert.Equal("(2, 2, 2)", Model.FieldValues.Format(transform.Fields[2], data));
    }

    [Fact]
    public async Task TheEditorsSceneReplacesTheGamesWorld()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<EntitySnapshot>();

        var parent = Pulsing(1, "Parent");
        var child = Entity(2, "Child");
        child.Parent = parent.Id;
        var loaded = await Load(editor, Scene(parent, child));
        Assert.Equal(["Child", "Parent"], loaded.Entities.Select(e => e.Name).Order(StringComparer.Ordinal));
        var loadedParent = loaded.Entities.Single(e => e.Name == "Parent");
        Assert.Equal(parent.Id, loadedParent.SceneId);
        Assert.Equal(loadedParent.Entity, loaded.Entities.Single(e => e.Name == "Child").Parent);

        // In Edit, the game's own behaviours end with their entities, without their callbacks, and the scene's one is
        // left.
        await editor.Next<GameStats>(s => s.Behaviours == 1);
        Assert.DoesNotContain(editor.Skipped, m => m is Log { Level: LogLevel.Error });
    }

    [Fact]
    public async Task TheGameAppliesEditsAndSendsBackWhatItCannot()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        var spinner = Spinning(1, "Spinner");
        var path = Path.Combine(Path.GetTempPath(), $"cinnabar-test-{Guid.NewGuid():N}.scene");
        var document = new Document.SceneDocument(path, Scene(spinner));
        document.Applied += ops => editor.Link.Send(new ApplyOperations([.. ops.Select(o => o.ToWire())]));
        await editor.Next<EntitySnapshot>();
        await Load(editor, document.Scene);

        document.Apply("Rename", new Document.Rename(spinner.Id, "Edited"));
        document.Apply("Bad field", new Document.SetField(spinner.Id, SpinId, "no_such_field", Document.SceneValue.Of(true)));

        var problems = await editor.Next<EditProblems>(p => !p.Snapshot);
        var problem = Assert.Single(problems.Problems);
        Assert.Equal(spinner.Id, problem.Entity);
        Assert.Contains("no_such_field", problem.Message);
        // The rename arrives with the next entity delta.
        await editor.Next<EntityDelta>(d => d.Changed.Any(e => e.SceneId == spinner.Id && e.Name == "Edited"));
    }

    [Fact]
    public async Task TheGameDrawsFromTheEditorsCameraAndAnswersPicks()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        // The game's world comes before the frame target, in the same poll.
        await editor.Next<EntitySnapshot>();
        var target = await editor.Next<FrameTarget>();

        // Two boxes ahead of the camera: a small one whose face is 1.2 m away, in front of a larger one whose face is
        // 1.5 m away.
        var near = Box(1, "Near", z: 0.4, scale: 0.4);
        var far = Box(2, "Far", z: 1, scale: 1);
        var loaded = await Load(editor, Scene(near, far), "Far");
        editor.Link.Send(new EditorCamera([Origin, 0, -Meter], [0, 0, 0, 1], (float)(60 * Math.PI / 180), 0.05f));

        // A pick over the whole frame finds both, once their mesh has streamed in, so it is picked again until it has.
        ulong[] both = [near.Id, far.Id];
        ulong[] found = [];
        for (var attempt = 0u; attempt < 60 && !found.SequenceEqual(both); attempt++)
        {
            editor.Link.Send(new PickRequest(100 + attempt, 0, 0, target.Width, target.Height));
            var all = await editor.Next<PickResult>(r => r.Id == 100 + attempt);
            found = [.. all.Hits.Select(h => h.SceneId).Order()];
        }
        Assert.Equal(both, found);

        // The middle finds the near box at its depth, and the corner finds nothing.
        editor.Link.Send(new PickRequest(7, target.Width / 2, target.Height / 2, 1, 1));
        var center = await editor.Next<PickResult>(r => r.Id == 7);
        Assert.Equal(near.Id, Assert.Single(center.Hits).SceneId);
        Assert.InRange(center.Depth, 1.15f, 1.25f);
        editor.Link.Send(new PickRequest(9, 0, 0, 1, 1));
        var corner = await editor.Next<PickResult>(r => r.Id == 9);
        Assert.Empty(corner.Hits);
        Assert.Equal(0, corner.Depth);

        // A hidden entity is not drawn, so the pick sees through it to the far box.
        editor.Link.Send(new SetHidden([loaded.Entities.Single(e => e.SceneId == near.Id).Entity]));
        editor.Link.Send(new PickRequest(10, target.Width / 2, target.Height / 2, 1, 1));
        var behind = await editor.Next<PickResult>(r => r.Id == 10);
        Assert.Equal(far.Id, Assert.Single(behind.Hits).SceneId);
        Assert.InRange(behind.Depth, 1.45f, 1.55f);
    }

    [Fact]
    public async Task TheWorldRunsOnlyInPlayAndInPausedSteps()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<EntitySnapshot>();
        // It spins in a Fixed system, so its Transform changes only while the world runs.
        var spinner = Assert.Single((await Load(editor, Scene(Spinning(1, "Spinner")))).Entities).Entity;
        // The values as they are now: a watch sends them at once, and values that stream while the world runs are
        // dropped before the next look.
        async Task<string> Values()
        {
            editor.Link.Send(new WatchEntity(spinner));
            var values = await editor.Next<EntityValues>(v => v.Entity == spinner);
            editor.Link.Send(new UnwatchEntity(spinner));
            await Task.Delay(100, TestContext.Current.CancellationToken);
            editor.Drain();
            return string.Join(";", values.Components.Select(c => Convert.ToHexString(c.Data)));
        }

        // A linked editor starts in Edit, where nothing moves.
        var still = await Values();
        await Task.Delay(300, TestContext.Current.CancellationToken);
        Assert.Equal(still, await Values());

        editor.Link.Send(new SetMode(EditorMode.Play, false));
        await Task.Delay(300, TestContext.Current.CancellationToken);
        var played = await Values();
        Assert.NotEqual(still, played);

        editor.Link.Send(new SetMode(EditorMode.Paused, false));
        await Task.Delay(200, TestContext.Current.CancellationToken);
        var paused = await Values();
        await Task.Delay(300, TestContext.Current.CancellationToken);
        Assert.Equal(paused, await Values());
        editor.Link.Send(new StepFrame());
        await Task.Delay(200, TestContext.Current.CancellationToken);
        Assert.NotEqual(paused, await Values());
    }

    [Fact]
    public async Task TheGameDescribesItsCommandsAndSendsStats()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        var commands = await editor.Next<GameCommands>();
        Assert.Contains(commands.Commands, c => c.Id == "mygame.add_triangle" && c.Edits && c.Tab == "Game");
        await editor.Next<EntitySnapshot>();
        var snapshot = await Load(editor, Scene(Spinning(1, "Spinner"), Pulsing(2, "Pulsing")));

        var host = await editor.Next<HostStats>();
        Assert.True(host.Frames > 0 && host.Buffers > 0 && host.Pipelines > 0 && host.PermanentBytes > 0);
        // The game's own behaviours end with its world, and the scene's one is left.
        var game = await editor.Next<GameStats>(s => s.Entities == 2 && s.Behaviours == 1);
        Assert.Contains(game.Modules, m => m.Name == "game/scripts/pulse.luau" && m.Bytes > 0);

        editor.Link.Send(new RunGameCommand("mygame.world_report"));
        var report = await editor.Next<GameCommandResult>(r => r.Id == "mygame.world_report");
        Assert.Contains("2 entities", report.Message);
        Assert.Empty(report.Operations);

        // A command that edits sends operations by scene ID, and leaves the world as it is.
        var spinner = Assert.Single(snapshot.Entities, e => e.Name == "Spinner");
        editor.Link.Send(new SetSelection([spinner.Entity]));
        editor.Link.Send(new RunGameCommand("mygame.reverse_spin"));
        var reversed = await editor.Next<GameCommandResult>(r => r.Id == "mygame.reverse_spin");
        var op = Assert.Single(reversed.Operations);
        Assert.Equal((OperationKind.SetField, spinner.SceneId, SpinId), (op.Kind, op.Entity, op.Component));
        Assert.Equal(-1.0, Assert.Single(op.Fields).Value.Floats[0]);
    }

    [Fact]
    public async Task TheGameDrawsMaterialPreviewsWhenTheyChange()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<FrameTarget>();
        // The sample's gold: an instance of the engine's default material.
        editor.Link.Send(new OpenPreview(0, Convert.FromHexString("f6d3de3190e2dfb97d6834ed5101c4c0"), false));
        editor.Link.Send(new PreviewSettings(0, PreviewMesh.Sphere, new byte[16], 0.6f, 0.3f, 2.5f, 128, 96));
        var target = await editor.Next<PreviewTarget>();
        Assert.Equal((0u, 0u, 128, 96), (target.Id, target.Generation, target.Width, target.Height));
        Assert.EndsWith(".preview0.g0", target.Prefix);
        using var device = new ViewportDevice(_adapter);
        using var frames = await Open(device, target.Prefix);

        // The preview draws until its mesh, its pipelines and its textures are ready, and then stops, because gold does
        // not read the time.
        var last = await Settle(editor, frames, target);
        Assert.True(last > 0);
        var center = Pixel(device, frames.Texture(last), 64, 48);
        var corner = Pixel(device, frames.Texture(last), 2, 2);
        // AgX, the default tone mapper, takes the saturation out of the bright highlight, so gold is a pale one there.
        Assert.True(center.R > center.B + 25 && center.G > center.B, $"the sphere's middle is {center}, not gold");
        Assert.True(corner.R < 60 && corner.G < 60 && corner.B < 60, $"the corner is {corner}, not the background");

        // A new camera and mesh draw it again, and so does a new size, into a new generation.
        editor.Link.Send(new PreviewSettings(0, PreviewMesh.Cube, new byte[16], 1.2f, 0.5f, 3f, 128, 96));
        Assert.True(await Settle(editor, frames, target) > last);
        editor.Link.Send(new PreviewSettings(0, PreviewMesh.Cube, new byte[16], 1.2f, 0.5f, 3f, 64, 64));
        var resized = await editor.Next<PreviewTarget>(t => t.Generation == 1);
        Assert.Equal((64, 64), (resized.Width, resized.Height));
        editor.Link.Send(new ClosePreview(0));

        // An unsaved material comes from the cache's preview area. The checker's own blob stands in for one that the
        // cook daemon cooked there.
        const string Checker = "f7eadea8bd278c0ae71b61b681352a82";
        var cache = Path.Combine(RepositoryRoot(), "build", "cache", "dev");
        var unsavedBlob = Path.Combine(cache, "preview", Checker + ".blob");
        Directory.CreateDirectory(Path.GetDirectoryName(unsavedBlob)!);
        File.Copy(Path.Combine(cache, Checker + ".blob"), unsavedBlob, overwrite: true);
        try
        {
            editor.Link.Send(new OpenPreview(1, Convert.FromHexString(Checker), true));
            // The plane, seen from above.
            editor.Link.Send(new PreviewSettings(1, PreviewMesh.Plane, new byte[16], 0, 1.2f, 1.2f, 64, 64));
            var unsaved = await editor.Next<PreviewTarget>(t => t.Id == 1);
            using var checker = await Open(device, unsaved.Prefix);
            var drawn = await Settle(editor, checker, unsaved);
            var middle = Pixel(device, checker.Texture(drawn), 32, 32);
            Assert.True(middle.R > 100, $"the plane's middle is {middle}, not the checker's red or white");
            editor.Link.Send(new ClosePreview(1));
        }
        finally
        {
            File.Delete(unsavedBlob);
        }
    }

    // Settle acknowledges a preview's frames until it stops drawing, and gives its last frame.
    static async Task<ulong> Settle(Editor editor, SharedFrames frames, PreviewTarget target)
    {
        var last = frames.Completed;
        var still = 0;
        for (var i = 0; i < 400 && still < 20; i++)
        {
            await Task.Delay(25, TestContext.Current.CancellationToken);
            var completed = frames.Completed;
            editor.Link.Send(new PreviewAcknowledged(target.Id, target.Generation, completed));
            still = completed == last ? still + 1 : 0;
            last = completed;
        }
        Assert.Equal(20, still);
        return last;
    }

    // Pixel reads one pixel of a shared texture, as sRGB bytes.
    static (byte R, byte G, byte B) Pixel(ViewportDevice device, Vortice.Direct3D11.ID3D11Texture2D texture, int x, int y)
    {
        var desc = texture.Description;
        desc.Usage = Vortice.Direct3D11.ResourceUsage.Staging;
        desc.BindFlags = Vortice.Direct3D11.BindFlags.None;
        desc.CPUAccessFlags = Vortice.Direct3D11.CpuAccessFlags.Read;
        desc.MiscFlags = Vortice.Direct3D11.ResourceOptionFlags.None;
        using var staging = device.Device.CreateTexture2D(desc);
        device.Context.CopyResource(staging, texture);
        var mapped = device.Context.Map(staging, 0, Vortice.Direct3D11.MapMode.Read);
        try
        {
            var at = (int)(y * mapped.RowPitch) + x * 4;
            return (Marshal.ReadByte(mapped.DataPointer, at), Marshal.ReadByte(mapped.DataPointer, at + 1), Marshal.ReadByte(mapped.DataPointer, at + 2));
        }
        finally
        {
            device.Context.Unmap(staging, 0);
        }
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
                var link = await LinkClient.ConnectAsync(_port, LinkMessages.Read, TestContext.Current.CancellationToken);
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

        /// <summary>Every message that Next has passed over.</summary>
        public List<ILinkMessage> Skipped { get; } = [];

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
                    Skipped.Add(message);
                }
            }
            catch (OperationCanceledException)
            {
            }
            throw new InvalidOperationException($"no {typeof(T).Name} came. These did:\n{string.Join("\n", skipped)}");
        }

        /// <summary>Drops the messages that have come.</summary>
        public void Drain()
        {
            while (_received.Reader.TryRead(out _))
            {
            }
        }

        public ValueTask DisposeAsync() => Link.DisposeAsync();
    }

    // The tests' scenes are built here, each with only what its test looks at, so that they do not depend on the
    // sample's scene. They sit 1.5e11 m along x, in World_Position's units of 2^-24 m, as the sample's scenes do.
    const long Origin = 2516582400000000000;
    const long Meter = 1 << 24;
    // The sample's box mesh (models/shapes.gltf, 1 m across) and scripts/pulse.luau, which pulses a Triangle.
    const string BoxMesh = "89fc38c8aa19f0cf0cc161d2ab5e015b";
    const string PulseScript = "7142e05b3941bc44849ed0379727e60b";
    // The engine's Mesh_Renderer, and the game's Spin and Triangle (samples/mygame/game.odin).
    const ulong MeshRendererId = 33;
    const ulong SpinId = 1001;
    const ulong TriangleId = 1002;

    static Document.Scene Scene(params Document.SceneEntity[] entities)
    {
        var scene = new Document.Scene();
        scene.Entities.AddRange(entities);
        return scene;
    }

    // Entity is an entity with only a Transform, z meters ahead of the origin.
    static Document.SceneEntity Entity(ulong id, string name, double z = 0, double scale = 1)
    {
        var entity = new Document.SceneEntity(id) { Name = name };
        entity.Components.Add(new Document.SceneComponent(1, "Transform",
        [
            Field("position", Document.SceneValue.Of(Number(Origin), Number(0), Number((long)(z * Meter)))),
            Field("rotation", Document.SceneValue.Of(Number(0), Number(0), Number(0), Number(1))),
            Field("scale", Document.SceneValue.Of(Number(scale), Number(scale), Number(scale))),
        ]));
        return entity;
    }

    static Document.SceneEntity Box(ulong id, string name, double z, double scale)
    {
        var entity = Entity(id, name, z, scale);
        entity.Components.Add(new Document.SceneComponent(MeshRendererId, "Mesh_Renderer", [Field("mesh", Document.SceneValue.AssetRef(BoxMesh))]));
        return entity;
    }

    // Spinning turns at 1 radian per second while the world runs.
    static Document.SceneEntity Spinning(ulong id, string name)
    {
        var entity = Entity(id, name);
        entity.Components.Add(new Document.SceneComponent(SpinId, "Spin", [Field("speed", Document.SceneValue.Of(Number(1.0)))]));
        return entity;
    }

    // Pulsing is a triangle with the pulse behaviour.
    static Document.SceneEntity Pulsing(ulong id, string name)
    {
        var entity = Entity(id, name);
        entity.Components.Add(new Document.SceneComponent(TriangleId, "Triangle", [Field("brightness", Document.SceneValue.Of(Number(1.0)))]));
        entity.Behaviours.Add(new Document.SceneBehaviour(PulseScript, []));
        return entity;
    }

    static Document.SceneField Field(string name, Document.SceneValue value) => new(name, value);

    static Document.SceneNumber Number(long value) => Document.SceneNumber.Of(value);

    static Document.SceneNumber Number(double value) => Document.SceneNumber.Of(value);

    /// <summary>Replaces the game's world with a scene, as the editor does, and gives the world once it has loaded.</summary>
    static async Task<EntitySnapshot> Load(Editor editor, Document.Scene scene, string? name = null)
    {
        name ??= scene.Entities[0].Name;
        editor.Link.Send(Document.SceneSnapshot.ToMessage(scene));
        return await editor.Next<EntitySnapshot>(s => s.Entities.Any(e => e.Name == name) && s.Entities.Length == scene.Entities.Count);
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
