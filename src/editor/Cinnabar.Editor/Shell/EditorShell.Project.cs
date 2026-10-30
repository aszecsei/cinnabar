using Avalonia.Threading;
using Cinnabar.Editor.Content;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Model;
using LogLevel = Cinnabar.Editor.Model.LogLevel;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The project's settings (see docs/overview/architecture.md#project-settings), which the game reads, and the game in its own
/// window. The viewport is always SDR, so the output mode shows only in the game's window: Run Game opens it, and it
/// takes a change of the settings at once. The render quality's preset is there too (see
/// docs/rendering/quality.md#saved-quality): the project's default, and this machine's in place of it.
/// </summary>
public sealed partial class EditorShell
{
    /// <summary>The output modes, as the ribbon shows them, by their names in the settings file.</summary>
    public static readonly IReadOnlyList<(string Name, string Label)> OutputModes = [("Auto", "Auto"), ("Sdr", "SDR"), ("Hdr10", "HDR10"), ("Scrgb", "scRGB")];

    /// <summary>The user's choice that leaves the output to the project.</summary>
    public const string ProjectOutputLabel = "Project's";

    const string OutputKey = "output";

    /// <summary>The quality presets, by their names in the settings files, which the ribbon shows as they are.</summary>
    public static readonly IReadOnlyList<string> QualityPresets = ["Low", "Medium", "High", "Ultra"];

    /// <summary>The project's choice that leaves the quality to the device's default, by its video memory.</summary>
    public const string HardwareQualityLabel = "By Hardware";

    /// <summary>A file's quality that is no preset: the features that a game saved, one by one.</summary>
    public const string CustomQualityLabel = "Custom";

    const string QualityPrefix = "quality.";
    const string QualityPresetKey = "quality.preset";

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

    /// <summary>The project's quality preset, as the ribbon shows it.</summary>
    public string ProjectQuality
    {
        get => QualityLabel(ProjectPath) ?? HardwareQualityLabel;
        set => SetQuality(ProjectPath, value, HardwareQualityLabel, removeWhenEmpty: false);
    }

    /// <summary>This machine's quality preset, which replaces the project's, or <see cref="ProjectOutputLabel"/>.</summary>
    public string UserQuality
    {
        get => QualityLabel(ProjectSettings.UserPath(ProjectPath)) ?? ProjectOutputLabel;
        set => SetQuality(ProjectSettings.UserPath(ProjectPath), value, ProjectOutputLabel, removeWhenEmpty: true);
    }

    public bool GameWindowRunning => _gameWindow != null;

    // A file's quality: its preset, Custom for one that gives quality keys without one of the presets, or null for none.
    static string? QualityLabel(string path)
    {
        var preset = ProjectSettings.Get(path, QualityPresetKey);
        if (QualityPresets.FirstOrDefault(p => string.Equals(p, preset, StringComparison.OrdinalIgnoreCase)) is { } name)
        {
            return name;
        }
        return ProjectSettings.Keys(path).Any(k => k.StartsWith(QualityPrefix, StringComparison.Ordinal)) ? CustomQualityLabel : null;
    }

    // A preset gives every feature, so the file's other quality keys go, such as those that a game saved. Custom keeps
    // the file's keys as they are.
    void SetQuality(string path, string label, string noneLabel, bool removeWhenEmpty)
    {
        if (label == CustomQualityLabel)
        {
            return;
        }
        try
        {
            foreach (var key in ProjectSettings.Keys(path).Where(k => k.StartsWith(QualityPrefix, StringComparison.Ordinal)))
            {
                ProjectSettings.Set(path, key, null, removeWhenEmpty);
            }
            if (label != noneLabel)
            {
                ProjectSettings.Set(path, QualityPresetKey, label, removeWhenEmpty);
            }
        }
        catch (IOException e)
        {
            Console.Add(LogLevel.Error, $"project: cannot write {path}: {e.Message}");
        }
        Commands.InvalidateAll();
    }

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
    /// Opens the game in its own window, as <c>just dev</c> does, with the scene that it loads itself, the editor's content
    /// and its project settings. A game window that is open closes first. It closes with the editor.
    /// </summary>
    public void RunGame()
    {
        StopGame();
        try
        {
            var process = ChildProcess.Start(_options.HostPath, _options.HostArguments(), _options.HostDirectory);
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
