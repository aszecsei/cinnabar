using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using Layout = Cinnabar.Editor.Tools.CutsceneTimelineLayout;

namespace Cinnabar.Editor.Cutscenes;

/// <summary>
/// The curve editor below the timeline (see docs/editor/cutscene-editor.md#curves): the list of the curves that the
/// selection shows on the left, as wide as the timeline's headers, and the curves on the timeline's time, with their
/// keys, the selected keys' handles, the markers and the playhead. It passes its input to a
/// <see cref="CutsceneCurveInput"/>.
/// </summary>
sealed class CutsceneCurveEditor : Control
{
    static readonly IBrush Background = new SolidColorBrush(Color.Parse("#17171A"));
    static readonly IBrush ListBackground = new SolidColorBrush(Color.Parse("#202024"));
    static readonly IBrush TextBrush = new SolidColorBrush(Color.Parse("#E6E6E6"));
    static readonly IBrush DimText = new SolidColorBrush(Color.Parse("#7A7A82"));
    static readonly IBrush LabelBrush = new SolidColorBrush(Color.FromArgb(0x90, 0xE6, 0xE6, 0xE6));
    static readonly IBrush TooltipBrush = new SolidColorBrush(Color.FromArgb(0xF0, 0x2A, 0x2A, 0x30));
    static readonly IBrush BoxBrush = new SolidColorBrush(Color.FromArgb(0x30, 0x9C, 0xC0, 0xF0));
    static readonly IPen BoxPen = new Pen(new SolidColorBrush(Color.FromArgb(0xA0, 0x9C, 0xC0, 0xF0)), 1);
    static readonly IPen GridPen = new Pen(new SolidColorBrush(Color.FromArgb(0x20, 0xFF, 0xFF, 0xFF)), 1);
    static readonly IPen ZeroPen = new Pen(new SolidColorBrush(Color.FromArgb(0x50, 0xFF, 0xFF, 0xFF)), 1);
    static readonly IPen PlayheadPen = new Pen(new SolidColorBrush(Color.Parse("#E5534B")), 1.5);
    static readonly IPen GuidePen = new Pen(new SolidColorBrush(Color.Parse("#FFD24A")), 1, new DashStyle([4, 3], 0));
    static readonly IPen HandlePen = new Pen(new SolidColorBrush(Color.FromArgb(0xC0, 0xE6, 0xE6, 0xE6)), 1);
    static readonly IBrush SelectedKey = new SolidColorBrush(Color.Parse("#FFD24A"));
    static readonly IPen KeyPen = new Pen(new SolidColorBrush(Color.Parse("#101012")), 1);
    static readonly IBrush MarkerBrush = new SolidColorBrush(Color.FromArgb(0x50, 0xF5, 0xA6, 0x23));
    static readonly Typeface Face = new("Inter");

    readonly CutsceneEditor _editor;
    readonly Dictionary<string, FormattedText> _texts = [];
    readonly Dictionary<uint, (IPen Line, IPen Dim, IBrush Fill, IPen Outside)> _colors = [];
    CutscenePaneFocus? _focus;

    public CutsceneCurveEditor(CutsceneEditor editor)
    {
        _editor = editor;
        Input = new CutsceneCurveInput(editor);
        Focusable = true;
        ClipToBounds = true;
        Input.Invalidated += InvalidateVisual;
        void Changed() => Input.Refresh();
        void Redraw() => InvalidateVisual();
        void Frame() => Input.Frame();
        new ViewSubscriptions(this, attached: Input.Refresh)
            .Add(() => _editor.Changed += Changed, () => _editor.Changed -= Changed)
            .Add(() => _editor.TimeViewChanged += Redraw, () => _editor.TimeViewChanged -= Redraw)
            .Add(() => _editor.PlayheadChanged += Redraw, () => _editor.PlayheadChanged -= Redraw)
            .Add(() => _editor.FrameCurvesRequested += Frame, () => _editor.FrameCurvesRequested -= Frame);
    }

    public CutsceneCurveInput Input { get; }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        _focus = new CutscenePaneFocus(this, _editor, CutscenePane.Curves);
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        _focus?.Dispose();
        _focus = null;
        base.OnDetachedFromVisualTree(e);
    }

    FormattedText Text(string text, IBrush brush, double size = 11)
    {
        var key = $"{text}\u0001{brush.GetHashCode()}\u0001{size}";
        if (!_texts.TryGetValue(key, out var formatted))
        {
            if (_texts.Count > 4096)
            {
                _texts.Clear();
            }
            formatted = new FormattedText(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, Face, size, brush);
            _texts[key] = formatted;
        }
        return formatted;
    }

    (IPen Line, IPen Dim, IBrush Fill, IPen Outside) Colors(uint argb)
    {
        if (!_colors.TryGetValue(argb, out var c))
        {
            var color = Color.FromUInt32(argb);
            var brush = new SolidColorBrush(color);
            var dim = new SolidColorBrush(Color.FromArgb(0x60, color.R, color.G, color.B));
            c = (new Pen(brush, 1.5), new Pen(dim, 1.5), brush, new Pen(brush, 1.5, new DashStyle([4, 3], 0)));
            _colors[argb] = c;
        }
        return c;
    }

    // A round step for grid lines about pixels apart: 1, 2 or 5 times a power of ten.
    static double NiceStep(double perPixel, double pixels)
    {
        var raw = perPixel * pixels;
        var power = Math.Pow(10, Math.Floor(Math.Log10(raw)));
        return raw / power < 2 ? 2 * power : raw / power < 5 ? 5 * power : 10 * power;
    }

    public override void Render(DrawingContext context)
    {
        var size = Bounds.Size;
        context.FillRectangle(Background, new Rect(size));
        var gutter = Layout.Gutter;
        var width = Input.TimeWidth;
        var view = Input.View;
        var layout = Input.Layout;
        var selected = Input.Selected;
        double X(double tick) => gutter + view.Time.X(tick);

        using (context.PushClip(new Rect(gutter, 0, width, size.Height)))
        {
            // The value grid, with 0 brighter, and the time grid on frames.
            var step = NiceStep(view.Value.PerPixel, 40);
            var top = view.Value.At(0);
            for (var v = Math.Floor(view.Value.At(size.Height) / step) * step; v <= top; v += step)
            {
                var y = view.Value.Y(v);
                context.DrawLine(Math.Abs(v) < step / 2 ? ZeroPen : GridPen, new Point(gutter, y), new Point(gutter + width, y));
                context.DrawText(Text(CutsceneKeying.Format(Math.Round(v / step) * step), LabelBrush, 10), new Point(gutter + 4, y - 13));
            }
            var spacing = TimelineGeometry.FrameSpacing(view.Time.PerPixel, _editor.FrameTicks);
            for (var t = Math.Floor(Math.Max(view.Time.At(0), 0) / spacing) * spacing; t <= view.Time.At(width); t += spacing)
            {
                context.DrawLine(GridPen, new Point(X(t), 0), new Point(X(t), size.Height));
            }
            foreach (var marker in _editor.File.Markers)
            {
                if (marker.Start is { } m)
                {
                    context.DrawLine(new Pen(MarkerBrush, 1), new Point(X(m), 0), new Point(X(m), size.Height));
                }
            }
            foreach (var row in layout.Rows)
            {
                DrawCurve(context, row, view, width, selected);
            }
            if (Input.Guide is { } guide)
            {
                context.DrawLine(GuidePen, new Point(X(guide), 0), new Point(X(guide), size.Height));
            }
            var playhead = X(_editor.Playhead);
            context.DrawLine(PlayheadPen, new Point(playhead, 0), new Point(playhead, size.Height));
            if (Input.Box is { } box)
            {
                var rect = new Rect(box.From, box.To).Normalize();
                context.FillRectangle(BoxBrush, rect);
                context.DrawRectangle(BoxPen, rect);
            }
            if (layout.Rows.Count == 0)
            {
                var hint = Text(_editor.ShownCurves.Count == 0 ? "Select a track, a section or keys to see their curves." : "Every curve here is hidden.", DimText);
                context.DrawText(hint, new Point(gutter + (width - hint.Width) / 2, (size.Height - hint.Height) / 2));
            }
        }

        DrawList(context, size);
        if (Input.Tooltip is { } tip)
        {
            var text = Text(tip, TextBrush);
            var p = Input.Pointer;
            var x = Math.Min(p.X + 14, size.Width - text.Width - 14);
            var y = p.Y + 36 < size.Height ? p.Y + 18 : p.Y - text.Height - 14;
            context.FillRectangle(TooltipBrush, new Rect(x, y, text.Width + 12, text.Height + 6), 3);
            context.DrawText(text, new Point(x + 6, y + 3));
        }
    }

    // A curve over its section, where it plays, dashed before its first key and after its last, where its infinity
    // decides; its keys; and the handles of its selected keys.
    void DrawCurve(DrawingContext context, CurveRow row, CurveView view, double width, IReadOnlySet<string> selected)
    {
        var (line, dim, fill, outside) = Colors(row.Color);
        int firstKey = row.TickOf(0), lastKey = row.TickOf(row.Keys.Count - 1);
        DrawPart(context, row, view, width, (row.Start, firstKey), row.Locked ? dim : outside);
        DrawPart(context, row, view, width, (firstKey, lastKey), row.Locked ? dim : line);
        DrawPart(context, row, view, width, (lastKey, row.End), row.Locked ? dim : outside);
        DrawKeys(context, row, view, width, selected, fill);
    }

    // A part of a curve, from and to on the cutscene's time.
    static void DrawPart(DrawingContext context, CurveRow row, CurveView view, double width, (int From, int To) part, IPen pen)
    {
        if (part.To <= part.From)
        {
            return;
        }
        var geometry = new StreamGeometry();
        using (var g = geometry.Open())
        {
            var first = true;
            foreach (var (px, py) in CutsceneCurveLayout.Samples(row, view, width, part))
            {
                var y = Math.Clamp(py, -10_000, 10_000);
                if (first)
                {
                    g.BeginFigure(new Point(px, y), false);
                    first = false;
                }
                else
                {
                    g.LineTo(new Point(px, y));
                }
            }
            if (!first)
            {
                g.EndFigure(false);
            }
        }
        context.DrawGeometry(null, pen, geometry);
    }

    // A curve's keys, and the handles of its selected keys.
    void DrawKeys(DrawingContext context, CurveRow row, CurveView view, double width, IReadOnlySet<string> selected, IBrush fill)
    {
        for (var i = 0; i < row.Keys.Count; i++)
        {
            var (kx, ky) = CutsceneCurveLayout.KeyPoint(row, i, view);
            if (kx < Layout.Gutter - 8 || kx > Layout.Gutter + width + 8)
            {
                continue;
            }
            var isSelected = selected.Contains(row.KeyPaths[i]);
            if (isSelected)
            {
                foreach (var side in (TangentSide[])[TangentSide.In, TangentSide.Out])
                {
                    if (row.HasHandle(i, side))
                    {
                        var (hx, hy) = CutsceneCurveLayout.HandlePoint(row, i, side, view);
                        context.DrawLine(HandlePen, new Point(kx, ky), new Point(hx, hy));
                        context.DrawEllipse(TextBrush, null, new Point(hx, hy), 3, 3);
                    }
                }
            }
            context.DrawRectangle(isSelected ? SelectedKey : fill, KeyPen, new Rect(kx - 3.5, ky - 3.5, 7, 7));
        }
    }

    // The curve list: each curve that the selection shows, with its colour, which is hollow while it is hidden.
    void DrawList(DrawingContext context, Size size)
    {
        context.FillRectangle(ListBackground, new Rect(0, 0, Layout.Gutter, size.Height));
        var rows = Input.List.Rows;
        for (var i = 0; i < rows.Count; i++)
        {
            var row = rows[i];
            var y = i * CutsceneCurveInput.ListRowHeight;
            var hidden = _editor.HiddenCurves.Contains(row.Path);
            var (line, _, fill, _) = Colors(row.Color);
            var swatch = new Rect(8, y + 6, 10, 8);
            if (hidden)
            {
                context.DrawRectangle(null, line, swatch);
            }
            else
            {
                context.FillRectangle(fill, swatch);
            }
            context.DrawText(Text(row.Name, hidden ? DimText : TextBrush), new Point(CutsceneCurveInput.EyeWidth + 4, y + 3));
        }
    }

    protected override void OnSizeChanged(SizeChangedEventArgs e)
    {
        base.OnSizeChanged(e);
        Input.Resize(e.NewSize.Width, e.NewSize.Height);
    }

    protected override void OnPointerWheelChanged(PointerWheelEventArgs e)
    {
        base.OnPointerWheelChanged(e);
        var p = e.GetPosition(this);
        Input.Wheel(p.X, p.Y, e.Delta.Y, e.KeyModifiers);
        e.Handled = true;
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        Focus();
        var point = e.GetCurrentPoint(this);
        var button = point.Properties.PointerUpdateKind switch
        {
            PointerUpdateKind.MiddleButtonPressed => MouseButton.Middle,
            PointerUpdateKind.RightButtonPressed => MouseButton.Right,
            _ => MouseButton.Left,
        };
        if (Input.Press(point.Position.X, point.Position.Y, button, e.KeyModifiers, e.ClickCount))
        {
            e.Pointer.Capture(this);
        }
        e.Handled = true;
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        var p = e.GetPosition(this);
        Input.Move(p.X, p.Y, e.KeyModifiers);
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);
        var p = e.GetPosition(this);
        Input.Release(p.X, p.Y, e.KeyModifiers, e.InitialPressMouseButton);
        e.Pointer.Capture(null);
    }

    protected override void OnPointerCaptureLost(PointerCaptureLostEventArgs e)
    {
        base.OnPointerCaptureLost(e);
        Input.LostCapture();
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (e.Key == Key.Escape && Input.Escape())
        {
            e.Handled = true;
        }
    }

    protected override void OnKeyUp(KeyEventArgs e)
    {
        base.OnKeyUp(e);
        // As in the timeline: a held nudge's release ends its entry, and Shuttle Pause's release ends its hold.
        _editor.EndNudge();
        if (_editor.ShuttlePauseShortcut is { } shortcut && KeyGesture.Parse(shortcut).Key == e.Key)
        {
            _editor.EndShuttleHold();
        }
    }
}
