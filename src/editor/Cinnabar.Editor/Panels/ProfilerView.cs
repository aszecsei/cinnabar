using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Profiler;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// The profiler (see docs/editor/shell-and-panels.md#profiler): a captured frame's timeline, the selected zone's
/// details, and the costs of the last stats interval by pass, system and script. The model is the shell's, so a panel
/// that docking rebuilds shows the same capture.
/// </summary>
public sealed class ProfilerView : DockPanel
{
    static readonly uint[] WorstCounts = [30, 60, 120];

    readonly EditorShell _shell;
    readonly ProfilerModel _model;
    readonly FrameTimeline _timeline;
    readonly TextBlock _status = new() { Classes = { "dim" }, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0) };
    readonly TextBlock _details = new() { Classes = { "dim" }, Margin = new Thickness(8, 4), TextTrimming = TextTrimming.CharacterEllipsis };
    readonly ToggleButton _record = new() { Content = "Record", Padding = new Thickness(8, 2), Margin = new Thickness(4) };
    readonly TextBlock _empty = new()
    {
        Text = "Capture a frame to see where each thread and the GPU spend it, or click a point of the Resource Monitor's graph to capture that interval's longest frame.",
        Classes = { "empty" },
        TextWrapping = TextWrapping.Wrap,
        TextAlignment = TextAlignment.Center,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        MaxWidth = 420,
        Margin = new Thickness(16),
    };

    public ProfilerView(EditorShell shell)
    {
        _shell = shell;
        _model = shell.Profiler;
        _timeline = new FrameTimeline(_model);

        var next = new Button { Content = "Capture Frame", Padding = new Thickness(8, 2), Margin = new Thickness(4) };
        next.Click += (_, _) => _shell.CaptureNextFrame();
        var worst = new ComboBox { ItemsSource = WorstCounts.Select(c => $"Worst of {c}").ToList(), SelectedIndex = 2, Margin = new Thickness(4) };
        var captureWorst = new Button { Content = "Capture", Padding = new Thickness(8, 2), Margin = new Thickness(0, 4, 4, 4) };
        captureWorst.Click += (_, _) => _shell.CaptureWorstFrame(WorstCounts[Math.Max(worst.SelectedIndex, 0)]);
        var fit = new Button { Content = "Fit", Padding = new Thickness(8, 2), Margin = new Thickness(4) };
        fit.Click += (_, _) => _timeline.Fit();
        ToolTip.SetTip(fit, "Fit the frame to the timeline (F)");
        ToolTip.SetTip(_record, "Record the profiler's zones. Off, the host does no profiling work.");
        _record.Click += (_, _) => _shell.ToggleProfilerRecording();
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Children = { next, worst, captureWorst, fit, _record, _status } };
        SetDock(bar, DockSide.Top);
        Children.Add(bar);

        var tables = new TabControl
        {
            ItemsSource = new[]
            {
                new TabItem { Header = "GPU passes", Content = new CostTable(_model, ProfileCostKind.Pass, "Each render pass's GPU time appears here while the host is linked.") },
                new TabItem { Header = "Systems", Content = new CostTable(_model, ProfileCostKind.System, "Each ECS system's CPU time appears here while the host is linked.") },
                new TabItem { Header = "Scripts", Content = new CostTable(_model, ProfileCostKind.Script, "Each behaviour class's time in each callback appears here while scripts run.") },
            },
        };
        var timeline = new DockPanel();
        SetDock(_details, DockSide.Bottom);
        timeline.Children.Add(_details);
        timeline.Children.Add(new Panel { Children = { _timeline, _empty } });
        var split = new Grid { RowDefinitions = new RowDefinitions("3*,Auto,2*") };
        Grid.SetRow(timeline, 0);
        var splitter = new GridSplitter { Height = 4, HorizontalAlignment = HorizontalAlignment.Stretch, ResizeDirection = GridResizeDirection.Rows };
        Grid.SetRow(splitter, 1);
        Grid.SetRow(tables, 2);
        split.Children.Add(timeline);
        split.Children.Add(splitter);
        split.Children.Add(tables);
        Children.Add(split);

        _timeline.SelectionChanged += ShowDetails;
        AttachedToVisualTree += (_, _) =>
        {
            _model.CaptureChanged += ShowCapture;
            _model.SummaryChanged += ShowStatus;
            ShowCapture();
        };
        DetachedFromVisualTree += (_, _) =>
        {
            _model.CaptureChanged -= ShowCapture;
            _model.SummaryChanged -= ShowStatus;
        };
    }

    void ShowCapture()
    {
        _timeline.Refresh();
        _empty.IsVisible = _model.Capture == null;
        ShowStatus();
        ShowDetails();
    }

    void ShowStatus()
    {
        _record.IsChecked = _model.Recording;
        var capture = _model.Capture;
        var text = _model.Status switch
        {
            CaptureStatus.Waiting => "Waiting for the frame…",
            CaptureStatus.Unavailable => _model.Reason,
            _ => "",
        };
        if (_model.Status != CaptureStatus.Waiting && capture != null)
        {
            var gpu = capture.HasGpu ? $" · GPU {capture.GpuMs:0.00} ms" : " · no GPU times";
            var dropped = capture.Message.Dropped > 0 ? $" · {capture.Message.Dropped} zones dropped" : "";
            var captured = $"Frame {capture.Frame}: {capture.FrameMs:0.00} ms · CPU {capture.CpuMs:0.00} ms · wait {capture.WaitMs:0.00} ms{gpu}{dropped}";
            text = text == "" ? captured : $"{text} · {captured}";
        }
        if (_model.Summary is { Dropped: > 0 } s)
        {
            text += $" · the host dropped {s.Dropped} zones in the last interval";
        }
        _status.Text = text;
    }

    void ShowDetails()
    {
        if (_timeline.Selected is not { } zone || _model.Capture is not { } capture)
        {
            _details.Text = _model.Capture != null ? "Click a zone to see its details. Double-click zooms to it." : "";
            return;
        }
        var (count, total) = capture.Occurrences(zone.Name);
        var callback = zone.Callback != ProfileCallback.None ? $":{ProfilerModel.CallbackName(zone.Callback)}" : "";
        _details.Text = $"{zone.Name}{callback} · {zone.Category} · {TimelineGeometry.Duration(zone.Duration)}, self {TimelineGeometry.Duration(zone.Self)} · "
            + $"at {TimelineGeometry.Duration(zone.Start)} on {capture.Lanes[zone.Lane].Name} · {count}× in the frame, {TimelineGeometry.Duration(total)} in all";
    }
}
