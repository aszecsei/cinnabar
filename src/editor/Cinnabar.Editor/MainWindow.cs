using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
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
        Closing += (_, _) => shell.SaveLayout();
        Closed += (_, _) => shell.Dispose();
    }

    Control StatusBar()
    {
        var mode = new TextBlock { Text = "Edit" };
        var left = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { _hostDot, _hostStatus } };
        var bar = new DockPanel { Children = { mode, left } };
        DockPanel.SetDock(mode, DockSide.Right);
        return new Border { Classes = { "status" }, Child = bar };
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
