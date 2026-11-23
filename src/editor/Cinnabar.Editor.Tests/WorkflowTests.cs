using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Commands.Ribbon;
using Cinnabar.Editor.Docking;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// Where the editor's controls are (see docs/editor/workflows.md): the ribbon's tabs by kind of work, what is a
/// viewport's or the Scene's and so not the ribbon's, a viewport's settings as data, and the workspaces.
/// </summary>
public sealed class WorkflowTests : IDisposable
{
    readonly TempDirectory _temp = new("workflow");

    EditorShell NewShell(string? settings = null) =>
        new(new EditorOptions("host.exe", "game.dll") { AutosaveDirectory = _temp.Combine("autosave") }, new EditorSettings(settings ?? _temp.Combine("settings")));

    static IEnumerable<string> CommandsOf(RibbonItem item) => item switch
    {
        LargeButton large => [large.Command],
        SmallStack stack => stack.Commands,
        SplitButton split => MenuEntry.Commands(split.Menu).Prepend(split.Command),
        Dropdown dropdown => MenuEntry.Commands(dropdown.Menu),
        Commands.Ribbon.ComboBox combo => [combo.Command],
        _ => [],
    };

    static IEnumerable<string> RibbonCommands(RibbonLayout ribbon) =>
        ribbon.Tabs.SelectMany(t => t.Groups).SelectMany(g => g.Items).SelectMany(CommandsOf).Concat(ribbon.QuickAccess);

    [Fact]
    public void TheRibbonHasATabForEachKindOfWorkUnderItsDiscipline()
    {
        using var shell = NewShell();

        Assert.Equal(["home", "lighting", "environment", "gameplay", "scripting", "audio", "project", "window"], shell.Ribbon.Tabs.Select(t => t.Id));
        var categories = shell.Ribbon.Categories.ToDictionary(c => c.Id, c => c.Label);
        string? Discipline(string tab) => shell.Ribbon.Tabs.Single(t => t.Id == tab).Category is { } c ? categories[c] : null;
        Assert.Equal("Art", Discipline("lighting"));
        Assert.Equal("Art", Discipline("environment"));
        Assert.Equal("Design", Discipline("gameplay"));
        Assert.Equal("Design", Discipline("scripting"));
        Assert.Equal("Audio", Discipline("audio"));
        Assert.Null(Discipline("home"));
        // Play is beside the tabs, whatever tab shows.
        Assert.Equal([EditorCommands.PlayMode, EditorCommands.PauseMode, EditorCommands.StepFrame, EditorCommands.StopMode], shell.Ribbon.QuickAccess);
        Assert.Empty(shell.Ribbon.Validate(shell.Commands));
    }

    [Fact]
    public void WhatIsAViewportsOrTheScenesIsNotInTheRibbon()
    {
        using var shell = NewShell();
        var ribbon = RibbonCommands(shell.Ribbon).ToHashSet();

        // A viewport's own: its settings, its view and the Scene's views (see docs/editor/viewport.md#toolbar).
        string[] viewport =
        [
            .. ViewportOptions.Toggles.Select(t => t.Command), .. ViewportOptions.Choices.Select(c => c.Command),
            EditorCommands.DebugView, EditorCommands.ExposureUp, EditorCommands.ExposureDown, EditorCommands.ExposureReset,
            EditorCommands.ViewProjection, EditorCommands.View2D, EditorCommands.SceneLayout, EditorCommands.ViewportScale, EditorCommands.Stats,
            EditorCommands.FrameSelected, EditorCommands.FrameScene, EditorCommands.OrbitSelection,
            .. Enumerable.Range(0, EditorViewport.SceneViews).Select(EditorCommands.SceneViewToggle),
        ];
        // The Scene's own: the tool, the space, snapping and mesh mode with its tools (see docs/editor/viewport.md#tool-strip).
        string[] scene =
        [
            EditorCommands.SelectTool, EditorCommands.MoveTool, EditorCommands.RotateTool, EditorCommands.ScaleTool, EditorCommands.NavPathTool,
            EditorCommands.LocalSpace, EditorCommands.Snap, EditorCommands.EditMesh, EditorCommands.ObjectMode, EditorCommands.MeshBlock,
            .. shell.Commands.All.Select(c => c.Id).Where(id => id.StartsWith("mesh.", StringComparison.Ordinal) || id.StartsWith("texture.", StringComparison.Ordinal)),
        ];

        // A cutscene's timeline's own, which act while it has the keyboard (see docs/editor/cutscene-editor.md#the-timeline).
        // And its keys, which act on the selection wherever the keyboard is (see docs/editor/cutscene-editor.md#keying).
        // And its bindings', which act between the selected entities and the cutscene (see docs/editor/cutscene-editor.md#bindings).
        // And its cameras', which act between the active scene view and the cutscene (see docs/editor/cutscene-editor.md#cameras).
        string[] timeline =
        [
            .. EditorCommands.CutsceneTimelineCommands, .. EditorCommands.CutsceneKeyCommands, .. EditorCommands.CutsceneBindingCommands,
            .. EditorCommands.CutsceneCameraCommands,
        ];

        Assert.All(viewport, id => Assert.DoesNotContain(id, ribbon));
        Assert.All(scene, id => Assert.DoesNotContain(id, ribbon));
        Assert.All(timeline, id => Assert.DoesNotContain(id, ribbon));
        // They are commands all the same, for the command palette and the key bindings.
        Assert.All(viewport.Concat(scene).Concat(timeline), id => Assert.NotNull(shell.Commands.Find(id)));
    }

    [Fact]
    public void AMenuNamesKnownCommandsAndHasNoEmptyMenuInIt()
    {
        var commands = new CommandRegistry();
        commands.Register(new Command("a", "A", () => { }));
        MenuEntry[] menu = ["a", new MenuSeparator(), new Submenu("More", null, ["a", "b"]), new Submenu("Empty", null, [])];

        Assert.Equal(["a", "a", "b"], MenuEntry.Commands(menu));
        var errors = MenuEntry.Validate(commands, menu).ToList();
        Assert.Contains(errors, e => e.Contains("no command b"));
        Assert.Contains(errors, e => e.Contains("Empty"));
        Assert.Equal(2, errors.Count);

        var layout = new RibbonLayout([], [new RibbonTab("home", "Home", [new RibbonGroup("G", [new Dropdown("D", null, menu)])])]) { QuickAccess = ["a", "gone"] };
        Assert.Contains(layout.Validate(commands), e => e.Contains("quick access") && e.Contains("gone"));
    }

    [Fact]
    public void EveryDebugViewButTheLitSceneIsInOneGroupOfAViewportsMenu()
    {
        var grouped = ViewportOptions.DebugViewGroups.SelectMany(g => g.Views).ToList();

        Assert.Equal(grouped.Count, grouped.Distinct().Count());
        Assert.Equal(Enum.GetValues<DebugView>().Where(v => v != DebugView.Lit).Order(), grouped.Order());
    }

    [Fact]
    public void AViewportsTogglesAndChoicesChangeTheSettingsThatTheyRead()
    {
        var settings = EditorShell.DefaultViewportSettings;

        foreach (var toggle in ViewportOptions.Toggles)
        {
            var on = toggle.IsOn(settings);
            var flipped = toggle.Set(settings, !on);
            Assert.Equal(!on, toggle.IsOn(flipped));
            Assert.Equal(settings, toggle.Set(flipped, on));
        }
        // Every feature draws until it is turned off, and the measurement is off until it is asked for.
        Assert.All(ViewportOptions.Features, f => Assert.True(f.IsOn(settings)));
        Assert.False(ViewportOptions.ShadingStats.IsOn(settings));
        foreach (var choice in ViewportOptions.Choices)
        {
            Assert.Contains(choice.Get(settings), choice.Options);
            foreach (var option in choice.Options)
            {
                Assert.Equal(option, choice.Get(choice.Set(settings, option)));
            }
            // An option that the choice does not have changes nothing.
            Assert.Equal(settings, choice.Set(settings, "no such option"));
        }
    }

    [Fact]
    public void AToolbarsChangeIsItsOwnViewportsAndTheCommandsIsTheSettingsViewports()
    {
        using var shell = NewShell();
        var top = shell.Viewports[1];
        var bloom = ViewportOptions.Features.Single(f => f.Command == EditorCommands.Bloom);

        // As a viewport's toolbar does.
        shell.ApplyViewportSettings(top, bloom.Set(top.Settings, false));

        Assert.True(top.Settings.NoBloom);
        Assert.False(shell.SettingsViewport.Settings.NoBloom);
        Assert.True(shell.Commands.Get(EditorCommands.Bloom).IsChecked);
        shell.Commands.Get(EditorCommands.Bloom).Execute();
        Assert.True(shell.SettingsViewport.Settings.NoBloom);
    }

    [Fact]
    public void EveryWorkspaceArrangesKnownPanelsAndKeepsTheViewports()
    {
        using var shell = NewShell();
        var panels = shell.Layout.Panels.Select(p => p.Id).ToHashSet();

        Assert.Equal(Workspaces.DefaultId, shell.Workspaces.Active.Id);
        Assert.Equal(shell.Workspaces.All.Count, shell.Workspaces.All.Select(w => w.Id).Distinct().Count());
        foreach (var workspace in shell.Workspaces.All)
        {
            shell.SwitchWorkspace(workspace);
            Assert.Equal(workspace, shell.Workspaces.Active);
            Assert.True(shell.Layout.IsViewportOpen(ViewportDocument.SceneId), workspace.Id);
            Assert.True(shell.Layout.IsViewportOpen(ViewportDocument.GameId), workspace.Id);
            Assert.True(shell.Layout.IsOpen("properties"), workspace.Id);
            // Its ribbon tab is one of the ribbon's.
            Assert.Contains(shell.Ribbon.Tabs, t => t.Id == workspace.RibbonTab);
            Assert.Equal(workspace.Label, ((ChoiceCommand)shell.Commands.Get(EditorCommands.Workspace)).Selected);
            Assert.True(shell.Commands.Get(EditorCommands.WorkspaceSwitch(workspace.Id)).IsChecked);
        }
        Assert.DoesNotContain(shell.Console.Lines, l => l.Level >= Model.LogLevel.Warning);
        // The first workspace has every panel, as an editor without workspaces had.
        shell.SwitchWorkspace(shell.Workspaces.Find(Workspaces.DefaultId)!);
        Assert.All(panels, id => Assert.True(shell.Layout.IsOpen(id), id));
    }

    [Fact]
    public void AWorkspaceIsAsItWasLeftAndResetPutsItBack()
    {
        using var shell = NewShell();
        var lighting = shell.Workspaces.Find("lighting")!;
        var general = shell.Workspaces.Find("General")!;
        var requested = new List<string>();
        shell.RibbonTabRequested += requested.Add;

        shell.SwitchWorkspace(lighting);
        Assert.Equal(["lighting"], requested);
        Assert.True(shell.Layout.IsOpen("atmosphere"));
        Assert.False(shell.Layout.IsOpen("contentBrowser"));
        shell.Layout.Close("atmosphere");
        shell.Layout.Show("contentBrowser");

        shell.SwitchWorkspace(general);
        Assert.True(shell.Layout.IsOpen("atmosphere"));
        shell.SwitchWorkspace(lighting);
        Assert.False(shell.Layout.IsOpen("atmosphere"));
        Assert.True(shell.Layout.IsOpen("contentBrowser"));

        Assert.True(shell.Commands.Get(EditorCommands.ResetLayout).Execute());
        Assert.True(shell.Layout.IsOpen("atmosphere"));
        Assert.False(shell.Layout.IsOpen("contentBrowser"));
        // The workspace that is active already does nothing.
        Assert.False(shell.Workspaces.Switch(lighting));
    }

    [Fact]
    public void TheWorkspacesStayAcrossSessions()
    {
        var settings = _temp.Combine("kept-settings");
        using (var shell = NewShell(settings))
        {
            shell.SwitchWorkspace(shell.Workspaces.Find("lighting")!);
            shell.Layout.Close("atmosphere");
            shell.SwitchWorkspace(shell.Workspaces.Find("scripting")!);
            shell.SaveLayout();
        }
        using (var shell = NewShell(settings))
        {
            Assert.Equal("scripting", shell.Workspaces.Active.Id);
            // The Scripting workspace has the scene and the game side by side, and no atmosphere.
            Assert.False(shell.Layout.IsOpen("atmosphere"));
            Assert.True(shell.Layout.IsOpen("console"));
            shell.SwitchWorkspace(shell.Workspaces.Find("lighting")!);
            Assert.False(shell.Layout.IsOpen("atmosphere"));
            Assert.True(shell.Layout.IsOpen("weather"));
        }
        // A file that is not the workspaces' is refused, and the layout is the first workspace's.
        File.WriteAllText(Path.Combine(settings, Workspaces.FileName), "{ \"active\": \"no such workspace\" }");
        using (var shell = NewShell(settings))
        {
            Assert.Equal(Workspaces.DefaultId, shell.Workspaces.Active.Id);
            Assert.Contains(shell.Console.Lines, l => l.Level == Model.LogLevel.Warning && l.Text.Contains(Workspaces.FileName));
        }
    }

    [Fact]
    public void TheUndoHistoryDoesNotMoveWhileTheGamePlays()
    {
        Directory.CreateDirectory(_temp.Path);
        using var shell = TestShell.Open(_temp, "door.scene", "scene 1\n\nentity 0000000000000001\nname = \"Door\"\n");
        Assert.True(shell.Edit("Rename", new Rename(1, "Gate")));
        Assert.True(shell.MoveHistoryTo(0));
        Assert.Equal("Door", shell.Scene!.Scene.Find(1)!.Name);
        Assert.True(shell.MoveHistoryTo(1));

        shell.Play();

        Assert.False(shell.MoveHistoryTo(0));
        Assert.Equal(1, shell.Scene.Position);
        Assert.Equal("Gate", shell.Scene.Scene.Find(1)!.Name);
        // The position that the scene is at already is no move.
        Assert.True(shell.MoveHistoryTo(1));
        shell.Stop();
        Assert.True(shell.MoveHistoryTo(0));
    }

    [Fact]
    public void HideAndLockActOnTheSelectionWhileTheGamePlays()
    {
        Directory.CreateDirectory(_temp.Path);
        using var shell = TestShell.Open(_temp, "door.scene", "scene 1\n\nentity 0000000000000001\nname = \"Door\"\n");
        shell.OnGameMessage(new EntitySnapshot([new EntityInfo(1UL << 32, "Door", 1, 1, 0, true, []), new EntityInfo(2UL << 32, "Spawned", 0, 0, 0, true, [])]));
        var hide = shell.Commands.Get(EditorCommands.HideSelected);
        Assert.False(hide.CanExecute);

        shell.Play();
        shell.Selection.Select(1UL << 32);

        // The document has no selection while the game plays, and what is hidden is not the document's.
        Assert.Empty(shell.SelectedSceneEntities);
        Assert.True(hide.Execute());
        Assert.True(shell.IsHidden(1));
        Assert.True(shell.Commands.Get(EditorCommands.LockSelected).Execute());
        Assert.True(shell.IsLocked(1));
        // An entity that the game spawned has no scene ID to keep them by.
        shell.Selection.Select(2UL << 32);
        Assert.False(hide.CanExecute);
    }

    public void Dispose() => _temp.Dispose();
}
