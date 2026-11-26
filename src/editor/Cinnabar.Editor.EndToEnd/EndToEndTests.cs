using System.Collections.Concurrent;
using System.Diagnostics;
using System.Threading.Channels;
using Cinnabar.Editor.Content;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Protocol;
using Cook = Cinnabar.Editor.Link.Cook;

namespace Cinnabar.Editor.EndToEnd;

/// <summary>
/// The editor's side of both links against the real processes: build/dev/null-host.exe, which renders with the null GPU
/// backend and so needs no GPU, running build/dev/mygame.dll with the sample's settings and no sound, and
/// build/tools/cook.exe as a daemon on a content root in a temporary directory. The unit tests pin each side alone over
/// fakes and the wire's encoding; this test only checks that they still meet. It is skipped when the executables are not
/// built.
/// </summary>
public sealed class EndToEndTests
{
    static readonly TimeSpan Timeout = TimeSpan.FromSeconds(30);

    // The tests' scene sits 1.5e11 m along x, in World_Position's units of 2^-24 m, as the sample's scenes do. Spin is the
    // game's component (samples/mygame), which turns its entity in a Fixed system while the world runs.
    const long Origin = 2516582400000000000;
    const ulong SpinId = 1001;

    [Fact]
    public async Task TheEditorDrivesTheHostAndTheCookDaemon()
    {
        var root = RepositoryRoot();
        var host = Path.Combine(root, "build", "dev", "null-host.exe");
        var game = Path.Combine(root, "build", "dev", "mygame.dll");
        var cook = Path.Combine(root, "build", "tools", "cook.exe");
        string[] missing = [.. new[] { host, game, cook }.Where(p => !File.Exists(p)).Select(p => Path.GetRelativePath(root, p))];
        if (missing.Length > 0)
        {
            Assert.Skip($"{string.Join(", ", missing)} not built: run just build, just null-host and just cook");
        }

        await DriveTheHost(root, host, game);
        await DriveTheCookDaemon(cook);
    }

    // The handshake, a scene that replaces the game's world, an edit and the problem that comes back, a paused step and
    // Play, and the end of the host.
    static async Task DriveTheHost(string root, string hostPath, string gamePath)
    {
        var output = new ConcurrentQueue<string>();
        var port = LinkClient.FreePort();
        var info = new ProcessStartInfo(hostPath,
        [
            gamePath, "--project", Path.Combine(root, "samples", "mygame", "project.settings"),
            "--shared", $"cinnabar-e2e-{Guid.NewGuid():N}", "--audio", "none", "--link", port.ToString(),
        ])
        {
            WorkingDirectory = root,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        using var process = Process.Start(info)!;
        process.OutputDataReceived += (_, e) => output.Enqueue(e.Data ?? "");
        process.ErrorDataReceived += (_, e) => output.Enqueue(e.Data ?? "");
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        string HostConsole() => $"\nThe host's console:\n{string.Join("\n", output)}";
        try
        {
            await using var editor = await Connect(process, port, HostConsole);
            editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "e2e"));
            var welcome = await editor.Next<Welcome>();
            Assert.Equal("mygame", welcome.Game);
            Assert.Equal(LinkMessages.ProtocolVersion, welcome.Protocol);
            await editor.Next<EntitySnapshot>();

            // The editor's scene replaces the game's world, and its edits go as the document makes them, with the scene's
            // number, which is 1 for a loaded scene.
            var spinner = Spinning(1, "Spinner");
            var document = new Document.SceneDocument(Path.Combine(Path.GetTempPath(), $"cinnabar-e2e-{Guid.NewGuid():N}.scene"), Scene(spinner));
            document.Applied += ops => editor.Link.Send(new ApplyOperations([.. ops.SelectMany(o => o.ToWires()).Select(o => o with { Scene = 1 })]));
            editor.Link.Send(Document.SceneSnapshot.ToMessage(document.Scene, ""));
            var loaded = await editor.Next<EntitySnapshot>(s => s.Entities.Any(e => e.Name == "Spinner"));
            var handle = Assert.Single(loaded.Entities).Entity;
            editor.Skipped.Clear();

            // A rename applies, and a field that the game does not have comes back as a problem. They come in either order.
            document.Apply("Rename", new Document.Rename(spinner.Id, "Edited"));
            document.Apply("Bad field", new Document.SetField(spinner.Id, SpinId, "no_such_field", Document.SceneValue.Of(true)));
            var problem = Assert.Single((await editor.Next<EditProblems>(p => !p.Snapshot)).Problems);
            Assert.Equal(spinner.Id, problem.Entity);
            Assert.Contains("no_such_field", problem.Message);
            static bool Renamed(EntityDelta d) => d.Changed.Any(e => e.Name == "Edited");
            if (!editor.Skipped.OfType<EntityDelta>().Any(Renamed))
            {
                await editor.Next<EntityDelta>(Renamed);
            }
            // A problem goes back as a problem, not as an error in the log.
            Assert.DoesNotContain(editor.Skipped, m => m is Log { Level: LogLevel.Error });

            // A watched entity's values go out when they change. In Edit the world stands still; a paused step runs it
            // once, and Play runs it on.
            static string Values(EntityValues v) => string.Join(";", v.Components.Select(c => Convert.ToHexString(c.Data)));
            editor.Link.Send(new WatchEntity(handle));
            var still = Values(await editor.Next<EntityValues>(v => v.Entity == handle));
            editor.Link.Send(new SetMode(EditorMode.Paused));
            editor.Link.Send(new StepFrame());
            var stepped = Values(await editor.Next<EntityValues>(v => v.Entity == handle && Values(v) != still));
            editor.Link.Send(new SetMode(EditorMode.Play));
            await editor.Next<EntityValues>(v => v.Entity == handle && Values(v) != stepped);
            editor.Link.Send(new SetMode(EditorMode.Edit));

            Assert.False(process.HasExited, $"the host exited with code {(process.HasExited ? process.ExitCode : 0)}{HostConsole()}");
        }
        finally
        {
            // The link has no quit: the editor ends the host as it does, by ending its process.
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
            await process.WaitForExitAsync(TestContext.Current.CancellationToken).WaitAsync(Timeout, TestContext.Current.CancellationToken);
        }
    }

    // The daemon's index of a content root, with a script's dependency and another's problem, and an asset operation whose
    // answer comes once the index has the new asset.
    static async Task DriveTheCookDaemon(string cookPath)
    {
        var dir = Directory.CreateTempSubdirectory("cinnabar-e2e-cook-").FullName;
        var content = Path.Combine(dir, "content");
        void Write(string path, string text)
        {
            var full = Path.Combine(content, path);
            Directory.CreateDirectory(Path.GetDirectoryName(full)!);
            File.WriteAllText(full, text);
        }
        Write("scripts/util.luau", "return {speed = 2}");
        Write("scripts/door.luau", "local util = require('./util')\nreturn Behaviour.define('Door', {speed = Field.number(util.speed)})");
        Write("scripts/broken.luau", "return require('./nothing')");
        var output = new ConcurrentQueue<string>();
        try
        {
            var index = new AssetIndex();
            using (var session = new CookSession(new CookOptions(cookPath, Path.Combine(dir, "cache"), null, [("game", content)], dir), index))
            {
                session.Output += output.Enqueue;
                session.Start();
                var deadline = DateTime.UtcNow + Timeout;
                while (!(session.Linked && index.Assets.Count == 3))
                {
                    Assert.True(DateTime.UtcNow < deadline, $"timed out in state {session.State}. The daemon's output:\n{string.Join("\n", output)}");
                    await Task.Delay(50, TestContext.Current.CancellationToken);
                }
                var door = index.Assets.Values.Single(a => a.Path == "scripts/door.luau");
                var util = index.Assets.Values.Single(a => a.Path == "scripts/util.luau");
                var broken = index.Assets.Values.Single(a => a.Path == "scripts/broken.luau");
                Assert.Equal("Door", door.Behaviour);
                Assert.Equal([util.Guid], door.Dependencies);
                Assert.Equal(Cook.AssetStatus.Failed, broken.Status);
                Assert.Contains("cannot require", Assert.Single(index.ProblemsOf(broken.Guid)).Text);

                var created = await session.Request(new Cook.CreateAsset(Cook.AssetTemplate.Behaviour, "game", "scripts", "gate"))
                    .WaitAsync(Timeout, TestContext.Current.CancellationToken);
                Assert.Equal("", created.Error);
                Assert.Equal("Gate", index.Find(Assert.Single(created.Guids))?.Behaviour);
            }
        }
        finally
        {
            try
            {
                Directory.Delete(dir, recursive: true);
            }
            catch (IOException)
            {
                // The daemon can still hold a file for a moment after it is killed.
            }
        }
    }

    static async Task<Editor> Connect(Process host, int port, Func<string> console)
    {
        var deadline = DateTime.UtcNow + Timeout;
        while (true)
        {
            Assert.False(host.HasExited, $"the host exited with code {(host.HasExited ? host.ExitCode : 0)}{console()}");
            try
            {
                return new Editor(await LinkClient.ConnectAsync(port, LinkMessages.Read, TestContext.Current.CancellationToken));
            }
            catch (System.Net.Sockets.SocketException) when (DateTime.UtcNow < deadline)
            {
                await Task.Delay(100, TestContext.Current.CancellationToken);
            }
        }
    }

    // The engine's root: the folder above the test that has the justfile and the sample.
    static string RepositoryRoot()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
        {
            if (File.Exists(Path.Combine(dir.FullName, "justfile")) && File.Exists(Path.Combine(dir.FullName, "samples", "mygame", "project.settings")))
            {
                return dir.FullName;
            }
        }
        return Environment.CurrentDirectory;
    }

    static Document.Scene Scene(params Document.SceneEntity[] entities)
    {
        var scene = new Document.Scene();
        scene.Entities.AddRange(entities);
        return scene;
    }

    // An entity with a Transform at the origin, and Spin at 1 radian per second.
    static Document.SceneEntity Spinning(ulong id, string name)
    {
        var entity = new Document.SceneEntity(id) { Name = name };
        entity.Components.Add(new Document.SceneComponent(1, "Transform",
        [
            new("position", Document.SceneValue.Of(Document.SceneNumber.Of(Origin), Document.SceneNumber.Of(0L), Document.SceneNumber.Of(0L))),
            new("rotation", Document.SceneValue.Of(Document.SceneNumber.Of(0L), Document.SceneNumber.Of(0L), Document.SceneNumber.Of(0L), Document.SceneNumber.Of(1L))),
            new("scale", Document.SceneValue.Of(Document.SceneNumber.Of(1.0), Document.SceneNumber.Of(1.0), Document.SceneNumber.Of(1.0))),
        ]));
        entity.Components.Add(new Document.SceneComponent(SpinId, "Spin", [new("speed", Document.SceneValue.Of(Document.SceneNumber.Of(1.0)))]));
        return entity;
    }

    /// <summary>The editor's end of the link, which reads what comes into a queue.</summary>
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
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
            timeout.CancelAfter(Timeout);
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

        public ValueTask DisposeAsync() => Link.DisposeAsync();
    }
}
