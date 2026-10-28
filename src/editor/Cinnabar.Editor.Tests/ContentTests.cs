using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Shell;
using LogLevel = Cinnabar.Editor.Panels.LogLevel;

namespace Cinnabar.Editor.Tests;

/// <summary>The content in the shell, without a cook daemon: the index fills from the daemon's messages.</summary>
public sealed class ContentTests : IDisposable
{
    readonly string _directory = Path.Combine(Path.GetTempPath(), $"cinnabar-content-tests-{Guid.NewGuid():N}");

    const string DoorScript = "9d2e41c0b7a35f6e81c4d2a90b3e7f15";
    const string UtilScript = "00112233445566778899aabbccddeeff";

    EditorShell NewShell()
    {
        Directory.CreateDirectory(_directory);
        var scenePath = Path.Combine(_directory, "main.scene");
        File.WriteAllText(scenePath, "scene 1\n\nentity 0000000000000001\nname = \"Door\"\n\nentity 0000000000000002\nname = \"Gate\"\n");
        var shell = new EditorShell(new EditorOptions("host.exe", "game.dll", scenePath) { AutosaveDirectory = Path.Combine(_directory, "autosave") },
            new EditorSettings(Path.Combine(_directory, "settings")));
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _directory)], [new Importer(AssetKind.Script, ".luau", [Native])], []));
        shell.Assets.Apply(new AssetSnapshot(
        [
            new Asset(DoorScript, AssetKind.Script, "game", "door.luau", AssetStatus.Current, 0, 0, "Door", [], [UtilScript], "", "", 0, [0, 0], "", []),
            new Asset(UtilScript, AssetKind.Script, "game", "lib/util.luau", AssetStatus.Current, 0, 0, "", [], [], "", "", 0, [0, 0], "", []),
        ], [new Folder("game", "lib")]));
        return shell;
    }

    static readonly SettingInfo Native = new("native", ["true", "false"], "false", "Compile to machine code.");

    [Fact]
    public void TheFileOperationsLeaveSubassetsToTheirFile()
    {
        using var shell = NewShell();
        shell.Assets.Apply(new AssetDelta(
        [
            new Asset("10", AssetKind.Model, "game", "kit.glb", AssetStatus.Current, 0, 0, "", [], [], "", "", 0, [0, 0], "", []),
            new Asset("11", AssetKind.Mesh, "game", "kit.glb", AssetStatus.Current, 0, 0, "", [], [], "10", "Wall", 0, [0, 0], "", []),
        ], [], [], []));

        shell.SelectContent(null, ["10", DoorScript]);
        Assert.False(shell.SelectionHasSubassets);
        shell.SelectContent(null, ["10", "11"]);
        Assert.True(shell.SelectionHasSubassets);

        // A mesh field takes the model's mesh and nothing else. A field without a kind takes any asset.
        var meshes = new Panels.AssetContext(shell.Assets, "mesh", _ => { });
        Assert.Equal(["11"], meshes.Choices.Select(a => a.Guid));
        Assert.False(meshes.Takes(shell.Assets.Find(DoorScript)!));
        Assert.True(new Panels.AssetContext(shell.Assets, "", _ => { }).Takes(shell.Assets.Find(DoorScript)!));
    }

    [Fact]
    public void AMaterialFieldTakesMaterialsAndTheirInstances()
    {
        using var shell = NewShell();
        shell.Assets.Apply(new AssetDelta(
        [
            new Asset("20", AssetKind.Material, "game", "rock.material", AssetStatus.Current, 0, 0, "", [], [], "", "", 0, [0, 0], "", []),
            new Asset("21", AssetKind.MaterialInstance, "game", "mossy.material_instance", AssetStatus.Current, 0, 0, "", [], ["20"], "", "", 0, [0, 0], "", []),
            new Asset("22", AssetKind.ShadingModel, "game", "lit.shading", AssetStatus.Current, 0, 0, "", [], [], "", "", 0, [0, 0], "", []),
        ], [], [], []));

        var materials = new Panels.AssetContext(shell.Assets, "material", _ => { });
        Assert.Equal(["21", "20"], materials.Choices.Select(a => a.Guid));
    }

    [Fact]
    public void ADeleteShowsTheAssetsThatUseWhatItTakes()
    {
        using var shell = NewShell();

        var (deleted, users) = shell.DeleteEffects([new ContentItem(UtilScript, null)]);
        Assert.Equal(UtilScript, Assert.Single(deleted).Guid);
        Assert.Equal(DoorScript, Assert.Single(users).Guid);

        // A folder takes the assets in it, and what uses each other goes with it.
        (deleted, users) = shell.DeleteEffects([ContentItem.Of(new ContentFolder("game", "lib")), new ContentItem(DoorScript, null)]);
        Assert.Equal(2, deleted.Count);
        Assert.Empty(users);
    }

    [Fact]
    public void ANewAssetIsNamedForWhatItIsAndNoFileHasTheName()
    {
        using var shell = NewShell();
        shell.SelectContent(new ContentFolder("game", ""), []);
        File.WriteAllText(Path.Combine(_directory, "new_script.luau"), "");

        Assert.Equal("new_script_2", shell.NewName(AssetTemplate.Script));
        Assert.Equal("new_behaviour", shell.NewName(AssetTemplate.Behaviour));
        Assert.Equal("new_folder", shell.NewName(null));
    }

    [Fact]
    public void AnImportSettingAtItsDefaultLeavesTheMetaFile()
    {
        Setting[] settings = [new("old", "1"), new("native", "true"), new("last", "2")];

        Assert.Equal([new Setting("old", "1"), new Setting("last", "2")], EditorShell.WithSetting(settings, [Native], "native", "false"));
        Assert.Equal([new Setting("old", "1"), new Setting("native", "false"), new Setting("last", "2")],
            EditorShell.WithSetting(settings, [], "native", "false"));
        Assert.Equal([new Setting("native", "true")], EditorShell.WithSetting([], [Native], "native", "true"));
    }

    [Fact]
    public async Task AnOperationWithoutTheDaemonFailsAndSaysWhy()
    {
        using var shell = NewShell();
        shell.SelectContent(new ContentFolder("game", ""), [DoorScript]);
        var failures = new List<string>();
        shell.OperationFailed += failures.Add;

        Assert.False(shell.CanChangeContent);
        Assert.False(shell.Commands.Get(EditorCommands.DuplicateAsset).CanExecute);
        Assert.False(await shell.Create(AssetTemplate.Script, "x"));
        Assert.Single(failures);
        Assert.Contains(shell.Console.Lines, l => l.Level == LogLevel.Warning && l.Text.StartsWith("content: "));
    }

    [Fact]
    public void ABehaviourScriptAddsItsBehaviourToEachEntityThatLacksIt()
    {
        using var shell = NewShell();

        Assert.True(shell.CanAddBehaviour([1, 2], DoorScript));
        Assert.True(shell.AddBehaviour([1, 2], DoorScript));
        Assert.Equal(DoorScript, Assert.Single(shell.Scene!.Scene.Find(1)!.Behaviours).Script);
        Assert.Equal(DoorScript, Assert.Single(shell.Scene.Scene.Find(2)!.Behaviours).Script);
        // Both in one undo entry.
        Assert.Equal("Add Door", Assert.Single(shell.Scene.History).Label);

        Assert.False(shell.CanAddBehaviour([1], DoorScript));
        shell.Scene.Undo();
        Assert.Empty(shell.Scene.Scene.Find(1)!.Behaviours);
    }

    [Fact]
    public void AScriptWithoutABehaviourAddsNone()
    {
        using var shell = NewShell();

        Assert.False(shell.CanAddBehaviour([1], UtilScript));
        Assert.False(shell.AddBehaviour([1], UtilScript));
        Assert.Contains(shell.Console.Lines, l => l.Level == LogLevel.Warning && l.Text.Contains("defines a behaviour"));
        Assert.Empty(shell.Scene!.History);
    }

    [Fact]
    public void OpeningTheOpenSceneAsksNothing()
    {
        using var shell = NewShell();
        var asked = new List<string>();
        shell.OpenSceneFileRequested += asked.Add;

        shell.RequestOpenScene(shell.Scene!.Path);
        shell.RequestOpenScene(Path.Combine(_directory, "other.scene"));

        Assert.Equal([Path.Combine(_directory, "other.scene")], asked);
    }

    [Fact]
    public void TheCommandLineNamesTheCookDaemonAndTheRoots()
    {
        var options = EditorOptions.Parse(
            ["--cook", "tools/cook.exe", "--cache", "cache", "--definitions", "types.d.luau", "--dxc", "dxc/dxc.exe", "--include", "shaders", "--root", "game=content", "--root", "engine=lib/content"]);

        Assert.Equal(Path.GetFullPath("tools/cook.exe"), options.Cook.CookPath);
        Assert.Equal(Path.GetFullPath("cache"), options.Cook.CachePath);
        Assert.Equal(Path.GetFullPath("types.d.luau"), options.Cook.DefinitionsPath);
        Assert.Equal([("game", Path.GetFullPath("content")), ("engine", Path.GetFullPath("lib/content"))], options.Cook.Roots);
        Assert.Equal(Path.GetFullPath("dxc/dxc.exe"), options.Cook.DxcPath);
        Assert.Equal([Path.GetFullPath("shaders")], options.Cook.Includes);
        // Without roots, the daemon cooks the sample's content and the engine's.
        Assert.Equal(["game", "engine"], EditorOptions.Parse([]).Cook.Roots.Select(r => r.Name));
    }

    [Fact]
    public void TheHostIsToldItsContentAndItsProjectAndRunsBesideItself()
    {
        var options = EditorOptions.Parse(["--host", "build/dev/host.exe", "--game", "build/dev/mygame.dll", "--cache", "build/dev/content", "--project", "samples/mygame/project.settings"]);

        Assert.Equal(
            [Path.GetFullPath("build/dev/mygame.dll"), "--content", Path.GetFullPath("build/dev/content"), "--project", Path.GetFullPath("samples/mygame/project.settings"), "--shared", "x"],
            options.HostArguments("--shared", "x"));
        Assert.Equal(Path.GetFullPath("build/dev"), options.HostDirectory);
        // The defaults are the repository's build layout, wherever the editor runs from.
        var defaults = EditorOptions.Parse([]);
        Assert.Equal(Path.Combine(EditorOptions.RepositoryRoot(), "build", "dev", "host.exe"), defaults.HostPath);
        Assert.Equal(Path.Combine(EditorOptions.RepositoryRoot(), "build", "dev", "content"), defaults.Cook.CachePath);
    }

    [Fact]
    public void TheScriptEditorComesFromTheSettings()
    {
        var settings = new EditorSettings(Path.Combine(_directory, "settings"));
        Assert.Equal(EditorSettings.DefaultScriptEditor, settings.ScriptEditor());

        settings.Write(EditorSettings.SettingsFileName, """{ "scriptEditor": ["notepad", "{file}"] }""");
        Assert.Equal(["notepad", "{file}"], settings.ScriptEditor());
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory))
        {
            Directory.Delete(_directory, recursive: true);
        }
    }
}
