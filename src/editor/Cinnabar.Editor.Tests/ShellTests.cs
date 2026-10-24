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
            shell.Layout.Close("assetBrowser");
            shell.Layout.Close("undoHistory");
            shell.SaveLayout();
            saved = shell.Layout.Save().ToJson();
        }

        using var restored = NewShell();

        Assert.Empty(Problems(restored));
        Assert.Equal(saved, restored.Layout.Save().ToJson());
        Assert.False(restored.Layout.IsOpen("assetBrowser"));
        Assert.True(restored.Layout.IsOpen("console"));
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
        Assert.False(shell.Layout.IsOpen("assetBrowser"));
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

    public void Dispose()
    {
        if (Directory.Exists(_settingsDirectory))
        {
            Directory.Delete(_settingsDirectory, recursive: true);
        }
    }
}
