using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Host;
using Cinnabar.Editor.Mesh;
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
    public const string CreateVolume = "entity.createVolume";
    public const string DuplicateEntity = "entity.duplicate";
    public const string DeleteEntity = "entity.delete";
    public const string RestartHost = "host.restart";
    public const string StopHost = "host.stop";
    public const string RestartCook = "cook.restart";
    public const string NewScript = "content.newScript";
    public const string NewBehaviour = "content.newBehaviour";
    public const string NewSceneAsset = "content.newScene";
    public const string NewMaterial = "content.newMaterial";
    public const string NewMaterialFunction = "content.newMaterialFunction";
    public const string NewMesh = "content.newMesh";
    public const string EditMesh = "mesh.edit";
    public const string ObjectMode = "mesh.objectMode";
    public const string MeshVertices = "mesh.vertices";
    public const string MeshEdges = "mesh.edges";
    public const string MeshFaces = "mesh.faces";
    public const string MeshBlock = "mesh.block";
    public const string MeshGridToggle = "mesh.grid";
    public const string MeshGridFiner = "mesh.gridFiner";
    public const string MeshGridCoarser = "mesh.gridCoarser";
    public const string MeshSelectThrough = "mesh.selectThrough";
    public const string NewFolder = "content.newFolder";
    public const string RenameAsset = "content.rename";
    public const string DuplicateAsset = "content.duplicate";
    public const string DeleteAsset = "content.delete";
    public const string Reimport = "content.reimport";
    public const string ResetLayout = "view.resetLayout";
    public const string Stats = "view.stats";
    public const string CaptureFrame = "profile.captureFrame";
    public const string CaptureWorstFrame = "profile.captureWorst";
    public const string RecordZones = "profile.record";
    public const string Screenshot = "capture.screenshot";
    public const string CaptureGif = "capture.gif";
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
    public const string DebugView = "view.debugView";
    public const string TemporalAa = "view.temporalAa";
    public const string Bloom = "view.bloom";
    public const string ToneMapping = "view.toneMapping";
    public const string Fog = "view.fog";
    public const string AmbientOcclusion = "view.ambientOcclusion";
    public const string GlobalIllumination = "view.globalIllumination";
    public const string Shadows = "view.shadows";
    public const string PostEffects = "view.postEffects";
    public const string Icons = "view.icons";
    public const string Helpers = "view.helpers";
    public const string ExposureUp = "view.exposureUp";
    public const string ExposureDown = "view.exposureDown";
    public const string ExposureReset = "view.exposureReset";
    public const string ViewportQuality = "view.quality";
    public const string ViewportAntiAliasing = "view.antiAliasing";
    public const string ViewportRenderScale = "view.renderScale";
    public const string RunGame = "game.run";
    public const string StopGame = "game.stop";
    public const string ProjectOutput = "project.output";
    public const string UserOutput = "project.userOutput";
    public const string ProjectQuality = "project.quality";
    public const string UserQuality = "project.userQuality";

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
            CanExecuteWhen = () => shell.Scene != null && shell.IsEditing,
        });
        commands.Register(new Command(CreateVolume, "New Volume", shell.CreateVolume)
        {
            Description = "Add a global volume, where the selected entity is, for settings such as the post-processing and the fog. Add its settings components in the properties panel.",
            Icon = "add",
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
            Description = "Delete the selected entities and their children, or in mesh mode the selected vertices, edges or faces.",
            Icon = "delete",
            Shortcut = "Delete",
            CanExecuteWhen = () => shell.InMeshMode ? !shell.MeshSelection.IsEmpty : shell.SelectedSceneEntities.Count > 0,
        });
        // Mesh mode (see docs/editor/mesh-editing.md#mesh-mode). Its keys, Tab, 1, 2, 3, [ and ], are the viewport's, as the
        // tools' are.
        commands.Register(new Command(EditMesh, "Edit Mesh", shell.ToggleMeshMode)
        {
            Description = "Edit the selected entities' mesh files: select their vertices, edges and faces and move them. Tab in the viewport enters and leaves.",
            Icon = "mesh",
            CanExecuteWhen = () => shell.CanEditMesh,
            IsCheckedWhen = () => shell.InMeshMode,
        });
        commands.Register(new Command(ObjectMode, "Object Mode", shell.LeaveMeshMode)
        {
            Description = "Leave mesh mode and select entities again. The meshes stay live until they are saved and cooked.",
            Icon = "select",
            CanExecuteWhen = () => shell.InMeshMode,
        });
        void ElementCommand(string id, MeshElement kind, string label, string icon, string description) =>
            commands.Register(new Command(id, label, () => shell.SetMeshElement(kind))
            {
                Description = description,
                Icon = icon,
                CanExecuteWhen = () => shell.InMeshMode,
                IsCheckedWhen = () => shell.InMeshMode && shell.MeshElement == kind,
            });
        ElementCommand(MeshVertices, MeshElement.Vertices, "Vertices", "select", "Select and move vertices. 1 in the viewport.");
        ElementCommand(MeshEdges, MeshElement.Edges, "Edges", "local", "Select and move edges. 2 in the viewport.");
        ElementCommand(MeshFaces, MeshElement.Faces, "Faces", "mesh", "Select and move faces. 3 in the viewport.");
        commands.Register(new Command(MeshBlock, "Block", () => shell.SetMeshTool(shell.MeshTool == MeshTool.Block ? MeshTool.Select : MeshTool.Block))
        {
            Description = "Drag a rectangle on the grid to add a box a grid cell high: a new mesh file and entity, or faces of the edited mesh in mesh mode. Ctrl at the release makes a new entity anyway.",
            Icon = "add",
            CanExecuteWhen = () => shell.IsEditing && shell.Scene != null,
            IsCheckedWhen = () => shell.MeshTool == MeshTool.Block,
        });
        commands.Register(new Command(MeshGridToggle, "Show Grid", shell.ToggleShowGrid)
        {
            Description = "Draw the grid that mesh mode snaps to, on the plane through the selection facing the camera.",
            Icon = "snap",
            IsCheckedWhen = () => shell.ShowGrid,
        });
        commands.Register(new Command(MeshGridFiner, "Finer Grid", shell.FinerGrid)
        {
            Description = "Halve the grid's size, down to 1/64 m. [ in the viewport.",
            Icon = "chevron-down",
            CanExecuteWhen = () => shell.GridSize > MeshGrid.MinSize,
        });
        commands.Register(new Command(MeshGridCoarser, "Coarser Grid", shell.CoarserGrid)
        {
            Description = "Double the grid's size, up to 16 m. ] in the viewport.",
            Icon = "collapse",
            CanExecuteWhen = () => shell.GridSize < MeshGrid.MaxSize,
        });
        commands.Register(new Command(MeshSelectThrough, "Select Through", shell.ToggleSelectThrough)
        {
            Description = "Let a box and a click in mesh mode take faces that face away, and their vertices and edges.",
            Icon = "visible",
            IsCheckedWhen = () => shell.SelectThrough,
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
        commands.Register(new Command(SelectAll, "Select All", () =>
        {
            if (shell.InMeshMode)
            {
                shell.SelectAllMeshElements();
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
        commands.Register(new Command(RestartCook, "Restart Cook Daemon", shell.StartCook)
        {
            Description = "Stop the cook daemon if it runs, and start it again. It cooks the content roots when they change.",
            Icon = "restart",
        });
        // The asset commands act on the content browser's folder and selection. Their keys, F2, Ctrl+D and Delete, work
        // while the content browser has focus, as the same keys act on entities elsewhere.
        void NewAssetCommand(string id, Link.Cook.AssetTemplate? template, string label, string icon, string description) =>
            commands.Register(new Command(id, label, () => shell.RequestNewAsset(template))
            {
                Description = description,
                Icon = icon,
                CanExecuteWhen = () => shell.CanChangeContent && shell.ContentFolder != null,
            });
        NewAssetCommand(NewScript, Link.Cook.AssetTemplate.Script, "New Script", "script", "Add a Luau module to the content browser's folder.");
        NewAssetCommand(NewBehaviour, Link.Cook.AssetTemplate.Behaviour, "New Behaviour", "script", "Add a script that defines a behaviour, named for its file, to the content browser's folder.");
        NewAssetCommand(NewSceneAsset, Link.Cook.AssetTemplate.Scene, "New Scene", "scene", "Add an empty scene to the content browser's folder.");
        NewAssetCommand(NewMaterial, Link.Cook.AssetTemplate.Material, "New Material", "material", "Add a material graph, lit, to the content browser's folder.");
        NewAssetCommand(NewMaterialFunction, Link.Cook.AssetTemplate.MaterialFunction, "New Material Function", "material-function", "Add a material function, a graph that materials call as a node, to the content browser's folder.");
        NewAssetCommand(NewMesh, Link.Cook.AssetTemplate.Mesh, "New Mesh", "mesh", "Add a mesh file, a 1 m box to build level geometry from, to the content browser's folder.");
        NewAssetCommand(NewFolder, null, "New Folder", "folder", "Add a folder to the content browser's folder.");
        commands.Register(new Command(RenameAsset, "Rename Asset", shell.RequestRenameSelected)
        {
            Description = "Rename the asset selected in the content browser, with its .meta file. F2 in the content browser.",
            CanExecuteWhen = () => shell.CanChangeContent && shell.SelectedAssets.Count == 1 && !shell.SelectionHasSubassets,
        });
        commands.Register(new Command(DuplicateAsset, "Duplicate Asset", () => _ = shell.DuplicateSelectedAssets())
        {
            Description = "Copy the assets selected in the content browser, each with a new GUID. Ctrl+D in the content browser.",
            Icon = "copy",
            CanExecuteWhen = () => shell.CanChangeContent && shell.SelectedAssets.Count > 0 && !shell.SelectionHasSubassets,
        });
        commands.Register(new Command(DeleteAsset, "Delete Asset", shell.RequestDeleteSelected)
        {
            Description = "Send the assets selected in the content browser to the Recycle Bin, after showing what uses them. Delete in the content browser.",
            Icon = "delete",
            CanExecuteWhen = () => shell.CanChangeContent && shell.SelectedAssets.Count > 0 && !shell.SelectionHasSubassets,
        });
        commands.Register(new Command(Reimport, "Re-import", () => _ = shell.ReimportSelectedAssets())
        {
            Description = "Cook the assets selected in the content browser again, also when they are up to date.",
            Icon = "restart",
            CanExecuteWhen = () => shell.CanChangeContent && shell.SelectedAssets.Count > 0 && !shell.SelectionHasSubassets,
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
        RegisterRendering(shell);
        RegisterProfiler(shell);
        RegisterCapture(shell);
        RegisterGameWindow(shell);
    }

    // The game in its own window, and the project's output mode, which shows only there (see
    // docs/overview/architecture.md#project-settings).
    static void RegisterGameWindow(EditorShell shell)
    {
        var commands = shell.Commands;
        commands.Register(new Command(RunGame, "Run Game", shell.RunGame)
        {
            Description = "Open the game in its own window, with the scene that it loads itself, as just dev does. It shows the output mode, such as HDR, which the viewport cannot.",
            Icon = "play",
            Shortcut = "Ctrl+F5",
        });
        commands.Register(new Command(StopGame, "Close Game", shell.StopGame)
        {
            Description = "Close the game's own window.",
            Icon = "stop",
            CanExecuteWhen = () => shell.GameWindowRunning,
        });
        string[] modes = [.. EditorShell.OutputModes.Select(m => m.Label)];
        commands.Register(new ChoiceCommand(ProjectOutput, "Output", modes, () => shell.ProjectOutput, option => shell.ProjectOutput = option)
        {
            Description = "The project's output mode for the game's window, in its settings file: Auto is HDR10 on a display in HDR and SDR otherwise. A running game takes it at once.",
            Icon = "viewport",
        });
        commands.Register(new ChoiceCommand(UserOutput, "On This PC", [EditorShell.ProjectOutputLabel, .. modes], () => shell.UserOutput, option => shell.UserOutput = option)
        {
            Description = "The output mode on this machine, which replaces the project's, for a display that HDR does not suit. It is in the project's user settings file, which is not committed.",
            Icon = "viewport",
        });
        commands.Register(new ChoiceCommand(ProjectQuality, "Quality",
            [EditorShell.HardwareQualityLabel, .. EditorShell.QualityPresets, EditorShell.CustomQualityLabel], () => shell.ProjectQuality, option => shell.ProjectQuality = option)
        {
            Description = "The project's render quality for the game: a preset, or By Hardware, which picks one by the video memory. Custom is a file's features one by one, which the preset replaces. A running game takes it at once.",
            Icon = "viewport",
        });
        commands.Register(new ChoiceCommand(UserQuality, "Quality On This PC",
            [EditorShell.ProjectOutputLabel, .. EditorShell.QualityPresets, EditorShell.CustomQualityLabel], () => shell.UserQuality, option => shell.UserQuality = option)
        {
            Description = "The render quality on this machine, which replaces the project's. A game's settings menu saves it here, as Custom when it changed single features.",
            Icon = "viewport",
        });
    }

    // The profiler (see docs/editor/shell-and-panels.md#profiler): captures of a frame, and whether the host records zones.
    static void RegisterProfiler(EditorShell shell)
    {
        var commands = shell.Commands;
        commands.Register(new Command(CaptureFrame, "Capture Frame", shell.CaptureNextFrame)
        {
            Description = "Capture the next frame in the profiler: where each thread and the GPU spent its time.",
            Icon = "monitor",
            Shortcut = "Ctrl+Alt+P",
            CanExecuteWhen = () => shell.Host.Linked,
        });
        commands.Register(new Command(CaptureWorstFrame, "Capture Worst Frame", () => shell.CaptureWorstFrame())
        {
            Description = $"Capture the longest of the last {EditorShell.WorstOfFrames} frames in the profiler, to find a stutter.",
            Icon = "monitor",
            CanExecuteWhen = () => shell.Host.Linked,
        });
        commands.Register(new Command(RecordZones, "Record Zones", shell.ToggleProfilerRecording)
        {
            Description = "Record the profiler's zones. Off, the host does no profiling work, and captures have no zones.",
            Icon = "stats",
            IsCheckedWhen = () => shell.Profiler.Recording,
            CanExecuteWhen = () => shell.Host.Linked,
        });
    }

    static void RegisterCapture(EditorShell shell)
    {
        var commands = shell.Commands;
        commands.Register(new Command(Screenshot, "Screenshot", () => _ = shell.Screenshot())
        {
            Description = "Write the viewport's next frame as a PNG, with a JSON sidecar of the editor's state, to the capture directory.",
            Icon = "viewport",
            Shortcut = "F12",
            CanExecuteWhen = () => shell.Host.Linked && !shell.Captures.Busy,
        });
        commands.Register(new Command(CaptureGif, "Record Last 5 s", () => _ = shell.Gif())
        {
            Description = "Write the last five seconds of the viewport, at half size and ten frames a second, as a GIF to the capture directory.",
            Icon = "monitor",
            Shortcut = "Shift+F12",
            CanExecuteWhen = () => shell.Host.Linked && !shell.Captures.Busy,
        });
    }

    // The viewport's rendering (see docs/editor/viewport.md#viewport): what it shows in place of the lit scene, the features
    // that it turns off, the exposure offset, and the helpers. Each toggle is checked while its feature is on.
    static void RegisterRendering(EditorShell shell)
    {
        var commands = shell.Commands;
        commands.Register(new ChoiceCommand(DebugView, "View", EditorShell.DebugViewNames,
            () => EditorShell.DebugViewName(shell.ViewportSettings.DebugView), shell.SetDebugView)
        {
            Description = "Show the lit scene, or a debug view of what makes it: the lighting, the albedo, the normals, the light complexity and more.",
            Icon = "viewport",
        });
        void Feature(string id, string label, string description, Func<Link.Protocol.ViewportSettings, bool> off,
            Func<Link.Protocol.ViewportSettings, bool, Link.Protocol.ViewportSettings> set) =>
            commands.Register(new Command(id, label, () => shell.ViewportSettings = set(shell.ViewportSettings, !off(shell.ViewportSettings)))
            {
                Description = description,
                IsCheckedWhen = () => !off(shell.ViewportSettings),
            });
        Feature(TemporalAa, "Temporal AA", "Smooth edges with temporal AA in the viewport.", s => s.NoTemporalAa, (s, v) => s with { NoTemporalAa = v });
        Feature(Bloom, "Bloom", "Draw bloom in the viewport.", s => s.NoBloom, (s, v) => s with { NoBloom = v });
        Feature(ToneMapping, "Tone Mapping", "Tone map and grade the viewport; off, a plain roll-off to white.", s => s.NoToneMapping, (s, v) => s with { NoToneMapping = v });
        Feature(Fog, "Fog", "Draw the volumes' fog in the viewport.", s => s.NoFog, (s, v) => s with { NoFog = v });
        Feature(AmbientOcclusion, "Ambient Occlusion", "Darken the indirect light where surfaces meet.", s => s.NoAmbientOcclusion, (s, v) => s with { NoAmbientOcclusion = v });
        Feature(GlobalIllumination, "Global Illumination", "Light the viewport with the light that bounces; off, with the environment's ambient light.", s => s.NoGi, (s, v) => s with { NoGi = v });
        Feature(Shadows, "Shadows", "Draw the lights' shadows in the viewport.", s => s.NoShadows, (s, v) => s with { NoShadows = v });
        Feature(PostEffects, "Post Effects", "Run the game's post effects in the viewport.", s => s.NoPostEffects, (s, v) => s with { NoPostEffects = v });
        commands.Register(new Command(Icons, "Icons", () => shell.ViewportSettings = shell.ViewportSettings with { ShowIcons = !shell.ViewportSettings.ShowIcons })
        {
            Description = "Show icons for the lights, volumes and cameras, which select them when clicked.",
            Icon = "visible",
            IsCheckedWhen = () => shell.ViewportSettings.ShowIcons,
        });
        commands.Register(new ChoiceCommand(Helpers, "Shapes", ["None", "Selected", "All"],
            () => shell.ViewportSettings.Helpers.ToString(),
            option => shell.ViewportSettings = shell.ViewportSettings with { Helpers = Enum.Parse<Link.Protocol.HelperMode>(option) })
        {
            Description = "Draw the shapes of lights, volumes and cameras: their ranges, cones and bounds, for the selection or for all of them.",
            Icon = "frame",
        });
        commands.Register(new ChoiceCommand(ViewportQuality, "Quality", EditorShell.ViewportPresetNames,
            () => EditorShell.ViewportPresetNames[(int)shell.ViewportSettings.QualityPreset],
            option => shell.ViewportSettings = shell.ViewportSettings with { QualityPreset = (Link.Protocol.ViewportPreset)Math.Max(0, EditorShell.ViewportPresetNames.ToList().IndexOf(option)) })
        {
            Description = "Draw the viewport at a quality preset in place of the game's, to see what each level costs and looks like. The anti-aliasing and the render scale stay the game's unless they are chosen too.",
            Icon = "viewport",
        });
        commands.Register(new ChoiceCommand(ViewportAntiAliasing, "Anti-Aliasing", EditorShell.ViewportAaNames,
            () => EditorShell.ViewportAaNames[(int)shell.ViewportSettings.AntiAliasing],
            option => shell.ViewportSettings = shell.ViewportSettings with { AntiAliasing = (Link.Protocol.ViewportAa)Math.Max(0, EditorShell.ViewportAaNames.ToList().IndexOf(option)) })
        {
            Description = "Smooth the viewport's edges with a technique in place of the game's. FSR needs a GPU and the library that run it; elsewhere the viewport uses TAA.",
            Icon = "viewport",
        });
        commands.Register(new ChoiceCommand(ViewportRenderScale, "Render Scale", [.. EditorShell.ViewportRenderScales.Select(s => s.Label)],
            () => shell.ViewportRenderScale, shell.SetViewportRenderScale)
        {
            Description = "Draw the viewport's scene at a share of its size in place of the game's, which TAA or FSR upscale.",
            Icon = "viewport",
        });
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
