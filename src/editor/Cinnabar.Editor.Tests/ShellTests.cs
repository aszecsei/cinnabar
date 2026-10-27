using Cinnabar.Editor.Docking;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Tests;

public sealed class ShellTests : IDisposable
{
    readonly string _settingsDirectory = Path.Combine(Path.GetTempPath(), $"cinnabar-editor-tests-{Guid.NewGuid():N}");

    EditorShell NewShell() =>
        new(new EditorOptions("host.exe", "game.dll"), new EditorSettings(_settingsDirectory));

    static IEnumerable<string> Problems(EditorShell shell) =>
        shell.Console.Lines.Where(l => l.Level >= LogLevel.Warning).Select(l => l.Text);

    [Fact]
    public void TheDefaultRibbonAndKeyBindingsAreValid()
    {
        using var shell = NewShell();

        Assert.Empty(Problems(shell));
        Assert.NotEmpty(shell.Ribbon.Tabs);
    }

    [Fact]
    public void TheCaptureCommandsNeedALinkedHost()
    {
        using var shell = NewShell();
        var screenshot = shell.Commands.Get(EditorCommands.Screenshot);
        var gif = shell.Commands.Get(EditorCommands.CaptureGif);
        Assert.Equal("F12", screenshot.Shortcut);
        Assert.Equal("Shift+F12", gif.Shortcut);
        Assert.False(screenshot.CanExecute);
        Assert.False(gif.CanExecute);
        Assert.False(shell.Captures.Busy);
        Assert.Equal(0, shell.AutomationPort);
    }

    [Fact]
    public void TheViewportsRenderingCommandsChangeItsSettingsAndTheyStay()
    {
        using (var shell = NewShell())
        {
            Assert.Equal(EditorShell.DefaultViewportSettings, shell.ViewportSettings);
            var bloom = shell.Commands.Get(EditorCommands.Bloom);
            Assert.True(bloom.IsChecked);
            Assert.True(bloom.Execute());
            Assert.False(bloom.IsChecked);
            Assert.True(shell.ViewportSettings.NoBloom);

            var view = (Commands.ChoiceCommand)shell.Commands.Get(EditorCommands.DebugView);
            Assert.Equal("Lit", view.Selected);
            Assert.Contains("Lighting Only", view.Options);
            view.Select("Light Complexity");
            Assert.Equal(Link.Protocol.DebugView.LightComplexity, shell.ViewportSettings.DebugView);

            shell.Commands.Get(EditorCommands.ExposureUp).Execute();
            shell.Commands.Get(EditorCommands.ExposureUp).Execute();
            Assert.Equal(1, shell.ViewportSettings.ExposureOffset);
            Assert.True(shell.Commands.Get(EditorCommands.ExposureReset).Execute());
            Assert.Equal(0, shell.ViewportSettings.ExposureOffset);

            ((Commands.ChoiceCommand)shell.Commands.Get(EditorCommands.Helpers)).Select("All");

            ((Commands.ChoiceCommand)shell.Commands.Get(EditorCommands.ViewportQuality)).Select("Low");
            ((Commands.ChoiceCommand)shell.Commands.Get(EditorCommands.ViewportAntiAliasing)).Select("FSR");
            var scale = (Commands.ChoiceCommand)shell.Commands.Get(EditorCommands.ViewportRenderScale);
            Assert.Equal(EditorShell.GameQualityLabel, scale.Selected);
            scale.Select("67%");
            Assert.Equal("67%", scale.Selected);
        }

        // The next session starts with them.
        using var again = NewShell();
        Assert.True(again.ViewportSettings.NoBloom);
        Assert.Equal(Link.Protocol.DebugView.LightComplexity, again.ViewportSettings.DebugView);
        Assert.Equal(Link.Protocol.HelperMode.All, again.ViewportSettings.Helpers);
        Assert.Equal(Link.Protocol.ViewportPreset.Low, again.ViewportSettings.QualityPreset);
        Assert.Equal(Link.Protocol.ViewportAa.Fsr, again.ViewportSettings.AntiAliasing);
        Assert.Equal(2f / 3, again.ViewportSettings.RenderScale, 1e-4f);
        Assert.Empty(Problems(again));
    }

    [Fact]
    public void TheQualityPresetIsTheProjectsUnlessThisMachineReplacesIt()
    {
        var project = Path.Combine(_settingsDirectory, "game", "project.settings");
        Directory.CreateDirectory(Path.GetDirectoryName(project)!);
        File.WriteAllText(project, "output = Auto\n");
        var user = Document.ProjectSettings.UserPath(project);
        // A game's settings menu saved single features on this machine.
        File.WriteAllText(user, "quality.preset = Custom\nquality.aa = Fsr\nquality.render_scale = 0.5\n");
        using var shell = new EditorShell(new EditorOptions("host.exe", "game.dll") { ProjectPath = project }, new EditorSettings(_settingsDirectory));
        var quality = (Commands.ChoiceCommand)shell.Commands.Get(EditorCommands.ProjectQuality);
        var mine = (Commands.ChoiceCommand)shell.Commands.Get(EditorCommands.UserQuality);
        Assert.Equal(EditorShell.HardwareQualityLabel, quality.Selected);
        Assert.Equal(EditorShell.CustomQualityLabel, mine.Selected);

        quality.Select("Medium");
        Assert.Equal("output = Auto\nquality.preset = Medium\n", File.ReadAllText(project));
        // Custom keeps the features; a preset replaces them.
        mine.Select(EditorShell.CustomQualityLabel);
        Assert.Equal("Fsr", Document.ProjectSettings.Get(user, "quality.aa"));
        mine.Select("Ultra");
        Assert.Equal(["quality.preset"], Document.ProjectSettings.Keys(user));
        Assert.Equal("Ultra", mine.Selected);
        // Leaving it to the project again removes the user's file, and By Hardware the project's preset.
        mine.Select(EditorShell.ProjectOutputLabel);
        Assert.False(File.Exists(user));
        quality.Select(EditorShell.HardwareQualityLabel);
        Assert.Equal("output = Auto\n", File.ReadAllText(project));
        Assert.Empty(Problems(shell));
    }

[Fact]
    public void TheOutputModeIsTheProjectsUnlessThisMachineReplacesIt()
    {
        var project = Path.Combine(_settingsDirectory, "game", "project.settings");
        Directory.CreateDirectory(Path.GetDirectoryName(project)!);
        File.WriteAllText(project, "# The window.\noutput = Auto\n");
        using var shell = new EditorShell(new EditorOptions("host.exe", "game.dll") { ProjectPath = project }, new EditorSettings(_settingsDirectory));
        var output = (Commands.ChoiceCommand)shell.Commands.Get(EditorCommands.ProjectOutput);
        var mine = (Commands.ChoiceCommand)shell.Commands.Get(EditorCommands.UserOutput);
        Assert.Equal("Auto", output.Selected);
        Assert.Equal(EditorShell.ProjectOutputLabel, mine.Selected);

        // The project's file keeps its comment, and the game reads the setting's name.
        output.Select("SDR");
        Assert.Equal("# The window.\noutput = Sdr\n", File.ReadAllText(project));

        var user = Document.ProjectSettings.UserPath(project);
        Assert.EndsWith("project.user.settings", user);
        mine.Select("HDR10");
        Assert.Equal("Hdr10", Document.ProjectSettings.Get(user, "output"));
        // Leaving it to the project again removes the user's file.
        mine.Select(EditorShell.ProjectOutputLabel);
        Assert.False(File.Exists(user));
        Assert.Empty(Problems(shell));
    }

    [Fact]
    public void EveryPanelStartsOpen()
    {
        using var shell = NewShell();

        Assert.All(shell.Layout.Panels, p => Assert.True(shell.Layout.IsOpen(p.Id), p.Id));
        Assert.True(shell.Layout.IsOpen(ViewportDocument.PanelId));
    }

    [Fact]
    public void APanelCommandClosesAndShowsItsPanel()
    {
        using var shell = NewShell();
        var command = shell.Commands.Get(EditorCommands.Panel("outliner"));

        command.Execute();
        Assert.False(shell.Layout.IsOpen("outliner"));
        Assert.False(command.IsChecked);

        command.Execute();
        Assert.True(shell.Layout.IsOpen("outliner"));
        Assert.True(command.IsChecked);
    }

    [Fact]
    public void APanelComesBackEvenWhenItsDockIsGone()
    {
        using var shell = NewShell();
        shell.Layout.Close("outliner");
        // Restoring a layout without the left dock is the same as the dock having collapsed away.
        Assert.True(shell.Layout.Restore(shell.Layout.Save()));

        shell.Layout.Show("outliner");

        Assert.True(shell.Layout.IsOpen("outliner"));
    }

    [Fact]
    public void ALayoutRoundTripsThroughSettings()
    {
        string saved;
        using (var shell = NewShell())
        {
            shell.Layout.Close("contentBrowser");
            shell.Layout.Close("undoHistory");
            shell.SaveLayout();
            saved = shell.Layout.Save().ToJson();
        }

        using var restored = NewShell();

        Assert.Empty(Problems(restored));
        Assert.Equal(saved, restored.Layout.Save().ToJson());
        Assert.False(restored.Layout.IsOpen("contentBrowser"));
        Assert.True(restored.Layout.IsOpen("console"));
    }

    [Fact]
    public void ALayoutOfAnEarlierEditorKeepsARenamedPanel()
    {
        using var shell = NewShell();
        var json = shell.Layout.Save().ToJson().Replace("\"contentBrowser\"", "\"assetBrowser\"");
        Assert.Contains("assetBrowser", json);

        Assert.True(shell.Layout.Restore(Docking.LayoutFile.FromJson(json)!));

        Assert.True(shell.Layout.IsOpen("contentBrowser"));
    }

    [Fact]
    public void ALayoutWithoutTheViewportIsRefused()
    {
        using var shell = NewShell();
        var before = shell.Layout.Save().ToJson();
        var file = new LayoutFile(LayoutFile.CurrentVersion, new ToolsNode("dock.left", null, "Left", ["outliner"], null), []);

        Assert.False(shell.Layout.Restore(file));
        Assert.Equal(before, shell.Layout.Save().ToJson());
    }

    [Fact]
    public void ARestoreSkipsUnknownAndRepeatedPanels()
    {
        using var shell = NewShell();
        var file = new LayoutFile(LayoutFile.CurrentVersion,
            new SplitNode("dock.main", null, false,
            [
                new ToolsNode("dock.left", 0.2, "Left", ["outliner", "no.such.panel"], "no.such.panel"),
                new DocumentsNode("dock.documents", 0.6),
                new ToolsNode("dock.right", 0.2, "Right", ["outliner", "properties"], null),
            ]),
            ["console"]);

        Assert.True(shell.Layout.Restore(file));
        Assert.True(shell.Layout.IsOpen("outliner"));
        Assert.True(shell.Layout.IsOpen("properties"));
        // A floating panel docks again in its default dock.
        Assert.True(shell.Layout.IsOpen("console"));
        Assert.False(shell.Layout.IsOpen("contentBrowser"));
    }

    [Fact]
    public void AnUnreadableLayoutFallsBackToTheDefaultWithAWarning()
    {
        new EditorSettings(_settingsDirectory).Write(EditorSettings.LayoutFileName, "{ not json");

        using var shell = NewShell();

        Assert.Contains(Problems(shell), p => p.Contains("layout"));
        Assert.All(shell.Layout.Panels, p => Assert.True(shell.Layout.IsOpen(p.Id), p.Id));
    }

    [Fact]
    public void UserKeyBindingsReplaceTheDefaults()
    {
        new EditorSettings(_settingsDirectory).Write(EditorSettings.KeyBindingsFileName, """{ "view.stats": "F3" }""");

        using var shell = NewShell();

        Assert.Equal("F3", shell.KeyBindings.ShortcutOf(EditorCommands.Stats));
    }

    [Fact]
    public void TheHostStartsOnceTheViewportFindsItsAdapter()
    {
        using var shell = NewShell();

        // host.exe is not there, so the start fails at once, but it is attempted.
        shell.Host.Start(adapter: 1);

        Assert.Equal(Host.HostState.Exited, shell.Host.State);
        Assert.Contains(shell.Console.Lines, l => l.Text.Contains("cannot start"));
        Assert.True(shell.Commands.Get(EditorCommands.RestartHost).CanExecute);
    }

    [Fact]
    public void HostCommandsWaitForTheViewportsAdapter()
    {
        using var shell = NewShell();

        Assert.False(shell.Commands.Get(EditorCommands.RestartHost).CanExecute);
        Assert.False(shell.Commands.Get(EditorCommands.StopHost).CanExecute);
    }

    [Fact]
    public void ASceneWithAnErrorDoesNotReplaceTheOpenOne()
    {
        Directory.CreateDirectory(_settingsDirectory);
        var good = Path.Combine(_settingsDirectory, "good.scene");
        var bad = Path.Combine(_settingsDirectory, "bad.scene");
        File.WriteAllText(good, "scene 1\nentity 0000000000000001\nname = \"One\"\n");
        File.WriteAllText(bad, "scene 1\nentity 0000000000000001\n\tx = 1\n");
        using var shell = NewShell();
        var changes = 0;
        shell.SceneChanged += () => changes++;

        Assert.True(shell.OpenScene(good));
        Assert.Equal("good.scene", shell.Scene!.Title);
        Assert.False(shell.OpenScene(bad));

        Assert.Equal(good, shell.Scene!.Path);
        Assert.Equal(1, changes);
        Assert.Contains(Problems(shell), p => p.Contains($"{bad}:3") && p.Contains("no component or behaviour is open"));
    }

    [Fact]
    public void TheCommandLineOpensAScene()
    {
        Directory.CreateDirectory(_settingsDirectory);
        var path = Path.Combine(_settingsDirectory, "start.scene");
        File.WriteAllText(path, "scene 1\n");
        using var shell = new EditorShell(new EditorOptions("host.exe", "game.dll", path), new EditorSettings(_settingsDirectory));

        Assert.Equal(path, shell.Scene?.Path);
        Assert.True(shell.Commands.Get(EditorCommands.OpenScene).CanExecute);
    }

    public void Dispose()
    {
        if (Directory.Exists(_settingsDirectory))
        {
            Directory.Delete(_settingsDirectory, recursive: true);
        }
    }
}
