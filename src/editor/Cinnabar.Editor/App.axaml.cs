using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Controls.Templates;
using Avalonia.Markup.Xaml;
using Avalonia.Threading;
using Cinnabar.Editor.Docking;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Viewport;
using Cinnabar.Editor.Projects;

namespace Cinnabar.Editor;

public partial class App : Application
{
    public override void Initialize()
    {
        AvaloniaXamlLoader.Load(this);
        // A panel's window does not outlive the editor.
        Dock.Settings.DockSettings.CloseFloatingWindowsOnMainWindowClose = true;
        // Docking templates each panel through these. A panel's state is in the panel, so a new view loses nothing.
        DataTemplates.Add(new FuncDataTemplate<PanelTool>((panel, _) => panel?.CreateView()));
        DataTemplates.Add(new FuncDataTemplate<ViewportDocument>((document, _) => document == null ? null : document.CreateView()));
        DataTemplates.Add(new FuncDataTemplate<EditorDocument>((document, _) => document?.CreateView()));
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            var settings = EditorSettings.ForUser();
            var args = desktop.Args ?? [];
            // Without a project, or with only a project's folder, the welcome window comes first: it builds the project
            // with cinnabar.exe, and then the editor opens it (see docs/editor/processes-and-projects.md#projects).
            if (args.Length == 0 || (args.Length == 1 && !args[0].StartsWith("--", StringComparison.Ordinal)))
            {
                var welcome = new WelcomeWindow(settings, ProjectLayout.EngineRoot(), args.Length == 1 ? args[0] : null);
                welcome.ProjectReady += options =>
                {
                    var main = OpenEditor(options, settings);
                    desktop.MainWindow = main;
                    main.Show();
                    welcome.Close();
                };
                desktop.MainWindow = welcome;
            }
            else
            {
                desktop.MainWindow = OpenEditor(EditorOptions.Parse(args), settings);
            }
        }
        base.OnFrameworkInitializationCompleted();
    }

    static MainWindow OpenEditor(EditorOptions options, EditorSettings settings)
    {
        if (ProjectLayout.ProjectDirectory(options.ProjectDirectory) is { } project)
        {
            new RecentProjects(settings).Add(project);
        }
        var shell = new EditorShell(options, settings);
        // A bug in one panel must not close the editor and lose the user's work. It goes to the console instead.
        Dispatcher.UIThread.UnhandledException += (_, e) =>
        {
            shell.Console.Add(LogLevel.Error, $"editor: {e.Exception}");
            e.Handled = true;
        };
        return new MainWindow(shell);
    }
}
