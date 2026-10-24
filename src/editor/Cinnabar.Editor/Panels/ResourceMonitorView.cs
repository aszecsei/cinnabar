using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// The resource monitor (see docs/editor.md#resource-monitor): the frame times of the last minute as a graph, the
/// host's memory and GPU resources, and the world's entities and the scripts' memory by module. The host and the game
/// send their stats four times a second while the link is up.
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

    public ResourceMonitorView(ResourceStats stats)
    {
        _stats = stats;
        _graph = new FrameGraph(stats) { Height = 110, MinWidth = 240 };
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
            _frames.Text = $"{fps:0} fps   ·   frame {h.FrameMsAverage:0.0} ms, longest {h.FrameMsMax:0.0} ms   ·   work {h.WorkMsAverage:0.0} ms";
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

/// <summary>The frame times of the last minute: each interval's longest frame, faint, and its average over it.</summary>
sealed class FrameGraph(ResourceStats stats) : Control
{
    static readonly IBrush Background = new SolidColorBrush(Color.FromArgb(0x60, 0x10, 0x10, 0x12));
    static readonly IPen Average = new Pen(new SolidColorBrush(Color.Parse("#E34234")), 1.5);
    static readonly IPen Longest = new Pen(new SolidColorBrush(Color.FromArgb(0x70, 0xE3, 0x42, 0x34)), 1);
    static readonly IPen Budget = new Pen(new SolidColorBrush(Color.FromArgb(0x50, 0xFF, 0xFF, 0xFF)), 1, new DashStyle([4, 4], 0));
    static readonly Typeface Face = new("Inter");

    public override void Render(DrawingContext context)
    {
        var size = Bounds.Size;
        context.FillRectangle(Background, new Rect(size));
        var samples = stats.History.ToArray();
        // The scale reaches the longest frame, and at least two 60 Hz frames, so a steady 16.7 ms sits in the middle.
        var top = Math.Max(samples.Length == 0 ? 0 : samples.Max(s => s.MaxMs), 1000.0 / 30) * 1.1;
        double Y(double ms) => size.Height - ms / top * size.Height;
        var budget = Y(1000.0 / 60);
        context.DrawLine(Budget, new Point(0, budget), new Point(size.Width, budget));
        context.DrawText(new FormattedText("16.7 ms", System.Globalization.CultureInfo.InvariantCulture, FlowDirection.LeftToRight, Face, 10, Brushes.Gray),
            new Point(4, budget - 13));
        if (samples.Length < 2)
        {
            return;
        }
        var step = size.Width / (ResourceStats.HistoryLength - 1);
        var start = size.Width - (samples.Length - 1) * step;
        void Line(IPen pen, Func<FrameSample, double> value)
        {
            var geometry = new StreamGeometry();
            using (var g = geometry.Open())
            {
                g.BeginFigure(new Point(start, Y(value(samples[0]))), false);
                for (var i = 1; i < samples.Length; i++)
                {
                    g.LineTo(new Point(start + i * step, Y(value(samples[i]))));
                }
                g.EndFigure(false);
            }
            context.DrawGeometry(null, pen, geometry);
        }
        Line(Longest, s => s.MaxMs);
        Line(Average, s => s.AverageMs);
    }
}
