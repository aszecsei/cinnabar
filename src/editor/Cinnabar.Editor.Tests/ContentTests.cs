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
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _directory)]));
        shell.Assets.Apply(new AssetSnapshot(
        [
            new Asset(DoorScript, AssetKind.Script, "game", "door.luau", AssetStatus.Current, 0, 0, "Door", [], [UtilScript]),
            new Asset(UtilScript, AssetKind.Script, "game", "util.luau", AssetStatus.Current, 0, 0, "", [], []),
        ], []));
        return shell;
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
        var options = EditorOptions.Parse(["--cook", "tools/cook.exe", "--cache", "cache", "--definitions", "types.d.luau", "--root", "game=content", "--root", "engine=lib/content"]);

        Assert.Equal(Path.GetFullPath("tools/cook.exe"), options.Cook.CookPath);
        Assert.Equal(Path.GetFullPath("cache"), options.Cook.CachePath);
        Assert.Equal(Path.GetFullPath("types.d.luau"), options.Cook.DefinitionsPath);
        Assert.Equal([("game", Path.GetFullPath("content")), ("engine", Path.GetFullPath("lib/content"))], options.Cook.Roots);
        Assert.Equal("game", Assert.Single(EditorOptions.Parse([]).Cook.Roots).Name);
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
