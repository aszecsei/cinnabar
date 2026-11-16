using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Threading.Channels;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// The editor link against a real host in build/dev, running build/dev/mygame.dll in shared mode with the sample's settings
/// and cooked content. Each test starts a host of its own. The tests here run on every host: <see cref="HostLinkTests"/>
/// runs them on host.exe, which renders with D3D12, and <see cref="NullHostTests"/> on null-host.exe, which renders with the
/// null GPU backend and so runs on a machine without a GPU. A test is skipped when its host or the game is not built.
/// </summary>
public abstract class HostTests : IAsyncDisposable
{
    protected static readonly TimeSpan Timeout = TimeSpan.FromSeconds(30);

    readonly Process? _host;
    readonly int _port;
    readonly string _missing;
    protected readonly ConcurrentQueue<string> _output = new();

    /// <param name="host">The host's executable in build/dev.</param>
    /// <param name="build">The recipes that build it and the game.</param>
    /// <param name="arguments">The host's arguments besides the game, the project and the link.</param>
    protected HostTests(string host, string build, Func<IEnumerable<string>> arguments)
    {
        var root = EditorOptions.RepositoryRoot();
        var hostPath = Path.Combine(root, "build", "dev", host);
        var gamePath = Path.Combine(root, "build", "dev", "mygame.dll");
        _missing = $"build/dev/{host} or build/dev/mygame.dll is not built: run {build}";
        if (!File.Exists(hostPath) || !File.Exists(gamePath))
        {
            return;
        }
        _port = FreePort();
        var info = new ProcessStartInfo(hostPath,
            // The project's settings name the scene that the game starts with (see docs/world/game-package.md#settings).
            [gamePath, "--project", Path.Combine(root, "samples", "mygame", "project.settings"), "--shared", $"cinnabar-test-{Guid.NewGuid():N}", "--link", _port.ToString(), .. arguments()])
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

    /// <summary>Why a host that exited before it linked cannot run here, from its console, or null when it should have.</summary>
    protected virtual string? CannotRun(string console) => null;

    // A pick that the game answers without drawing: of a viewport that is closed, of the Game view, or of a scene view
    // that has no camera yet. Each answer has its request's ID, no hits, no depth and no submesh.
    [Fact]
    public async Task PicksOfViewportsThatCannotBePickedAnswerWithNothing()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<EntitySnapshot>();
        await Load(editor, Scene(Box(1, "Box", z: 1, scale: 2)));

        // Viewport 1 is not open, viewport 2 is a scene view without a camera, and viewport 4 is the Game view.
        editor.Link.Send(new OpenViewport(2, ViewportKind.Scene, 320, 240));
        await Show(editor, 4, ViewportKind.Game, 320, 240);
        HashSet<uint> waiting = [11, 12, 14];
        foreach (var id in waiting)
        {
            editor.Link.Send(new PickRequest(id, id - 10, 0, 0, 320, 240));
        }
        while (waiting.Count > 0)
        {
            var result = await editor.Next<PickResult>(r => waiting.Contains(r.Id));
            waiting.Remove(result.Id);
            Assert.Empty(result.Hits);
            Assert.Equal((0f, -1), (result.Depth, result.Submesh));
        }
    }

    [Fact]
    public async Task TheHostWelcomesAnOpenViewportResizesItAndSendsItsLog()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));

        var welcome = await editor.Next<Welcome>();
        Assert.Equal("mygame", welcome.Game);
        Assert.Equal(LinkMessages.ProtocolVersion, welcome.Protocol);
        // The host says that it linked, and that line comes over the link, not its console.
        try
        {
            await editor.Next<Log>(l => l.Text.Contains("linked to test"));
        }
        catch (InvalidOperationException e)
        {
            Assert.Fail($"{e.Message}\nThe host's console:\n{string.Join("\n", _output)}");
        }
        // A viewport has a target only once the editor opens it, at the size it asks for.
        var first = await Show(editor, 0, ViewportKind.Scene, 1280, 720);
        Assert.Equal((0u, 0u, 1280, 720), (first.Viewport, first.Generation, first.Width, first.Height));
        Assert.EndsWith(".g0", first.Prefix);

        editor.Link.Send(new OpenViewport(0, ViewportKind.Scene, 640, 360));
        var resized = await editor.Next<ViewportTarget>(t => t.Viewport == 0 && t.Generation == 1);
        Assert.Equal(new ViewportTarget(0, first.Prefix[..^1] + "1", 1, 640, 360), resized);
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
        document.Applied += ops => editor.Link.Send(new ApplyOperations([.. ops.Select(o => o.ToWire()).OfType<Link.Protocol.Operation>()]));
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

        editor.Link.Send(new SetMode(EditorMode.Play));
        await Task.Delay(300, TestContext.Current.CancellationToken);
        var played = await Values();
        Assert.NotEqual(still, played);

        editor.Link.Send(new SetMode(EditorMode.Paused));
        await Task.Delay(200, TestContext.Current.CancellationToken);
        var paused = await Values();
        await Task.Delay(300, TestContext.Current.CancellationToken);
        Assert.Equal(paused, await Values());
        editor.Link.Send(new StepFrame());
        await Task.Delay(200, TestContext.Current.CancellationToken);
        Assert.NotEqual(paused, await Values());
    }

    [Fact]
    public async Task AnEditModeBehavioursWritesComeAsOperations()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<EntitySnapshot>();
        // The sample's Ring lays out its entity's children on a circle, in Edit too.
        var ring = Entity(1, "Ring");
        ring.Behaviours.Add(new Document.SceneBehaviour(RingScript, [Field("radius", Document.SceneValue.Of(Number(3.0)))]));
        Document.SceneEntity Child(ulong id)
        {
            // A child has its pose in the world and its Local_Transform, as the editor's reparent gives it.
            var child = Entity(id, $"Child {id}");
            child.Parent = 1;
            child.Components.Add(new Document.SceneComponent(2, "Local_Transform",
            [
                Field("offset", Document.SceneValue.Of(Number(0.0), Number(0.0), Number(0.0))),
                Field("rotation", Document.SceneValue.Of(Number(0.0), Number(0.0), Number(0.0), Number(1.0))),
                Field("scale", Document.SceneValue.Of(Number(1.0), Number(1.0), Number(1.0))),
            ]));
            return child;
        }
        var scene = Scene(ring, Child(2), Child(3));
        editor.Link.Send(Document.SceneSnapshot.ToMessage(scene, "", 7));

        // The game does not move the children: it sends their poses, as the editor's scene sets them.
        var batch = await editor.Next<BehaviourOperations>();
        Assert.Equal(7UL, batch.Scene);
        Assert.Equal("Ring", batch.Label);
        Assert.All(batch.Operations, op => Assert.Equal(OperationKind.SetField, op.Kind));
        Assert.Equal([2UL, 3UL], batch.Operations.Select(op => op.Entity).Distinct().Order());
        Assert.All(batch.Operations, op => Assert.Equal("offset", Assert.Single(op.Fields).Name));

        // Nothing more comes before the answer, and once the edit is the world's, the ring has settled.
        await Task.Delay(300, TestContext.Current.CancellationToken);
        Assert.DoesNotContain(editor.Skipped.Concat(Drained(editor)), m => m is BehaviourOperations);
        editor.Link.Send(new ApplyOperations(batch.Operations));
        editor.Link.Send(new BehaviourOperationsAnswer(batch.Ticket, true));
        await Task.Delay(500, TestContext.Current.CancellationToken);
        Assert.DoesNotContain(Drained(editor), m => m is BehaviourOperations);
        Assert.DoesNotContain(editor.Skipped, m => m is Log { Level: LogLevel.Error });
    }

    // The messages that have come, which it drops.
    static List<ILinkMessage> Drained(Editor editor)
    {
        var messages = new List<ILinkMessage>();
        while (editor.TryRead(out var message))
        {
            messages.Add(message);
        }
        return messages;
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

    // Show opens a viewport and gives its target. With keepUp, it acknowledges every frame of that target ahead of time, as
    // an editor that always keeps up would, so the game draws the viewport in every frame and its picks and captures run
    // without the test copying frames. A test of the back-pressure itself passes false.
    protected static async Task<ViewportTarget> Show(Editor editor, uint viewport = 0, ViewportKind kind = ViewportKind.Scene, int width = 1280, int height = 720, bool keepUp = true)
    {
        editor.Link.Send(new OpenViewport(viewport, kind, width, height));
        // A scene view draws, and so has a target, once it has a camera, as the editor sends with each one that it opens.
        if (kind == ViewportKind.Scene)
        {
            editor.Link.Send(new EditorCamera(viewport, [0, 0, 0], [0, 0, 0, 1], (float)(60 * Math.PI / 180), 0.05f, CameraProjection.Perspective, 0, 0));
        }
        var target = await editor.Next<ViewportTarget>(t => t.Viewport == viewport);
        if (keepUp)
        {
            editor.Link.Send(new ViewportAcknowledged(viewport, target.Generation, ulong.MaxValue / 2));
        }
        return target;
    }

    protected async Task<Editor> Connect()
    {
        if (_host == null)
        {
            Assert.Skip(_missing);
        }
        var deadline = DateTime.UtcNow + Timeout;
        while (true)
        {
            if (_host.HasExited)
            {
                var output = string.Join("\n", _output);
                if (CannotRun(output) is { } reason)
                {
                    Assert.Skip(reason);
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

    protected sealed class Editor : IAsyncDisposable
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

        /// <summary>The next message that has come, if any.</summary>
        public bool TryRead(out ILinkMessage message) => _received.Reader.TryRead(out message!);

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
    protected const long Origin = 2516582400000000000;
    protected const long Meter = 1 << 24;
    // The sample's box mesh (models/shapes.gltf, 1 m across) and scripts/pulse.luau, which pulses a Triangle.
    protected const string BoxMesh = "89fc38c8aa19f0cf0cc161d2ab5e015b";
    protected const string PulseScript = "7142e05b3941bc44849ed0379727e60b";
    // scripts/ring.luau, an edit-mode behaviour that lays out its entity's children on a circle.
    protected const string RingScript = "c433be522bd64beab865e9d8a30774b2";
    // The engine's Mesh_Renderer, and the game's Spin and Triangle (samples/mygame/game.odin).
    protected const ulong CameraId = 32;
    protected const ulong MeshRendererId = 33;
    protected const ulong PointLightId = 35;
    protected const ulong VolumeId = 42;
    protected const ulong EnvironmentId = 49;
    protected const ulong SpinId = 1001;
    protected const ulong TriangleId = 1002;

    protected static Document.Scene Scene(params Document.SceneEntity[] entities)
    {
        var scene = new Document.Scene();
        scene.Entities.AddRange(entities);
        return scene;
    }

    // Entity is an entity with only a Transform, z meters ahead of the origin.
    protected static Document.SceneEntity Entity(ulong id, string name, double z = 0, double scale = 1)
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

    protected static Document.SceneEntity Box(ulong id, string name, double z, double scale)
    {
        var entity = Entity(id, name, z, scale);
        entity.Components.Add(new Document.SceneComponent(MeshRendererId, "Mesh_Renderer", [Field("mesh", Document.SceneValue.AssetRef(BoxMesh))]));
        return entity;
    }

    // Spinning turns at 1 radian per second while the world runs.
    protected static Document.SceneEntity Spinning(ulong id, string name)
    {
        var entity = Entity(id, name);
        entity.Components.Add(new Document.SceneComponent(SpinId, "Spin", [Field("speed", Document.SceneValue.Of(Number(1.0)))]));
        return entity;
    }

    // Pulsing is a triangle with the pulse behaviour.
    protected static Document.SceneEntity Pulsing(ulong id, string name)
    {
        var entity = Entity(id, name);
        entity.Components.Add(new Document.SceneComponent(TriangleId, "Triangle", [Field("brightness", Document.SceneValue.Of(Number(1.0)))]));
        entity.Behaviours.Add(new Document.SceneBehaviour(PulseScript, []));
        return entity;
    }

    protected static Document.SceneField Field(string name, Document.SceneValue value) => new(name, value);

    protected static Document.SceneNumber Number(long value) => Document.SceneNumber.Of(value);

    protected static Document.SceneNumber Number(double value) => Document.SceneNumber.Of(value);

    /// <summary>Replaces the game's world with a scene, as the editor does, and gives the world once it has loaded.</summary>
    protected static async Task<EntitySnapshot> Load(Editor editor, Document.Scene scene, string? name = null, string guid = "")
    {
        name ??= scene.Entities[0].Name;
        editor.Link.Send(Document.SceneSnapshot.ToMessage(scene, guid));
        return await editor.Next<EntitySnapshot>(s => s.Entities.Any(e => e.Name == name) && s.Entities.Length == scene.Entities.Count);
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
