using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Media;
using Avalonia.VisualTree;
using Cinnabar.Editor.Commands;
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
    static readonly IBrush LoopBrush = new SolidColorBrush(Color.Parse("#5B8DEF"), 0.35);
    static readonly IBrush InOutBrush = new SolidColorBrush(Color.Parse("#5B8DEF"));
    static readonly IBrush OutsideLoop = new SolidColorBrush(Color.Parse("#000000"), 0.25);
    static readonly IPen GuidePen = new Pen(new SolidColorBrush(Color.Parse("#FFD24A")), 1, new DashStyle([4, 3], 0));
    static readonly IPen LengthPen = new Pen(new SolidColorBrush(Color.FromArgb(0xA0, 0xFF, 0xFF, 0xFF)), 1);
    static readonly IPen LockPen = new Pen(new SolidColorBrush(Color.Parse("#9A9AA2")), 1.2);
    static readonly IPen LockedPen = new Pen(new SolidColorBrush(Color.Parse("#FFD24A")), 1.2);
    static readonly IBrush SilentFill = new SolidColorBrush(Color.Parse("#4A4A50"));
    static readonly IBrush MutedBrush = new SolidColorBrush(Color.Parse("#E69138"));
    static readonly IBrush WarnBrush = new SolidColorBrush(Color.Parse("#E5A93B"));
    // An event whose name no behaviour handles (see docs/editor/cutscene-editor.md#events).
    static readonly IPen WarnPen = new Pen(WarnBrush, 1.5);
    static readonly IBrush SoloBrush = new SolidColorBrush(Color.Parse("#FFD24A"));
    static readonly IPen StrikePen = new Pen(new SolidColorBrush(Color.Parse("#9A9AA2")), 1);
    static readonly IBrush MarkerDefault = new SolidColorBrush(Color.Parse("#F5A623"));
    static readonly IBrush OverlapBrush = new SolidColorBrush(Color.FromArgb(0x38, 0x00, 0x00, 0x00));
    static readonly IBrush HeldBrush = new SolidColorBrush(Color.FromArgb(0x60, 0x1B, 0x1B, 0x1E));
    static readonly IPen LoopPen = new Pen(new SolidColorBrush(Color.FromArgb(0x70, 0x10, 0x10, 0x12)), 1);
    static readonly IBrush LoopRun = new SolidColorBrush(Color.FromArgb(0x50, 0x10, 0x10, 0x12));
    static readonly IPen ClipEndPen = new Pen(new SolidColorBrush(Color.FromArgb(0xC0, 0x10, 0x10, 0x12)), 1, new DashStyle([3, 2], 0));
    static readonly IPen EasePen = new Pen(new SolidColorBrush(Color.FromArgb(0xB0, 0x10, 0x10, 0x12)), 1.2);
    static readonly IBrush EaseHandle = new SolidColorBrush(Color.FromArgb(0xE0, 0xF4, 0xF4, 0xF6));
    static readonly IPen EaseHandlePen = new Pen(new SolidColorBrush(Color.FromArgb(0xC0, 0x10, 0x10, 0x12)), 1);
    static readonly IBrush WaveBrush = new SolidColorBrush(Color.FromArgb(0x90, 0x10, 0x10, 0x12));
    static readonly IPen EventPen = new Pen(new SolidColorBrush(Color.FromArgb(0xE0, 0xF4, 0xF4, 0xF6)), 1.5);
    // A trigger's flag behind its name, and a badge behind its count (see docs/editor/cutscene-editor.md#flags-on-the-timeline).
    static readonly IBrush FlagBrush = new SolidColorBrush(Color.Parse("#F1C232"), 0.85);
    static readonly IBrush BadgeBrush = new SolidColorBrush(Color.Parse("#E8E8EC"));
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
        // Entities from the Outliner possess, prefabs from the content browser spawn, and an entity with Alt on a
        // binding's row rebinds it (see docs/editor/cutscene-editor.md#bindings).
        DragDrop.SetAllowDrop(this, true);
        AddHandler(DragDrop.DragOverEvent, (_, e) => e.DragEffects = DropOf(e) ? DragDropEffects.Link : DragDropEffects.None);
        AddHandler(DragDrop.DropEvent, (_, e) => Drop(e));
        void Changed() => Input.Refresh();
        void Frame() => Input.Frame();
        void Playhead() => Input.ShowPlayhead();
        void Played() => Input.OnPlayStarted();
        void Reveal(string path) => Input.Reveal(path);
        void Viewed() => InvalidateVisual();
        // A sound's peaks that arrive draw at once, with no new build of the rows (see docs/editor/cutscene-editor.md#waveforms).
        void WaveLoaded(string path) => InvalidateVisual();
        // Tells the editor when the keyboard is in the timeline.
        FocusFollower.Follow(this, () => _editor.SetKeyboardPane(CutscenePane.Timeline), () => _editor.LeaveKeyboardPane(CutscenePane.Timeline));
        new ViewSubscriptions(this, attached: Input.Refresh)
            .Add(() => _editor.TimeViewChanged += Viewed, () => _editor.TimeViewChanged -= Viewed)
            .Add(() => WaveformCache.Shared.Loaded += WaveLoaded, () => WaveformCache.Shared.Loaded -= WaveLoaded)
            .Add(() => _editor.RevealRequested += Reveal, () => _editor.RevealRequested -= Reveal)
            .Add(() => _editor.PlayStarted += Played, () => _editor.PlayStarted -= Played)
            .Add(() => _editor.Changed += Changed, () => _editor.Changed -= Changed)
            .Add(() => _editor.ProblemsChanged += Changed, () => _editor.ProblemsChanged -= Changed)
            .Add(() => _editor.LooksChanged += Viewed, () => _editor.LooksChanged -= Viewed)
            .Add(() => _editor.FrameRequested += Frame, () => _editor.FrameRequested -= Frame)
            .Add(() => _editor.PlayheadChanged += Playhead, () => _editor.PlayheadChanged -= Playhead)
            .Add(() => _editor.Flashed += Viewed, () => _editor.Flashed -= Viewed);
    }

    public CutsceneTimelineInput Input { get; }

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

    static readonly Dictionary<string, IBrush> HintFills = [];

    // A clip's faded head and tail past its section's edges: its kind's color, faint.
    static IBrush HintFill(string? kind)
    {
        kind ??= "";
        if (!HintFills.TryGetValue(kind, out var brush))
        {
            var color = ((ISolidColorBrush)Fill(kind, false)).Color;
            brush = new SolidColorBrush(Color.FromArgb(0x38, color.R, color.G, color.B));
            HintFills[kind] = brush;
        }
        return brush;
    }

    string Units(int ticks) => _editor.ShowFrames
        ? CutsceneTime.Frames(ticks, _editor.File.Rate).ToString(CultureInfo.InvariantCulture)
        : CutsceneTime.Timecode(ticks, _editor.File.Rate);

    public override void Render(DrawingContext context)
    {
        // A fired event's flash fades on the next frames, also after the play stops (see docs/editor/cutscene-editor.md#events-in-the-preview).
        if (_editor.Flashes.Live())
        {
            TopLevel.GetTopLevel(this)?.RequestAnimationFrame(_ => InvalidateVisual());
        }
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
            if (_editor.Loop && _editor.LoopRange is { } loop)
            {
                // Outside the loop, a shade.
                context.FillRectangle(OutsideLoop, new Rect(gutter, Layout.RulerHeight, Math.Max(X(loop.Start) - gutter, 0), size.Height));
                context.FillRectangle(OutsideLoop, new Rect(X(loop.End), Layout.RulerHeight, Math.Max(gutter + width - X(loop.End), 0), size.Height));
            }
            DrawRuler(context, layout, view, width, X);
            DrawInOut(context, X);
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

    // The loop's span on the ruler, under the range bar, while it loops or has an in or an out point, and a bracket at
    // each of those points.
    void DrawInOut(DrawingContext context, Func<double, double> x)
    {
        if ((_editor.Loop || _editor.InPoint != null || _editor.OutPoint != null) && _editor.LoopRange is { } loop)
        {
            var y = Layout.RulerHeight - Layout.RangeBarHeight - 4;
            context.FillRectangle(LoopBrush, new Rect(x(loop.Start), y, Math.Max(x(loop.End) - x(loop.Start), 1), 3));
        }
        foreach (var (point, inward) in new[] { (_editor.InPoint, 1), (_editor.OutPoint, -1) })
        {
            if (point is { } at)
            {
                var px = x(at);
                context.FillRectangle(InOutBrush, new Rect(px - (inward < 0 ? 2 : 0), 0, 2, Layout.RulerHeight - Layout.RangeBarHeight));
                context.FillRectangle(InOutBrush, new Rect(inward > 0 ? px : px - 6, 0, 6, 2));
            }
        }
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
        // A camera cut track names each cut's camera past a short cut's end (see docs/editor/cutscene-editor.md#the-cut-strip).
        var cuts = row.Row.Kind == CutsceneRowKind.Track && row.Row.TrackKind == "camera_cut";
        var view = Input.View;
        var area = Bounds.Width - Layout.Gutter;
        var track = row.Row.Kind == CutsceneRowKind.Track;
        // A clip's cut-off head and tail, under the bars (see docs/editor/cutscene-editor.md#loops-and-hints).
        var marks = new Dictionary<CutsceneVisibleBar, CutsceneClipMarks>();
        foreach (var bar in row.Bars)
        {
            if (track && bar.Item.Clip is { } clip)
            {
                var m = Layout.ClipMarks(bar.Item.Start, bar.Item.End, clip, view, area);
                marks[bar] = m;
                foreach (var (h0, h1) in new[] { m.Head, m.Tail }.OfType<(double X0, double X1)>())
                {
                    context.FillRectangle(HintFill(row.Row.TrackKind), new Rect(Layout.Gutter + h0, top + 2, Math.Max(h1 - h0, 1), height - 4), 2);
                }
            }
        }
        foreach (var bar in row.Bars)
        {
            var x0 = Layout.Gutter + bar.X0;
            var rect = new Rect(x0, bar.Item.Kind == CutsceneItemKind.Range ? top + height / 4 : top, Math.Max(bar.X1 - bar.X0, 2), bar.Item.Kind == CutsceneItemKind.Range ? height / 2 : height);
            context.FillRectangle(silent ? SilentFill : Fill(row.Row.TrackKind, locked || row.Row.Kind == CutsceneRowKind.Channel), rect, 2);
            if (track && bar.Item is { Peaks: { } peaksPath, Clip: { } waveClip } && WaveformCache.Shared.Get(peaksPath) is { } peaks)
            {
                DrawWaveform(context, CutsceneWaveform.Columns(bar.Item, waveClip, bar.Item.Gain, peaks, view, area), top, height);
            }
            if (marks.TryGetValue(bar, out var clipMarks))
            {
                // Past a clip that does not loop, the pose holds or the sound is silent.
                if (clipMarks.End is { } end)
                {
                    context.FillRectangle(HeldBrush, new Rect(Layout.Gutter + end, top, Math.Max(rect.Right - Layout.Gutter - end, 0), height));
                    context.DrawLine(ClipEndPen, new Point(Layout.Gutter + end, top), new Point(Layout.Gutter + end, top + height));
                }
                foreach (var (l0, l1) in clipMarks.Loops)
                {
                    if (l1 - l0 < 1)
                    {
                        context.DrawLine(LoopPen, new Point(Layout.Gutter + l0 + 0.5, top + 2), new Point(Layout.Gutter + l0 + 0.5, top + height - 2));
                    }
                    else
                    {
                        context.FillRectangle(LoopRun, new Rect(Layout.Gutter + l0, top + 2, l1 - l0, height - 4));
                    }
                }
            }
            // A clip's events, from its binding's graph, as ticks along the bar's bottom (see docs/editor/cutscene-editor.md#clip-events).
            if (track && bar.Item is { Clip: { } eventClip, Events.Count: > 0 })
            {
                foreach (var tick in CutsceneWaveform.EventTicks(bar.Item, eventClip, bar.Item.Events, view, area))
                {
                    var ex = Layout.Gutter + tick.X;
                    context.DrawLine(EventPen, new Point(ex, top + height - Layout.EventBand + 1), new Point(ex, top + height));
                }
            }
            if (track && !cuts && bar.Item.Kind == CutsceneItemKind.Section)
            {
                DrawEases(context, bar, view, top, height);
            }
            if (problems.Contains(bar.Item.Path))
            {
                context.DrawRectangle(ErrorPen, rect.Deflate(0.75), 2);
            }
            else if (bar.Item.Warning != null)
            {
                context.DrawRectangle(WarnPen, rect.Deflate(0.75), 2);
            }
            if (bar.Item.Kind == CutsceneItemKind.Range && _editor.Flashes.Strength(bar.Item.Path) is > 0 and var flash)
            {
                context.FillRectangle(new SolidColorBrush(Colors.White, 0.7 * flash), rect.Inflate(2 * flash), 3);
            }
            if (selected.Contains(bar.Item.Path))
            {
                context.DrawRectangle(SelectedPen, rect.Deflate(1), 2);
            }
            // The label stays in the part of its bar in view (see docs/editor/cutscene-editor.md#labels).
            if (track && !cuts && bar.Item.Label is { Length: > 0 } label && Layout.LabelRoom(bar.X0, bar.X1, area) is var (lx, room))
            {
                // A range's bar is half a row high, so its name is smaller and may stand a little past it.
                var range = bar.Item.Kind == CutsceneItemKind.Range;
                using (context.PushClip(new Rect(Layout.Gutter + lx, rect.Y - (range ? 2 : 0), room, rect.Height + (range ? 4 : 0))))
                {
                    var text = Text(label, BarText, range ? 8 : 10);
                    context.DrawText(text, new Point(Layout.Gutter + lx, rect.Y + (rect.Height - text.Height) / 2));
                }
            }
        }
        // Where sections overlap, they blend: a darker band, across which their eases are the blend's curve.
        if (track && !cuts)
        {
            foreach (var (o0, o1) in Layout.Overlaps(row.Bars))
            {
                context.FillRectangle(OverlapBrush, new Rect(Layout.Gutter + o0, top, Math.Max(o1 - o0, 1), height));
            }
            foreach (var bar in row.Bars)
            {
                if (Layout.Handles(bar.Item, view) is { } handles)
                {
                    foreach (var hx in new[] { handles.In, handles.Out })
                    {
                        var square = new Rect(Layout.Gutter + hx - Layout.HandleSize / 2, top - 1, Layout.HandleSize, Layout.HandleSize);
                        context.FillRectangle(EaseHandle, square);
                        context.DrawRectangle(EaseHandlePen, square);
                    }
                }
            }
        }
        if (cuts)
        {
            foreach (var (at, room, name) in Layout.CutNames(row.Bars, area))
            {
                var x0 = Layout.Gutter + at + 3;
                using (context.PushClip(new Rect(x0, top, room, height)))
                {
                    var text = Text(name, BarText, 10);
                    context.FillRectangle(silent ? SilentFill : Fill(row.Row.TrackKind, locked), new Rect(x0, top, Math.Min(text.Width + 6, room), height), 2);
                    context.DrawText(text, new Point(x0 + 3, top + (height - text.Height) / 2));
                }
            }
        }
        var middle = y + Layout.RowHeight / 2;
        // Each trigger is a flag with its name, and triggers closer than a name is wide are a badge with their count.
        foreach (var flag in row.Flags)
        {
            var fx = Layout.Gutter + flag.X;
            var label = new Rect(fx + Layout.FlagInset - 3, middle - 7, flag.Width - Layout.FlagInset + 1, 14);
            context.FillRectangle(flag.Badge ? BadgeBrush : FlagBrush, label, flag.Badge ? 7 : 2);
            using (context.PushClip(label))
            {
                var text = Text(flag.Text, BarText, 10);
                context.DrawText(text, new Point(label.X + (flag.Badge ? (label.Width - text.Width) / 2 : 3), middle - text.Height / 2));
            }
            var flash = flag.Paths.Max(_editor.Flashes.Strength);
            if (flash > 0)
            {
                Diamond(context, fx, middle, 6 + 4 * flash, new SolidColorBrush(Colors.White, flash), false);
            }
            Diamond(context, fx, middle, 6, flag.Paths.Any(selected.Contains) ? SelectedKey : Fill("event", locked), flag.Paths.Any(problems.Contains),
                flag.Items.Any(i => i.Warning != null));
        }
        foreach (var glyph in row.Keys)
        {
            var radius = glyph.Items.Count > 1 ? 4.5 : 3.5;
            Diamond(context, Layout.Gutter + glyph.X, middle, radius, glyph.Paths.Any(selected.Contains) ? SelectedKey : KeyBrush, glyph.Paths.Any(problems.Contains));
        }
    }

    // A sound's waveform: a line for each column, about the bar's middle, as tall as the bar at full scale.
    static void DrawWaveform(DrawingContext context, List<CutsceneWaveColumn> columns, double top, double height)
    {
        if (columns.Count == 0)
        {
            return;
        }
        var middle = top + height / 2;
        var half = height / 2 - 1;
        var g = new StreamGeometry();
        using (var c = g.Open())
        {
            foreach (var column in columns)
            {
                var x = Layout.Gutter + column.X;
                // A column at least one pixel tall, so a quiet part still shows where the sound is.
                var y0 = middle - Math.Max(column.High * half, 0.5);
                var y1 = middle - Math.Min(column.Low * half, -0.5);
                c.BeginFigure(new Point(x, y0), true);
                c.LineTo(new Point(x + 1, y0));
                c.LineTo(new Point(x + 1, y1));
                c.LineTo(new Point(x, y1));
                c.EndFigure(true);
            }
        }
        context.DrawGeometry(WaveBrush, null, g);
    }

    // A section's eases as smoothstep ramps, the shape that the runtime weighs them by: up from its bottom left over
    // ease_in, and down to its bottom right over ease_out.
    static void DrawEases(DrawingContext context, CutsceneVisibleBar bar, TimelineView view, double top, double height)
    {
        void Ramp(double from, double to, bool rising)
        {
            if (Math.Abs(to - from) < 2)
            {
                return;
            }
            var g = new StreamGeometry();
            using (var c = g.Open())
            {
                const int Steps = 12;
                for (var i = 0; i <= Steps; i++)
                {
                    var u = i / (double)Steps;
                    var w = u * u * (3 - 2 * u);
                    var point = new Point(Layout.Gutter + from + (to - from) * u, top + height - height * (rising ? w : 1 - w));
                    if (i == 0)
                    {
                        c.BeginFigure(point, false);
                    }
                    else
                    {
                        c.LineTo(point);
                    }
                }
                c.EndFigure(false);
            }
            context.DrawGeometry(null, EasePen, g);
        }
        var item = bar.Item;
        if (item.EaseIn > 0)
        {
            Ramp(bar.X0, view.X(item.Start + item.EaseIn), rising: true);
        }
        if (item.EaseOut > 0)
        {
            Ramp(view.X(item.End - item.EaseOut), bar.X1, rising: false);
        }
    }

    // A diamond of each size about the origin, made once and moved to each glyph.
    static readonly Dictionary<double, StreamGeometry> Diamonds = [];

    static void Diamond(DrawingContext context, double x, double y, double r, IBrush fill, bool problem, bool warning = false)
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
            context.DrawGeometry(fill, problem ? ErrorPen : warning ? WarnPen : null, g);
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
                // A binding's row (see docs/editor/cutscene-editor.md#bindings): a dot for a possessed entity, a ring for a
                // spawned prefab, a square for a script slot, the name, the entity's or prefab's name after it (a slot's
                // stand-in's), and a warning when it is not bound.
                var warn = r.Binding is { State: not CutsceneBindingState.Bound };
                if (r.Binding is { } info)
                {
                    var center = new Point(x + 4, y + Layout.RowHeight / 2);
                    var brush = warn ? WarnBrush : DimText;
                    if (info.Kind == CutsceneBindingKind.Spawned)
                    {
                        context.DrawEllipse(null, new Pen(brush, 1.5), center, 3.5, 3.5);
                    }
                    else if (info.Kind == CutsceneBindingKind.Provided)
                    {
                        context.DrawRectangle(null, new Pen(brush, 1.5), new Rect(center.X - 3.5, center.Y - 3.5, 7, 7));
                    }
                    else
                    {
                        context.DrawEllipse(brush, null, center, 4, 4);
                    }
                    x += 12;
                }
                var label = Text(r.Label, r.Kind == CutsceneRowKind.Channel ? DimText : TextBrush, r.Kind == CutsceneRowKind.Binding ? 12 : 11);
                var camera = r.Binding is { Camera: true } && !warn;
                var right = r.Kind == CutsceneRowKind.Binding ? Layout.Gutter - (warn || camera ? 22 : 6) : Layout.MuteX - 12;
                using (context.PushClip(new Rect(x, y, right - x, Layout.RowHeight)))
                {
                    context.DrawText(label, new Point(x, y + (Layout.RowHeight - label.Height) / 2));
                    if (r.Binding?.TargetName is { } target && target != r.Label)
                    {
                        var dim = Text(target, DimText, 11);
                        context.DrawText(dim, new Point(x + label.Width + 6, y + (Layout.RowHeight - dim.Height) / 2));
                    }
                }
                if (warn)
                {
                    var sign = Text("!", BarText, 10);
                    var at = new Point(Layout.Gutter - 14, y + Layout.RowHeight / 2);
                    context.DrawEllipse(r.Binding!.State == CutsceneBindingState.Broken ? ErrorBrush : WarnBrush, null, at, 6, 6);
                    context.DrawText(sign, new Point(at.X - sign.Width / 2, at.Y - sign.Height / 2));
                }
                if (camera && _editor.File.Find(r.Path) is { Id: { } binding })
                {
                    LookThrough(context, Layout.Gutter - Layout.LockWidth + 4, y + 6, _editor.LooksThrough(binding));
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

    // A camera binding's look-through toggle: a small camera, lit while the active scene view looks through it.
    void LookThrough(DrawingContext context, double x, double y, bool on)
    {
        var brush = on ? SoloBrush : DimText;
        var pen = new Pen(brush, 1.2);
        context.DrawRectangle(on ? brush : null, pen, new Rect(x, y + 2, 9, 7), 1.5);
        var lens = new StreamGeometry();
        using (var g = lens.Open())
        {
            g.BeginFigure(new Point(x + 9, y + 5.5), true);
            g.LineTo(new Point(x + 14, y + 2.5));
            g.LineTo(new Point(x + 14, y + 8.5));
            g.EndFigure(true);
        }
        context.DrawGeometry(on ? brush : null, pen, lens);
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

    // Whether a drag holds what the timeline takes: an entity, an animation or a sound that has a track to go on, or an
    // asset that places a prefab.
    bool DropOf(DragEventArgs e)
    {
        if (_editor.Document.InTransaction)
        {
            return false;
        }
        if (EntityView.Dropped(e) != 0)
        {
            return true;
        }
        var at = e.GetPosition(this);
        return ContentBrowserView.DroppedAll(e) is { } assets && (Input.CanDropClips(assets, at.X, at.Y) || _editor.PrefabsOf(assets).Count > 0);
    }

    void Drop(DragEventArgs e)
    {
        var at = e.GetPosition(this);
        if (EntityView.Dropped(e) is not 0 and var handle)
        {
            _editor.DropEntity(handle, Input.BindingRowAt(at.X, at.Y)?.Path, e.KeyModifiers.HasFlag(KeyModifiers.Alt));
        }
        else if (ContentBrowserView.DroppedAll(e) is { } assets)
        {
            // Clips go on tracks at the drop's time (see docs/editor/cutscene-editor.md#drops), and prefabs spawn.
            Input.DropClips(assets, at.X, at.Y);
            if (_editor.PrefabsOf(assets) is { Count: > 0 } prefabs)
            {
                _editor.Spawn(prefabs);
            }
        }
        Focus();
        e.Handled = true;
    }

    // The section menu, over an animation or audio section (see docs/editor/cutscene-editor.md#the-section-menu).
    void OpenSectionMenu()
    {
        var shell = _editor.Shell;
        var menu = new ContextMenu();
        // The commands act while the timeline has the keyboard, which the menu's popup takes: a click gives it back first.
        void Refocus()
        {
            Focus();
            _editor.SetKeyboardPane(CutscenePane.Timeline);
        }
        MenuBuilder.Build(menu.Items,
            [EditorCommands.CutsceneRevealClip, EditorCommands.CutsceneOpenClip, new MenuSeparator(), EditorCommands.CutsceneMatchClipLength],
            shell.Commands, shell.KeyBindings, MenuBinding.Snapshot, Refocus);
        menu.Open(this);
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
        if (button == MouseButton.Right && !e.KeyModifiers.HasFlag(KeyModifiers.Alt) && Input.ContextAt(point.Position.X, point.Position.Y) != null)
        {
            OpenSectionMenu();
        }
        else if (Input.Press(point.Position.X, point.Position.Y, button, e.KeyModifiers))
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

    protected override void OnPointerExited(PointerEventArgs e)
    {
        base.OnPointerExited(e);
        Input.Leave();
    }

    protected override void OnPointerCaptureLost(PointerCaptureLostEventArgs e)
    {
        base.OnPointerCaptureLost(e);
        Input.LostCapture();
    }

    protected override void OnKeyUp(KeyEventArgs e)
    {
        base.OnKeyUp(e);
        // A held nudge key's repeats are one undo entry, which its release ends, whatever key keybindings.json gives it.
        _editor.EndNudge();
        // The release of Shuttle Pause's key ends its hold, so J and L play again.
        if (_editor.ShuttlePauseShortcut is { } shortcut && KeyGesture.Parse(shortcut).Key == e.Key)
        {
            _editor.EndShuttleHold();
        }
    }
}
