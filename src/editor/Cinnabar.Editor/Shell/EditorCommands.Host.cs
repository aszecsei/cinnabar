using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Host;

namespace Cinnabar.Editor.Shell;

static partial class EditorCommands
{
    // Play mode and its camera.
    static void RegisterPlay(EditorShell shell)
    {
        var commands = shell.Commands;
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
    }

    // The host and the cook daemon.
    static void RegisterHost(EditorShell shell)
    {
        var commands = shell.Commands;
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
}
