using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// The resource monitor (see docs/editor/shell-and-panels.md#resource-monitor): the frame times of the last minute as a graph, the
/// host's memory and GPU resources, and the world's entities and the scripts' memory by module. The host and the game
/// send their stats four times a second while the link is up. A click on the graph captures that interval's worst frame
/// in the profiler.
/// </summary>
public sealed class ResourceMonitorView : Grid
{
    readonly ResourceStats _stats;
    readonly FrameGraph _graph;
    readonly TextBlock _frames = new() { Classes = { "dim" } };
    readonly Grid _host = Table();
    readonly Grid _game = Table();
    readonly Grid _modules = Table();
    readonly TextBlock _empty = new()
    {
        Text = "Frame times, memory and GPU resources appear here while the host is linked.",
        Classes = { "empty" },
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
    };

    public ResourceMonitorView(ResourceStats stats, Action<ulong>? capture = null)
    {
        _stats = stats;
        _graph = new FrameGraph(stats, capture) { Height = 110, MinWidth = 240 };
        // The tables take what their rows need, and the graph the rest.
        ColumnDefinitions = new ColumnDefinitions("*,Auto,Auto,Auto");
        Margin = new Thickness(8);
        var frames = new StackPanel { Spacing = 4, Children = { Heading("Frame times"), _graph, _frames } };
        AddColumn(frames, 0);
        AddColumn(new ScrollViewer { Content = new StackPanel { Spacing = 4, Children = { Heading("Host"), _host } } }, 1);
        AddColumn(new ScrollViewer { Content = new StackPanel { Spacing = 4, Children = { Heading("World"), _game } } }, 2);
        AddColumn(new ScrollViewer { Content = new StackPanel { Spacing = 4, Children = { Heading("Script memory by module"), _modules } } }, 3);
        Children.Add(_empty);
        SetColumnSpan(_empty, 4);
        AttachedToVisualTree += (_, _) =>
        {
            _stats.Changed += Show;
            Show();
        };
        DetachedFromVisualTree += (_, _) => _stats.Changed -= Show;
    }

    void AddColumn(Control control, int column)
    {
        control.Margin = new Thickness(0, 0, 16, 0);
        SetColumn(control, column);
        Children.Add(control);
    }

    static TextBlock Heading(string text) => new() { Text = text, FontWeight = FontWeight.SemiBold };

    static Grid Table() => new() { ColumnDefinitions = new ColumnDefinitions("Auto,Auto") };

    void Show()
    {
        _empty.IsVisible = _stats.Host == null && _stats.Game == null;
        _graph.InvalidateVisual();
        if (_stats.Host is { } h)
        {
            var fps = h.Interval > 0 ? h.Frames / h.Interval : 0;
            var last = _stats.History.LastOrDefault();
            _frames.Text = last.Profiled
                ? $"{fps:0} fps   ·   frame {h.FrameMsAverage:0.0} ms, longest {h.FrameMsMax:0.0} ms   ·   CPU {last.CpuMs:0.0} ms   ·   GPU {last.GpuMs:0.0} ms   ·   wait {last.WaitMs:0.0} ms"
                : $"{fps:0} fps   ·   frame {h.FrameMsAverage:0.0} ms, longest {h.FrameMsMax:0.0} ms   ·   work {h.WorkMsAverage:0.0} ms";
            Rows(_host,
            [
                ("Permanent memory", ResourceStats.Bytes(h.PermanentBytes)),
                ("Frame memory, most", ResourceStats.Bytes(h.FrameBytesMax)),
                ("Upload ring, most", ResourceStats.Bytes(h.UploadBytesMax)),
                ("Video memory", h.VideoMemoryBudget > 0 ? $"{ResourceStats.Bytes(h.VideoMemoryUsed)} / {ResourceStats.Bytes(h.VideoMemoryBudget)}" : "unknown"),
                ("Buffers", $"{h.Buffers:N0}"),
                ("Textures", $"{h.Textures:N0}"),
                ("Pipelines", $"{h.Pipelines:N0}"),
                ("Samplers", $"{h.Samplers:N0}"),
                ("Acceleration structures", $"{h.Accels:N0}"),
            ]);
        }
        if (_stats.Game is { } g)
        {
            var modules = g.Modules.Aggregate(0UL, (sum, m) => sum + m.Bytes);
            Rows(_game,
            [
                ("Entities", $"{g.Entities:N0}"),
                ("Archetypes", $"{g.Archetypes:N0}"),
                ("Behaviours", $"{g.Behaviours:N0}"),
                ("Script memory", ResourceStats.Bytes(g.ScriptBytes)),
                ("Engine's part", ResourceStats.Bytes(g.ScriptBytes - Math.Min(modules, g.ScriptBytes))),
            ]);
            Rows(_modules, [.. g.Modules.OrderByDescending(m => m.Bytes).Select(m => (m.Name, ResourceStats.Bytes(m.Bytes)))]);
        }
    }

    // A table's rows are rebuilt only when their number changes, so the text updates in place four times a second.
    static void Rows(Grid table, IReadOnlyList<(string Name, string Value)> rows)
    {
        if (table.RowDefinitions.Count != rows.Count)
        {
            table.Children.Clear();
            table.RowDefinitions.Clear();
            for (var i = 0; i < rows.Count; i++)
            {
                table.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
                var name = new TextBlock { Classes = { "dim" } };
                var value = new TextBlock { HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(12, 0, 0, 0) };
                SetRow(name, i);
                SetRow(value, i);
                SetColumn(value, 1);
                table.Children.Add(name);
                table.Children.Add(value);
            }
        }
        for (var i = 0; i < rows.Count; i++)
        {
            ((TextBlock)table.Children[2 * i]).Text = rows[i].Name;
            ((TextBlock)table.Children[2 * i + 1]).Text = rows[i].Value;
        }
    }
}

/// <summary>
/// The frame times of the last minute: each interval's longest frame, faint, and with the profiler its average CPU
/// time, GPU time and wait, or its average frame without. The pointer shows an interval's times, and a click asks the
/// profiler for its longest CPU frame, or its longest GPU frame when the GPU line is nearer.
/// </summary>
sealed class FrameGraph : Control
{
    static readonly IBrush Background = new SolidColorBrush(Color.FromArgb(0x60, 0x10, 0x10, 0x12));
    static readonly IBrush CpuBrush = new SolidColorBrush(Color.Parse("#E34234"));
    static readonly IBrush GpuBrush = new SolidColorBrush(Color.Parse("#3FB8AF"));
    static readonly IBrush WaitBrush = new SolidColorBrush(Color.Parse("#D9A441"));
    static readonly IPen Cpu = new Pen(CpuBrush, 1.5);
    static readonly IPen Gpu = new Pen(GpuBrush, 1.5);
    static readonly IPen Wait = new Pen(WaitBrush, 1);
    static readonly IPen Longest = new Pen(new SolidColorBrush(Color.FromArgb(0x70, 0xE3, 0x42, 0x34)), 1);
    static readonly IPen Budget = new Pen(new SolidColorBrush(Color.FromArgb(0x50, 0xFF, 0xFF, 0xFF)), 1, new DashStyle([4, 4], 0));
    static readonly IPen Marker = new Pen(new SolidColorBrush(Color.FromArgb(0x60, 0xFF, 0xFF, 0xFF)), 1);
    static readonly Typeface Face = new("Inter");

    readonly ResourceStats _stats;
    readonly Action<ulong>? _capture;
    // The sample under the pointer, or -1.
    int _hover = -1;

    public FrameGraph(ResourceStats stats, Action<ulong>? capture)
    {
        _stats = stats;
        _capture = capture;
        if (capture != null)
        {
            Cursor = new Cursor(StandardCursorType.Hand);
        }
    }

    static FormattedText Text(string text, IBrush brush) =>
        new(text, System.Globalization.CultureInfo.InvariantCulture, FlowDirection.LeftToRight, Face, 10, brush);

    // The scale reaches the longest frame, and at least two 60 Hz frames, so a steady 16.7 ms sits in the middle.
    static double Top(FrameSample[] samples) => Math.Max(samples.Length == 0 ? 0 : samples.Max(s => s.MaxMs), 1000.0 / 30) * 1.1;

    double Step => Bounds.Width / (ResourceStats.HistoryLength - 1);

    double StartX(int count) => Bounds.Width - (count - 1) * Step;

    int SampleAt(double x, int count)
    {
        if (count == 0)
        {
            return -1;
        }
        var i = (int)Math.Round((x - StartX(count)) / Step);
        return i >= 0 && i < count ? i : -1;
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        var hover = SampleAt(e.GetPosition(this).X, _stats.History.Count);
        if (hover != _hover)
        {
            _hover = hover;
            InvalidateVisual();
        }
    }

    protected override void OnPointerExited(PointerEventArgs e)
    {
        base.OnPointerExited(e);
        _hover = -1;
        InvalidateVisual();
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        var samples = _stats.History.ToArray();
        var position = e.GetPosition(this);
        var i = SampleAt(position.X, samples.Length);
        if (_capture == null || i < 0 || !samples[i].Profiled)
        {
            return;
        }
        var s = samples[i];
        var ms = (Bounds.Height - position.Y) / Bounds.Height * Top(samples);
        var gpuNearer = Math.Abs(ms - s.GpuMs) < Math.Abs(ms - s.CpuMs);
        var frame = gpuNearer && s.GpuWorstFrame != 0 ? s.GpuWorstFrame : s.CpuWorstFrame;
        if (frame != 0)
        {
            _capture(frame);
            e.Handled = true;
        }
    }

    public override void Render(DrawingContext context)
    {
        var size = Bounds.Size;
        context.FillRectangle(Background, new Rect(size));
        var samples = _stats.History.ToArray();
        var top = Top(samples);
        double Y(double ms) => size.Height - ms / top * size.Height;
        foreach (var (ms, label) in new[] { (1000.0 / 60, "16.7 ms"), (1000.0 / 30, "33.3 ms") })
        {
            var y = Y(ms);
            context.DrawLine(Budget, new Point(0, y), new Point(size.Width, y));
            context.DrawText(Text(label, Brushes.Gray), new Point(4, y - 13));
        }
        if (samples.Length < 2)
        {
            return;
        }
        var step = Step;
        var start = StartX(samples.Length);
        // A line has a gap where value has none, such as the GPU line before the profiler's first summary.
        void Line(IPen pen, Func<FrameSample, double?> value)
        {
            var geometry = new StreamGeometry();
            using (var g = geometry.Open())
            {
                var open = false;
                for (var i = 0; i < samples.Length; i++)
                {
                    if (value(samples[i]) is not { } v)
                    {
                        if (open)
                        {
                            g.EndFigure(false);
                        }
                        open = false;
                        continue;
                    }
                    var p = new Point(start + i * step, Y(v));
                    if (open)
                    {
                        g.LineTo(p);
                    }
                    else
                    {
                        g.BeginFigure(p, false);
                        open = true;
                    }
                }
                if (open)
                {
                    g.EndFigure(false);
                }
            }
            context.DrawGeometry(null, pen, geometry);
        }
        Line(Longest, s => s.MaxMs);
        Line(Wait, s => s.Profiled ? s.WaitMs : null);
        Line(Gpu, s => s.Profiled && s.GpuMs > 0 ? s.GpuMs : null);
        Line(Cpu, s => s.Profiled ? s.CpuMs : s.AverageMs);

        if (_hover >= 0 && _hover < samples.Length)
        {
            var s = samples[_hover];
            var x = start + _hover * step;
            context.DrawLine(Marker, new Point(x, 0), new Point(x, size.Height));
            (string, IBrush)[] lines = s.Profiled
                ? [($"longest {s.MaxMs:0.0} ms", Brushes.Gray), ($"CPU {s.CpuMs:0.0} ms", CpuBrush), ($"GPU {s.GpuMs:0.0} ms", GpuBrush), ($"wait {s.WaitMs:0.0} ms", WaitBrush)]
                : [($"longest {s.MaxMs:0.0} ms", Brushes.Gray), ($"frame {s.AverageMs:0.0} ms", CpuBrush)];
            var texts = lines.Select(l => Text(l.Item1, l.Item2)).ToArray();
            var width = texts.Max(t => t.Width) + 8;
            var left = x + 6 + width < size.Width ? x + 6 : x - 6 - width;
            context.FillRectangle(Background, new Rect(left, 4, width, texts.Length * 13 + 4));
            for (var i = 0; i < texts.Length; i++)
            {
                context.DrawText(texts[i], new Point(left + 4, 6 + i * 13));
            }
        }
    }
}
