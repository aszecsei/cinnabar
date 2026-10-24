using System.Diagnostics;
using Avalonia.Controls;
using Avalonia.Threading;
using Cinnabar.Editor.Host;

namespace Cinnabar.Editor;

public partial class MainWindow : Window
{
    readonly EditorOptions _options;
    // One shared target per editor, so two editors never open each other's frames.
    readonly string _sharedName = $"cinnabar-editor-{Environment.ProcessId}";
    readonly DispatcherTimer _statsTimer;
    readonly Stopwatch _statsClock = Stopwatch.StartNew();
    ulong _statsPresented;
    ulong _statsShown;
    HostProcess? _host;

    // For the XAML previewer.
    public MainWindow() : this(EditorOptions.Parse([]))
    {
    }

    internal MainWindow(EditorOptions options)
    {
        _options = options;
        InitializeComponent();
        Viewport.Ready += StartHost;
        Viewport.Failed += SetStatus;
        _statsTimer = new DispatcherTimer(TimeSpan.FromMilliseconds(500), DispatcherPriority.Background, (_, _) => UpdateStats());
        _statsTimer.Start();
    }

    void StartHost(ulong adapter)
    {
        try
        {
            _host = HostProcess.Start(_options.HostPath,
                [_options.GamePath, "--shared", _sharedName, "--adapter", adapter.ToString("x16")],
                Environment.CurrentDirectory);
        }
        catch (Exception e)
        {
            SetStatus($"cannot start {_options.HostPath}: {e.Message}");
            return;
        }
        _host.Output += line => Dispatcher.UIThread.Post(() => SetStatus(line));
        _host.Exited += code => Dispatcher.UIThread.Post(() =>
        {
            Viewport.Disconnect();
            SetStatus($"the host exited with code {code}");
        });
        Viewport.Connect(_sharedName);
    }

    void SetStatus(string text) => Status.Text = text;

    void UpdateStats()
    {
        var seconds = _statsClock.Elapsed.TotalSeconds;
        _statsClock.Restart();
        // The host's rate comes from its frame numbers. A lower presented rate means that the viewport drops frames.
        var hostFps = (Viewport.FrameShown - Math.Min(_statsShown, Viewport.FrameShown)) / seconds;
        var presentedFps = (Viewport.FramesPresented - _statsPresented) / seconds;
        _statsShown = Viewport.FrameShown;
        _statsPresented = Viewport.FramesPresented;
        var size = Viewport.FrameSize;
        Stats.Text = $"frame {Viewport.FrameShown}  {size.Width}x{size.Height}\nhost {hostFps:0.0} fps  shown {presentedFps:0.0} fps\n{Viewport.AdapterName}\n{Viewport.Interop}";
    }

    protected override void OnClosed(EventArgs e)
    {
        _statsTimer.Stop();
        Viewport.Disconnect();
        _host?.Dispose();
        base.OnClosed(e);
    }
}
