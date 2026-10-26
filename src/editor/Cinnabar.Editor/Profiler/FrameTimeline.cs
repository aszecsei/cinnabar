using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Profiler;

/// <summary>
/// A captured frame as a flame chart (see docs/editor/shell-and-panels.md#profiler): a lane for each thread, with its
/// zones in rows by depth, and a lane for each GPU queue with its passes. The wheel zooms around the pointer, Shift and
/// the wheel scroll the lanes, a drag pans, a click selects a zone, a double click zooms to it, and F fits the frame.
/// </summary>
public sealed class FrameTimeline : Control
{
    const double Gutter = 120;
    const double RulerHeight = 20;
    const double RowHeight = 18;
    const double LaneGap = 8;
    const double LaneHeader = 16;
    // A press must move this far, in pixels, before it pans instead of selecting.
    const double ClickSlop = 4;
    const double LabelMinWidth = 28;

    static readonly IBrush Background = new SolidColorBrush(Color.Parse("#1B1B1E"));
    static readonly IBrush GutterBrush = new SolidColorBrush(Color.Parse("#232327"));
    static readonly IBrush LaneBand = new SolidColorBrush(Color.FromArgb(0x10, 0xFF, 0xFF, 0xFF));
    static readonly IBrush TextBrush = new SolidColorBrush(Color.Parse("#E6E6E6"));
    static readonly IBrush DimText = new SolidColorBrush(Color.Parse("#9A9AA2"));
    static readonly IBrush ZoneText = new SolidColorBrush(Color.Parse("#101012"));
    static readonly IBrush TooltipBrush = new SolidColorBrush(Color.FromArgb(0xF0, 0x2A, 0x2A, 0x30));
    static readonly IPen FramePen = new Pen(new SolidColorBrush(Color.FromArgb(0x90, 0xFF, 0xFF, 0xFF)), 1);
    static readonly IPen GpuPen = new Pen(new SolidColorBrush(Color.FromArgb(0xA0, 0x3F, 0xB8, 0xAF)), 1, new DashStyle([3, 3], 0));
    static readonly IPen TickPen = new Pen(new SolidColorBrush(Color.FromArgb(0x30, 0xFF, 0xFF, 0xFF)), 1);
    static readonly IPen SelectedPen = new Pen(Brushes.White, 2);
    static readonly IPen HoverPen = new Pen(new SolidColorBrush(Color.FromArgb(0xC0, 0xFF, 0xFF, 0xFF)), 1);
    static readonly IPen HighlightPen = new Pen(new SolidColorBrush(Color.Parse("#FFD24A")), 1.5);
    static readonly IBrush CutBrush = new SolidColorBrush(Color.FromArgb(0xC0, 0xFF, 0xFF, 0xFF));
    static readonly Typeface Face = new("Inter");

    readonly ProfilerModel _model;
    readonly Dictionary<string, FormattedText> _labels = [];
    TimelineView _view = new(0, 1000);
    double _scroll;
    FrameCapture? _shown;
    CapturedZone? _hover;
    Point _pointer;
    // The press of a gesture: where it started, and whether it moved far enough to pan.
    Point? _press;
    bool _panning;

    public FrameTimeline(ProfilerModel model)
    {
        _model = model;
        Focusable = true;
        ClipToBounds = true;
    }

    /// <summary>The zone that a click selected, which the panel's details show.</summary>
    public CapturedZone? Selected { get; private set; }

    public event Action? SelectionChanged;

    /// <summary>Shows the model's capture. A new capture is fitted, and the selection goes.</summary>
    public void Refresh()
    {
        if (!ReferenceEquals(_shown, _model.Capture))
        {
            _shown = _model.Capture;
            _scroll = 0;
            _hover = null;
            Select(null);
            Fit();
        }
        InvalidateVisual();
    }

    public void Fit()
    {
        if (_shown is { } c)
        {
            var (start, end) = c.Extent;
            // The frame itself fills the view; zones of the neighbouring frames that overlap it stay reachable by panning.
            _view = TimelineView.Fit(Math.Max(start, -c.FrameNs / 20), Math.Min(end, c.FrameNs + c.FrameNs / 20), ViewWidth());
        }
        InvalidateVisual();
    }

    double ViewWidth() => Math.Max(Bounds.Width - Gutter, 1);

    void Select(CapturedZone? zone)
    {
        if (!ReferenceEquals(Selected, zone))
        {
            Selected = zone;
            SelectionChanged?.Invoke();
        }
    }

    // The lanes that the timeline shows, with each one's top and height in content coordinates. A thread that ran
    // nothing in the frame has no lane.
    List<(CaptureLane Lane, int Index, double Top, double Height)> Layout()
    {
        var result = new List<(CaptureLane, int, double, double)>();
        if (_shown is not { } c)
        {
            return result;
        }
        var y = RulerHeight;
        for (var i = 0; i < c.Lanes.Count; i++)
        {
            var lane = c.Lanes[i];
            if (lane.Rows.Count == 0 && !lane.IsGpu)
            {
                continue;
            }
            var height = LaneHeader + Math.Max(lane.Rows.Count, 1) * RowHeight;
            result.Add((lane, i, y, height));
            y += height + LaneGap;
        }
        return result;
    }

    double ContentHeight()
    {
        var lanes = Layout();
        return lanes.Count == 0 ? 0 : lanes[^1].Top + lanes[^1].Height + LaneGap;
    }

    static IBrush Fill(CapturedZone zone, bool dim)
    {
        var (h, s, l) = zone.Category switch
        {
            ProfileCategory.Wait => (40.0, 0.15, 0.45),
            ProfileCategory.Job => (220.0, 0.15, 0.5),
            ProfileCategory.System => (140.0, 0.45, 0.55),
            ProfileCategory.Script => (275.0, 0.45, 0.65),
            ProfileCategory.Render => (200.0, 0.5, 0.6),
            ProfileCategory.Gpu => (175.0, 0.5, 0.55),
            ProfileCategory.Asset => (30.0, 0.55, 0.6),
            ProfileCategory.Editor => (330.0, 0.35, 0.65),
            ProfileCategory.User => (55.0, 0.6, 0.6),
            _ => (10.0, 0.45, 0.62),
        };
        // Names vary the hue a little, so neighbours of one category stay apart.
        var hash = 0u;
        foreach (var ch in zone.Name)
        {
            hash = hash * 31 + ch;
        }
        h += (hash % 21) - 10;
        l += ((hash / 21) % 7 - 3) * 0.02;
        if ((zone.Flags & ZoneFlags.Job) != 0)
        {
            s *= 0.4;
            l *= 0.75;
        }
        var color = Hsl(h, s, l);
        return new SolidColorBrush(dim ? Color.FromArgb(0x80, color.R, color.G, color.B) : color);
    }

    static Color Hsl(double h, double s, double l)
    {
        h = ((h % 360) + 360) % 360 / 360;
        double Channel(double t)
        {
            t = (t % 1 + 1) % 1;
            var q = l < 0.5 ? l * (1 + s) : l + s - l * s;
            var p = 2 * l - q;
            return t < 1.0 / 6 ? p + (q - p) * 6 * t : t < 0.5 ? q : t < 2.0 / 3 ? p + (q - p) * (2.0 / 3 - t) * 6 : p;
        }
        return Color.FromRgb((byte)(255 * Channel(h + 1.0 / 3)), (byte)(255 * Channel(h)), (byte)(255 * Channel(h - 1.0 / 3)));
    }

    static FormattedText Text(string text, IBrush brush, double size = 11) =>
        new(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, Face, size, brush);

    FormattedText Label(string name)
    {
        if (!_labels.TryGetValue(name, out var text))
        {
            text = Text(name, ZoneText);
            _labels[name] = text;
        }
        return text;
    }

    public override void Render(DrawingContext context)
    {
        var size = Bounds.Size;
        context.FillRectangle(Background, new Rect(size));
        if (_shown is not { } c)
        {
            return;
        }
        var width = ViewWidth();
        var view = _view;
        double X(double ns) => Gutter + view.X(ns);
        var startNs = view.Ns(0);
        var endNs = view.Ns(width);
        var lanes = Layout();

        using (context.PushClip(new Rect(Gutter, 0, width, size.Height)))
        {
            var spacing = TimelineGeometry.TickSpacing(view.NsPerPixel);
            for (var t = Math.Floor(startNs / spacing) * spacing; t <= endNs; t += spacing)
            {
                var x = X(t);
                context.DrawLine(TickPen, new Point(x, RulerHeight), new Point(x, size.Height));
                context.DrawText(Text(TimelineGeometry.Duration(t), DimText, 10), new Point(x + 3, 3));
            }
            foreach (var lane in lanes)
            {
                var top = lane.Top - _scroll;
                if (top > size.Height || top + lane.Height < RulerHeight)
                {
                    continue;
                }
                context.FillRectangle(LaneBand, new Rect(Gutter, top, width, lane.Height));
                for (var d = 0; d < lane.Lane.Rows.Count; d++)
                {
                    DrawRow(context, lane.Lane, d, top + LaneHeader + d * RowHeight, startNs, endNs, X);
                }
            }
            context.DrawLine(FramePen, new Point(X(0), RulerHeight), new Point(X(0), size.Height));
            context.DrawLine(FramePen, new Point(X(c.FrameNs), RulerHeight), new Point(X(c.FrameNs), size.Height));
            if (c.HasGpu)
            {
                context.DrawLine(GpuPen, new Point(X(c.Message.GpuBegin), RulerHeight), new Point(X(c.Message.GpuBegin), size.Height));
                context.DrawLine(GpuPen, new Point(X(c.Message.GpuEnd), RulerHeight), new Point(X(c.Message.GpuEnd), size.Height));
            }
            if (Selected is { } selected)
            {
                foreach (var z in c.Segments(selected))
                {
                    Outline(context, z, lanes, SelectedPen, X);
                }
            }
            if (_hover is { } hover && !ReferenceEquals(hover, Selected))
            {
                foreach (var z in c.Segments(hover))
                {
                    Outline(context, z, lanes, HoverPen, X);
                }
            }
        }

        context.FillRectangle(GutterBrush, new Rect(0, 0, Gutter, size.Height));
        context.DrawText(Text($"frame {c.Frame}", DimText, 10), new Point(6, 3));
        foreach (var lane in lanes)
        {
            var top = lane.Top - _scroll;
            if (top + LaneHeader < RulerHeight || top > size.Height)
            {
                continue;
            }
            context.DrawText(Text(lane.Lane.Name, TextBrush), new Point(6, top + 1));
            var note = lane.Lane.IsGpu
                ? lane.Lane.Kind == ProfileLaneKind.GpuGraphics && c.HasGpu ? $"{c.GpuMs:0.00} ms" : ""
                : $"{lane.Lane.Busy * 100:0}% busy";
            context.DrawText(Text(note, DimText, 10), new Point(6, top + 15));
        }
        if (_hover is { } tip && _press == null)
        {
            DrawTooltip(context, tip, c);
        }
    }

    void DrawRow(DrawingContext context, CaptureLane lane, int depth, double y, double startNs, double endNs, Func<double, double> x)
    {
        var row = lane.Rows[depth];
        var spans = new List<(double, double)>();
        var first = lane.FirstReaching(depth, (long)startNs);
        var last = first;
        for (; last < row.Count && row[last].Start < endNs; last++)
        {
            spans.Add((x(row[last].Start), x(row[last].End)));
        }
        foreach (var run in TimelineGeometry.Runs(spans))
        {
            var zone = row[first + run.First];
            var rect = new Rect(run.X0, y + 1, Math.Max(run.X1 - run.X0, 1), RowHeight - 2);
            var highlighted = _model.Highlight != null && (run.Count == 1 ? zone.Name == _model.Highlight : RunHas(row, first + run.First, run.Count, _model.Highlight));
            context.FillRectangle(Fill(zone, run.Count > 1), rect);
            if (highlighted)
            {
                context.DrawRectangle(HighlightPen, rect.Deflate(0.75));
            }
            if (run.Count > 1)
            {
                continue;
            }
            // A cut where the zone's fiber waited.
            if ((zone.Flags & ZoneFlags.Suspended) != 0)
            {
                context.FillRectangle(CutBrush, new Rect(rect.Right - 2, rect.Y, 2, rect.Height));
            }
            if ((zone.Flags & ZoneFlags.Resumed) != 0)
            {
                context.FillRectangle(CutBrush, new Rect(rect.X, rect.Y, 2, rect.Height));
            }
            if (rect.Width >= LabelMinWidth)
            {
                var label = Label(zone.Name);
                using (context.PushClip(rect.Deflate(new Thickness(3, 0))))
                {
                    var left = Math.Max(rect.X, Gutter) + 3;
                    context.DrawText(label, new Point(left, y + (RowHeight - label.Height) / 2));
                }
            }
        }
    }

    static bool RunHas(IReadOnlyList<CapturedZone> row, int first, int count, string name)
    {
        for (var i = first; i < first + count; i++)
        {
            if (row[i].Name == name)
            {
                return true;
            }
        }
        return false;
    }

    void Outline(DrawingContext context, CapturedZone zone, List<(CaptureLane Lane, int Index, double Top, double Height)> lanes, IPen pen, Func<double, double> x)
    {
        foreach (var lane in lanes)
        {
            if (lane.Index == zone.Lane)
            {
                var y = lane.Top - _scroll + LaneHeader + zone.Depth * RowHeight;
                context.DrawRectangle(pen, new Rect(x(zone.Start), y + 1, Math.Max(x(zone.End) - x(zone.Start), 1), RowHeight - 2));
            }
        }
    }

    void DrawTooltip(DrawingContext context, CapturedZone zone, FrameCapture c)
    {
        var lines = new List<string>
        {
            zone.Callback != ProfileCallback.None ? $"{zone.Name}:{ProfilerModel.CallbackName(zone.Callback)}" : zone.Name,
            $"{TimelineGeometry.Duration(zone.Duration)}, self {TimelineGeometry.Duration(zone.Self)}",
            $"at {TimelineGeometry.Duration(zone.Start)} · {c.Lanes[zone.Lane].Name} · {zone.Category}",
        };
        if (zone.Split)
        {
            var segments = c.Segments(zone).ToList();
            var total = segments.Sum(s => s.Duration);
            lines.Add($"waited: {segments.Count} segments, {TimelineGeometry.Duration(total)} running");
        }
        if ((zone.Flags & ZoneFlags.Job) != 0)
        {
            lines.Add("a job, named after the zone that started it");
        }
        if ((zone.Flags & ZoneFlags.Unbalanced) != 0)
        {
            lines.Add("closed by the profiler: its code left it open");
        }
        var texts = lines.Select((l, i) => Text(l, i == 0 ? TextBrush : DimText)).ToList();
        var width = texts.Max(t => t.Width) + 12;
        var height = texts.Sum(t => t.Height) + 8;
        var x = Math.Min(_pointer.X + 14, Bounds.Width - width - 2);
        var y = _pointer.Y + 18 + height < Bounds.Height ? _pointer.Y + 18 : _pointer.Y - height - 6;
        context.FillRectangle(TooltipBrush, new Rect(x, y, width, height), 3);
        foreach (var t in texts)
        {
            context.DrawText(t, new Point(x + 6, y + 4));
            y += t.Height;
        }
    }

    CapturedZone? HitTest(Point p)
    {
        if (_shown is null || p.X < Gutter || p.Y < RulerHeight)
        {
            return null;
        }
        var ns = _view.Ns(p.X - Gutter);
        // A zone narrower than a few pixels is still hit when the pointer is near it.
        var slop = (long)(_view.NsPerPixel * 2);
        foreach (var lane in Layout())
        {
            var depth = (int)Math.Floor((p.Y + _scroll - lane.Top - LaneHeader) / RowHeight);
            if (depth < 0 || depth >= lane.Lane.Rows.Count || p.Y + _scroll >= lane.Top + lane.Height)
            {
                continue;
            }
            return lane.Lane.At(depth, (long)ns) ?? lane.Lane.At(depth, (long)ns - slop) ?? lane.Lane.At(depth, (long)ns + slop);
        }
        return null;
    }

    void ClampScroll() => _scroll = Math.Clamp(_scroll, 0, Math.Max(ContentHeight() - Bounds.Height, 0));

    protected override void OnPointerWheelChanged(PointerWheelEventArgs e)
    {
        base.OnPointerWheelChanged(e);
        if (_shown is null)
        {
            return;
        }
        if (e.KeyModifiers.HasFlag(KeyModifiers.Shift))
        {
            _scroll -= e.Delta.Y * RowHeight * 3;
            ClampScroll();
        }
        else
        {
            var x = Math.Max(e.GetPosition(this).X - Gutter, 0);
            _view = _view.ZoomAbout(x, Math.Pow(1.25, -e.Delta.Y));
        }
        InvalidateVisual();
        e.Handled = true;
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        Focus();
        var point = e.GetCurrentPoint(this);
        if (e.ClickCount == 2 && point.Properties.IsLeftButtonPressed && HitTest(point.Position) is { } zone)
        {
            Select(zone);
            _view = TimelineView.Fit(zone.Start, zone.End, ViewWidth());
            InvalidateVisual();
            e.Handled = true;
            return;
        }
        _press = _pointer = point.Position;
        _panning = point.Properties.IsMiddleButtonPressed;
        e.Pointer.Capture(this);
        e.Handled = true;
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        var position = e.GetPosition(this);
        var delta = position - _pointer;
        _pointer = position;
        if (_press is { } press)
        {
            var moved = position - press;
            if (!_panning && Math.Sqrt(moved.X * moved.X + moved.Y * moved.Y) > ClickSlop)
            {
                _panning = true;
            }
            if (_panning)
            {
                _view = _view.Pan(delta.X);
                _scroll -= delta.Y;
                ClampScroll();
            }
        }
        else
        {
            _hover = HitTest(position);
        }
        InvalidateVisual();
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);
        if (_press != null && !_panning)
        {
            Select(HitTest(e.GetPosition(this)));
        }
        _press = null;
        _panning = false;
        e.Pointer.Capture(null);
        InvalidateVisual();
    }

    protected override void OnPointerExited(PointerEventArgs e)
    {
        base.OnPointerExited(e);
        _hover = null;
        InvalidateVisual();
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        switch (e.Key)
        {
            case Key.F when e.KeyModifiers == KeyModifiers.None:
                Fit();
                break;
            case Key.Escape:
                Select(null);
                InvalidateVisual();
                break;
            default:
                return;
        }
        e.Handled = true;
    }

    protected override void OnSizeChanged(SizeChangedEventArgs e)
    {
        base.OnSizeChanged(e);
        // The first layout of a capture has no width to fit it to yet.
        if (e.PreviousSize.Width <= Gutter && _shown != null)
        {
            Fit();
        }
        ClampScroll();
    }
}
