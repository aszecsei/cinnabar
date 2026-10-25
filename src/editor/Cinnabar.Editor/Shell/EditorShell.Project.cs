using Avalonia.Threading;
using Cinnabar.Editor.Content;
using Cinnabar.Editor.Document;
using LogLevel = Cinnabar.Editor.Panels.LogLevel;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The project's settings (see docs/architecture.md#project-settings), which the game reads, and the game in its own
/// window. The viewport is always SDR, so the output mode shows only in the game's window: Run Game opens it, and it
/// takes a change of the settings at once.
/// </summary>
public sealed partial class EditorShell
{
    /// <summary>The output modes, as the ribbon shows them, by their names in the settings file.</summary>
    public static readonly IReadOnlyList<(string Name, string Label)> OutputModes = [("Auto", "Auto"), ("Sdr", "SDR"), ("Hdr10", "HDR10"), ("Scrgb", "scRGB")];

    /// <summary>The user's choice that leaves the output to the project.</summary>
    public const string ProjectOutputLabel = "Project's";

    const string OutputKey = "output";

    ChildProcess? _gameWindow;

    public string ProjectPath => _options.ProjectPath;

    /// <summary>The project's output mode, as the ribbon shows it.</summary>
    public string ProjectOutput
    {
        get => Label(ProjectSettings.Get(ProjectPath, OutputKey)) ?? "Auto";
        set => SetOutput(ProjectPath, value, removeWhenEmpty: false);
    }

    /// <summary>This machine's output mode, which replaces the project's, or <see cref="ProjectOutputLabel"/>.</summary>
    public string UserOutput
    {
        get => Label(ProjectSettings.Get(ProjectSettings.UserPath(ProjectPath), OutputKey)) ?? ProjectOutputLabel;
        set => SetOutput(ProjectSettings.UserPath(ProjectPath), value, removeWhenEmpty: true);
    }

    public bool GameWindowRunning => _gameWindow != null;

    static string? Label(string? name) => OutputModes.FirstOrDefault(m => string.Equals(m.Name, name, StringComparison.OrdinalIgnoreCase)).Label;

    void SetOutput(string path, string label, bool removeWhenEmpty)
    {
        var name = OutputModes.FirstOrDefault(m => m.Label == label).Name;
        try
        {
            ProjectSettings.Set(path, OutputKey, name, removeWhenEmpty);
        }
        catch (IOException e)
        {
            Console.Add(LogLevel.Error, $"project: cannot write {path}: {e.Message}");
        }
        Commands.InvalidateAll();
    }

    /// <summary>
    /// Opens the game in its own window, as <c>just dev</c> does, with the scene and content that it loads itself. A game
    /// window that is open closes first. It closes with the editor.
    /// </summary>
    public void RunGame()
    {
        StopGame();
        try
        {
            var process = ChildProcess.Start(_options.HostPath, [_options.GamePath], Environment.CurrentDirectory);
            _gameWindow = process;
            process.Output += line => Dispatcher.UIThread.Post(() => Console.Add(LogLevel.Info, $"game window: {line}"));
            process.Exited += code => Dispatcher.UIThread.Post(() =>
            {
                if (_gameWindow == process)
                {
                    _gameWindow = null;
                    process.Dispose();
                    Console.Add(code == 0 ? LogLevel.Info : LogLevel.Warning, $"game window: exited with code {code}");
                    Commands.InvalidateAll();
                }
            });
        }
        catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            Console.Add(LogLevel.Error, $"game window: cannot start {_options.HostPath}: {e.Message}");
        }
        Commands.InvalidateAll();
    }

    public void StopGame()
    {
        var process = _gameWindow;
        _gameWindow = null;
        process?.Dispose();
        Commands.InvalidateAll();
    }
}
