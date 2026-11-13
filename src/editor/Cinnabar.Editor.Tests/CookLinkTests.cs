using Cinnabar.Editor.Content;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// The cook link against the real daemon, build/tools/cook.exe, cooking a content root in a temporary directory. The tests
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
        _cook = Path.Combine(EditorOptions.RepositoryRoot(), "build", "tools", "cook.exe");
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
            Assert.Skip("build/tools/cook.exe is not built");
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

        await Until(() => session.Linked && index.Assets.Count == 4, session, output);
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

        // A removed asset leaves the index, and its blob leaves the cache, so a game that starts later does not run it.
        var blob = Path.Combine(_dir, "cache", util.Guid + ".blob");
        Assert.True(File.Exists(blob));
        File.Delete(Path.Combine(_content, "scripts", "util.luau"));
        await Until(() => index.Find(util.Guid) == null && index.Find(door.Guid)?.Status == AssetStatus.Failed, session, output);
        Assert.False(File.Exists(blob));
    }

    [Fact]
    public async Task TheDaemonDoesAssetOperationsAndAnswersAfterTheIndexChanges()
    {
        var index = new AssetIndex();
        using var session = Start(index);
        var output = new List<string>();
        session.Output += line => { lock (output) { output.Add(line); } };
        await Until(() => session.Linked && index.Assets.Count == 4, session, output);
        var script = Assert.Single(index.Importers, i => i.Kind == AssetKind.Script);
        Assert.Equal(".luau", script.Extension);
        Assert.Contains(script.Settings, s => s.Key == "native" && s.Default == "false");

        var created = await session.Request(new CreateAsset(AssetTemplate.Behaviour, "game", "scripts", "gate"));
        Assert.Equal("", created.Error);
        var gate = Assert.Single(created.Guids);
        Assert.Equal("Gate", index.Find(gate)?.Behaviour);
        Assert.True(File.Exists(Path.Combine(_content, "scripts", "gate.luau.meta")));

        Assert.Equal("", (await session.Request(new CreateFolder("game", "scripts/doors"))).Error);
        Assert.Equal("", (await session.Request(new MoveAssets([gate], "game", "scripts/doors"))).Error);
        Assert.Equal("", (await session.Request(new RenameAsset(gate, "portcullis"))).Error);
        Assert.Equal("scripts/doors/portcullis.luau", index.Find(gate)?.Path);

        var copy = Assert.Single((await session.Request(new DuplicateAssets([gate]))).Guids);
        Assert.Equal("scripts/doors/portcullis_copy.luau", index.Find(copy)?.Path);

        Assert.Equal("", (await session.Request(new SetImportSettings([new AssetSettings(gate, [new Setting("native", "true")])]))).Error);
        Assert.Equal([new Setting("native", "true")], index.Find(gate)!.Settings);
        Assert.Equal("", (await session.Request(new Reimport([gate]))).Error);
        Assert.Equal([new CookedCount(AssetKind.Script, 1)], session.LastCook!.Cooked);

        // A refused operation changes nothing, and says why.
        var refused = await session.Request(new RenameAsset(copy, "portcullis"));
        Assert.Contains("already exists", refused.Error);
        Assert.Equal("scripts/doors/portcullis_copy.luau", index.Find(copy)?.Path);
        Assert.Contains("root", (await session.Request(new DeleteAssets([], [new Folder("game", "")]))).Error);
    }

    [Fact]
    public async Task TheIndexCarriesAThumbnailPathAndItsFileExists()
    {
        Directory.CreateDirectory(Path.Combine(_content, "textures"));
        // A 1x1 PNG.
        File.WriteAllBytes(Path.Combine(_content, "textures", "dot.png"), Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="));
        var index = new AssetIndex();
        using var session = Start(index);
        var output = new List<string>();
        session.Output += line => { lock (output) { output.Add(line); } };
        await Until(() => session.Linked && index.Assets.Values.Any(a => a.Path == "textures/dot.png"), session, output);

        var dot = index.Assets.Values.Single(a => a.Path == "textures/dot.png");
        Assert.True(dot.ThumbnailReady);
        Assert.True(File.Exists(dot.Thumbnail));
        Assert.StartsWith(Path.Combine(_dir, "cache", "thumbnails").Replace('\\', '/'), dot.Thumbnail.Replace('\\', '/'));
        // A script has no thumbnail.
        Assert.Equal("", index.Assets.Values.First(a => a.Kind == AssetKind.Script).Thumbnail);
    }

    [Fact]
    public async Task SettingsOfTwoAssetsMakeOnePass()
    {
        var index = new AssetIndex();
        using var session = Start(index);
        var output = new List<string>();
        session.Output += line => { lock (output) { output.Add(line); } };
        await Until(() => session.Linked && index.Assets.Count == 4, session, output);
        var door = index.Assets.Values.Single(a => a.Path == "scripts/door.luau");
        var util = index.Assets.Values.Single(a => a.Path == "scripts/util.luau");
        var cooks = 0;
        session.Cooked += _ => cooks++;

        var native = new[] { new Setting("native", "true") };
        Assert.Equal("", (await session.Request(new SetImportSettings([new AssetSettings(door.Guid, native), new AssetSettings(util.Guid, native)]))).Error);

        Assert.Equal(native, index.Find(door.Guid)!.Settings);
        Assert.Equal(native, index.Find(util.Guid)!.Settings);
        Assert.Equal(1, cooks);
        Assert.Equal([new CookedCount(AssetKind.Script, 2)], session.LastCook!.Cooked);
    }

    [Fact]
    public async Task TheDaemonDescribesMaterialGraphsAndCooksPreviews()
    {
        var root = EditorOptions.RepositoryRoot();
        var dxc = Path.Combine(root, "vendor", "dxc", "1.9.2609", "dxc.exe");
        if (!File.Exists(_cook) || !File.Exists(dxc))
        {
            Assert.Skip("build/tools/cook.exe or DXC is missing");
        }
        Write("shading/lit.shading", File.ReadAllText(Path.Combine(root, "lib", "engine", "content", "shading", "lit.shading")));
        Write("shading/lit.hlsli", File.ReadAllText(Path.Combine(root, "lib", "engine", "content", "shading", "lit.hlsli")));
        const string Graph = "material 1\nshading = lit\nparam tint color = [1, 0, 0, 1]\n\nnode 1 output\n\tposition = [0, 0]\n\tbase_color = @2.value\nnode 2 parameter\n\tposition = [-200, 0]\n\tname = \"tint\"\n";
        Write("red.material", Graph);
        var index = new AssetIndex();
        var includes = new[] { Path.Combine(root, "lib", "core", "gpu", "shaders"), Path.Combine(root, "lib", "engine", "content", "shaders") };
        using var session = new CookSession(new CookOptions(_cook, Path.Combine(_dir, "cache"), null, [("game", _content)], _dir, dxc, includes), index);
        session.Start();
        var output = new List<string>();
        session.Output += line => { lock (output) { output.Add(line); } };
        await Until(() => session.Linked && index.Assets.Values.Any(a => a.Kind == AssetKind.Material) && index.ShadingModels.Count == 1, session, output);

        Assert.Contains(index.Nodes, n => n.Kind == "output" && n.PinsFrom == NodePinsFrom.ShadingModel);
        Assert.Contains(index.Nodes, n => n.Kind == "texture_sample" && n.Inputs.Any(p => p.Name == "uv" && p.DefaultLabel == "UV0"));
        var lit = Assert.Single(index.ShadingModels);
        Assert.Equal("lit", lit.Name);
        Assert.Contains(lit.Inputs, p => p.Name == "base_color" && p.Type == PinType.Float3);
        var red = index.Assets.Values.Single(a => a.Kind == AssetKind.Material);
        Assert.Equal(1u, red.Permutations);

        // An unsaved graph cooks into the preview area, and its problems come back with its lines.
        var cooked = await session.CookPreview(red.Guid, Graph.Replace("[1, 0, 0, 1]", "[0, 1, 0, 1]"));
        Assert.Equal("", cooked.Error);
        Assert.True(File.Exists(Path.Combine(_dir, "cache", "preview", red.Guid + ".blob")));
        var broken = await session.CookPreview(red.Guid, Graph.Replace("@2.value", "@3.value"));
        Assert.NotEqual("", broken.Error);
        Assert.Equal(7u, Assert.Single(broken.Problems).Line);
    }

    [Fact]
    public async Task TheDaemonChecksAnUnsavedAnimationGraphAndKeepsItsBlob()
    {
        if (!File.Exists(_cook))
        {
            Assert.Skip("build/tools/cook.exe is missing");
        }
        var fox = File.ReadAllText(Path.Combine(EditorOptions.RepositoryRoot(), "samples", "mygame", "content", "models", "fox", "fox.animation_graph"));
        Write("fox.animation_graph", fox);
        var index = new AssetIndex();
        using var session = Start(index);
        await Until(() => session.Linked && index.Assets.Values.Any(a => a.Kind == AssetKind.AnimationGraph && a.Status == AssetStatus.Current), session, []);
        var asset = index.Assets.Values.Single(a => a.Kind == AssetKind.AnimationGraph);
        var blob = Path.Combine(_dir, "cache", asset.Guid + ".blob");
        var written = File.GetLastWriteTimeUtc(blob);

        Assert.Equal("", (await session.CookPreview(asset.Guid, fox)).Error);

        // A problem names the file and its line, so the editor finds the node, and the graph's blob stays.
        var document = AnimationGraphFile.Parse(fox).File!;
        document.Find(20)!.Set("to", "nowhere");
        var broken = await session.CookPreview(asset.Guid, document.Text);
        Assert.NotEqual("", broken.Error);
        var problem = Assert.Single(broken.Problems);
        Assert.Equal(Path.GetFullPath(Path.Combine(_content, "fox.animation_graph")), Path.GetFullPath(problem.File), ignoreCase: true);
        Assert.Equal(20, document.NodeAt((int)problem.Line));
        Assert.Equal(written, File.GetLastWriteTimeUtc(blob));

        // An edit that the editor writes cooks.
        document = AnimationGraphFile.Parse(fox).File!;
        document.Find(1)!.SetPosition(40, 80);
        Write("fox.animation_graph", document.Text);
        await Until(() => File.GetLastWriteTimeUtc(blob) != written, session, []);
        Assert.Equal(AssetStatus.Current, index.Assets[asset.Guid].Status);
    }

    [Fact]
    public async Task TheDaemonChecksAnUnsavedDecisionAgainstItsBlackboardAndAnUnsavedBlackboard()
    {
        if (!File.Exists(_cook))
        {
            Assert.Skip("build/tools/cook.exe is missing");
        }
        const string Board = "blackboard 1\nentity target\nbool searching\n";
        Write("guard.blackboard", Board);
        var index = new AssetIndex();
        using var session = Start(index);
        await Until(() => session.Linked && index.Assets.Values.Any(a => a.Kind == AssetKind.Blackboard && a.Status == AssetStatus.Current), session, []);
        var board = index.Assets.Values.Single(a => a.Kind == AssetKind.Blackboard);
        var tree = $"decision 1\ntechnique = behavior_tree\nblackboard = ${board.Guid}\n\nnode 1 selector\n\tchildren = 2\nnode 2 action\n\twhen = target != none\n\taction = move_to(key = \"target\")\n";
        Write("guard.decision", tree);
        await Until(() => index.Assets.Values.Any(a => a.Kind == AssetKind.Decision && a.Status == AssetStatus.Current), session, []);
        var decision = index.Assets.Values.Single(a => a.Kind == AssetKind.Decision);

        Assert.Equal("", (await session.CookPreview(decision.Guid, tree)).Error);
        // A key that the blackboard does not have is a problem at the line of its node, which the editor finds.
        var file = DecisionFile.Parse(tree).File!;
        file.Find(2)!.Set("when", "enemy != none");
        var broken = await session.CookPreview(decision.Guid, file.Text);
        Assert.NotEqual("", broken.Error);
        Assert.Equal(2, file.NodeAt((int)Assert.Single(broken.Problems).Line));

        // A blackboard's unsaved text is checked too, at its lines.
        var twice = await session.CookPreview(board.Guid, Board + "bool searching\n");
        Assert.Equal(4u, Assert.Single(twice.Problems).Line);
    }

    [Fact]
    public async Task TheDaemonCooksAnUnsavedUiDocumentAndPutsItsProblemsOnItsElements()
    {
        if (!File.Exists(_cook))
        {
            Assert.Skip("build/tools/cook.exe is missing");
        }
        const string Menu = """
            ui 1
            <ui>
            	<column id="menu" gap="4">
            		<button id="ok">OK</button>
            	</column>
            </ui>

            """;
        Write("menu.ui", Menu);
        var index = new AssetIndex();
        using var session = Start(index);
        await Until(() => session.Linked && index.Assets.Values.Any(a => a.Kind == AssetKind.Ui && a.Status == AssetStatus.Current), session, []);
        var asset = index.Assets.Values.Single(a => a.Kind == AssetKind.Ui);
        Assert.Contains(index.UiAttributes, a => a.Name == "padding" && a.Kind == "edges");
        var preview = Path.Combine(_dir, "cache", "preview", asset.Guid + ".blob");

        Assert.Equal("", (await session.CookPreview(asset.Guid, Menu)).Error);
        Assert.True(File.Exists(preview));
        var written = File.GetLastWriteTimeUtc(preview);

        // A problem names the file, its line and its column, which find the element; the last good preview stays.
        var file = UiFile.Parse(Menu).File!;
        file.SetAttribute(file.AllElements().First(e => e.Get("id") == "ok"), "gap", "wide");
        var broken = await session.CookPreview(asset.Guid, file.Text);
        Assert.NotEqual("", broken.Error);
        var problem = broken.Problems.First(p => p.Error);
        Assert.Equal(Path.GetFullPath(Path.Combine(_content, "menu.ui")), Path.GetFullPath(problem.File), ignoreCase: true);
        Assert.Equal(file.NodeById("ok")!.Index, file.NodeAt((int)problem.Line, (int)problem.Column));
        Assert.Equal(written, File.GetLastWriteTimeUtc(preview));
    }

    [Fact]
    public async Task AModelsSubAssetsHaveTheNamesInItsFile()
    {
        if (!File.Exists(_cook))
        {
            Assert.Skip("build/tools/cook.exe is missing");
        }
        var fox = Path.Combine(EditorOptions.RepositoryRoot(), "samples", "mygame", "content", "models", "fox");
        Directory.CreateDirectory(_content);
        foreach (var name in new[] { "Fox.gltf", "Fox.bin", "Texture.png" })
        {
            File.Copy(Path.Combine(fox, name), Path.Combine(_content, name));
        }
        // A model that the cooker parses after the fox, whose text can land in what the fox's parse gave back.
        File.Copy(Path.Combine(fox, "..", "shapes.gltf"), Path.Combine(_content, "shapes.gltf"));
        var index = new AssetIndex();
        using var session = Start(index);
        await Until(() => session.Linked && index.Assets.Values.Count(a => a.Kind == AssetKind.Animation) == 3, session, []);

        // The index reads them after the model's parse has been freed.
        Assert.Equal(["Run", "Survey", "Walk"], index.Assets.Values.Where(a => a.Kind == AssetKind.Animation).Select(a => a.Subasset).Order(StringComparer.Ordinal));
        Assert.Contains(index.Assets.Values, a => a.Kind == AssetKind.Mesh && a.Subasset == "fox1");
    }

    [Fact]
    public async Task AnOperationWithoutTheDaemonFails()
    {
        using var session = new CookSession(new CookOptions("missing.exe", "cache", null, [], _dir), new AssetIndex());
        var result = await session.Request(new Reimport([]));
        Assert.NotEqual("", result.Error);
    }

    [Fact]
    public async Task ASecondDaemonOfTheSameCacheExitsAndIsNotStartedAgain()
    {
        var first = new AssetIndex();
        using var running = Start(first);
        await Until(() => running.Linked, running, []);

        var second = new AssetIndex();
        using var refused = Start(second);
        var output = new List<string>();
        refused.Output += line => { lock (output) { output.Add(line); } };
        await Until(() => refused.State is CookState.Exited { Code: not 0 }, refused, output);
        Assert.True(running.Linked);
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
