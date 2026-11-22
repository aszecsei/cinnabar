using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Media;
using Avalonia.VisualTree;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Ribbon;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using Layout = Cinnabar.Editor.Tools.CutsceneTimelineLayout;

namespace Cinnabar.Editor.Cutscenes;

/// <summary>
/// The cutscene's timeline (see docs/editor/cutscene-editor.md#the-timeline): the headers of its bindings, tracks and
/// channels on the left, with each track's mute, solo and lock, the ruler with the markers, the range bar and the
/// playhead at the top, and the sections, events and keys on one time axis. It draws what <see cref="CutsceneTimelineLayout.Visible"/> gives, and passes its input to a
/// <see cref="CutsceneTimelineInput"/>.
/// </summary>
sealed class CutsceneTimeline : Control
{
    static readonly IBrush Background = new SolidColorBrush(Color.Parse("#1B1B1E"));
    static readonly IBrush GutterBrush = new SolidColorBrush(Color.Parse("#232327"));
    static readonly IBrush RulerBrush = new SolidColorBrush(Color.Parse("#26262B"));
    static readonly IBrush Band = new SolidColorBrush(Color.FromArgb(0x0C, 0xFF, 0xFF, 0xFF));
    static readonly IBrush SelectedRow = new SolidColorBrush(Color.FromArgb(0x50, 0x2F, 0x4F, 0x7F));
    static readonly IBrush PastLength = new SolidColorBrush(Color.FromArgb(0x70, 0x00, 0x00, 0x00));
    static readonly IBrush RangeBrush = new SolidColorBrush(Color.Parse("#4A6FA5"));
    static readonly IBrush HandleBrush = new SolidColorBrush(Color.Parse("#9CC0F0"));
    static readonly IBrush TextBrush = new SolidColorBrush(Color.Parse("#E6E6E6"));
    static readonly IBrush DimText = new SolidColorBrush(Color.Parse("#9A9AA2"));
    static readonly IBrush BarText = new SolidColorBrush(Color.Parse("#101012"));
    static readonly IBrush KeyBrush = new SolidColorBrush(Color.Parse("#E8E8EC"));
    static readonly IBrush SelectedKey = new SolidColorBrush(Color.Parse("#FFD24A"));
    static readonly IBrush ErrorBrush = new SolidColorBrush(Color.Parse("#E5534B"));
    static readonly IBrush TooltipBrush = new SolidColorBrush(Color.FromArgb(0xF0, 0x2A, 0x2A, 0x30));
    static readonly IBrush BoxBrush = new SolidColorBrush(Color.FromArgb(0x30, 0x9C, 0xC0, 0xF0));
    static readonly IPen BoxPen = new Pen(new SolidColorBrush(Color.FromArgb(0xA0, 0x9C, 0xC0, 0xF0)), 1);
    static readonly IPen TickPen = new Pen(new SolidColorBrush(Color.FromArgb(0x28, 0xFF, 0xFF, 0xFF)), 1);
    static readonly IPen SelectedPen = new Pen(Brushes.White, 2);
    static readonly IPen ErrorPen = new Pen(new SolidColorBrush(Color.Parse("#E5534B")), 1.5);
    static readonly IPen PlayheadPen = new Pen(new SolidColorBrush(Color.Parse("#E5534B")), 1.5);
    static readonly IPen GuidePen = new Pen(new SolidColorBrush(Color.Parse("#FFD24A")), 1, new DashStyle([4, 3], 0));
    static readonly IPen LengthPen = new Pen(new SolidColorBrush(Color.FromArgb(0xA0, 0xFF, 0xFF, 0xFF)), 1);
    static readonly IPen LockPen = new Pen(new SolidColorBrush(Color.Parse("#9A9AA2")), 1.2);
    static readonly IPen LockedPen = new Pen(new SolidColorBrush(Color.Parse("#FFD24A")), 1.2);
    static readonly IBrush SilentFill = new SolidColorBrush(Color.Parse("#4A4A50"));
    static readonly IBrush MutedBrush = new SolidColorBrush(Color.Parse("#E69138"));
    static readonly IBrush SoloBrush = new SolidColorBrush(Color.Parse("#FFD24A"));
    static readonly IPen StrikePen = new Pen(new SolidColorBrush(Color.Parse("#9A9AA2")), 1);
    static readonly IBrush MarkerDefault = new SolidColorBrush(Color.Parse("#F5A623"));
    static readonly Typeface Face = new("Inter");

    readonly CutsceneEditor _editor;
    readonly Dictionary<string, FormattedText> _texts = [];

    public CutsceneTimeline(CutsceneEditor editor)
    {
        _editor = editor;
        Input = new CutsceneTimelineInput(editor);
        Focusable = true;
        ClipToBounds = true;
        Input.Invalidated += InvalidateVisual;
        void Changed() => Input.Refresh();
        void Frame() => Input.Frame();
        void Playhead() => Input.ShowPlayhead();
        new ViewSubscriptions(this, attached: Input.Refresh)
            .Add(() => _editor.Changed += Changed, () => _editor.Changed -= Changed)
            .Add(() => _editor.ProblemsChanged += Changed, () => _editor.ProblemsChanged -= Changed)
            .Add(() => _editor.FrameRequested += Frame, () => _editor.FrameRequested -= Frame)
            .Add(() => _editor.PlayheadChanged += Playhead, () => _editor.PlayheadChanged -= Playhead);
    }

    public CutsceneTimelineInput Input { get; }

    // The timeline's commands act while the keyboard is here, or in the command palette that the timeline opened.
    void OnFocusChanged(object? sender, RoutedEventArgs e)
    {
        if (e.Source is not Visual focused)
        {
            return;
        }
        if (focused == this || focused.GetVisualAncestors().Contains(this))
        {
            _editor.TimelineFocused = true;
        }
        else if (!focused.GetVisualAncestors().OfType<CommandPalette>().Any() && focused is not CommandPalette)
        {
            _editor.TimelineFocused = false;
        }
    }

    // Another window, such as a floating panel, has the keyboard: the timeline's keys are that window's.
    void OnDeactivated(object? sender, EventArgs e) => _editor.TimelineFocused = false;

    // Back in this window, the keys are the timeline's when the focus is in it.
    void OnActivated(object? sender, EventArgs e) => _editor.TimelineFocused = IsKeyboardFocusWithin;

    // The window whose focus changes the timeline follows, kept so that a detach, when the timeline may no longer find
    // it, takes the handler off the same window.
    TopLevel? _window;

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        _window = TopLevel.GetTopLevel(this);
        _window?.AddHandler(GotFocusEvent, OnFocusChanged, RoutingStrategies.Bubble, handledEventsToo: true);
        if (_window is Window window)
        {
            window.Deactivated += OnDeactivated;
            window.Activated += OnActivated;
        }
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        _window?.RemoveHandler(GotFocusEvent, OnFocusChanged);
        if (_window is Window window)
        {
            window.Deactivated -= OnDeactivated;
            window.Activated -= OnActivated;
        }
        _window = null;
        _editor.TimelineFocused = false;
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

    static readonly Dictionary<(string?, bool), IBrush> Fills = [];

    static IBrush Fill(string? kind, bool dim)
    {
        if (!Fills.TryGetValue((kind, dim), out var brush))
        {
            brush = MakeFill(kind, dim);
            Fills[(kind, dim)] = brush;
        }
        return brush;
    }

    static IBrush MakeFill(string? kind, bool dim)
    {
        var color = Color.Parse(kind switch
        {
            "transform" => "#6FA8DC",
            "property" => "#8E7CC3",
            "animation" => "#93C47D",
            "camera_cut" => "#E69138",
            "audio" => "#45B5AA",
            "event" => "#F1C232",
            "sub_sequence" => "#C27BA0",
            "presentation" => "#A2A2A8",
            _ => "#888888",
        });
        return new SolidColorBrush(dim ? Color.FromArgb(0x70, color.R, color.G, color.B) : color);
    }

    string Units(int ticks) => _editor.ShowFrames
        ? CutsceneTime.Frames(ticks, _editor.File.Rate).ToString(CultureInfo.InvariantCulture)
        : CutsceneTime.Timecode(ticks, _editor.File.Rate);

    public override void Render(DrawingContext context)
    {
        var size = Bounds.Size;
        context.FillRectangle(Background, new Rect(size));
        var layout = Input.Layout;
        var view = Input.View;
        var gutter = Layout.Gutter;
        var width = Input.TimeWidth;
        double X(double tick) => gutter + view.X(tick);
        var selected = _editor.SelectedPaths.ToHashSet();
        var rows = layout.Visible(view, width, Input.ScrollY, size.Height);
        var problems = _editor.Problems.Where(p => p.Line > 0).Select(p => _editor.BlockAt(p.Line)).OfType<CutsceneBlock>()
            .Select(CutsceneFile.PathOf).ToHashSet();

        using (context.PushClip(new Rect(gutter, 0, width, size.Height)))
        {
            // The rows' bands, and past the length, shade.
            foreach (var row in rows)
            {
                if (selected.Contains(row.Row.Path) && row.Row.Kind != CutsceneRowKind.Channel)
                {
                    context.FillRectangle(SelectedRow, new Rect(gutter, row.Y, width, Layout.RowHeight));
                }
                else if (rows.IndexOf(row) % 2 == 0)
                {
                    context.FillRectangle(Band, new Rect(gutter, row.Y, width, Layout.RowHeight));
                }
            }
            var spacing = TimelineGeometry.FrameSpacing(view.PerPixel, layout.FrameTicks);
            var first = Math.Floor(Math.Max(view.At(0), 0) / spacing) * spacing;
            for (var t = first; t <= view.At(width); t += spacing)
            {
                context.DrawLine(TickPen, new Point(X(t), Layout.RulerHeight), new Point(X(t), size.Height));
            }
            foreach (var row in rows)
            {
                DrawRow(context, row, selected, problems, X);
            }
            foreach (var marker in layout.Markers)
            {
                var mx = X(marker.Start);
                if (mx >= gutter - 1 && mx <= gutter + width + 1)
                {
                    context.DrawLine(new Pen(MarkerLine(marker.Color), 1), new Point(mx, Layout.RulerHeight), new Point(mx, size.Height));
                }
            }
            var lengthX = X(layout.Length);
            if (lengthX < gutter + width)
            {
                context.FillRectangle(PastLength, new Rect(lengthX, 0, gutter + width - lengthX, size.Height));
            }
            if (X(0) > gutter)
            {
                context.FillRectangle(PastLength, new Rect(gutter, 0, X(0) - gutter, size.Height));
            }
            DrawRuler(context, layout, view, width, X);
            DrawMarkers(context, layout, selected, width, X);
            if (Input.Guide is { } guide)
            {
                context.DrawLine(GuidePen, new Point(X(guide), 0), new Point(X(guide), size.Height));
            }
            var playhead = X(_editor.Playhead);
            context.DrawLine(PlayheadPen, new Point(playhead, 0), new Point(playhead, size.Height));
            var head = new StreamGeometry();
            using (var g = head.Open())
            {
                g.BeginFigure(new Point(playhead - 5, 0), true);
                g.LineTo(new Point(playhead + 5, 0));
                g.LineTo(new Point(playhead, 8));
                g.EndFigure(true);
            }
            context.DrawGeometry(PlayheadPen.Brush, null, head);
            if (Input.Box is { } box)
            {
                var rect = new Rect(box.From, box.To).Normalize();
                context.FillRectangle(BoxBrush, rect);
                context.DrawRectangle(BoxPen, rect);
            }
        }

        DrawHeaders(context, rows, selected, problems, size);
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

    void DrawRuler(DrawingContext context, Layout layout, TimelineView view, double width, Func<double, double> x)
    {
        context.FillRectangle(RulerBrush, new Rect(Layout.Gutter, 0, width, Layout.RulerHeight));
        var spacing = TimelineGeometry.FrameSpacing(view.PerPixel, layout.FrameTicks);
        var first = Math.Floor(Math.Max(view.At(0), 0) / spacing) * spacing;
        for (var t = first; t <= view.At(width); t += spacing)
        {
            var at = x(t);
            context.DrawLine(LengthPen, new Point(at, Layout.RulerHeight - Layout.RangeBarHeight - 6), new Point(at, Layout.RulerHeight - Layout.RangeBarHeight));
            context.DrawText(Text(Units((int)t), DimText, 10), new Point(at + 3, 2));
        }
        // The range bar, with a handle at each end, and the length's handle above it.
        var (start, end) = layout.Range;
        var bar = new Rect(x(start), Layout.RulerHeight - Layout.RangeBarHeight + 1, Math.Max(x(end) - x(start), 1), Layout.RangeBarHeight - 2);
        context.FillRectangle(RangeBrush, bar);
        context.FillRectangle(HandleBrush, new Rect(bar.X - 2, bar.Y, 4, bar.Height));
        context.FillRectangle(HandleBrush, new Rect(bar.Right - 2, bar.Y, 4, bar.Height));
        var lengthX = x(layout.Length);
        context.DrawLine(LengthPen, new Point(lengthX, 0), new Point(lengthX, Layout.RulerHeight - Layout.RangeBarHeight));
        context.FillRectangle(HandleBrush, new Rect(lengthX - 3, 2, 6, 10));
    }

    static readonly Dictionary<string, IBrush> MarkerBrushes = [];

    // A marker's color, or the default amber for none or one that does not parse.
    static IBrush MarkerBrush(string? color, byte alpha = 0xFF)
    {
        var key = $"{color}/{alpha}";
        if (!MarkerBrushes.TryGetValue(key, out var brush))
        {
            var c = color != null && Color.TryParse(color, out var parsed) ? parsed : ((SolidColorBrush)MarkerDefault).Color;
            brush = new SolidColorBrush(Color.FromArgb(alpha, c.R, c.G, c.B));
            MarkerBrushes[key] = brush;
        }
        return brush;
    }

    static IBrush MarkerLine(string? color) => MarkerBrush(color, 0x50);

    // The markers' flags in the top of the ruler, each with its name while it fits before the next.
    void DrawMarkers(DrawingContext context, Layout layout, HashSet<string> selected, double width, Func<double, double> x)
    {
        var markers = layout.Markers;
        for (var i = 0; i < markers.Count; i++)
        {
            var m = markers[i];
            var at = x(m.Start);
            if (at < Layout.Gutter - 60 || at > Layout.Gutter + width + 1)
            {
                continue;
            }
            var flag = new StreamGeometry();
            using (var g = flag.Open())
            {
                g.BeginFigure(new Point(at, 0), true);
                g.LineTo(new Point(at + 8, 0));
                g.LineTo(new Point(at + 8, Layout.MarkerHeight - 4));
                g.LineTo(new Point(at, Layout.MarkerHeight));
                g.EndFigure(true);
            }
            context.DrawGeometry(MarkerBrush(m.Color), selected.Contains(m.Path) ? SelectedPen : null, flag);
            var room = (i + 1 < markers.Count ? x(markers[i + 1].Start) : Layout.Gutter + width) - at - 12;
            if (room > 16 && m.Label is { Length: > 0 } name)
            {
                using (context.PushClip(new Rect(at + 10, 0, room, Layout.MarkerHeight)))
                {
                    // On the ruler's color, so the name reads over the ticks' labels under it.
                    var text = Text(name, MarkerBrush(m.Color), 9);
                    context.FillRectangle(RulerBrush, new Rect(at + 9, 0, text.Width + 3, Layout.MarkerHeight));
                    context.DrawText(text, new Point(at + 10, -1));
                }
            }
        }
    }

    void DrawRow(DrawingContext context, CutsceneVisibleRow row, HashSet<string> selected, HashSet<string> problems, Func<double, double> x)
    {
        var y = row.Y;
        var locked = row.Row.TrackId is { } id && _editor.Locked.Contains(id);
        // A track that the preview does not play, as muted or not soloed, draws grey, as a locked one draws faint.
        var silent = row.Row.TrackId is { } trackId && !_editor.Audible(trackId);
        var top = y + 3;
        var height = Layout.RowHeight - 6;
        foreach (var bar in row.Bars)
        {
            var x0 = Layout.Gutter + bar.X0;
            var rect = new Rect(x0, bar.Item.Kind == CutsceneItemKind.Range ? top + height / 4 : top, Math.Max(bar.X1 - bar.X0, 2), bar.Item.Kind == CutsceneItemKind.Range ? height / 2 : height);
            context.FillRectangle(silent ? SilentFill : Fill(row.Row.TrackKind, locked || row.Row.Kind == CutsceneRowKind.Channel), rect, 2);
            if (problems.Contains(bar.Item.Path))
            {
                context.DrawRectangle(ErrorPen, rect.Deflate(0.75), 2);
            }
            if (selected.Contains(bar.Item.Path))
            {
                context.DrawRectangle(SelectedPen, rect.Deflate(1), 2);
            }
            if (rect.Width > 40 && row.Row.Kind == CutsceneRowKind.Track && bar.Item.Label is { Length: > 0 } label)
            {
                using (context.PushClip(rect.Deflate(new Thickness(4, 0))))
                {
                    var text = Text(label, BarText, 10);
                    context.DrawText(text, new Point(Math.Max(rect.X, Layout.Gutter) + 4, rect.Y + (rect.Height - text.Height) / 2));
                }
            }
        }
        var middle = y + Layout.RowHeight / 2;
        foreach (var glyph in row.Points)
        {
            Diamond(context, Layout.Gutter + glyph.X, middle, 6, glyph.Paths.Any(selected.Contains) ? SelectedKey : Fill("event", locked), glyph.Paths.Any(problems.Contains));
        }
        foreach (var glyph in row.Keys)
        {
            var radius = glyph.Items.Count > 1 ? 4.5 : 3.5;
            Diamond(context, Layout.Gutter + glyph.X, middle, radius, glyph.Paths.Any(selected.Contains) ? SelectedKey : KeyBrush, glyph.Paths.Any(problems.Contains));
        }
    }

    // A diamond of each size about the origin, made once and moved to each glyph.
    static readonly Dictionary<double, StreamGeometry> Diamonds = [];

    static void Diamond(DrawingContext context, double x, double y, double r, IBrush fill, bool problem)
    {
        if (!Diamonds.TryGetValue(r, out var g))
        {
            g = new StreamGeometry();
            using (var c = g.Open())
            {
                c.BeginFigure(new Point(0, -r), true);
                c.LineTo(new Point(r, 0));
                c.LineTo(new Point(0, r));
                c.LineTo(new Point(-r, 0));
                c.EndFigure(true);
            }
            Diamonds[r] = g;
        }
        using (context.PushTransform(Matrix.CreateTranslation(x, y)))
        {
            context.DrawGeometry(fill, problem ? ErrorPen : null, g);
        }
    }

    void DrawHeaders(DrawingContext context, List<CutsceneVisibleRow> rows, HashSet<string> selected, HashSet<string> problems, Size size)
    {
        context.FillRectangle(GutterBrush, new Rect(0, 0, Layout.Gutter, size.Height));
        using (context.PushClip(new Rect(0, Layout.RulerHeight, Layout.Gutter, size.Height)))
        {
            foreach (var row in rows)
            {
                var r = row.Row;
                var y = row.Y;
                if (selected.Contains(r.Path) && r.Kind != CutsceneRowKind.Channel)
                {
                    context.FillRectangle(SelectedRow, new Rect(0, y, Layout.Gutter, Layout.RowHeight));
                }
                var x = 4 + r.Depth * Layout.Indent;
                if (r.CanFold)
                {
                    context.DrawText(Text(r.Folded ? "▸" : "▾", DimText), new Point(x + 2, y + 3));
                }
                x += Layout.Indent;
                if (r.Kind == CutsceneRowKind.Track)
                {
                    context.FillRectangle(Fill(r.TrackKind, false), new Rect(x, y + 7, 8, 8), 2);
                    x += 12;
                }
                var label = Text(r.Label, r.Kind == CutsceneRowKind.Channel ? DimText : TextBrush, r.Kind == CutsceneRowKind.Binding ? 12 : 11);
                using (context.PushClip(new Rect(x, y, Layout.MuteX - x - 12, Layout.RowHeight)))
                {
                    context.DrawText(label, new Point(x, y + (Layout.RowHeight - label.Height) / 2));
                }
                if (problems.Contains(r.Path) && r.Kind != CutsceneRowKind.Channel)
                {
                    context.DrawEllipse(ErrorBrush, null, new Point(Layout.MuteX - 6, y + Layout.RowHeight / 2), 3, 3);
                }
                if (r.Kind == CutsceneRowKind.Track && r.TrackId is { } id)
                {
                    Toggle(context, Layout.MuteX, y, "M", _editor.Muted.Contains(id) ? MutedBrush : null, r.AssetMuted);
                    Toggle(context, Layout.SoloX, y, "S", _editor.Soloed.Contains(id) ? SoloBrush : null, false);
                    Lock(context, Layout.Gutter - Layout.LockWidth + 6, y + 5, _editor.Locked.Contains(id));
                }
            }
        }
        context.FillRectangle(RulerBrush, new Rect(0, 0, Layout.Gutter, Layout.RulerHeight));
        context.DrawText(Text(Units(_editor.Playhead), TextBrush, 12), new Point(8, 7));
    }

    // A mute or solo toggle: a letter, on a color when it is on. A track whose asset mutes it shows its M struck
    // through, which no toggle changes.
    void Toggle(DrawingContext context, double x, double y, string letter, IBrush? on, bool struck)
    {
        var box = new Rect(x + 4, y + 4, Layout.LockWidth - 8, Layout.RowHeight - 8);
        if (on != null)
        {
            context.FillRectangle(on, box, 2);
        }
        var text = Text(letter, on != null ? BarText : DimText, 10);
        context.DrawText(text, new Point(box.X + (box.Width - text.Width) / 2, box.Y + (box.Height - text.Height) / 2));
        if (struck)
        {
            context.DrawLine(StrikePen, box.BottomLeft, box.TopRight);
        }
    }

    // A padlock: closed and yellow when the track is locked, open and grey when not.
    static void Lock(DrawingContext context, double x, double y, bool locked)
    {
        var pen = locked ? LockedPen : LockPen;
        context.DrawRectangle(locked ? pen.Brush : null, pen, new Rect(x, y + 5, 10, 7), 1);
        var shackle = new StreamGeometry();
        using (var g = shackle.Open())
        {
            g.BeginFigure(new Point(x + 2, y + 5), false);
            g.LineTo(new Point(x + 2, y + 2));
            g.ArcTo(new Point(x + 8, y + 2), new Size(3, 3), 0, false, SweepDirection.Clockwise);
            g.LineTo(new Point(x + 8, locked ? y + 5 : y + 3));
            g.EndFigure(false);
        }
        context.DrawGeometry(null, pen, shackle);
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
        if (Input.Press(point.Position.X, point.Position.Y, button, e.KeyModifiers))
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
        // A held nudge key's repeats are one undo entry, which its release ends, whatever key keybindings.json gives it.
        _editor.EndNudge();
    }
}
