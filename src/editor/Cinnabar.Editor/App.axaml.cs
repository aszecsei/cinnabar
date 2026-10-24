using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Controls.Templates;
using Avalonia.Markup.Xaml;
using Avalonia.Threading;
using Cinnabar.Editor.Docking;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Viewport;

namespace Cinnabar.Editor;

public partial class App : Application
{
    public override void Initialize()
    {
        AvaloniaXamlLoader.Load(this);
        // Docking templates each panel through these. A panel's state is in the panel, so a new view loses nothing.
        DataTemplates.Add(new FuncDataTemplate<PanelTool>((panel, _) => panel?.CreateView()));
        DataTemplates.Add(new FuncDataTemplate<ViewportDocument>((document, _) => document == null ? null : new ViewportView(document.Session)));
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            var shell = new EditorShell(EditorOptions.Parse(desktop.Args ?? []), EditorSettings.ForUser());
            // A bug in one panel must not close the editor and lose the user's work. It goes to the console instead.
            Dispatcher.UIThread.UnhandledException += (_, e) =>
            {
                shell.Console.Add(LogLevel.Error, $"editor: {e.Exception}");
                e.Handled = true;
            };
            desktop.MainWindow = new MainWindow(shell);
        }
        base.OnFrameworkInitializationCompleted();
    }
}
