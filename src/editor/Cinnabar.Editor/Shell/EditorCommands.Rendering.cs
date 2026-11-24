using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Docking;
using CameraProjection = Cinnabar.Editor.Link.Protocol.CameraProjection;

namespace Cinnabar.Editor.Shell;

static partial class EditorCommands
{
    // The panels, the layout, the ribbon, the viewports' documents and their scale.
    static void RegisterWindow(EditorShell shell)
    {
        var commands = shell.Commands;
        foreach (var panel in shell.Layout.Panels)
        {
            commands.Register(new Command(Panel(panel.Id), panel.Title, () => shell.Layout.Toggle(panel.Id))
            {
                Description = $"Show or hide the {panel.Title.ToLowerInvariant()} panel.",
                Icon = panel.Icon,
                IsCheckedWhen = () => shell.Layout.IsOpen(panel.Id),
            });
        }
        commands.Register(new Command(ResetLayout, "Reset Layout", shell.Workspaces.Reset)
        {
            Description = "Put the panels back where the workspace starts them.",
            Icon = "reset",
        });
        // The workspaces (see docs/editor/shell-and-panels.md#workspaces): a choice for the ribbon, and a command for each,
        // which the command palette and a key binding can run.
        var workspaces = shell.Workspaces;
        commands.Register(new ChoiceCommand(Workspace, "Workspace", [.. workspaces.All.Select(w => w.Label)], () => workspaces.Active.Label,
            label => shell.SwitchWorkspace(workspaces.Find(label)!))
        {
            Description = "Arrange the panels for a kind of work. Each workspace is as it was left, and Reset Layout puts it back as it starts.",
            Icon = "workspace",
        });
        foreach (var workspace in workspaces.All)
        {
            commands.Register(new Command(WorkspaceSwitch(workspace.Id), $"{workspace.Label} Workspace", () => shell.SwitchWorkspace(workspace))
            {
                Description = workspace.Description,
                Icon = "workspace",
                IsCheckedWhen = () => workspaces.Active == workspace,
            });
        }
        commands.Register(new Command(Stats, "Viewport Stats", () =>
        {
            var show = !shell.Viewports.Any(v => v.Session.ShowStats);
            foreach (var viewport in shell.Viewports)
            {
                viewport.Session.ShowStats = show;
            }
        })
        {
            Description = "Show the frame rates and the adapter over the viewports.",
            Icon = "stats",
            IsCheckedWhen = () => shell.Viewports.Any(v => v.Session.ShowStats),
        });
        commands.Register(new Command(CollapseRibbon, "Collapse Ribbon", () => shell.RibbonCollapsed = !shell.RibbonCollapsed)
        {
            Description = "Show only the ribbon's tabs. Double-clicking a tab does the same.",
            Icon = "collapse",
            Shortcut = "Ctrl+F1",
            IsCheckedWhen = () => shell.RibbonCollapsed,
        });
        commands.Register(ChoiceCommand.ForEnum<Viewport.ViewportScale>(ViewportScale, "Scale", () => shell.ActiveViewport.Session.Scale,
            scale =>
            {
                foreach (var viewport in shell.Viewports)
                {
                    viewport.Session.Scale = scale;
                }
            },
            scale => scale == Viewport.ViewportScale.Fit ? "Fit" : "100%",
            description: "Fit the frame to the viewport, or show one frame pixel per screen pixel.",
            icon: "scale"));
        // A preset is a shortcut for the four toggles: the choice shows the preset that they make, or Custom, which is not
        // an option, since there is nothing to choose in it.
        commands.Register(new ChoiceCommand(SceneLayout, "Layout", [.. ScenePreset.All.Select(p => p.Name)],
            () => shell.ScenePresetName, name =>
            {
                if (ScenePreset.Find(name) is { } preset)
                {
                    shell.SetSceneViews(preset.Views);
                }
            })
        {
            Description = "Choose which views the Scene shows: one, two side by side, or the four. The toggles next to it put one view in or out.",
            Icon = "viewport",
        });
        commands.Register(ChoiceCommand.ForEnum(ViewProjection, "Projection",
            () => shell.ProjectionViewport.HasCamera ? shell.ProjectionViewport.Camera.Projection : CameraProjection.Perspective,
            projection => shell.SetProjection(shell.ProjectionViewport, projection),
            description: "Draw the view with perspective, or without it, as a plan or an elevation, or a 2D scene, is drawn. Orbiting an orthographic view makes it a perspective one.",
            icon: "viewport",
            canExecuteWhen: () => shell.ProjectionViewport.HasCamera));
        commands.Register(new Command(View2D, "2D View", () => shell.Show2D(shell.ProjectionViewport))
        {
            Description = "Look at the scene as a 2D game's camera does: without perspective, along +z, with +x to the right and +y up.",
            Icon = "viewport",
            CanExecuteWhen = () => shell.ProjectionViewport.HasCamera,
        });
        for (var i = 0; i < EditorViewport.SceneViews; i++)
        {
            var index = i;
            var view = shell.Viewports[index];
            commands.Register(new Command(SceneViewToggle(index), view.Title, () => shell.ToggleSceneView(index))
            {
                Description = $"Show or hide the {view.Title} view in the Scene. One view always stays.",
                Icon = "viewport",
                CanExecuteWhen = () => shell.CanToggleSceneView(index),
                IsCheckedWhen = () => shell.SceneViews.HasFlag((SceneViewSet)(1 << index)),
            });
        }
        ViewportDocumentToggle(shell, SceneView, "Scene View", ViewportDocument.SceneId, "Show or hide the Scene, which holds the editor's views of the world and its tools.", "viewport");
        ViewportDocumentToggle(shell, GameView, "Game View", ViewportDocument.GameId, "Show or hide the Game view, which shows the game as a player sees it and gives it the input while it plays.", "camera");
    }

    static void ViewportDocumentToggle(EditorShell shell, string id, string label, string document, string description, string icon) =>
        shell.Commands.Register(new Command(id, label, () =>
        {
            if (shell.Layout.IsViewportOpen(document))
            {
                shell.Layout.CloseViewport(document);
            }
            else
            {
                shell.Layout.ShowViewport(document);
            }
        })
        {
            Description = description,
            Icon = icon,
            IsCheckedWhen = () => shell.Layout.IsViewportOpen(document),
        });

    // The settings viewport's rendering (see docs/editor/viewport.md#viewport): what it shows in place of the lit scene, the
    // features that it turns off, the exposure offset, and the helpers. Each toggle is checked while its feature is on.
    static void RegisterRendering(EditorShell shell)
    {
        var commands = shell.Commands;
        commands.Register(ChoiceCommand.ForEnum<Link.Protocol.DebugView>(DebugView, "View", () => shell.ViewportSettings.DebugView,
            view => shell.ViewportSettings = shell.ViewportSettings with { DebugView = view }, EditorShell.DebugViewName,
            description: "Show the lit scene, or a debug view of what makes it: the lighting, the albedo, the normals, the light complexity and more.",
            icon: "viewport"));
        // Each toggle and choice of a viewport's settings is data, which the viewports' toolbars show too (see ViewportOptions).
        foreach (var toggle in ViewportOptions.Toggles)
        {
            commands.Register(Command.Toggle(toggle.Command, toggle.Label, () => toggle.IsOn(shell.ViewportSettings),
                on => shell.ViewportSettings = toggle.Set(shell.ViewportSettings, on), toggle.Description, toggle.Icon));
        }
        foreach (var guide in ViewportOptions.Guides)
        {
            commands.Register(Command.Toggle(guide.Command, guide.Label, () => guide.IsOn(shell.SettingsViewport.Guides),
                on => shell.SetGuides(shell.SettingsViewport, guide.Set(shell.SettingsViewport.Guides, on)), guide.Description, "frame"));
        }
        foreach (var choice in ViewportOptions.Choices)
        {
            commands.Register(new ChoiceCommand(choice.Command, choice.Label, choice.Options, () => choice.Get(shell.ViewportSettings),
                option => shell.ViewportSettings = choice.Set(shell.ViewportSettings, option))
            {
                Description = choice.Description,
                Icon = choice == ViewportOptions.Shapes ? "frame" : "viewport",
            });
        }
        commands.Register(new Command(ExposureUp, "Brighter", () => shell.ChangeExposure(1))
        {
            Description = "Add half a stop to the viewport's exposure.",
        });
        commands.Register(new Command(ExposureDown, "Darker", () => shell.ChangeExposure(-1))
        {
            Description = "Take half a stop from the viewport's exposure.",
        });
        commands.Register(new Command(ExposureReset, "Reset Exposure", () => shell.ChangeExposure(0))
        {
            Description = "Show the exposure that the volumes give, with no offset.",
            CanExecuteWhen = () => shell.ViewportSettings.ExposureOffset != 0,
        });
    }

}
