using Cinnabar.Editor.Commands;
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
            Description = "Open a scene file. The host's world becomes the scene.",
            Icon = "assets",
            Shortcut = "Ctrl+O",
        });
        // Save, Undo and Redo act on the material editor whose document is active, and on the scene otherwise.
        commands.Register(new Command(Save, "Save", () => _ = shell.ActiveMaterial is { } material ? shell.SaveMaterial(material) : shell.SaveScene())
        {
            Description = "Write the scene, or the material that the material editor shows, to its file.",
            Icon = "save",
            Shortcut = "Ctrl+S",
            CanExecuteWhen = () => shell.ActiveMaterial != null || shell.Scene != null,
        });
        commands.Register(new Command(SaveAs, "Save As", shell.RequestSaveAs)
        {
            Description = "Write the scene to a new file, which it then edits.",
            Icon = "save-as",
            Shortcut = "Ctrl+Shift+S",
            CanExecuteWhen = () => shell.Scene != null,
        });
        commands.Register(new Command(Undo, "Undo", () =>
        {
            if (shell.ActiveMaterial is { } material)
            {
                material.Document.Undo();
            }
            else
            {
                shell.Scene?.Undo();
            }
        })
        {
            Description = "Undo the last edit.",
            Icon = "undo",
            Shortcut = "Ctrl+Z",
            CanExecuteWhen = () => shell.ActiveMaterial is { } material ? material.Document.CanUndo : shell.IsEditing && shell.Scene?.CanUndo == true,
        });
        commands.Register(new Command(Redo, "Redo", () =>
        {
            if (shell.ActiveMaterial is { } material)
            {
                material.Document.Redo();
            }
            else
            {
                shell.Scene?.Redo();
            }
        })
        {
            Description = "Apply the last undone edit again.",
            Icon = "redo",
            Shortcut = "Ctrl+Y",
            CanExecuteWhen = () => shell.ActiveMaterial is { } material ? material.Document.CanRedo : shell.IsEditing && shell.Scene?.CanRedo == true,
        });
        commands.Register(new Command(CreateEntity, "New Entity", shell.CreateEntity)
        {
            Description = "Add an entity with a Transform, where the selected entity is.",
            Icon = "add",
            Shortcut = "Ctrl+Shift+N",
            CanExecuteWhen = () => shell.CanEditScene,
        });
        commands.Register(new Command(CreateVolume, "New Volume", shell.CreateVolume)
        {
            Description = "Add a global volume, where the selected entity is, for settings such as the post-processing and the fog. Add its settings components in the properties panel.",
            Icon = "add",
            CanExecuteWhen = () => shell.CanEditScene,
        });
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
            CanExecuteWhen = () => shell.SelectedSceneEntities.Count > 0,
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
            CanExecuteWhen = () => shell.SelectedSceneEntities.Count > 0,
        });
        // The viewport's tools have keys of their own, which work while the viewport has focus, so typing in a box
        // does not change tools.
        ToolCommand(shell, SelectTool, Tool.Select, "Select", "select", "Click or drag a box in the viewport to select. Q in the viewport.");
        ToolCommand(shell, MoveTool, Tool.Move, "Move", "move", "Move the selection along an axis or a plane. W in the viewport.");
        ToolCommand(shell, RotateTool, Tool.Rotate, "Rotate", "rotate", "Turn the selection about an axis. E in the viewport.");
        ToolCommand(shell, ScaleTool, Tool.Scale, "Scale", "scale-tool", "Scale the selection along its own axes. R in the viewport.");
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
            CanExecuteWhen = () => shell.SelectedSceneEntities.Count > 0,
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
