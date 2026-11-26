using Cinnabar.Editor.Docking;
using Cinnabar.Editor.Model;
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
    public void FloatingBoundsRoundTrip()
    {
        using var dir = new TempDirectory("floating-bounds");
        using var shell = TestShell.Open(dir, null, null);
        var saved = shell.Layout.Save() with { Floating = ["contentBrowser"], Windows = [new Docking.FloatingWindow("contentBrowser", -1200, 40.5, 900, 600)] };

        var file = Docking.LayoutFile.FromJson(saved.ToJson());

        Assert.Equal(saved.Windows, file!.Windows);
        // The panel docks first, as the window pops out only when the main window has opened.
        Assert.True(shell.Layout.Restore(file));
        Assert.Equal(saved.Windows, shell.Layout.PendingWindows);
        Assert.True(shell.Layout.IsOpen("contentBrowser"));
    }

    [Fact]
    public void AWindowOffEveryScreenComesBackOnOne()
    {
        (double, double, double, double)[] screens = [(0, 0, 1920, 1080), (1920, 0, 1280, 720)];
        var onSecond = new Docking.FloatingWindow("p", 2000, 100, 800, 600);
        Assert.Equal(onSecond, onSecond.OnScreen(screens));
        // Partly off is still found: it can be dragged by the top that shows.
        var partly = new Docking.FloatingWindow("p", 1800, 100, 800, 600);
        Assert.Equal(partly, partly.OnScreen(screens));

        // The monitor it was on is gone: it comes back whole, in the middle of the first.
        var gone = new Docking.FloatingWindow("p", -2000, 100, 800, 600).OnScreen(screens);
        Assert.Equal((560d, 240d, 800d, 600d), (gone.X, gone.Y, gone.Width, gone.Height));

        // Above a screen, its title bar could not be reached.
        var above = new Docking.FloatingWindow("p", 100, -300, 800, 600).OnScreen(screens);
        Assert.Equal(240d, above.Y);

        // Larger than the screen, it fits.
        var large = new Docking.FloatingWindow("p", -9000, 0, 4000, 3000).OnScreen(screens);
        Assert.Equal((0d, 0d, 1920d, 1080d), (large.X, large.Y, large.Width, large.Height));

        // With no screens known, it stays.
        Assert.Equal(gone, gone.OnScreen([]));
    }

    [Fact]
    public void TheDefaultRibbonAndKeyBindingsAreValid()
    {
        using var shell = NewShell();

        Assert.Empty(Problems(shell));
        Assert.NotEmpty(shell.Ribbon.Tabs);
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
            view.Select("Light Complexity");
            Assert.Equal(Link.Protocol.DebugView.LightComplexity, shell.ViewportSettings.DebugView);

            shell.Commands.Get(EditorCommands.ExposureUp).Execute();
            shell.Commands.Get(EditorCommands.ExposureUp).Execute();
            Assert.Equal(1, shell.ViewportSettings.ExposureOffset);
            Assert.True(shell.Commands.Get(EditorCommands.ExposureReset).Execute());
            Assert.Equal(0, shell.ViewportSettings.ExposureOffset);

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
        Assert.Equal(Link.Protocol.ViewportAa.Fsr, again.ViewportSettings.AntiAliasing);
        Assert.Equal(2f / 3, again.ViewportSettings.RenderScale, 1e-4f);
        Assert.Empty(Problems(again));
    }

    [Fact]
    public void TheQualityPresetIsTheProjectsUnlessThisMachineReplacesIt()
    {
        var project = Path.Combine(_settingsDirectory, "game", "project.settings");
        Directory.CreateDirectory(Path.GetDirectoryName(project)!);
        File.WriteAllText(project, "# The window.\noutput = Auto\n");
        var user = Document.ProjectSettings.UserPath(project);
        // A game's settings menu saved single features on this machine.
        File.WriteAllText(user, "quality.preset = Custom\nquality.aa = Fsr\nquality.render_scale = 0.5\n");
        using var shell = new EditorShell(new EditorOptions("host.exe", "game.dll") { ProjectPath = project }, new EditorSettings(_settingsDirectory));
        var quality = (Commands.ChoiceCommand)shell.Commands.Get(EditorCommands.ProjectQuality);
        var mine = (Commands.ChoiceCommand)shell.Commands.Get(EditorCommands.UserQuality);
        Assert.Equal(EditorShell.HardwareQualityLabel, quality.Selected);
        Assert.Equal(EditorShell.CustomQualityLabel, mine.Selected);

        quality.Select("Medium");
        Assert.Equal("# The window.\noutput = Auto\nquality.preset = Medium\n", File.ReadAllText(project));
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
        Assert.Equal("# The window.\noutput = Auto\n", File.ReadAllText(project));
        Assert.Empty(Problems(shell));
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

    // The viewport's keys are the commands' shortcuts in the viewport's scope, and not the window's, or W in the outliner
    // would change the tool.
    [Fact]
    public void TheViewportsKeysAreItsScopedShortcuts()
    {
        using var shell = NewShell();
        string[] commands =
        [
            EditorCommands.SelectTool, EditorCommands.MoveTool, EditorCommands.RotateTool, EditorCommands.ScaleTool,
            EditorCommands.FrameSelected, EditorCommands.EditMesh, EditorCommands.MeshVertices, EditorCommands.TextureShiftLeft,
            EditorCommands.TextureShiftLeft + EditorCommands.Times10, EditorCommands.Cancel,
        ];

        var viewport = shell.KeyBindings.InScope(Commands.ShortcutScopes.Viewport).Select(b => b.CommandId).ToHashSet();
        Assert.All(commands, command =>
        {
            Assert.Contains(command, viewport);
            Assert.DoesNotContain(shell.KeyBindings.All, b => b.CommandId == command);
        });
    }

    // A scope's key comes before the window's, so a window shortcut with the same key would not run while the scope has
    // the keyboard. No scope's key is a window's.
    [Fact]
    public void AScopedKeyShadowsNoWindowKey()
    {
        using var shell = NewShell();
        var window = shell.KeyBindings.All.ToLookup(b => Commands.KeyBindings.Normalize(b.Shortcut), b => b.CommandId);

        var shadowed = Commands.ShortcutScopes.All
            .SelectMany(scope => shell.KeyBindings.InScope(scope))
            .SelectMany(b => window[Commands.KeyBindings.Normalize(b.Shortcut)])
            .Distinct()
            .ToList();

        Assert.Empty(shadowed);
    }

    // The timeline's keys are bare letters, Space and the arrows, so they are the timeline's and the curve editor's alone,
    // and nothing runs the commands while neither pane has the keyboard.
    [Fact]
    public void TheCutsceneTimelinesKeysAreItsScopedShortcuts()
    {
        using var shell = NewShell();

        Assert.Empty(shell.KeyBindings.Warnings);
        foreach (var id in EditorCommands.CutsceneTimelineCommands)
        {
            if (shell.KeyBindings.ShortcutOf(id) != null)
            {
                Assert.Equal([Commands.ShortcutScopes.CutsceneTimeline], shell.KeyBindings.ScopesOf(id));
            }
            Assert.DoesNotContain(shell.KeyBindings.All, b => b.CommandId == id);
            Assert.False(shell.Commands.Get(id).CanExecute);
        }
        Assert.Contains((EditorCommands.CutscenePlayPause, "Space"), shell.KeyBindings.InScope(Commands.ShortcutScopes.CutsceneTimeline));
    }

    // Esc is Cancel in each scope that has something to cancel, and is not the window's, so the pickers, the value boxes
    // and the other controls that use Esc keep it.
    [Fact]
    public void EscIsCancelInTheViewportTheCanvasesAndTheCutsceneEditor()
    {
        using var shell = NewShell();

        Assert.Equal(
            [Commands.ShortcutScopes.Viewport, Commands.ShortcutScopes.Canvas, Commands.ShortcutScopes.CutsceneEditor],
            shell.KeyBindings.ScopesOf(EditorCommands.Cancel));
        Assert.Contains((EditorCommands.Cancel, "Escape"), shell.KeyBindings.InScope(Commands.ShortcutScopes.CutsceneEditor));
        Assert.DoesNotContain(shell.KeyBindings.All, b => b.Shortcut == "Escape");
        Assert.False(shell.Commands.Get(EditorCommands.Cancel).CanExecute);
    }

    [Fact]
    public void UserKeyBindingsReplaceTheDefaultsAndMoveAViewportKey()
    {
        new EditorSettings(_settingsDirectory).Write(EditorSettings.KeyBindingsFileName, """{ "view.stats": "F3", "tool.move": "G" }""");

        using var shell = NewShell();

        Assert.Equal("F3", shell.KeyBindings.ShortcutOf(EditorCommands.Stats));
        Assert.Contains((EditorCommands.MoveTool, "G"), shell.KeyBindings.InScope(Commands.ShortcutScopes.Viewport));
        Assert.DoesNotContain(shell.KeyBindings.All, b => b.CommandId == EditorCommands.MoveTool);
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

    public void Dispose()
    {
        if (Directory.Exists(_settingsDirectory))
        {
            Directory.Delete(_settingsDirectory, recursive: true);
        }
    }
}
