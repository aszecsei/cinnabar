using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Shell;

static partial class EditorCommands
{
    static void RegisterScene(EditorShell shell)
    {
        var commands = shell.Commands;
        commands.Register(new Command(Palette, "Command Palette", shell.RequestPalette)
        {
            Description = "Search every command by name.",
            Icon = "search",
            Shortcut = "Ctrl+Shift+P",
        });
        commands.Register(new Command(OpenScene, "Open Scene", shell.RequestOpenScene)
        {
            Description = "Open a scene file in place of the open scenes. The host's world becomes the scene.",
            Icon = "assets",
            Shortcut = "Ctrl+O",
        });
        // Several scenes of a world open together, each its own document (see
        // docs/editor/document-and-scenes.md#several-scenes).
        commands.Register(new Command(AddScene, "Add Scene", shell.RequestAddScene)
        {
            Description = "Open a scene file beside the open scenes, as the active scene. The host's world holds them all, and each keeps its own undo and save.",
            Icon = "scene",
            Shortcut = "Ctrl+Shift+O",
            CanExecuteWhen = () => shell.Scene is { IsPrefab: false },
        });
        commands.Register(new Command(CloseScene, "Close Scene", shell.RequestCloseScene)
        {
            Description = "Close the active scene, which asks about its changes first. The other open scenes stay.",
            Icon = "delete",
            CanExecuteWhen = () => shell.Scenes.Count > 1,
        });
        // Save, Undo and Redo act on the graph editor whose document is active, and on the active scene otherwise.
        commands.Register(new Command(Save, "Save", () => _ = shell.ActiveGraphEditor is { } graph ? shell.SaveGraph(graph) : shell.SaveScene())
        {
            Description = "Write the active scene, or the graph that the active graph editor shows, to its file. Not while a drag or a tool has an edit open.",
            Icon = "save",
            Shortcut = "Ctrl+S",
            // An open entry's preview can still be put back, so the file waits for it to end.
            CanExecuteWhen = () => shell.ActiveGraphEditor is { } graph ? !graph.Document.InTransaction : shell.Scene != null && shell.OpenEdit == null,
        });
        commands.Register(new Command(SaveAs, "Save As", shell.RequestSaveAs)
        {
            Description = "Write the active scene to a new file, which it then edits. Not while a drag or a tool has an edit open.",
            Icon = "save-as",
            Shortcut = "Ctrl+Shift+S",
            CanExecuteWhen = () => shell.Scene != null && shell.OpenEdit == null,
        });
        commands.Register(new Command(SaveAll, "Save All Scenes", () => _ = shell.SaveAllScenes())
        {
            Description = "Write every open scene that has changes to its file. Not while a drag or a tool has an edit open.",
            Icon = "save",
            CanExecuteWhen = () => shell.AnySceneDirty && shell.OpenEdit == null,
        });
        commands.Register(new Command(Undo, "Undo", () =>
        {
            if (shell.ActiveGraphEditor is { } graph)
            {
                graph.Document.Undo();
            }
            else
            {
                shell.Scene?.Undo();
            }
        })
        {
            Description = "Undo the last edit of the active scene.",
            Icon = "undo",
            Shortcut = "Ctrl+Z",
            CanExecuteWhen = () => shell.ActiveGraphEditor is { } graph ? graph.Document.CanUndo : shell.IsEditing && shell.Scene?.CanUndo == true,
        });
        commands.Register(new Command(Redo, "Redo", () =>
        {
            if (shell.ActiveGraphEditor is { } graph)
            {
                graph.Document.Redo();
            }
            else
            {
                shell.Scene?.Redo();
            }
        })
        {
            Description = "Apply the last undone edit of the active scene again.",
            Icon = "redo",
            Shortcut = "Ctrl+Y",
            CanExecuteWhen = () => shell.ActiveGraphEditor is { } graph ? graph.Document.CanRedo : shell.IsEditing && shell.Scene?.CanRedo == true,
        });
        // A command for each kind of entity of the catalog (see docs/editor/shell-and-panels.md#add), which the Add
        // menus and the command palette show.
        foreach (var template in EntityCatalog.All)
        {
            commands.Register(new Command(AddEntity(template.Id), template.Label, () => shell.AddEntity(template))
            {
                Description = $"{template.Description} It goes where the selected entity is, or else where the view looks.",
                Icon = template.Icon,
                Shortcut = template.Id == EntityCatalog.EmptyId ? "Ctrl+Shift+N" : null,
                CanExecuteWhen = () => shell.CanEditScene,
            });
        }
        commands.Register(new Command(DuplicateEntity, "Duplicate", shell.DuplicateSelected)
        {
            Description = "Copy the selected entities and their children.",
            Icon = "copy",
            Shortcut = "Ctrl+D",
            CanExecuteWhen = () => shell.SelectedSceneEntities.Count > 0,
        });
        commands.Register(new Command(MakePrefab, "Make Prefab", shell.RequestMakePrefab)
        {
            Description = "Make a prefab of the selected entity and its children in the content browser's folder, and put an instance of it in their place.",
            Icon = "prefab",
            Shortcut = "Ctrl+Shift+M",
            CanExecuteWhen = () => shell.SelectedSceneEntity is { } e && shell.InstanceOf(e.Id) == null,
        });
        commands.Register(new Command(UnpackPrefab, "Unpack", () => shell.UnpackSelected(completely: false))
        {
            Description = "Make the selected instances' entities the scene's own, keeping the prefabs inside them as instances.",
            Icon = "prefab",
            CanExecuteWhen = () => shell.SelectedSceneEntities.Any(e => shell.InstanceOf(e.Id) is { IsInstanceRoot: true }),
        });
        commands.Register(new Command(UnpackPrefabCompletely, "Unpack Completely", () => shell.UnpackSelected(completely: true))
        {
            Description = "Make the selected instances' entities the scene's own, through every prefab inside them.",
            Icon = "prefab",
            CanExecuteWhen = () => shell.SelectedSceneEntities.Any(e => shell.InstanceOf(e.Id) is { IsInstanceRoot: true }),
        });
        commands.Register(new Command(OpenPrefab, "Open Prefab", shell.OpenSelectedPrefab)
        {
            Description = "Open the selected instance's prefab in the scene's place, to edit it as a scene.",
            Icon = "prefab",
            CanExecuteWhen = () => shell.SelectedPrefab != null,
        });
        commands.Register(new Command(ApplyAllPrefab, "Apply All", () => shell.ApplyAllSelected())
        {
            Description = "Apply every override of the selected instances to their prefabs, so every instance has them.",
            Icon = "prefab",
            CanExecuteWhen = () => shell.SelectedSceneEntities.Any(e => shell.InstanceOf(e.Id) != null),
        });
        commands.Register(new Command(RevertAllPrefab, "Revert All", () => shell.RevertAllSelected())
        {
            Description = "Drop every override of the selected instances, and the entities added to them, so they are their prefabs again.",
            Icon = "prefab",
            CanExecuteWhen = () => shell.SelectedSceneEntities.Any(e => shell.InstanceOf(e.Id) != null),
        });
        commands.Register(new Command(MakeVariant, "Make Variant", shell.RequestMakeVariant)
        {
            Description = "Make a new prefab of the selected instance with its overrides, which varies its prefab, and make the instance one of it.",
            Icon = "prefab",
            CanExecuteWhen = () => shell.SelectedSceneEntities.Select(e => shell.InstanceOf(e.Id)?.Instance).OfType<ulong>().Distinct().Count() == 1,
        });
        commands.Register(new Command(SelectPrefabAsset, "Select Prefab Asset", shell.SelectPrefabAsset)
        {
            Description = "Show the prefab of the selected entity's instance in the content browser.",
            Icon = "prefab",
            CanExecuteWhen = () => shell.SelectedSceneEntity is { } e && shell.InstanceOf(e.Id) != null,
        });
        commands.Register(new Command(DeleteEntity, "Delete", shell.DeleteSelected)
        {
            Description = "Delete the selected entities and their children, or in mesh mode the selected vertices, edges or faces.",
            Icon = "delete",
            Shortcut = "Delete",
            CanExecuteWhen = () => shell.Mesh.InMeshMode ? !shell.Mesh.MeshSelection.IsEmpty : shell.SelectedSceneEntities.Count > 0,
        });
    }

    // Selection, visibility, the viewport's tools and the camera (see docs/editor/viewport.md#viewport). The tools have keys of their own, which work while the viewport has focus.
    static void RegisterSceneView(EditorShell shell)
    {
        var commands = shell.Commands;
        commands.Register(new Command(SelectAll, "Select All", () =>
        {
            if (shell.Mesh.InMeshMode)
            {
                shell.Mesh.SelectAllMeshElements();
            }
            else
            {
                shell.Selection.Set(shell.World.Entities.Select(e => e.Handle));
            }
        })
        {
            Description = "Select every entity, or in mesh mode every vertex, edge or face of the edited meshes.",
            Shortcut = "Ctrl+A",
            CanExecuteWhen = () => shell.World.HasWorld,
        });
        commands.Register(new Command(HideSelected, "Hide", shell.ToggleHideSelected)
        {
            Description = "Hide the selected entities and their children in the viewport, or show them again. The scene does not change. H in the viewport.",
            Icon = "hidden",
            CanExecuteWhen = () => shell.HasSceneSelection,
        });
        commands.Register(new Command(ShowAll, "Show All", shell.ShowAll)
        {
            Description = "Show every hidden entity in the viewport.",
            Icon = "visible",
            CanExecuteWhen = () => shell.HasHidden,
        });
        commands.Register(new Command(LockSelected, "Lock", shell.ToggleLockSelected)
        {
            Description = "Stop the viewport from selecting the selected entities and their children, or let it again.",
            Icon = "locked",
            CanExecuteWhen = () => shell.HasSceneSelection,
        });
        // The viewport's tools have keys of their own, which work while the viewport has focus, so typing in a box
        // does not change tools.
        ToolCommand(shell, SelectTool, Tool.Select, "Select", "select", "Click or drag a box in the viewport to select. Q in the viewport.");
        ToolCommand(shell, MoveTool, Tool.Move, "Move", "move", "Move the selection along an axis or a plane. W in the viewport.");
        ToolCommand(shell, RotateTool, Tool.Rotate, "Rotate", "rotate", "Turn the selection about an axis. E in the viewport.");
        ToolCommand(shell, ScaleTool, Tool.Scale, "Scale", "scale-tool", "Scale the selection along its own axes. R in the viewport.");
        commands.Register(new Command(NavPathTool, "Navigation Path", () => shell.SetTool(Tool.NavPath))
        {
            Description = "Click two points in the viewport to draw the path between them on each agent type's navmesh. N in the viewport.",
            Icon = "nav-path",
            IsCheckedWhen = () => shell.Tool == Tool.NavPath,
            CanExecuteWhen = () => !shell.Mesh.InMeshMode,
        });
        commands.Register(new Command(LandscapeTool, "Landscape", () => shell.SetTool(Tool.Landscape))
        {
            Description = "Sculpt the selected terrain's height map and paint its holes with a brush, in the viewport. L in the viewport.",
            Icon = "landscape",
            IsCheckedWhen = () => shell.Tool == Tool.Landscape,
            CanExecuteWhen = () => !shell.Mesh.InMeshMode,
        });
        commands.Register(ChoiceCommand.ForEnum(LandscapeBrush, "Brush", () => shell.Landscape.Brush, shell.Landscape.SetBrush,
            description: "What a stroke does: raise, lower, smooth, flatten, ramp or add noise to the height map, paint holes into the hole mask or fill them, paint a layer into the layer map, or scatter or erase foliage.",
            canExecuteWhen: () => shell.Tool == Tool.Landscape));
        commands.Register(new ChoiceCommand(LandscapeRadius, "Radius", [.. LandscapeSession.Radii.Select(Meters)], () => Meters(NearestOf(LandscapeSession.Radii, shell.Landscape.Radius)), v => shell.Landscape.SetRadius(LandscapeSession.Radii.First(r => Meters(r) == v)))
        {
            Description = "The brush's radius on the terrain.",
            CanExecuteWhen = () => shell.Tool == Tool.Landscape,
        });
        commands.Register(new ChoiceCommand(LandscapeStrength, "Strength", [.. LandscapeSession.Shares.Select(Percent)], () => Percent(NearestOf(LandscapeSession.Shares, shell.Landscape.Strength)), v => shell.Landscape.SetStrength(LandscapeSession.Shares.First(s => Percent(s) == v)))
        {
            Description = "How much each dab of the brush changes the terrain.",
            CanExecuteWhen = () => shell.Tool == Tool.Landscape,
        });
        commands.Register(new ChoiceCommand(LandscapeFalloff, "Falloff", [.. LandscapeSession.Shares.Select(Percent)], () => Percent(NearestOf(LandscapeSession.Shares, shell.Landscape.Falloff)), v => shell.Landscape.SetFalloff(LandscapeSession.Shares.First(s => Percent(s) == v)))
        {
            Description = "How much of the brush's radius, from its edge in, softens to nothing.",
            CanExecuteWhen = () => shell.Tool == Tool.Landscape,
        });
        string LayerName(int layer) => $"Layer {layer + 1}";
        commands.Register(new ChoiceCommand(LandscapeLayer, "Layer", [.. Enumerable.Range(0, LandscapeSession.Layers).Select(LayerName)], () => LayerName(shell.Landscape.Layer), v => shell.Landscape.SetLayer(int.Parse(v["Layer ".Length..], System.Globalization.CultureInfo.InvariantCulture) - 1))
        {
            Description = "The layer that the Paint brush paints: the red, green, blue or alpha of the terrain's layer map, which its material blends.",
            CanExecuteWhen = () => shell.Tool == Tool.Landscape,
        });
        static string PerHundred(double d) => string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{d:0.##} / 100 m²");
        commands.Register(new ChoiceCommand(LandscapeDensity, "Density", [.. LandscapeSession.Densities.Select(PerHundred)], () => PerHundred(NearestOf(LandscapeSession.Densities, shell.Landscape.Density)), v => shell.Landscape.SetDensity(LandscapeSession.Densities.First(d => PerHundred(d) == v)))
        {
            Description = "How many instances the Scatter brush puts on 100 square meters of the terrain.",
            CanExecuteWhen = () => shell.Tool == Tool.Landscape,
        });
        commands.Register(new Command(LocalSpace, "Local Axes", shell.ToggleSpace)
        {
            Description = "Move and turn along the entity's axes, not the world's. X in the viewport.",
            Icon = "local",
            IsCheckedWhen = () => shell.Space == Space.Local,
        });
        commands.Register(new Command(Snap, "Snap", shell.ToggleSnap)
        {
            Description = "Round gizmo drags to steps: 0.25 m, 15° and 0.1 of scale. Ctrl during a drag does the opposite.",
            Icon = "snap",
            IsCheckedWhen = () => shell.Snap,
        });
        commands.Register(new Command(FrameSelected, "Frame Selected", shell.FrameSelected)
        {
            Description = "Move the camera to the selected entities. F in the viewport.",
            Icon = "frame",
            CanExecuteWhen = () => shell.HasSceneSelection,
        });
        commands.Register(new Command(OrbitSelection, "Orbit Selection", shell.ToggleOrbitSelection)
        {
            Description = "Alt and the left button orbit about the selected entities' middle, not the point ahead of the camera.",
            Icon = "rotate",
            IsCheckedWhen = () => shell.OrbitSelection,
        });
        commands.Register(new Command(FrameScene, "Frame Scene", shell.FrameScene)
        {
            Description = "Move the camera so the whole scene is in view.",
            Icon = "viewport",
            CanExecuteWhen = () => shell.Scene != null,
        });
    }

    static void ToolCommand(EditorShell shell, string id, Tool tool, string label, string icon, string description) =>
        shell.Commands.Register(new Command(id, label, () => shell.SetTool(tool))
        {
            Description = description,
            Icon = icon,
            IsCheckedWhen = () => shell.Tool == tool,
        });
}
