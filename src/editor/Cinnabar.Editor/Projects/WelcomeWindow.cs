using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Cinnabar.Editor.Content;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Projects;

/// <summary>
/// The window that the editor opens without a project (see docs/editor/processes-and-projects.md#projects): New Project,
/// Open Project and the recent projects. Opening a project builds it with <c>cinnabar build</c> first, whose output shows
/// here, and then raises <see cref="ProjectReady"/> with the project's options.
/// </summary>
public sealed class WelcomeWindow : Window
{
    readonly EditorSettings _settings;
    readonly RecentProjects _recent;
    readonly string? _engine;
    readonly ProjectTool? _tool;
    readonly StackPanel _recentList = new() { Spacing = 2 };
    readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap, Foreground = new SolidColorBrush(Color.Parse("#A0A0A8")) };
    readonly SelectableTextBlock _log = new() { FontFamily = new FontFamily("Cascadia Mono,Consolas,monospace"), FontSize = 11, TextWrapping = TextWrapping.Wrap };
    readonly ScrollViewer _logView;
    readonly Button _new = new() { Content = "New Project…", MinWidth = 160, Classes = { "accent" } };
    readonly Button _open = new() { Content = "Open Project…", MinWidth = 160 };
    // The project that the tool builds or makes, which opens when the build succeeds.
    string? _pending;

    /// <summary>The project built, and the editor opens it with these options.</summary>
    public event Action<EditorOptions>? ProjectReady;

    public WelcomeWindow(EditorSettings settings, string? engineRoot, string? openNow = null)
    {
        _settings = settings;
        _recent = new RecentProjects(settings);
        _engine = engineRoot;
        Title = "cinnabar";
        Width = 860;
        Height = 560;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = new SolidColorBrush(Color.Parse("#1C1C1F"));
        _logView = new ScrollViewer { Content = _log, IsVisible = false, MaxHeight = 220, Margin = new Thickness(0, 8, 0, 0) };

        if (engineRoot != null)
        {
            _tool = new ProjectTool(ProjectLayout.Tool(engineRoot), engineRoot, ChildProcess.Start);
            _tool.Output += line =>
            {
                _log.Text += line + "\n";
                _logView.ScrollToEnd();
            };
            _tool.Finished += OnFinished;
        }
        _new.Click += (_, _) => _ = NewProject();
        _open.Click += (_, _) => _ = PickProject();

        var actions = new StackPanel
        {
            Spacing = 10,
            Width = 220,
            Children =
            {
                new TextBlock { Text = "cinnabar", FontSize = 28, FontWeight = FontWeight.SemiBold },
                new TextBlock { Text = "Make a game with the engine, in a folder of its own.", TextWrapping = TextWrapping.Wrap, Foreground = new SolidColorBrush(Color.Parse("#A0A0A8")), Margin = new Thickness(0, 0, 0, 12) },
                _new,
                _open,
            },
        };
        var recent = new DockPanel
        {
            Children =
            {
                new TextBlock { Text = "Recent", FontWeight = FontWeight.SemiBold, Margin = new Thickness(0, 0, 0, 8), [DockPanel.DockProperty] = Avalonia.Controls.Dock.Top },
                new ScrollViewer { Content = _recentList },
            },
        };
        var body = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,24,*") };
        Grid.SetColumn(actions, 0);
        Grid.SetColumn(recent, 2);
        body.Children.Add(actions);
        body.Children.Add(recent);
        var footer = new StackPanel { Children = { _status, _logView } };
        DockPanel.SetDock(footer, Avalonia.Controls.Dock.Bottom);
        Content = new DockPanel { Margin = new Thickness(28), LastChildFill = true, Children = { footer, body } };

        ShowRecent();
        if (engineRoot == null)
        {
            Fail($"The editor cannot find the engine's checkout. Set {ProjectLayout.EngineVariable} to it, or run the editor that `just engine` built in it.");
        }
        else if (!File.Exists(ProjectLayout.Tool(engineRoot)))
        {
            Fail($"{ProjectLayout.Tool(engineRoot)} is not built. Run `just engine` in {engineRoot}.");
        }
        else if (openNow != null)
        {
            Opened += (_, _) => Open(openNow);
        }
    }

    void ShowRecent()
    {
        _recentList.Children.Clear();
        var projects = _recent.List();
        if (projects.Count == 0)
        {
            _recentList.Children.Add(new TextBlock { Text = "No projects yet.", Foreground = new SolidColorBrush(Color.Parse("#808088")) });
        }
        foreach (var project in projects)
        {
            var item = new Button
            {
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
                Background = Brushes.Transparent,
                Padding = new Thickness(8, 6),
                Content = new StackPanel
                {
                    Children =
                    {
                        new TextBlock { Text = ProjectLayout.Name(project), FontWeight = FontWeight.SemiBold },
                        new TextBlock { Text = project, FontSize = 11, Foreground = new SolidColorBrush(Color.Parse("#808088")) },
                    },
                },
            };
            ToolTip.SetTip(item, $"Open {project}");
            item.Click += (_, _) => Open(project);
            _recentList.Children.Add(item);
        }
    }

    void SetBusy(bool busy)
    {
        _new.IsEnabled = !busy && _tool != null;
        _open.IsEnabled = !busy && _tool != null;
        _recentList.IsEnabled = !busy && _tool != null;
        Cursor = busy ? new Cursor(StandardCursorType.Wait) : Cursor.Default;
    }

    void Fail(string message)
    {
        _status.Text = message;
        _status.Foreground = new SolidColorBrush(Color.Parse("#E8836F"));
        SetBusy(false);
    }

    /// <summary>Builds a project with <c>cinnabar build</c>, which writes what the editor runs it with, and then opens it.</summary>
    void Open(string path)
    {
        if (ProjectLayout.ProjectDirectory(path) is not { } project)
        {
            _recent.Remove(path);
            ShowRecent();
            Fail($"{path} is not a project: it has no {ProjectLayout.SettingsFileName}.");
            return;
        }
        Run("build", project, $"Building {ProjectLayout.Name(project)}…", project);
    }

    void Run(string command, string project, string status, params string[] args)
    {
        if (_tool == null || _tool.IsRunning)
        {
            return;
        }
        _pending = project;
        _log.Text = "";
        _logView.IsVisible = true;
        _status.Text = status;
        _status.Foreground = new SolidColorBrush(Color.Parse("#A0A0A8"));
        SetBusy(true);
        if (!_tool.Run(command, args))
        {
            Fail($"cinnabar {command} did not start.");
        }
    }

    void OnFinished(string command, int code)
    {
        if (_pending is not { } project || _engine == null)
        {
            return;
        }
        if (code != 0)
        {
            Fail($"cinnabar {command} failed with code {code}. Its output is above.");
            return;
        }
        if (command == "new")
        {
            Open(project);
            return;
        }
        _recent.Add(project);
        _status.Text = $"Opening {ProjectLayout.Name(project)}…";
        ProjectReady?.Invoke(EditorOptions.ForProject(project, _engine));
    }

    async Task PickProject()
    {
        var folders = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = "Open Project", AllowMultiple = false });
        if (folders.Count == 1 && folders[0].TryGetLocalPath() is { } path)
        {
            Open(path);
        }
    }

    async Task NewProject()
    {
        if (_engine == null)
        {
            return;
        }
        var location = _recent.List().FirstOrDefault() is { } last && Path.GetDirectoryName(last) is { } parent
            ? parent
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "cinnabar");
        if (await NewProjectDialog.Ask(this, location, ProjectLayout.Templates(_engine)) is not { } answer)
        {
            return;
        }
        var dir = Path.Combine(answer.Location, answer.Folder);
        if (Directory.Exists(dir) && Directory.EnumerateFileSystemEntries(dir).Any())
        {
            Fail($"{dir} is not empty. A new project goes in a new or empty folder.");
            return;
        }
        Run("new", dir, $"Making {answer.Name}…", dir, "--name", answer.Name, "--template", answer.Template);
    }

    protected override void OnClosed(EventArgs e)
    {
        _tool?.Dispose();
        base.OnClosed(e);
    }
}
