using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;

namespace Cinnabar.Editor.Viewport;

/// <summary>The viewport panel: the frames, and the stats overlay over them.</summary>
public sealed class ViewportView : Grid
{
    readonly ViewportSession _session;
    readonly Border _overlay;
    readonly TextBlock _stats;
    readonly DispatcherTimer _timer;
    ulong _lastPresented;
    ulong _lastShown;
    long _lastTick = Environment.TickCount64;

    public ViewportView(ViewportSession session)
    {
        _session = session;
        Background = Brushes.Black;
        Children.Add(new ViewportControl { Session = session });
        _stats = new TextBlock { FontFamily = new FontFamily("Consolas"), FontSize = 12 };
        _overlay = new Border
        {
            Child = _stats,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(8),
            Padding = new Thickness(8, 4),
            CornerRadius = new CornerRadius(3),
            Background = new SolidColorBrush(Color.FromArgb(0xc0, 0x20, 0x20, 0x24)),
            IsHitTestVisible = false,
        };
        Children.Add(_overlay);
        _timer = new DispatcherTimer(TimeSpan.FromMilliseconds(500), DispatcherPriority.Background, (_, _) => UpdateStats());
        AttachedToVisualTree += (_, _) =>
        {
            _session.ViewChanged += ShowOverlay;
            _timer.Start();
        };
        DetachedFromVisualTree += (_, _) =>
        {
            _session.ViewChanged -= ShowOverlay;
            _timer.Stop();
        };
        UpdateStats();
    }

    void ShowOverlay() => _overlay.IsVisible = _session.ShowStats;

    void UpdateStats()
    {
        ShowOverlay();
        var now = Environment.TickCount64;
        var seconds = Math.Max(now - _lastTick, 1) / 1000.0;
        _lastTick = now;
        // The host's rate comes from its frame numbers. A lower shown rate means that the viewport drops frames.
        var hostFps = (_session.FrameShown - Math.Min(_lastShown, _session.FrameShown)) / seconds;
        var shownFps = (_session.FramesPresented - _lastPresented) / seconds;
        _lastShown = _session.FrameShown;
        _lastPresented = _session.FramesPresented;
        var size = _session.FrameSize;
        _stats.Text = $"frame {_session.FrameShown}  {size.Width}x{size.Height}\nhost {hostFps:0.0} fps  shown {shownFps:0.0} fps\n{_session.AdapterName}\n{_session.Interop}";
    }
}
