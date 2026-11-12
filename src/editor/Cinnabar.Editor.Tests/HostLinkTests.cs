using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading.Channels;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Viewport;
using SkiaSharp;
using Vortice.DXGI;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// The editor link against a real host: build/dev/host.exe running build/dev/mygame.dll in shared mode. The test is skipped
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
        var root = EditorOptions.RepositoryRoot();
        var hostPath = Path.Combine(root, "build", "dev", "host.exe");
        var gamePath = Path.Combine(root, "build", "dev", "mygame.dll");
        if (!File.Exists(hostPath) || !File.Exists(gamePath))
        {
            return;
        }
        _port = FreePort();
        _adapter = HighPerformanceAdapter();
        var info = new ProcessStartInfo(hostPath,
            // The project's settings name the scene that the game starts with (see docs/world/game-package.md#settings).
            [gamePath, "--project", Path.Combine(root, "samples", "mygame", "project.settings"), "--shared", $"cinnabar-test-{Guid.NewGuid():N}", "--link", _port.ToString(), "--adapter", _adapter.ToString("x16")])
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
    public async Task WithoutAcknowledgementsTheHostStopsSharingFrames()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        var target = await Show(editor, keepUp: false);
        using var device = new ViewportDevice(_adapter);
        using var frames = await Open(device, target.Prefix);

        // Paced from the viewport's opening, the host shares two frames and then renders into its scratch target.
        await Task.Delay(500, TestContext.Current.CancellationToken);
        var stalled = frames.Completed;
        await Task.Delay(300, TestContext.Current.CancellationToken);
        Assert.Equal(stalled, frames.Completed);

        // An acknowledgement lets exactly two more frames through.
        editor.Link.Send(new ViewportAcknowledged(target.Viewport, target.Generation, stalled));
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

    // Opens a viewport of the game, as the editor does when its control has a size, and waits for the target that the game
    // makes for it.
    // Show opens a viewport and gives its target. With keepUp, it acknowledges every frame of that target ahead of time, as
    // an editor that always keeps up would, so the game draws the viewport in every frame and its picks and captures run
    // without the test copying frames. A test of the back-pressure itself passes false.
    static async Task<ViewportTarget> Show(Editor editor, uint viewport = 0, ViewportKind kind = ViewportKind.Scene, int width = 1280, int height = 720, bool keepUp = true)
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
    public async Task TheGameDrawsFromTheEditorsCameraAndAnswersPicks()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<EntitySnapshot>();
        var target = await Show(editor);

        // Two boxes ahead of the camera: a small one whose face is 1.2 m away, in front of a larger one whose face is
        // 1.5 m away.
        var near = Box(1, "Near", z: 0.4, scale: 0.4);
        var far = Box(2, "Far", z: 1, scale: 1);
        var loaded = await Load(editor, Scene(near, far), "Far");
        editor.Link.Send(new EditorCamera(0, [Origin, 0, -Meter], [0, 0, 0, 1], (float)(60 * Math.PI / 180), 0.05f, CameraProjection.Perspective, 0, 0));

        // A pick over the whole frame finds both, once their mesh has streamed in, so it is picked again until it has.
        ulong[] both = [near.Id, far.Id];
        ulong[] found = [];
        for (var attempt = 0u; attempt < 60 && !found.SequenceEqual(both); attempt++)
        {
            editor.Link.Send(new PickRequest(100 + attempt, 0, 0, 0, target.Width, target.Height));
            var all = await editor.Next<PickResult>(r => r.Id == 100 + attempt);
            found = [.. all.Hits.Select(h => h.SceneId).Order()];
        }
        Assert.Equal(both, found);

        // The middle finds the near box at its depth, and the corner finds nothing.
        editor.Link.Send(new PickRequest(7, 0, target.Width / 2, target.Height / 2, 1, 1));
        var center = await editor.Next<PickResult>(r => r.Id == 7);
        Assert.Equal(near.Id, Assert.Single(center.Hits).SceneId);
        Assert.InRange(center.Depth, 1.15f, 1.25f);
        Assert.Equal(0, center.Submesh);
        editor.Link.Send(new PickRequest(9, 0, 0, 0, 1, 1));
        var corner = await editor.Next<PickResult>(r => r.Id == 9);
        Assert.Empty(corner.Hits);
        Assert.Equal(0, corner.Depth);
        Assert.Equal(-1, corner.Submesh);

        // A hidden entity is not drawn, so the pick sees through it to the far box.
        editor.Link.Send(new SetHidden([loaded.Entities.Single(e => e.SceneId == near.Id).Entity]));
        editor.Link.Send(new PickRequest(10, 0, target.Width / 2, target.Height / 2, 1, 1));
        var behind = await editor.Next<PickResult>(r => r.Id == 10);
        Assert.Equal(far.Id, Assert.Single(behind.Hits).SceneId);
        Assert.InRange(behind.Depth, 1.45f, 1.55f);
    }

    [Fact]
    public async Task AnOrthographicSceneViewDrawsAndAnswersItsPicksAtTheRightDepth()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<EntitySnapshot>();
        var target = await Show(editor, 0, ViewportKind.Scene, 640, 360);
        using var device = new ViewportDevice(_adapter);
        using var frames = await Open(device, target.Prefix);

        // Two boxes on the z axis, a small one at 0.4 m and a larger one at 1 m, under a red background, seen along +z
        // from 1 m before the origin by a camera that shows 4 m from bottom to top: 90 pixels to a meter, at every
        // distance.
        var near = Box(1, "Near", z: 0.4, scale: 0.4);
        var far = Box(2, "Far", z: 1, scale: 1);
        var volume = Entity(3, "Volume");
        volume.Components.Add(new Document.SceneComponent(VolumeId, "Volume", [Field("shape", Document.SceneValue.Name("Global"))]));
        volume.Components.Add(new Document.SceneComponent(EnvironmentId, "Environment", [Field("background", Document.SceneValue.Of(Number(1.0), Number(0.0), Number(0.0)))]));
        await Load(editor, Scene(near, far, volume), "Far");
        var fov = (float)(60 * Math.PI / 180);
        editor.Link.Send(new EditorCamera(0, [Origin, 0, -Meter], [0, 0, 0, 1], fov, 0.05f, CameraProjection.Orthographic, 4, 100));
        editor.Link.Send(new SetViewportSettings(0, EditorShell.DefaultViewportSettings with { DebugView = DebugView.Albedo, ShowIcons = false }));
        async Task<ulong> Drawn()
        {
            for (var i = 0; i < 20; i++)
            {
                await Task.Delay(25, TestContext.Current.CancellationToken);
                editor.Link.Send(new ViewportAcknowledged(target.Viewport, target.Generation, frames.Completed));
            }
            return frames.Completed;
        }
        async Task<PickResult> Pick(uint id, int x, int y, int width = 1, int height = 1)
        {
            editor.Link.Send(new PickRequest(id, 0, x, y, width, height));
            editor.Link.Send(new ViewportAcknowledged(target.Viewport, target.Generation, frames.Completed));
            return await editor.Next<PickResult>(r => r.Id == id);
        }

        // Both boxes are in the frame once the mesh has streamed in.
        ulong[] found = [];
        for (var attempt = 0u; attempt < 60 && found.Length != 2; attempt++)
        {
            found = [.. (await Pick(100 + attempt, 0, 0, target.Width, target.Height)).Hits.Select(h => h.SceneId).Order()];
        }
        Assert.Equal([near.Id, far.Id], found);
        var shown = await Drawn();
        Assert.True(shown > 0, "the orthographic viewport drew no frame");
        var background = Pixel(device, frames.Texture(shown), 2, 2);
        Assert.True(background.R > 240 && background.G < 20 && background.B < 20, $"the background is {background}, not the albedo view's red");
        var box = Pixel(device, frames.Texture(shown), target.Width / 2, target.Height / 2);
        Assert.False(box.R > 240 && box.G < 20 && box.B < 20, "the middle of the frame shows no box");

        // The middle is the small box's front face, 1.2 m along the view.
        var (centerX, centerY) = (target.Width / 2, target.Height / 2);
        var front = await Pick(200, centerX, centerY);
        Assert.Equal(near.Id, Assert.Single(front.Hits).SceneId);
        Assert.InRange(front.Depth, 1.15f, 1.25f);
        // 32 pixels to the side is 0.36 m off the axis at every distance: past the small box, whose half width is
        // 0.2 m, and on the larger one's front face, 1.5 m along the view. A perspective camera would see the small
        // box there.
        var side = await Pick(201, centerX + 32, centerY);
        Assert.Equal(far.Id, Assert.Single(side.Hits).SceneId);
        Assert.InRange(side.Depth, 1.45f, 1.55f);
        // The larger box is 1 m, so 90 pixels, tall: 40 pixels up is on it, and 50 is past it.
        Assert.Equal(far.Id, Assert.Single((await Pick(202, centerX, centerY - 40)).Hits).SceneId);
        Assert.Empty((await Pick(203, centerX, centerY - 50)).Hits);

        // The frames keep coming, lit, at each quality and with each global illumination, anti-aliasing and reflections:
        // those that take a perspective give way to what an orthographic view draws in their place.
        async Task Draws(ViewportSettings quality, string what)
        {
            editor.Link.Send(new SetViewportSettings(0, quality with { ShowIcons = false }));
            var before = await Drawn();
            var after = await Drawn();
            Assert.True(after > before, $"the orthographic viewport stopped drawing with {what}");
        }
        foreach (var preset in Enum.GetValues<ViewportPreset>())
        {
            await Draws(EditorShell.DefaultViewportSettings with { QualityPreset = preset }, $"the {preset} preset");
        }
        foreach (var gi in Enum.GetValues<ViewportGi>())
        {
            await Draws(EditorShell.DefaultViewportSettings with { GlobalIllumination = gi }, $"{gi} global illumination");
        }
        foreach (var aa in Enum.GetValues<ViewportAa>())
        {
            await Draws(EditorShell.DefaultViewportSettings with { AntiAliasing = aa, RenderScale = 0.5f }, $"{aa} anti-aliasing");
        }
        foreach (var reflections in Enum.GetValues<ViewportReflections>())
        {
            await Draws(EditorShell.DefaultViewportSettings with { Reflections = reflections }, $"{reflections} reflections");
        }
        // The pick still answers after them all.
        editor.Link.Send(new SetViewportSettings(0, EditorShell.DefaultViewportSettings with { ShowIcons = false }));
        await Drawn();
        Assert.Equal(near.Id, Assert.Single((await Pick(300, centerX, centerY)).Hits).SceneId);
    }

    [Fact]
    public async Task TwoSceneViewsShowTheSceneFromTheirOwnCamerasAndAnswerTheirOwnPicks()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<EntitySnapshot>();
        var target = await Show(editor, 0, ViewportKind.Scene, 640, 360);
        using var device = new ViewportDevice(_adapter);
        using var frames = await Open(device, target.Prefix);

        // Two boxes on the z axis, a small one at 0.4 m and a larger one at 1 m, under a red background. The first
        // viewport looks along +z from 1 m before the origin, so the small box is in front. The second looks back along
        // -z from 3 m, so the larger box, whose face is 1.5 m from it, hides the small one.
        var near = Box(1, "Near", z: 0.4, scale: 0.4);
        var far = Box(2, "Far", z: 1, scale: 1);
        var volume = Entity(3, "Volume");
        volume.Components.Add(new Document.SceneComponent(VolumeId, "Volume", [Field("shape", Document.SceneValue.Name("Global"))]));
        volume.Components.Add(new Document.SceneComponent(EnvironmentId, "Environment", [Field("background", Document.SceneValue.Of(Number(1.0), Number(0.0), Number(0.0)))]));
        await Load(editor, Scene(near, far, volume), "Far");
        var fov = (float)(60 * Math.PI / 180);
        editor.Link.Send(new EditorCamera(0, [Origin, 0, -Meter], [0, 0, 0, 1], fov, 0.05f, CameraProjection.Perspective, 0, 0));
        // Each viewport has its own view: the normals, which are black where nothing drew, and the albedo, which shows
        // the background as it is. Neither shows the volume's icon, which would be in the middle of the first one.
        editor.Link.Send(new SetViewportSettings(0, EditorShell.DefaultViewportSettings with { DebugView = DebugView.Normals, ShowIcons = false }));
        editor.Link.Send(new SetViewportSettings(1, EditorShell.DefaultViewportSettings with { DebugView = DebugView.Albedo, ShowIcons = false }));

        // The game makes the second viewport's target at its size, and draws into it beside the first one's.
        var second = await Show(editor, 1, ViewportKind.Scene, 320, 240);
        editor.Link.Send(new EditorCamera(1, [Origin, 0, 3 * Meter], [0, 1, 0, 0], fov, 0.05f, CameraProjection.Perspective, 0, 0));
        Assert.Equal((320, 240), (second.Width, second.Height));
        using var secondFrames = await Open(device, second.Prefix);
        Assert.Equal((320, 240), (secondFrames.Size.Width, secondFrames.Size.Height));
        async Task<(ulong First, ulong Second)> Both()
        {
            for (var i = 0; i < 20; i++)
            {
                await Task.Delay(25, TestContext.Current.CancellationToken);
                editor.Link.Send(new ViewportAcknowledged(target.Viewport, target.Generation, frames.Completed));
                editor.Link.Send(new ViewportAcknowledged(1, second.Generation, secondFrames.Completed));
            }
            return (frames.Completed, secondFrames.Completed);
        }
        var shown = await Both();
        Assert.True(shown.Second > 0, "the second viewport drew no frame");
        var albedo = Pixel(device, secondFrames.Texture(shown.Second), 2, 2);
        Assert.True(albedo.R > 240 && albedo.G < 20 && albedo.B < 20, $"the second viewport's background is {albedo}, not the albedo view's red");
        var normals = Pixel(device, frames.Texture(shown.First), 2, 2);
        Assert.True(normals.R < 20 && normals.G < 20 && normals.B < 20, $"the first viewport's background is {normals}, not the normals view's black");

        // A pick over the second viewport's whole frame finds only the larger box, which hides the small one from
        // there, once the mesh has streamed in. The same pick in the first viewport finds both.
        async Task<ulong[]> PickAll(uint viewport, int width, int height, uint id, ulong[] expected)
        {
            ulong[] found = [];
            for (var attempt = 0u; attempt < 60 && !found.SequenceEqual(expected); attempt++)
            {
                editor.Link.Send(new PickRequest(id + attempt, viewport, 0, 0, width, height));
                editor.Link.Send(new ViewportAcknowledged(1, second.Generation, secondFrames.Completed));
                var all = await editor.Next<PickResult>(r => r.Id == id + attempt);
                found = [.. all.Hits.Select(h => h.SceneId).Order()];
            }
            return found;
        }
        Assert.Equal([far.Id], await PickAll(1, second.Width, second.Height, 100, [far.Id]));
        Assert.Equal([near.Id, far.Id], await PickAll(0, target.Width, target.Height, 200, [near.Id, far.Id]));

        // The middle of each viewport is what its own camera sees there, at its own depth.
        editor.Link.Send(new ViewportAcknowledged(1, second.Generation, secondFrames.Completed));
        editor.Link.Send(new PickRequest(7, 1, second.Width / 2, second.Height / 2, 1, 1));
        var behind = await editor.Next<PickResult>(r => r.Id == 7);
        Assert.Equal(far.Id, Assert.Single(behind.Hits).SceneId);
        Assert.InRange(behind.Depth, 1.45f, 1.55f);
        editor.Link.Send(new PickRequest(8, 0, target.Width / 2, target.Height / 2, 1, 1));
        var front = await editor.Next<PickResult>(r => r.Id == 8);
        Assert.Equal(near.Id, Assert.Single(front.Hits).SceneId);
        Assert.InRange(front.Depth, 1.15f, 1.25f);

        // The second viewport draws the whole frame, as the first does, at each quality and with each global
        // illumination, anti-aliasing and reflections, each with a state of its own for its camera. Its frames keep
        // coming through every change, and its background is still the albedo view's.
        async Task SecondDraws(ViewportSettings quality, string what)
        {
            editor.Link.Send(new SetViewportSettings(0, quality with { ShowIcons = false }));
            var before = (await Both()).Second;
            var after = (await Both()).Second;
            Assert.True(after > before, $"the second viewport stopped drawing with {what}");
            var pixel = Pixel(device, secondFrames.Texture(after), 2, 2);
            Assert.True(pixel.R > 240 && pixel.G < 20 && pixel.B < 20, $"the second viewport's background is {pixel} with {what}");
        }
        foreach (var preset in Enum.GetValues<ViewportPreset>())
        {
            await SecondDraws(EditorShell.DefaultViewportSettings with { QualityPreset = preset }, $"the {preset} preset");
        }
        foreach (var gi in Enum.GetValues<ViewportGi>())
        {
            await SecondDraws(EditorShell.DefaultViewportSettings with { GlobalIllumination = gi }, $"{gi} global illumination");
        }
        foreach (var aa in Enum.GetValues<ViewportAa>())
        {
            await SecondDraws(EditorShell.DefaultViewportSettings with { AntiAliasing = aa, RenderScale = 0.5f }, $"{aa} anti-aliasing");
        }
        foreach (var reflections in Enum.GetValues<ViewportReflections>())
        {
            await SecondDraws(EditorShell.DefaultViewportSettings with { Reflections = reflections }, $"{reflections} reflections");
        }
        editor.Link.Send(new SetViewportSettings(0, EditorShell.DefaultViewportSettings with { ShowIcons = false }));

        // A closed viewport draws no more, and a pick of it answers with no hits.
        editor.Link.Send(new CloseViewport(1));
        editor.Link.Send(new PickRequest(9, 1, second.Width / 2, second.Height / 2, 1, 1));
        var closed = await editor.Next<PickResult>(r => r.Id == 9);
        Assert.Empty(closed.Hits);
        var last = (await Both()).Second;
        Assert.Equal(last, (await Both()).Second);
        // The first one goes on.
        Assert.True((await Both()).First > shown.First);
    }

    // The Game view draws from the scene's Camera entity, which here is past the box and looks away from it, and a scene
    // view from the editor's camera, which looks at the box. The game's camera is near the scene, as it is in a real one:
    // the views of a frame share a render origin (see docs/rendering/frame.md#views).
    [Fact]
    public async Task TheGameViewShowsTheGamesCameraAndNotTheEditorsAndItsPicksFindNothing()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<EntitySnapshot>();
        var scene = await Show(editor, 0, ViewportKind.Scene, 320, 240);
        var game = await Show(editor, 4, ViewportKind.Game, 320, 240);
        using var device = new ViewportDevice(_adapter);
        using var sceneFrames = await Open(device, scene.Prefix);
        using var gameFrames = await Open(device, game.Prefix);

        // A box filling the editor's view, under a red background. Both views show the albedo, which has the background
        // whole, and no icons.
        var box = Box(1, "Box", z: 1, scale: 2);
        var volume = Entity(2, "Volume");
        volume.Components.Add(new Document.SceneComponent(VolumeId, "Volume", [Field("shape", Document.SceneValue.Name("Global"))]));
        volume.Components.Add(new Document.SceneComponent(EnvironmentId, "Environment", [Field("background", Document.SceneValue.Of(Number(1.0), Number(0.0), Number(0.0)))]));
        var camera = Entity(3, "Camera", z: 5);
        camera.Components.Add(new Document.SceneComponent(CameraId, "Camera", [Field("vertical_fov", Document.SceneValue.Of(Number(1.0))), Field("near", Document.SceneValue.Of(Number(0.05)))]));
        await Load(editor, Scene(box, volume, camera), "Box");
        var albedo = EditorShell.DefaultViewportSettings with { DebugView = DebugView.Albedo, ShowIcons = false };
        editor.Link.Send(new EditorCamera(0, [Origin, 0, -Meter], [0, 0, 0, 1], (float)(60 * Math.PI / 180), 0.05f, CameraProjection.Perspective, 0, 0));
        editor.Link.Send(new SetViewportSettings(0, albedo));
        editor.Link.Send(new SetViewportSettings(4, albedo));

        // Both pictures come, and they differ: the scene view looks at the box, the Game view at the background.
        ulong sceneFrame = 0;
        ulong gameFrame = 0;
        // The box's mesh streams in over the first frames, so the scene view is looked at until it shows it.
        static bool Background((byte R, byte G, byte B) p) => p.R > 240 && p.G < 20 && p.B < 20;
        for (var i = 0; i < 400; i++)
        {
            await Task.Delay(25, TestContext.Current.CancellationToken);
            editor.Link.Send(new ViewportAcknowledged(0, scene.Generation, sceneFrames.Completed));
            editor.Link.Send(new ViewportAcknowledged(4, game.Generation, gameFrames.Completed));
            (sceneFrame, gameFrame) = (sceneFrames.Completed, gameFrames.Completed);
            if (i >= 20 && sceneFrame > 0 && !Background(Pixel(device, sceneFrames.Texture(sceneFrame), scene.Width / 2, scene.Height / 2)))
            {
                break;
            }
        }
        Assert.True(sceneFrame > 0 && gameFrame > 0, "a viewport drew no frame");
        var inScene = Pixel(device, sceneFrames.Texture(sceneFrame), scene.Width / 2, scene.Height / 2);
        var inGame = Pixel(device, gameFrames.Texture(gameFrame), game.Width / 2, game.Height / 2);
        Assert.False(inScene.G < 20 && inScene.B < 20 && inScene.R > 240, $"the scene view shows {inScene}, the background, not the box");
        Assert.True(inGame.R > 240 && inGame.G < 20 && inGame.B < 20, $"the Game view shows {inGame}, not the background of the game's own camera");

        // A pick in the Game view finds nothing, where the same pick in the scene view finds the box.
        ulong[] found = [];
        for (var attempt = 0u; attempt < 60 && found.Length == 0; attempt++)
        {
            editor.Link.Send(new PickRequest(100 + attempt, 0, scene.Width / 2, scene.Height / 2, 1, 1));
            found = [.. (await editor.Next<PickResult>(r => r.Id == 100 + attempt)).Hits.Select(h => h.SceneId)];
        }
        Assert.Equal([box.Id], found);
        editor.Link.Send(new PickRequest(7, 4, game.Width / 2, game.Height / 2, 1, 1));
        Assert.Empty((await editor.Next<PickResult>(r => r.Id == 7)).Hits);
    }

    [Fact]
    public async Task ACloseViewportStopsItsFramesAndAnOpenOneStartsThemAgain()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<EntitySnapshot>();
        var target = await Show(editor, 2, ViewportKind.Scene, 320, 240);
        editor.Link.Send(new EditorCamera(2, [Origin, 0, -Meter], [0, 0, 0, 1], (float)(60 * Math.PI / 180), 0.05f, CameraProjection.Perspective, 0, 0));
        using var device = new ViewportDevice(_adapter);
        using var frames = await Open(device, target.Prefix);
        async Task<ulong> Drawn()
        {
            for (var i = 0; i < 20; i++)
            {
                await Task.Delay(25, TestContext.Current.CancellationToken);
                editor.Link.Send(new ViewportAcknowledged(2, target.Generation, frames.Completed));
            }
            return frames.Completed;
        }
        var before = await Drawn();
        Assert.True(before > 0, "the viewport drew no frame");
        Assert.True(await Drawn() > before);

        editor.Link.Send(new CloseViewport(2));
        var closed = await Drawn();
        Assert.Equal(closed, await Drawn());

        // It opens again with a target of its own, and draws from the camera that the editor sends.
        editor.Link.Send(new OpenViewport(2, ViewportKind.Scene, 320, 240));
        var again = await editor.Next<ViewportTarget>(t => t.Viewport == 2);
        editor.Link.Send(new EditorCamera(2, [Origin, 0, -Meter], [0, 0, 0, 1], (float)(60 * Math.PI / 180), 0.05f, CameraProjection.Perspective, 0, 0));
        using var secondFrames = await Open(device, again.Prefix);
        for (var i = 0; i < 20; i++)
        {
            await Task.Delay(25, TestContext.Current.CancellationToken);
            editor.Link.Send(new ViewportAcknowledged(2, again.Generation, secondFrames.Completed));
        }
        Assert.True(secondFrames.Completed > 0, "the viewport drew nothing after it opened again");
    }

    // The engine draws at most five viewports: the four scene views of a quad and the Game view.
    [Fact]
    public async Task FourSceneViewsAndTheGameViewDrawTogetherAndEachAnswersItsPicks()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<EntitySnapshot>();
        List<ViewportTarget> targets = [];
        for (uint viewport = 0; viewport < 4; viewport++)
        {
            targets.Add(await Show(editor, viewport, ViewportKind.Scene, 320, 240));
        }
        targets.Add(await Show(editor, 4, ViewportKind.Game, 320, 240));
        Assert.Equal(5, targets.Select(t => t.Prefix).Distinct().Count());
        using var device = new ViewportDevice(_adapter);
        List<SharedFrames> frames = [];
        foreach (var target in targets)
        {
            frames.Add(await Open(device, target.Prefix));
        }

        var box = Box(1, "Box", z: 1, scale: 1);
        var volume = Entity(2, "Volume");
        volume.Components.Add(new Document.SceneComponent(VolumeId, "Volume", [Field("shape", Document.SceneValue.Name("Global"))]));
        volume.Components.Add(new Document.SceneComponent(EnvironmentId, "Environment", [Field("background", Document.SceneValue.Of(Number(1.0), Number(0.0), Number(0.0)))]));
        // The views of a frame share the render origin of the Game view, so the game's camera is in the scene.
        var camera = Entity(3, "Camera", z: 5);
        camera.Components.Add(new Document.SceneComponent(CameraId, "Camera", [Field("vertical_fov", Document.SceneValue.Of(Number(1.0))), Field("near", Document.SceneValue.Of(Number(0.05)))]));
        await Load(editor, Scene(box, volume, camera), "Box");
        for (uint viewport = 0; viewport < 4; viewport++)
        {
            editor.Link.Send(new EditorCamera(viewport, [Origin, 0, -Meter], [0, 0, 0, 1], (float)(60 * Math.PI / 180), 0.05f, CameraProjection.Perspective, 0, 0));
        }

        // Every viewport draws, and the frames go on coming while all five are open.
        ulong[] first = new ulong[5];
        for (var i = 0; i < 400 && frames.Any(f => f.Completed == 0); i++)
        {
            await Task.Delay(25, TestContext.Current.CancellationToken);
        }
        for (var i = 0; i < 5; i++)
        {
            first[i] = frames[i].Completed;
            Assert.True(first[i] > 0, $"viewport {i} drew no frame");
        }
        await Task.Delay(500, TestContext.Current.CancellationToken);
        for (var i = 0; i < 5; i++)
        {
            Assert.True(frames[i].Completed > first[i], $"viewport {i} stopped drawing");
        }

        // The fourth scene view finds the box in the middle of its frame, once the mesh has streamed in.
        ulong[] found = [];
        for (var attempt = 0u; attempt < 200 && found.Length == 0; attempt++)
        {
            editor.Link.Send(new PickRequest(100 + attempt, 3, targets[3].Width / 2, targets[3].Height / 2, 1, 1));
            found = [.. (await editor.Next<PickResult>(r => r.Id == 100 + attempt)).Hits.Select(h => h.SceneId)];
            await Task.Delay(50, TestContext.Current.CancellationToken);
        }
        Assert.Equal([box.Id], found);
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

    // The sample's main script logs the input that it sees through the Input library, so these go from the editor's
    // events through core.queue_input to a script.
    [Fact]
    public async Task GamepadsAndTextFromTheEditorReachTheGamesScripts()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<EntitySnapshot>();
        editor.Link.Send(new SetMode(EditorMode.Play));

        void Send(params InputEvent[] events) => editor.Link.Send(new EditorInput(events));
        Task<Log> Logged(string text) => editor.Next<Log>(l => l.Text.Contains(text));

        Send(GameInput.Composition("にほ", 1));
        await Logged("composing にほ");
        Send(GameInput.Composition("", 0), GameInput.Text("日本語"));
        await Logged("typed 日本語");

        Send(GameInput.Pad(1, new GamepadReading(0x1000, 0, 0, 0, 0, 0, 0)));
        await Logged("gamepad 2 connected");
        await Logged("gamepad 2 pressed A");

        // A pad that goes while the link stays.
        Send(GameInput.Pad(1, null));
        await Logged("gamepad 2 disconnected");
    }

    // The sample's fly_camera behaviour, on the camera of the scene that the sample starts with. That camera looks along
    // +z with no turn, so each stick has a direction to check.
    [Fact]
    public async Task AGamepadFliesTheSamplesCamera()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        var world = await editor.Next<EntitySnapshot>();
        var camera = world.Entities.Single(e => e.Name == "Camera").Entity;

        // The Transform's bytes: a position of three i64, then a rotation of x, y, z and w as f32.
        async Task<(long X, long Y, long Z, float TurnX, float TurnY)> Pose()
        {
            editor.Link.Send(new WatchEntity(camera));
            var values = await editor.Next<EntityValues>(v => v.Entity == camera);
            editor.Link.Send(new UnwatchEntity(camera));
            await Task.Delay(100, TestContext.Current.CancellationToken);
            editor.Drain();
            var data = values.Components.Single(c => c.Id == 1).Data;
            return (BitConverter.ToInt64(data, 0), BitConverter.ToInt64(data, 8), BitConverter.ToInt64(data, 16), BitConverter.ToSingle(data, 24), BitConverter.ToSingle(data, 28));
        }
        // Holds a pad's reading for a moment, then lets go of it, and gives the pose that it stops at.
        async Task<(long X, long Y, long Z, float TurnX, float TurnY)> Hold(GamepadReading reading)
        {
            editor.Link.Send(new EditorInput([GameInput.Pad(0, reading)]));
            await Task.Delay(300, TestContext.Current.CancellationToken);
            editor.Link.Send(new EditorInput([GameInput.Pad(0, default(GamepadReading))]));
            await Task.Delay(100, TestContext.Current.CancellationToken);
            return await Pose();
        }

        editor.Link.Send(new SetMode(EditorMode.Play));
        // A pad that nothing touches leaves it where it is.
        var start = await Hold(default);
        await Task.Delay(200, TestContext.Current.CancellationToken);
        Assert.Equal(start, await Pose());

        // The left stick pushed up flies it forward, and pushed right flies it right.
        var forward = await Hold(new GamepadReading(0, 0, 1, 0, 0, 0, 0));
        Assert.True(forward.Z > start.Z, $"{forward} from {start}");
        Assert.Equal((start.X, start.Y), (forward.X, forward.Y));
        var right = await Hold(new GamepadReading(0, 1, 0, 0, 0, 0, 0));
        Assert.True(right.X > forward.X, $"{right} from {forward}");

        // The right trigger lifts it and the left lowers it.
        var lifted = await Hold(new GamepadReading(0, 0, 0, 0, 0, 0, 1));
        Assert.True(lifted.Y > right.Y, $"{lifted} from {right}");
        var lowered = await Hold(new GamepadReading(0, 0, 0, 0, 0, 1, 0));
        Assert.True(lowered.Y < lifted.Y, $"{lowered} from {lifted}");

        // It stays where the sticks left it.
        await Task.Delay(200, TestContext.Current.CancellationToken);
        Assert.Equal(lowered, await Pose());

        // The right stick pushed right turns it right, around +y, and pushed up tilts it up, against +x.
        Assert.Equal(0, lowered.TurnY);
        var turned = await Hold(new GamepadReading(0, 0, 0, 1, 0, 0, 0));
        Assert.True(turned.TurnY > 0, $"{turned}");
        var tilted = await Hold(new GamepadReading(0, 0, 0, 0, 1, 0, 0));
        Assert.True(tilted.TurnX < 0, $"{tilted}");
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
    public async Task TheGameSaysWhereItsSkysSunIs()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<Welcome>();
        // The sample's sky is Flat, so it has no texture whose sun to aim at.
        await editor.Next<HostStats>(s => s.Frames > 0);
        editor.Link.Send(new SkySunRequest());
        var sun = await editor.Next<SkySun>();
        Assert.Equal(SkySunState.NoTextureSky, sun.State);
    }

    const string FoxGraph = "71f3481642654d8590e42837f2565d58";

    static void SkipWithoutTheFox()
    {
        if (!File.Exists(Path.Combine(EditorOptions.RepositoryRoot(), "build", "dev", "content", FoxGraph + ".blob")))
        {
            Assert.Skip("the sample's content is not cooked");
        }
    }

    [Fact]
    public async Task AWatchedFoxShowsItsStatesAsItsBehaviourDrivesThem()
    {
        SkipWithoutTheFox();
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<Welcome>();
        var text = File.ReadAllText(Path.Combine(EditorOptions.RepositoryRoot(), "samples", "mygame", "content", "scenes", "animation.scene")).ReplaceLineEndings("\n");
        var (scene, problems) = Document.SceneFile.Parse(text);
        Assert.Empty(problems);
        var world = await Load(editor, scene!);
        var fox = world.Entities.Single(e => e.Name == "Walking Fox").Entity;

        editor.Link.Send(new WatchEntity(fox));
        editor.Link.Send(new SetMode(EditorMode.Play));
        var idle = await editor.Next<AnimatorView>(v => v.Entity == fox && v.State == 1);
        Assert.Equal(FoxGraph, Convert.ToHexStringLower(idle.Graph));
        Assert.Equal(["speed", "look"], idle.Parameters.Select(p => p.Name));
        Assert.Equal(AnimatorParameterKind.Trigger, idle.Parameters[1].Kind);

        var move = await editor.Next<AnimatorView>(v => v.Entity == fox && v.State == 2);
        Assert.Equal(20u, move.Transition);
        Assert.Equal(1u, move.Source);
        Assert.True(move.Parameters[0].Value > 0.1f);

        // Its behaviour pulls look a quarter of the way through a cycle.
        var look = await editor.Next<AnimatorView>(v => v.Entity == fox && v.State == 3);
        Assert.Equal(22u, look.Transition);
        Assert.Equal(0.25f, look.FadeDuration);
    }

    [Fact]
    public async Task APreviewPlaysAGraphOnItsMeshApartFromTheWorld()
    {
        const string FoxMesh = "e049cf90c64cbdc7eec588c7120cbabb";
        SkipWithoutTheFox();
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<Welcome>();

        // The mode stays Edit, in which the world stands still.
        editor.Link.Send(new OpenPreview(0, Convert.FromHexString(FoxGraph), false));
        editor.Link.Send(new PreviewSettings(0, PreviewMesh.Asset, Convert.FromHexString(FoxMesh), 0, 0, 3, 64, 64));
        var target = await editor.Next<PreviewTarget>();
        // It draws while the editor keeps up with its frames, which this one takes as read.
        editor.Link.Send(new PreviewAcknowledged(0, target.Generation, 1_000_000));

        static bool Preview(AnimatorView v) => v.Entity == 0;
        var idle = await editor.Next<AnimatorView>(v => Preview(v) && v.State == 1);
        Assert.Equal(FoxGraph, Convert.ToHexStringLower(idle.Graph));
        Assert.Equal(0u, idle.Transition);

        // What it is told stays: nothing else sets its parameters, and it plays the state's blend.
        editor.Link.Send(new SetPreviewParameter(0, "speed", 2));
        var move = await editor.Next<AnimatorView>(v => Preview(v) && v.State == 2);
        Assert.Equal(20u, move.Transition);
        Assert.Equal(2, move.Parameters[0].Value);
        var later = await editor.Next<AnimatorView>(v => Preview(v) && v.State == 2 && v.Progress > move.Progress + 0.2f);
        Assert.Equal(2, later.Parameters[0].Value);

        editor.Link.Send(new SetPreviewParameter(0, "look", 1));
        var look = await editor.Next<AnimatorView>(v => Preview(v) && v.State == 3);
        Assert.Equal(22u, look.Transition);

        // Restart goes back to the entry, with the parameters at their defaults.
        editor.Link.Send(new RestartPreview(0));
        var again = await editor.Next<AnimatorView>(v => Preview(v) && v.State == 1 && v.Transition == 0);
        Assert.Equal(0, again.Parameters[0].Value);
        editor.Link.Send(new ClosePreview(0));
    }

    [Fact]
    public async Task TheHostProfilesItsFramesAndCapturesOne()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<Welcome>();

        // The first intervals can end before a frame's GPU times arrive.
        var summary = await editor.Next<ProfileSummary>(s => s.Frames > 0 && s.GpuFrames > 0);
        Assert.True(summary.Recording);
        Assert.True(summary.CpuMsAverage > 0 && summary.GpuMsAverage > 0 && summary.CpuWorstFrame != 0);
        Assert.Contains(summary.Costs, c => c.Kind == ProfileCostKind.Pass && c.MsAverage > 0);
        // The host pairs each summary with the Host_Stats of the same interval.
        await editor.Next<HostStats>();

        editor.Link.Send(new ProfileCaptureRequest(1, ProfileCaptureMode.Next, 0, 0));
        var capture = await editor.Next<ProfileCapture>(c => c.Id == 1);
        Assert.True(capture.Available, capture.Reason);
        Assert.Equal("Main", capture.Lanes[0].Name);
        Assert.Contains(capture.Lanes, l => l.Name.StartsWith("Worker"));
        string Name(ProfileZone z) => capture.Names[z.Name].Text;
        Assert.Contains(capture.Zones, z => z.Lane == 0 && Name(z) == "Game update");
        Assert.Contains(capture.Zones, z => Name(z) == "Wait for GPU" || Name(z) == "Shared frame pacing");
        var graphics = Array.FindIndex(capture.Lanes, l => l.Kind == ProfileLaneKind.GpuGraphics);
        Assert.Contains(capture.Zones, z => z.Lane == graphics && Name(z) == "prepass" && z.Duration > 0);
        Assert.True(capture.GpuEnd > capture.GpuBegin && capture.FrameNs > 0);

        // A frame that the host never had is unavailable, with a reason.
        editor.Link.Send(new ProfileCaptureRequest(2, ProfileCaptureMode.Frame, 0, 0));
        var missing = await editor.Next<ProfileCapture>(c => c.Id == 2);
        Assert.False(missing.Available);
        Assert.NotEmpty(missing.Reason);

        // Off, the host records no zones, and the summaries say so.
        editor.Link.Send(new ProfileRecording(false));
        await editor.Next<ProfileSummary>(s => !s.Recording);
    }

    // The sample's room, and its main scene, which a bake reads as it does a prefab, as they are the same flat entities. A
    // prefab has one root, which stands at the origin, so the scene's 21 stand there together, with its brick box in front.
    const string RoomMesh = "3b7f2c9e4d1a4f6b8c0d2e4f6a8b0c1d";
    const string MainScene = "047ea7c35e4dbfb73d2dac450b79b9a8";

    static void SkipWithoutTheRoom()
    {
        foreach (var guid in new[] { RoomMesh, MainScene })
        {
            if (!File.Exists(Path.Combine(EditorOptions.RepositoryRoot(), "build", "dev", "content", guid + ".blob")))
            {
                Assert.Skip("the sample's content is not cooked");
            }
        }
    }

    // Asks for a picture as the content browser does, and decodes what the host wrote.
    static async Task<SKBitmap> Bake(Editor editor, uint id, ThumbnailKind kind, string guid, string directory, ulong node = 0)
    {
        var path = Path.Combine(directory, $"{guid}.{id}.png");
        editor.Link.Send(new CaptureRequest(id, CaptureKind.Thumbnail, path));
        editor.Link.Send(new BakeThumbnail(id, kind, Convert.FromHexString(guid), node, 64, 64));
        var written = await editor.Next<CaptureResult>(r => r.Id == id);
        Assert.True(written.Ok, written.Reason);
        Assert.Equal((CaptureKind.Thumbnail, path, 64u, 64u), (written.Kind, written.Path, written.Width, written.Height));
        return SKBitmap.Decode(path);
    }

    [Fact]
    public async Task ABakeWritesAPngOfTheMesh()
    {
        SkipWithoutTheRoom();
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<Welcome>();
        var directory = Path.Combine(Path.GetTempPath(), $"cinnabar-bake-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        try
        {
            using var picture = await Bake(editor, 1, ThumbnailKind.Mesh, RoomMesh, directory);
            var background = picture.GetPixel(0, 0);
            var drawn = picture.Pixels.Count(p => p != background);
            Assert.True(drawn > 64 * 64 / 20, $"{drawn} pixels were drawn");

            // What cannot be drawn says so, and leaves no file for the index to call ready.
            const string Missing = "0123456789abcdef0123456789abcdef";
            var missing = Path.Combine(directory, "missing.png");
            editor.Link.Send(new CaptureRequest(2, CaptureKind.Thumbnail, missing));
            editor.Link.Send(new BakeThumbnail(2, ThumbnailKind.Mesh, Convert.FromHexString(Missing), 0, 64, 64));
            var failed = await editor.Next<ThumbnailFailed>(m => m.Id == 2);
            Assert.Equal("what it draws could not be loaded", failed.Reason);
            Assert.False(File.Exists(missing));

            // The next one is not lost behind it.
            using var again = await Bake(editor, 3, ThumbnailKind.Mesh, RoomMesh, directory);
            Assert.Equal(picture.Pixels.Count(p => p != background), again.Pixels.Count(p => p != background));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task ABakeOfAPrefabDrawsItsMaterials()
    {
        SkipWithoutTheRoom();
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<Welcome>();
        var directory = Path.Combine(Path.GetTempPath(), $"cinnabar-bake-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        try
        {
            // A bare mesh is gray, and the sample's box is red brick.
            static int Warm(SKBitmap picture) => picture.Pixels.Count(p => p.Red - p.Blue > 20);
            using var bare = await Bake(editor, 1, ThumbnailKind.Mesh, RoomMesh, directory);
            using var dressed = await Bake(editor, 2, ThumbnailKind.Prefab, MainScene, directory);
            Assert.True(Warm(dressed) > 64 * 64 / 10, $"{Warm(dressed)} pixels are warm");
            Assert.True(Warm(bare) < Warm(dressed) / 10, $"the bare mesh has {Warm(bare)} warm pixels, and the prefab {Warm(dressed)}");
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task ABakeOfANodeDrawsItsEntityAndNotThePrefab()
    {
        // Sponza's prefab, and its first floor, which are the intel sample's.
        const string Sponza = "bfd7069a83795b6a4ffb0c1ca75a8aa9";
        const ulong FirstFloor = 0xe7e4b781f0a1effe;
        if (!File.Exists(Path.Combine(EditorOptions.RepositoryRoot(), "build", "dev", "content", Sponza + ".blob")))
        {
            Assert.Skip("the intel sample's content is not cooked");
        }

        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<Welcome>();
        var directory = Path.Combine(Path.GetTempPath(), $"cinnabar-bake-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        try
        {
            using var whole = await Bake(editor, 1, ThumbnailKind.Prefab, Sponza, directory);
            using var part = await Bake(editor, 2, ThumbnailKind.Prefab, Sponza, directory, FirstFloor);
            var differ = whole.Pixels.Zip(part.Pixels).Count(p => p.First != p.Second);
            Assert.True(differ > 64 * 64 / 10, $"{differ} pixels differ");

            // A node that is not in it draws nothing, and says so.
            var nowhere = Path.Combine(directory, "nowhere.png");
            editor.Link.Send(new CaptureRequest(3, CaptureKind.Thumbnail, nowhere));
            editor.Link.Send(new BakeThumbnail(3, ThumbnailKind.Prefab, Convert.FromHexString(Sponza), 0x0123456789abcdef, 64, 64));
            var failed = await editor.Next<ThumbnailFailed>(m => m.Id == 3);
            Assert.Equal("it draws nothing", failed.Reason);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task TheHostWritesScreenshotsAndGifs()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<Welcome>();
        await Show(editor, 0, ViewportKind.Scene, 320, 180);
        // The host's screenshots and history ring read the viewport that the editor names.
        editor.Link.Send(new CaptureSource(0));
        var directory = Path.Combine(Path.GetTempPath(), $"cinnabar-capture-{Guid.NewGuid():N}");
        try
        {
            // The history ring samples ten times a second, so a second and a half gives it frames at the new size.
            await Task.Delay(1500, TestContext.Current.CancellationToken);

            var shot = Path.Combine(directory, "shot.png");
            editor.Link.Send(new CaptureRequest(1, CaptureKind.Screenshot, shot));
            var written = await editor.Next<CaptureResult>(r => r.Id == 1);
            Assert.True(written.Ok, written.Reason);
            Assert.Equal((shot, 320u, 180u, OutputMode.Sdr), (written.Path, written.Width, written.Height, written.Output));
            Assert.True(written.Frame > 0);
            Assert.Equal(new byte[] { 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a }, File.ReadAllBytes(shot).Take(8));

            var clip = Path.Combine(directory, "clip.gif");
            editor.Link.Send(new CaptureRequest(2, CaptureKind.Gif, clip));
            var recorded = await editor.Next<CaptureResult>(r => r.Id == 2);
            Assert.True(recorded.Ok, recorded.Reason);
            Assert.Equal((clip, 160u, 90u), (recorded.Path, recorded.Width, recorded.Height));
            Assert.True(recorded.Frames >= 5, $"{recorded.Frames} frames");
            Assert.True(recorded.DurationMs > 300, $"{recorded.DurationMs} ms");
            Assert.Equal("GIF89a"u8.ToArray(), File.ReadAllBytes(clip).Take(6));

            // Without a path, the host names the file beside itself.
            editor.Link.Send(new CaptureRequest(3, CaptureKind.Screenshot, ""));
            var named = await editor.Next<CaptureResult>(r => r.Id == 3);
            Assert.True(named.Ok, named.Reason);
            Assert.Contains(Path.Combine("build", "dev", "captures"), named.Path);
            Assert.True(File.Exists(named.Path));
            File.Delete(named.Path);
        }
        finally
        {
            if (Directory.Exists(directory))
            {
                Directory.Delete(directory, recursive: true);
            }
        }
    }

    [Fact]
    public async Task TheGameDrawsMaterialPreviewsWhenTheyChange()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<Welcome>();
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
        var cache = Path.Combine(EditorOptions.RepositoryRoot(), "build", "dev", "content");
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

    [Fact]
    public async Task TheViewportDrawsTheVolumesSettingsAndItsDebugViews()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<EntitySnapshot>();
        var target = await Show(editor);
        using var device = new ViewportDevice(_adapter);
        using var frames = await Open(device, target.Prefix);

        // A global volume whose environment's background is red, and nothing else, so the whole frame is background.
        var volume = Entity(1, "Volume");
        volume.Components.Add(new Document.SceneComponent(VolumeId, "Volume", [Field("shape", Document.SceneValue.Name("Global"))]));
        volume.Components.Add(new Document.SceneComponent(EnvironmentId, "Environment", [Field("background", Document.SceneValue.Of(Number(1.0), Number(0.0), Number(0.0)))]));
        await Load(editor, Scene(volume));
        editor.Link.Send(new EditorCamera(0, [Origin, 0, -Meter], [0, 0, 0, 1], (float)(60 * Math.PI / 180), 0.05f, CameraProjection.Perspective, 0, 0));

        var lit = Pixel(device, frames.Texture(await Latest(editor, frames, target)), 2, 2);
        Assert.True(lit.R > lit.G + 60 && lit.R > lit.B + 60, $"the background is {lit}, not the volume's red");

        // The albedo view shows the background as it is, without the tone mapper, so the red is whole.
        editor.Link.Send(new SetViewportSettings(0, EditorShell.DefaultViewportSettings with { DebugView = DebugView.Albedo }));
        var albedo = Pixel(device, frames.Texture(await Latest(editor, frames, target)), 2, 2);
        Assert.True(albedo.R > 240 && albedo.G < 20 && albedo.B < 20, $"the albedo view's background is {albedo}");

        // Where nothing drew, the prepass's normals are zero, which the normals view shows black. Every other view draws.
        editor.Link.Send(new SetViewportSettings(0, EditorShell.DefaultViewportSettings with { DebugView = DebugView.Normals }));
        var normals = Pixel(device, frames.Texture(await Latest(editor, frames, target)), 2, 2);
        Assert.True(normals.R < 20 && normals.G < 20 && normals.B < 20, $"the normals view's background is {normals}");
        foreach (var view in Enum.GetValues<DebugView>())
        {
            editor.Link.Send(new SetViewportSettings(0, EditorShell.DefaultViewportSettings with { DebugView = view, NoBloom = true, NoShadows = true, ExposureOffset = 1 }));
            await Latest(editor, frames, target);
        }
        // The viewport's quality in place of the game's: each preset, each anti-aliasing at half the size, FSR
        // included, which is temporal AA where the device cannot run it, and each global illumination, the split
        // cascades included, which are the screen cascades where the device has no ray queries, and each reflections'
        // technique at each level, the traced ones included, which are the screen-space ones without ray queries.
        foreach (var preset in Enum.GetValues<ViewportPreset>())
        {
            editor.Link.Send(new SetViewportSettings(0, EditorShell.DefaultViewportSettings with { QualityPreset = preset }));
            await Latest(editor, frames, target);
        }
        foreach (var aa in Enum.GetValues<ViewportAa>())
        {
            editor.Link.Send(new SetViewportSettings(0, EditorShell.DefaultViewportSettings with { AntiAliasing = aa, RenderScale = 0.5f }));
            await Latest(editor, frames, target);
        }
        foreach (var gi in Enum.GetValues<ViewportGi>())
        {
            editor.Link.Send(new SetViewportSettings(0, EditorShell.DefaultViewportSettings with { GlobalIllumination = gi, RenderScale = 0.5f }));
            await Latest(editor, frames, target);
        }
        foreach (var reflections in Enum.GetValues<ViewportReflections>())
        {
            foreach (var level in Enum.GetValues<ViewportLevel>())
            {
                editor.Link.Send(new SetViewportSettings(0, EditorShell.DefaultViewportSettings with { Reflections = reflections, ReflectionsLevel = level, RenderScale = 0.5f }));
                await Latest(editor, frames, target);
            }
        }
        var scaled = Pixel(device, frames.Texture(await Latest(editor, frames, target)), 2, 2);
        Assert.True(scaled.R > scaled.G + 60 && scaled.R > scaled.B + 60, $"at half the size, the background is {scaled}");
        Assert.DoesNotContain(editor.Skipped, m => m is Log { Level: LogLevel.Error });
    }

    [Fact]
    public async Task TheAtmospheresSkyIsBlueByDayAndDarkByNight()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<EntitySnapshot>();
        var target = await Show(editor);
        using var device = new ViewportDevice(_adapter);
        using var frames = await Open(device, target.Prefix);

        // A global volume with an atmosphere whose own sun is high, and nothing else, so the frame is sky. The camera
        // looks at the horizon, so the frame's top is the sky above it.
        Document.SceneEntity Sky(double elevation)
        {
            var volume = Entity(1, "Atmosphere");
            volume.Components.Add(new Document.SceneComponent(VolumeId, "Volume", [Field("shape", Document.SceneValue.Name("Global"))]));
            volume.Components.Add(new Document.SceneComponent(EnvironmentId, "Environment",
                [Field("mode", Document.SceneValue.Name("Atmosphere")), Field("sun_elevation", Document.SceneValue.Of(Number(elevation)))]));
            return volume;
        }
        await Load(editor, Scene(Sky(60)));
        editor.Link.Send(new EditorCamera(0, [Origin, 0, -Meter], [0, 0, 0, 1], (float)(60 * Math.PI / 180), 0.05f, CameraProjection.Perspective, 0, 0));
        editor.Link.Send(new SetViewportSettings(0, EditorShell.DefaultViewportSettings));

        var day = Pixel(device, frames.Texture(await Latest(editor, frames, target)), 32, 2);
        Assert.True(day.B > day.R + 20 && day.B > 40, $"the day's sky is {day}, not blue");

        await Load(editor, Scene(Sky(-20)));
        var night = Pixel(device, frames.Texture(await Latest(editor, frames, target)), 32, 2);
        Assert.True(night.R + night.G + night.B < 30, $"the night's sky is {night}, not dark");
        Assert.DoesNotContain(editor.Skipped, m => m is Log { Level: LogLevel.Error });
    }

    // A global volume whose sky is a texture, and nothing else, so the frame is sky.
    static Document.SceneEntity TextureSky(string texture)
    {
        var volume = Entity(1, "Sky");
        volume.Components.Add(new Document.SceneComponent(VolumeId, "Volume", [Field("shape", Document.SceneValue.Name("Global"))]));
        volume.Components.Add(new Document.SceneComponent(EnvironmentId, "Environment",
            [Field("mode", Document.SceneValue.Name("Texture")), Field("texture", Document.SceneValue.AssetRef(texture))]));
        return volume;
    }

    static readonly float Half = MathF.Sqrt(0.5f);
    // The sample's assets in textures/cube.
    const string CubeFaces = "c0be0000000000000000000000000010";
    const string SmallSky = "c0be0000000000000000000000000040";
    const string SmallSkyCube = "c0be0000000000000000000000000041";

    [Fact]
    public async Task ACubeMapSkyShowsEachFaceInItsDirection()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<EntitySnapshot>();
        var target = await Show(editor);
        using var device = new ViewportDevice(_adapter);
        using var frames = await Open(device, target.Prefix);
        await Load(editor, Scene(TextureSky(CubeFaces)));
        editor.Link.Send(new SetViewportSettings(0, EditorShell.DefaultViewportSettings));

        // Each direction, with the rotation that turns the camera's +z toward it and the channels that its face's color has
        // high.
        (string Name, float[] Rotation, bool R, bool G, bool B)[] looks =
        [
            ("+x", [0, Half, 0, Half], true, false, false),
            ("-x", [0, -Half, 0, Half], false, true, true),
            ("+y", [-Half, 0, 0, Half], false, true, false),
            ("-y", [Half, 0, 0, Half], true, false, true),
            ("+z", [0, 0, 0, 1], false, false, true),
            ("-z", [0, 1, 0, 0], true, true, false),
        ];
        foreach (var look in looks)
        {
            editor.Link.Send(new EditorCamera(0, [Origin, 0, 0], look.Rotation, (float)(60 * Math.PI / 180), 0.05f, CameraProjection.Perspective, 0, 0));
            (byte R, byte G, byte B) color = default;
            var matches = false;
            for (var attempt = 0; attempt < 40 && !matches; attempt++)
            {
                color = Pixel(device, frames.Texture(await Latest(editor, frames, target)), (int)target.Width / 2, (int)target.Height / 2);
                // Tone mapping desaturates, so a channel is high when it is nearer to the brightest than to the darkest.
                var high = Math.Max(color.R, Math.Max(color.G, color.B));
                var low = Math.Min(color.R, Math.Min(color.G, color.B));
                var middle = (high + low) / 2;
                matches = high - low > 40 && (color.R > middle) == look.R && (color.G > middle) == look.G && (color.B > middle) == look.B;
            }
            Assert.True(matches, $"looking toward {look.Name}, the sky is {color}");
        }
        Assert.DoesNotContain(editor.Skipped, m => m is Log { Level: LogLevel.Error });
    }

    [Fact]
    public async Task ASkyIsTheSameAsACubeMap()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<EntitySnapshot>();
        var target = await Show(editor);
        using var device = new ViewportDevice(_adapter);
        using var frames = await Open(device, target.Prefix);
        editor.Link.Send(new SetViewportSettings(0, EditorShell.DefaultViewportSettings));

        // The same image as an equirectangular texture and as a cube, under each a white box that it lights, at the bottom
        // of the frame, with the sky above it.
        async Task<(float[] Sun, (byte R, byte G, byte B) Sky, (byte R, byte G, byte B) Lit)> Look(string texture)
        {
            var box = Box(2, "Box", 1, 1);
            await Load(editor, Scene(TextureSky(texture), box));
            editor.Link.Send(new EditorCamera(0, [Origin, 0, -2 * Meter], [0, 0, 0, 1], (float)(60 * Math.PI / 180), 0.05f, CameraProjection.Perspective, 0, 0));
            SkySun sun = new(SkySunState.NotReady, [0, 0, 0]);
            for (var attempt = 0; attempt < 200 && sun.State != SkySunState.Found; attempt++)
            {
                await Latest(editor, frames, target);
                editor.Link.Send(new SkySunRequest());
                sun = await editor.Next<SkySun>();
            }
            Assert.Equal(SkySunState.Found, sun.State);
            // The exposure adapts over time, so give it a while.
            for (var i = 0; i < 40; i++)
            {
                await Latest(editor, frames, target);
            }
            var last = frames.Texture(await Latest(editor, frames, target));
            return (sun.Direction, Pixel(device, last, (int)target.Width / 2, 2), Pixel(device, last, (int)target.Width / 2, (int)target.Height / 2));
        }
        var flat = await Look(SmallSky);
        var cube = await Look(SmallSkyCube);

        // The sun is 60 degrees of azimuth from +z toward +x and 40 of elevation. Within a texel or two of a small mip.
        var azimuth = 60 * MathF.PI / 180;
        var elevation = 40 * MathF.PI / 180;
        float[] expected = [MathF.Cos(elevation) * MathF.Sin(azimuth), MathF.Sin(elevation), MathF.Cos(elevation) * MathF.Cos(azimuth)];
        foreach (var sun in new[] { flat.Sun, cube.Sun })
        {
            var cosine = sun[0] * expected[0] + sun[1] * expected[1] + sun[2] * expected[2];
            Assert.True(cosine > MathF.Cos(6 * MathF.PI / 180), $"the sun is toward [{string.Join(", ", sun)}], not [{string.Join(", ", expected)}]");
        }
        static void Close((byte R, byte G, byte B) a, (byte R, byte G, byte B) b, string what)
        {
            Assert.True(Math.Abs(a.R - b.R) <= 16 && Math.Abs(a.G - b.G) <= 16 && Math.Abs(a.B - b.B) <= 16, $"{what}: {a} from the equirectangular sky, and {b} from the cube");
        }
        Close(flat.Sky, cube.Sky, "the background");
        Close(flat.Lit, cube.Lit, "the lit box");
        Assert.True(flat.Lit.R + flat.Lit.G + flat.Lit.B > 30, $"the box is {flat.Lit}, which the sky does not light");
        Assert.DoesNotContain(editor.Skipped, m => m is Log { Level: LogLevel.Error });
    }

    [Fact]
    public async Task TheSamplesTrianglesEachReadALayerOfAnArray()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<EntitySnapshot>();
        var target = await Show(editor);
        using var device = new ViewportDevice(_adapter);
        using var frames = await Open(device, target.Prefix);

        // One triangle in one place, after 0, 1 and 2 other entities. Its entity's index picks its layer, and is all that
        // differs: at another place in the frame, the lens would change its color too.
        async Task<(byte R, byte G, byte B)> Look(int before)
        {
            var entities = new List<Document.SceneEntity>();
            for (var i = 0; i < before; i++)
            {
                entities.Add(Entity(10 + (ulong)i, $"Other {i}"));
            }
            var triangle = Entity(1, "Triangle");
            triangle.Components.Add(new Document.SceneComponent(TriangleId, "Triangle", [Field("brightness", Document.SceneValue.Of(Number(1.0)))]));
            entities.Add(triangle);
            await Load(editor, Scene([.. entities]));
            editor.Link.Send(new EditorCamera(0, [Origin, 0, -3 * Meter], [0, 0, 0, 1], (float)(60 * Math.PI / 180), 0.05f, CameraProjection.Perspective, 0, 0));
            editor.Link.Send(new SetViewportSettings(0, EditorShell.DefaultViewportSettings));
            for (var i = 0; i < 4; i++)
            {
                await Latest(editor, frames, target);
            }
            return Pixel(device, frames.Texture(await Latest(editor, frames, target)), (int)target.Width / 2, (int)target.Height / 2);
        }
        // The hue, which the exposure does not change as it adapts.
        static bool Differ((byte R, byte G, byte B) a, (byte R, byte G, byte B) b)
        {
            float aSum = Math.Max(a.R + a.G + a.B, 1), bSum = Math.Max(b.R + b.G + b.B, 1);
            return Math.Abs(a.R / aSum - b.R / bSum) > 0.02f || Math.Abs(a.G / aSum - b.G / bSum) > 0.02f || Math.Abs(a.B / aSum - b.B / bSum) > 0.02f;
        }

        (byte R, byte G, byte B) first = default, second = default, third = default;
        var differ = false;
        // The array streams in over a few frames, and draws no tint until then.
        for (var attempt = 0; attempt < 5 && !differ; attempt++)
        {
            (first, second, third) = (await Look(0), await Look(1), await Look(2));
            differ = Differ(first, second) && Differ(second, third) && Differ(first, third);
        }
        Assert.True(differ, $"the triangle is {first}, {second} and {third}");
        Assert.DoesNotContain(editor.Skipped, m => m is Log { Level: LogLevel.Error });
    }

    [Fact]
    public async Task ACubeMapInATexturesPlaceIsLoggedAndNotRead()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<EntitySnapshot>();
        // The array is neither of the sky's two dimensions, so the sky is Flat's and says why.
        const string Tints = "c0be0000000000000000000000000030";
        await Load(editor, Scene(TextureSky(Tints)));
        await editor.Next<Log>(m => m.Level == LogLevel.Error && m.Text.Contains("read as a"));
    }

    [Fact]
    public async Task ALightsIconPicksIt()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<EntitySnapshot>();
        var target = await Show(editor);

        // A point light 2 m ahead of the camera, with nothing else to draw.
        var lamp = Entity(1, "Lamp", z: 1);
        lamp.Components.Add(new Document.SceneComponent(PointLightId, "Point_Light", [Field("intensity", Document.SceneValue.Of(Number(1.0)))]));
        await Load(editor, Scene(lamp));
        editor.Link.Send(new EditorCamera(0, [Origin, 0, -Meter], [0, 0, 0, 1], (float)(60 * Math.PI / 180), 0.05f, CameraProjection.Perspective, 0, 0));
        editor.Link.Send(new SetViewportSettings(0, EditorShell.DefaultViewportSettings));

        PickResult center = new(0, [], 0, -1);
        for (var attempt = 0u; attempt < 60 && center.Hits.Length == 0; attempt++)
        {
            editor.Link.Send(new PickRequest(100 + attempt, 0, target.Width / 2, target.Height / 2, 1, 1));
            center = await editor.Next<PickResult>(r => r.Id == 100 + attempt);
        }
        Assert.Equal(lamp.Id, Assert.Single(center.Hits).SceneId);
        Assert.InRange(center.Depth, 1.9f, 2.1f);

        // At half the render size, a pick in the viewport's pixels still finds it.
        editor.Link.Send(new SetViewportSettings(0, EditorShell.DefaultViewportSettings with { RenderScale = 0.5f }));
        center = new(0, [], 0, -1);
        for (var attempt = 0u; attempt < 60 && center.Hits.Length == 0; attempt++)
        {
            editor.Link.Send(new PickRequest(200 + attempt, 0, target.Width / 2, target.Height / 2, 1, 1));
            center = await editor.Next<PickResult>(r => r.Id == 200 + attempt);
        }
        Assert.Equal(lamp.Id, Assert.Single(center.Hits).SceneId);

        // Without the icons, the light is not drawn, so nothing is there.
        editor.Link.Send(new SetViewportSettings(0, EditorShell.DefaultViewportSettings with { ShowIcons = false }));
        editor.Link.Send(new PickRequest(7, 0, target.Width / 2, target.Height / 2, 1, 1));
        Assert.Empty((await editor.Next<PickResult>(r => r.Id == 7)).Hits);
    }

    // Latest acknowledges the viewport's frames for a while, so the game draws with what it was sent, and gives the last.
    static async Task<ulong> Latest(Editor editor, SharedFrames frames, ViewportTarget target)
    {
        for (var i = 0; i < 20; i++)
        {
            await Task.Delay(25, TestContext.Current.CancellationToken);
            editor.Link.Send(new ViewportAcknowledged(target.Viewport, target.Generation, frames.Completed));
        }
        return frames.Completed;
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
            Assert.Skip("build/dev/host.exe or build/dev/mygame.dll is not built");
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
    const ulong CameraId = 32;
    const ulong MeshRendererId = 33;
    const ulong PointLightId = 35;
    const ulong VolumeId = 42;
    const ulong EnvironmentId = 49;
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
        editor.Link.Send(Document.SceneSnapshot.ToMessage(scene, ""));
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
