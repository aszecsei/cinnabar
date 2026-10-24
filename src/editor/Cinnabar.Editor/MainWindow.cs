using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
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
    readonly Ellipse _hostDot = new() { Width = 8, Height = 8, VerticalAlignment = VerticalAlignment.Center };

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
        Closing += (_, _) => shell.SaveLayout();
        Closed += (_, _) => shell.Dispose();
    }

    Control StatusBar()
    {
        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16, Children = { _sceneStatus, _worldStatus, new TextBlock { Text = "Edit" } } };
        var left = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { _hostDot, _hostStatus } };
        var bar = new DockPanel { Children = { right, left } };
        DockPanel.SetDock(right, DockSide.Right);
        return new Border { Classes = { "status" }, Child = bar };
    }

    async Task PickScene()
    {
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
        Title = scene == null ? "cinnabar editor" : $"{scene.Title} - cinnabar editor";
        _sceneStatus.Text = scene == null ? "No scene" : scene.Title;
        ToolTip.SetTip(_sceneStatus, scene?.Path);
    }

    void UpdateWorldStatus()
    {
        var count = _shell.World.Entities.Count;
        var selected = _shell.Selection.IsEmpty ? "" : $"  ·  {_shell.World.Find(_shell.Selection.Entity)?.Label ?? Model.EntityNode.Format(_shell.Selection.Entity)} selected";
        _worldStatus.Text = _shell.World.HasWorld ? $"{count} {(count == 1 ? "entity" : "entities")}{selected}" : "";
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
