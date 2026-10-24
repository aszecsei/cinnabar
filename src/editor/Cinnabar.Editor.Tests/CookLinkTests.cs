using Cinnabar.Editor.Content;
using Cinnabar.Editor.Link.Cook;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// The cook link against the real daemon, build/cook.exe, cooking a content root in a temporary directory. The tests
/// are skipped when the cooker is not built.
/// </summary>
public sealed class CookLinkTests : IDisposable
{
    static readonly TimeSpan Timeout = TimeSpan.FromSeconds(30);

    readonly string _cook;
    readonly string _dir;
    readonly string _content;

    public CookLinkTests()
    {
        _cook = Path.Combine(RepositoryRoot(), "build", "cook.exe");
        _dir = Directory.CreateTempSubdirectory("cook_link_test_").FullName;
        _content = Path.Combine(_dir, "content");
        Write("scripts/util.luau", "return {speed = 2}");
        Write("scripts/door.luau", "local util = require('./util')\nreturn Behaviour.define('Door', {speed = Field.number(util.speed)})");
        Write("scripts/broken.luau", "return require('./nothing')");
        Write("scenes/main.scene", "scene 1\n");
    }

    void Write(string path, string text)
    {
        var full = Path.Combine(_content, path);
        Directory.CreateDirectory(Path.GetDirectoryName(full)!);
        File.WriteAllText(full, text);
    }

    CookSession Start(AssetIndex index)
    {
        if (!File.Exists(_cook))
        {
            Assert.Skip("build/cook.exe is not built");
        }
        var session = new CookSession(new CookOptions(_cook, Path.Combine(_dir, "cache"), null, [("game", _content)], _dir), index);
        session.Start();
        return session;
    }

    [Fact]
    public async Task TheDaemonSendsItsIndexAndWhatChanges()
    {
        var index = new AssetIndex();
        using var session = Start(index);
        var output = new List<string>();
        session.Output += line => { lock (output) { output.Add(line); } };

        await Until(() => session.State == CookState.Linked && index.Assets.Count == 4, session, output);
        Assert.Equal("game", Assert.Single(index.Roots).Name);
        var door = index.Assets.Values.Single(a => a.Path == "scripts/door.luau");
        var util = index.Assets.Values.Single(a => a.Path == "scripts/util.luau");
        Assert.Equal("Door", door.Behaviour);
        Assert.Equal([util.Guid], door.Dependencies);
        var broken = index.Assets.Values.Single(a => a.Path == "scripts/broken.luau");
        Assert.Equal(AssetStatus.Failed, broken.Status);
        var problem = Assert.Single(index.ProblemsOf(broken.Guid));
        Assert.Equal(1u, problem.Line);
        Assert.Contains("cannot require", problem.Text);
        Assert.Equal(["scenes", "scripts"], index.ChildFolders("game", ""));

        // Fixing the script clears its problem, and a new file comes in a new folder.
        Write("scripts/broken.luau", "return 1");
        Write("levels/hall.scene", "scene 1\n");
        await Until(() => index.Find(broken.Guid)?.Status == AssetStatus.Current && index.ProblemsOf(broken.Guid).Count == 0
            && index.Assets.Values.Any(a => a.Path == "levels/hall.scene"), session, output);
        Assert.Contains("levels", index.ChildFolders("game", ""));
        Assert.NotNull(session.LastCook);

        // A removed asset leaves the index.
        File.Delete(Path.Combine(_content, "scripts", "util.luau"));
        await Until(() => index.Find(util.Guid) == null && index.Find(door.Guid)?.Status == AssetStatus.Failed, session, output);
    }

    [Fact]
    public async Task ASecondDaemonOfTheSameCacheExitsAndIsNotStartedAgain()
    {
        var first = new AssetIndex();
        using var running = Start(first);
        await Until(() => running.State == CookState.Linked, running, []);

        var second = new AssetIndex();
        using var refused = Start(second);
        var output = new List<string>();
        refused.Output += line => { lock (output) { output.Add(line); } };
        await Until(() => refused.State == CookState.Exited, refused, output);
        Assert.NotEqual(0, refused.ExitCode);
        Assert.Equal(CookState.Linked, running.State);
    }

    static async Task Until(Func<bool> condition, CookSession session, List<string> output)
    {
        var deadline = DateTime.UtcNow + Timeout;
        while (!condition())
        {
            if (DateTime.UtcNow > deadline)
            {
                string lines;
                lock (output)
                {
                    lines = string.Join("\n", output);
                }
                Assert.Fail($"timed out in state {session.State}. The daemon's output:\n{lines}");
            }
            await Task.Delay(50, TestContext.Current.CancellationToken);
        }
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

    public void Dispose()
    {
        try
        {
            Directory.Delete(_dir, recursive: true);
        }
        catch (IOException)
        {
            // The daemon can still hold a file for a moment after it is killed.
        }
    }
}
