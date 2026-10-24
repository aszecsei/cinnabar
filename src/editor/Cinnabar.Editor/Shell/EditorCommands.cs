using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Host;
using Cinnabar.Editor.Tools;
using Cinnabar.Editor.Viewport;

namespace Cinnabar.Editor.Shell;

/// <summary>The editor's own commands. Their IDs are what ribbon layouts and key bindings refer to.</summary>
static class EditorCommands
{
    public const string Palette = "app.commandPalette";
    public const string OpenScene = "file.openScene";
    public const string Save = "file.save";
    public const string SaveAs = "file.saveAs";
    public const string Undo = "edit.undo";
    public const string Redo = "edit.redo";
    public const string CreateEntity = "entity.create";
    public const string DuplicateEntity = "entity.duplicate";
    public const string DeleteEntity = "entity.delete";
    public const string RestartHost = "host.restart";
    public const string StopHost = "host.stop";
    public const string ResetLayout = "view.resetLayout";
    public const string Stats = "view.stats";
    public const string CollapseRibbon = "view.collapseRibbon";
    public const string ViewportScale = "viewport.scale";
    public const string SelectAll = "edit.selectAll";
    public const string PlayMode = "mode.play";
    public const string PauseMode = "mode.pause";
    public const string StepFrame = "mode.step";
    public const string StopMode = "mode.stop";
    public const string FreeCamera = "viewport.freeCamera";
    public const string HideSelected = "entity.hide";
    public const string ShowAll = "entity.showAll";
    public const string LockSelected = "entity.lock";
    public const string SelectTool = "tool.select";
    public const string MoveTool = "tool.move";
    public const string RotateTool = "tool.rotate";
    public const string ScaleTool = "tool.scale";
    public const string LocalSpace = "tool.localSpace";
    public const string Snap = "tool.snap";
    public const string FrameSelected = "viewport.frameSelected";
    public const string FrameScene = "viewport.frameScene";
    public const string OrbitSelection = "viewport.orbitSelection";

    /// <summary>The command that shows or hides a panel.</summary>
    public static string Panel(string panelId) => $"view.panel.{panelId}";

    public static void Register(EditorShell shell)
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
        commands.Register(new Command(Save, "Save", () => shell.SaveScene())
        {
            Description = "Write the scene to its file.",
            Icon = "save",
            Shortcut = "Ctrl+S",
            CanExecuteWhen = () => shell.Scene != null,
        });
        commands.Register(new Command(SaveAs, "Save As", shell.RequestSaveAs)
        {
            Description = "Write the scene to a new file, which it then edits.",
            Icon = "save-as",
            Shortcut = "Ctrl+Shift+S",
            CanExecuteWhen = () => shell.Scene != null,
        });
        commands.Register(new Command(Undo, "Undo", () => shell.Scene?.Undo())
        {
            Description = "Undo the last edit.",
            Icon = "undo",
            Shortcut = "Ctrl+Z",
            CanExecuteWhen = () => shell.IsEditing && shell.Scene?.CanUndo == true,
        });
        commands.Register(new Command(Redo, "Redo", () => shell.Scene?.Redo())
        {
            Description = "Apply the last undone edit again.",
            Icon = "redo",
            Shortcut = "Ctrl+Y",
            CanExecuteWhen = () => shell.IsEditing && shell.Scene?.CanRedo == true,
        });
        commands.Register(new Command(CreateEntity, "New Entity", shell.CreateEntity)
        {
            Description = "Add an entity with a Transform, where the selected entity is.",
            Icon = "add",
            Shortcut = "Ctrl+Shift+N",
            CanExecuteWhen = () => shell.Scene != null && shell.IsEditing,
        });
        commands.Register(new Command(DuplicateEntity, "Duplicate", shell.DuplicateSelected)
        {
            Description = "Copy the selected entities and their children.",
            Icon = "copy",
            Shortcut = "Ctrl+D",
            CanExecuteWhen = () => shell.SelectedSceneEntities.Count > 0,
        });
        commands.Register(new Command(DeleteEntity, "Delete", shell.DeleteSelected)
        {
            Description = "Delete the selected entities and their children.",
            Icon = "delete",
            Shortcut = "Delete",
            CanExecuteWhen = () => shell.SelectedSceneEntities.Count > 0,
        });
        commands.Register(new Command(PlayMode, "Play", shell.Play)
        {
            Description = "Run the game's world from the scene, or go on after a pause. Edits wait until Stop.",
            Icon = "play",
            Shortcut = "F5",
            CanExecuteWhen = () => shell.Host.Linked && shell.Mode != Link.Protocol.EditorMode.Play,
            IsCheckedWhen = () => shell.Mode == Link.Protocol.EditorMode.Play,
        });
        commands.Register(new Command(PauseMode, "Pause", shell.TogglePause)
        {
            Description = "Stop the world where it is, or let it go on.",
            Icon = "pause",
            Shortcut = "F6",
            CanExecuteWhen = () => !shell.IsEditing,
            IsCheckedWhen = () => shell.Mode == Link.Protocol.EditorMode.Paused,
        });
        commands.Register(new Command(StepFrame, "Step", shell.Step)
        {
            Description = "While paused, run one frame of one fixed tick.",
            Icon = "step",
            Shortcut = "F10",
            CanExecuteWhen = () => shell.Mode == Link.Protocol.EditorMode.Paused,
        });
        commands.Register(new Command(StopMode, "Stop", shell.Stop)
        {
            Description = "End play. The game gets the scene again, and nothing of play stays.",
            Icon = "stop",
            Shortcut = "Shift+F5",
            CanExecuteWhen = () => !shell.IsEditing,
        });
        commands.Register(new Command(FreeCamera, "Free Camera", shell.ToggleFreeCamera)
        {
            Description = "While the game plays, fly the editor's camera in the viewport and draw from it, instead of giving the game its input.",
            Icon = "free-camera",
            IsCheckedWhen = () => shell.FreeCamera,
        });
        commands.Register(new Command(SelectAll, "Select All", () => shell.Selection.Set(shell.World.Entities.Select(e => e.Handle)))
        {
            Description = "Select every entity.",
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
        void ToolCommand(string id, Tool tool, string label, string icon, string description) =>
            commands.Register(new Command(id, label, () => shell.SetTool(tool))
            {
                Description = description,
                Icon = icon,
                IsCheckedWhen = () => shell.Tool == tool,
            });
        ToolCommand(SelectTool, Tool.Select, "Select", "select", "Click or drag a box in the viewport to select. Q in the viewport.");
        ToolCommand(MoveTool, Tool.Move, "Move", "move", "Move the selection along an axis or a plane. W in the viewport.");
        ToolCommand(RotateTool, Tool.Rotate, "Rotate", "rotate", "Turn the selection about an axis. E in the viewport.");
        ToolCommand(ScaleTool, Tool.Scale, "Scale", "scale-tool", "Scale the selection along its own axes. R in the viewport.");
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
        commands.Register(new Command(RestartHost, "Restart Host", shell.Host.Restart)
        {
            Description = "Stop the host if it runs, and start it again with the game.",
            Icon = "restart",
            Shortcut = "Ctrl+Shift+F5",
            CanExecuteWhen = () => shell.Host.CanStart,
        });
        commands.Register(new Command(StopHost, "Stop Host", shell.Host.Stop)
        {
            Description = "Stop the host. The viewport goes blank until it starts again.",
            Icon = "stop",
            CanExecuteWhen = () => shell.Host.State == HostState.Running,
        });
        foreach (var panel in shell.Layout.Panels)
        {
            commands.Register(new Command(Panel(panel.Id), panel.Title, () => shell.Layout.Toggle(panel.Id))
            {
                Description = $"Show or hide the {panel.Title.ToLowerInvariant()} panel.",
                Icon = panel.Icon,
                IsCheckedWhen = () => shell.Layout.IsOpen(panel.Id),
            });
        }
        commands.Register(new Command(ResetLayout, "Reset Layout", shell.Layout.Reset)
        {
            Description = "Put every panel back where it starts.",
            Icon = "reset",
        });
        commands.Register(new Command(Stats, "Viewport Stats", () => shell.Viewport.ShowStats = !shell.Viewport.ShowStats)
        {
            Description = "Show the frame rates and the adapter over the viewport.",
            Icon = "stats",
            IsCheckedWhen = () => shell.Viewport.ShowStats,
        });
        commands.Register(new Command(CollapseRibbon, "Collapse Ribbon", () => shell.RibbonCollapsed = !shell.RibbonCollapsed)
        {
            Description = "Show only the ribbon's tabs. Double-clicking a tab does the same.",
            Icon = "collapse",
            Shortcut = "Ctrl+F1",
            IsCheckedWhen = () => shell.RibbonCollapsed,
        });
        commands.Register(new ChoiceCommand(ViewportScale, "Scale", ["Fit", "100%"],
            () => shell.Viewport.Scale == Viewport.ViewportScale.Fit ? "Fit" : "100%",
            option => shell.Viewport.Scale = option == "Fit" ? Viewport.ViewportScale.Fit : Viewport.ViewportScale.Actual)
        {
            Description = "Fit the frame to the viewport, or show one frame pixel per screen pixel.",
            Icon = "scale",
        });
    }
}
