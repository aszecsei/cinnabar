using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Host;
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
            CanExecuteWhen = () => shell.Scene?.CanUndo == true,
        });
        commands.Register(new Command(Redo, "Redo", () => shell.Scene?.Redo())
        {
            Description = "Apply the last undone edit again.",
            Icon = "redo",
            Shortcut = "Ctrl+Y",
            CanExecuteWhen = () => shell.Scene?.CanRedo == true,
        });
        commands.Register(new Command(CreateEntity, "New Entity", shell.CreateEntity)
        {
            Description = "Add an entity with a Transform, where the selected entity is.",
            Icon = "add",
            Shortcut = "Ctrl+Shift+N",
            CanExecuteWhen = () => shell.Scene != null,
        });
        commands.Register(new Command(DuplicateEntity, "Duplicate", shell.DuplicateSelected)
        {
            Description = "Copy the selected entity and its children.",
            Icon = "copy",
            Shortcut = "Ctrl+D",
            CanExecuteWhen = () => shell.SelectedSceneEntity != null,
        });
        commands.Register(new Command(DeleteEntity, "Delete", shell.DeleteSelected)
        {
            Description = "Delete the selected entity and its children.",
            Icon = "delete",
            Shortcut = "Delete",
            CanExecuteWhen = () => shell.SelectedSceneEntity != null,
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
            Shortcut = "Shift+F5",
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
