using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using Cinnabar.Editor.Host;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Ribbon;
using Cinnabar.Editor.Shell;
using Dock.Avalonia.Controls;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor;

/// <summary>The shell's window: the ribbon, the docked panels, the status bar and the command palette.</summary>
public sealed class MainWindow : Window
{
    readonly EditorShell _shell;
    readonly TextBlock _hostStatus = new();
    readonly TextBlock _worldStatus = new();
    readonly TextBlock _sceneStatus = new();
    readonly TextBlock _modeStatus = new() { Text = "Edit" };
    Border? _status;
    readonly Ellipse _hostDot = new() { Width = 8, Height = 8, VerticalAlignment = VerticalAlignment.Center };
    // The autosave is due at most every 30 s, so a check every few seconds is close enough.
    readonly DispatcherTimer _autosave = new() { Interval = TimeSpan.FromSeconds(5) };
    // Set once the user has answered about unsaved changes, so the second Close goes through.
    bool _closing;

    public MainWindow(EditorShell shell)
    {
        _shell = shell;
        Title = "cinnabar editor";
        Width = 1600;
        Height = 900;

        var views = new CommandViews(shell.Commands, shell.KeyBindings);
        var ribbon = new RibbonView(shell, views);
        var dock = new DockControl
        {
            Factory = shell.Layout.Factory,
            Layout = shell.Layout.Root,
            InitializeFactory = true,
            InitializeLayout = false,
        };
        shell.Layout.RootChanged += () => dock.Layout = shell.Layout.Root;

        var main = new DockPanel();
        DockPanel.SetDock(ribbon, DockSide.Top);
        main.Children.Add(ribbon);
        var status = StatusBar();
        DockPanel.SetDock(status, DockSide.Bottom);
        main.Children.Add(status);
        main.Children.Add(dock);

        var palette = new CommandPalette(views);
        shell.PaletteRequested += palette.Open;
        shell.OpenSceneRequested += () => _ = PickScene();
        shell.SaveAsRequested += () => _ = PickSaveAs();
        shell.RestoreOffered += () => _ = OfferRestore();
        shell.SceneChanged += UpdateSceneStatus;
        UpdateSceneStatus();
        Content = new Grid { Children = { main, palette } };

        foreach (var (id, shortcut) in shell.KeyBindings.All)
        {
            if (views.Gesture(id) is { } gesture)
            {
                KeyBindings.Add(new KeyBinding { Gesture = gesture, Command = views.Adapter(id) });
            }
            else
            {
                shell.Console.Add(LogLevel.Warning, $"key bindings: {shortcut} for {id} is not a key gesture");
            }
        }

        shell.Host.StateChanged += UpdateHostStatus;
        UpdateHostStatus();
        shell.World.EntitiesChanged += UpdateWorldStatus;
        shell.Selection.Changed += (_, _) => UpdateWorldStatus();
        shell.ModeChanged += UpdateModeStatus;
        _autosave.Tick += (_, _) => shell.Tick(DateTime.UtcNow);
        _autosave.Start();
        // The command line's scene opened before the window could ask about its autosave.
        Opened += (_, _) =>
        {
            if (shell.PendingRestore != null)
            {
                _ = OfferRestore();
            }
        };
        Closing += OnClosing;
        Closed += (_, _) =>
        {
            _autosave.Stop();
            shell.Dispose();
        };
    }

    async void OnClosing(object? sender, WindowClosingEventArgs e)
    {
        if (_closing)
        {
            return;
        }
        e.Cancel = true;
        if (await ConfirmDiscard("closing"))
        {
            _closing = true;
            _shell.SaveLayout();
            Close();
        }
    }

    /// <summary>Asks about unsaved changes before they would be lost, and returns whether to go on.</summary>
    async Task<bool> ConfirmDiscard(string doing)
    {
        if (_shell.Scene is not { IsDirty: true } scene)
        {
            return true;
        }
        var answer = await Dialogs.Ask(this, "Unsaved changes", $"{scene.Title} has changes that are not saved. Save them before {doing}?",
            "Save", "Don't Save", "Cancel");
        switch (answer)
        {
            case "Save":
                return _shell.SaveScene();
            case "Don't Save":
                _shell.DiscardChanges();
                return true;
            default:
                return false;
        }
    }

    async Task OfferRestore()
    {
        if (_shell.Scene is not { } scene || _shell.PendingRestore is not { } autosave)
        {
            return;
        }
        var when = File.GetLastWriteTime(autosave).ToString("g", System.Globalization.CultureInfo.CurrentCulture);
        var answer = await Dialogs.Ask(this, "Restore unsaved changes",
            $"The editor autosaved changes to {scene.Title} at {when} that the file does not have. It may have closed without saving them. Restore them?",
            "Restore", "Discard");
        if (answer == "Restore")
        {
            _shell.RestoreAutosave();
        }
        else
        {
            _shell.DiscardAutosave();
        }
    }

    async Task PickSaveAs()
    {
        if (_shell.Scene is not { } scene)
        {
            return;
        }
        var file = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = "Save Scene As",
            SuggestedFileName = scene.Title,
            DefaultExtension = Document.SceneFile.Extension,
            FileTypeChoices = [new FilePickerFileType("Scenes") { Patterns = [$"*{Document.SceneFile.Extension}"] }],
            SuggestedStartLocation = await StorageProvider.TryGetFolderFromPathAsync(System.IO.Path.GetDirectoryName(scene.Path)!),
        });
        if (file?.TryGetLocalPath() is { } path)
        {
            _shell.SaveScene(path);
        }
    }

    Control StatusBar()
    {
        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16, Children = { _sceneStatus, _worldStatus, _modeStatus } };
        var left = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { _hostDot, _hostStatus } };
        var bar = new DockPanel { Children = { right, left } };
        DockPanel.SetDock(right, DockSide.Right);
        _status = new Border { Classes = { "status" }, Child = bar };
        return _status;
    }

    async Task PickScene()
    {
        if (!await ConfirmDiscard("opening another scene"))
        {
            return;
        }
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "Open Scene",
            AllowMultiple = false,
            FileTypeFilter = [new FilePickerFileType("Scenes") { Patterns = [$"*{Document.SceneFile.Extension}"] }],
            SuggestedStartLocation = _shell.Scene is { } open
                ? await StorageProvider.TryGetFolderFromPathAsync(System.IO.Path.GetDirectoryName(open.Path)!)
                : null,
        });
        if (files.Count == 1 && files[0].TryGetLocalPath() is { } path)
        {
            _shell.OpenScene(path);
        }
    }

    void UpdateSceneStatus()
    {
        var scene = _shell.Scene;
        var dirty = scene is { IsDirty: true } ? " •" : "";
        Title = scene == null ? "cinnabar editor" : $"{scene.Title}{dirty} - cinnabar editor";
        _sceneStatus.Text = scene == null ? "No scene" : scene.Title + dirty;
        ToolTip.SetTip(_sceneStatus, scene?.Path);
    }

    void UpdateWorldStatus()
    {
        var count = _shell.World.Entities.Count;
        var selected = _shell.Selection.Count switch
        {
            0 => "",
            1 => $"  ·  {_shell.World.Find(_shell.Selection.Entity)?.Label ?? Model.EntityNode.Format(_shell.Selection.Entity)} selected",
            var n => $"  ·  {n} selected",
        };
        _worldStatus.Text = _shell.World.HasWorld ? $"{count} {(count == 1 ? "entity" : "entities")}{selected}" : "";
    }

    // Play mode tints the status bar, as the viewport's frame, so nobody edits by mistake while the game runs.
    void UpdateModeStatus()
    {
        _modeStatus.Text = _shell.Mode switch
        {
            Link.Protocol.EditorMode.Play => _shell.FreeCamera ? "Play, free camera" : "Play",
            Link.Protocol.EditorMode.Paused => "Paused",
            _ => "Edit",
        };
        _status?.Classes.Set("playing", _shell.Mode == Link.Protocol.EditorMode.Play);
        _status?.Classes.Set("paused", _shell.Mode == Link.Protocol.EditorMode.Paused);
    }

    void UpdateHostStatus()
    {
        var host = _shell.Host;
        (_hostStatus.Text, _hostDot.Fill) = host.State switch
        {
            HostState.Waiting => ("Host: waiting for the viewport", Brushes.Gray),
            HostState.Running when host.Linked => ($"Host: running {host.Game}, linked", Brush.Parse("#4caf50")),
            HostState.Running => ("Host: starting, linking", Brush.Parse("#e8b04a")),
            HostState.Stopped => ("Host: stopped", Brushes.Gray),
            _ => ($"Host: exited with code {host.ExitCode}", Brush.Parse("#f0605a")),
        };
    }
}
