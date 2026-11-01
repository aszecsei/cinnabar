using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using static Cinnabar.Editor.Materials.CanvasDrawing;

namespace Cinnabar.Editor.AnimationGraphs;

/// <summary>
/// The animation graph editor's canvas (see docs/editor/animation-graph-editor.md#animation-graph-editor): the graph's states and
/// blends, a link from each blend to the states that play it, and an arrow for each transition, drawn in the canvas's
/// own units under a pan and a zoom. The left button selects, drags, drags a box, drags a transition from a state's handle
/// to another state, and drags a link from a blend to a state; a link dragged off a state comes away. The right or middle
/// button pans, and a right click without a drag, Space or Tab adds a node. The wheel zooms about the mouse. Delete
/// deletes the selected nodes, and F frames the graph.
/// </summary>
public sealed class AnimationGraphCanvas : Control
{
    const double MinZoom = 0.2;
    const double MaxZoom = 2;
    const double ArrowHead = 8;

    static readonly IBrush NodeBody = new SolidColorBrush(Color.Parse("#2A2A2E"));
    static readonly IPen NodeBorder = new Pen(new SolidColorBrush(Color.Parse("#3C3C42")), 1);
    static readonly IPen SelectedBorder = new Pen(new SolidColorBrush(Palette.Accent), 2);
    static readonly IPen ErrorBorder = new Pen(new SolidColorBrush(Palette.Error), 2, new DashStyle([3, 2], 0));
    static readonly IBrush Text = new SolidColorBrush(Color.Parse("#E4E4E8"));
    static readonly IBrush DimText = new SolidColorBrush(Color.Parse("#8A8A92"));
    static readonly IBrush BoxFill = new SolidColorBrush(Color.Parse("#22E34234"));
    static readonly IPen BoxPen = new Pen(new SolidColorBrush(Palette.Accent), 1);
    static readonly IBrush StateHeader = new SolidColorBrush(Color.Parse("#2E4A66"));
    static readonly IBrush BlendHeader = new SolidColorBrush(Color.Parse("#4E3E6A"));
    static readonly IBrush ArrowBrush = new SolidColorBrush(Color.Parse("#A8A8B0"));
    static readonly IPen ArrowPen = new Pen(ArrowBrush, 1.5);
    static readonly IBrush LinkBrush = new SolidColorBrush(Color.Parse("#D97AB5"));
    static readonly IPen LinkPen = new Pen(LinkBrush, 2);
    static readonly IBrush GlyphBody = new SolidColorBrush(Color.Parse("#323238"));
    // The live view: what plays, what it fades from, and the transition between them.
    static readonly Color LiveColor = Color.Parse("#5BC47F");
    static readonly IBrush LiveBrush = new SolidColorBrush(LiveColor);
    static readonly IPen LivePen = new Pen(LiveBrush, 3);
    static readonly IBrush LastTakenBrush = new SolidColorBrush(LiveColor, 0.45);
    static readonly IPen LastTakenPen = new Pen(LastTakenBrush, 2);

    enum Gesture
    {
        None,
        Click,
        Move,
        Box,
        Transition,
        Link,
        Pan,
        PanClick,
    }

    readonly EditorShell _shell;
    readonly AnimationGraphEditor _editor;
    AnimationGraphGeometry _geometry;
    Canvas2DView _view = new(new Vec2(-200, -150), 1);
    Gesture _gesture;
    Point _start;
    Point _last;
    int _pressed;
    Dictionary<int, Vec2> _moveStarts = [];
    // A drag from a state's handle or a blend's output, and the state that a link came off, if any.
    int _dragFrom;
    int? _detachedFrom;
    Vec2 _dragEnd;
    bool _framed;

    public AnimationGraphCanvas(EditorShell shell, AnimationGraphEditor editor)
    {
        _shell = shell;
        _editor = editor;
        _geometry = editor.Geometry();
        Focusable = true;
        ClipToBounds = true;
        new ViewSubscriptions(this, attached: OnChanged)
            .Add(() => _editor.Changed += OnChanged, () => _editor.Changed -= OnChanged)
            .Add(() => _editor.SelectionChanged += InvalidateVisual, () => _editor.SelectionChanged -= InvalidateVisual)
            .Add(() => _editor.ProblemsChanged += InvalidateVisual, () => _editor.ProblemsChanged -= InvalidateVisual)
            .Add(() => _editor.LiveChanged += InvalidateVisual, () => _editor.LiveChanged -= InvalidateVisual);
    }

    void OnChanged()
    {
        _geometry = _editor.Geometry();
        InvalidateVisual();
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        var size = base.ArrangeOverride(finalSize);
        // The graph starts framed, once the canvas has a size.
        if (!_framed && finalSize.Width > 0 && finalSize.Height > 0)
        {
            _framed = true;
            Frame(finalSize);
        }
        return size;
    }

    Vec2 ToCanvas(Point p) => _view.ToCanvas(p.X, p.Y);

    /// <summary>Pans and zooms so the whole graph is in view.</summary>
    public void Frame() => Frame(Bounds.Size);

    void Frame(Size size)
    {
        if (_geometry.Extent() is not { } extent || size.Width <= 0)
        {
            return;
        }
        const double Margin = 40;
        _view = Canvas2DView.Fit(extent, size.Width, size.Height, Margin, MinZoom, 1);
        InvalidateVisual();
    }

    /// <summary>The middle of the view, in canvas units, where a node that the view adds goes.</summary>
    public Vec2 Middle => ToCanvas(new Point(Bounds.Width / 2, Bounds.Height / 2));

    public override void Render(DrawingContext context)
    {
        DrawBackground(context, Bounds.Size, _view);
        using (context.PushTransform(Matrix.CreateTranslation(-_view.Offset.X, -_view.Offset.Y) * Matrix.CreateScale(_view.Zoom, _view.Zoom)))
        {
            var problems = _editor.Problems.Where(p => p.Error && p.Node != null).Select(p => p.Node!.Value).ToHashSet();
            foreach (var t in _geometry.Transitions)
            {
                DrawArrow(context, t, ArrowPen, ArrowBrush);
            }
            foreach (var link in _geometry.Links)
            {
                DrawCurve(context, link.Start, link.End);
            }
            foreach (var node in _geometry.Nodes)
            {
                DrawNode(context, node, _editor.Selection.Contains(node.Node.Id), problems.Contains(node.Node.Id));
            }
            foreach (var t in _geometry.Transitions)
            {
                DrawGlyph(context, t, _editor.Selection.Contains(t.Node.Id), problems.Contains(t.Node.Id));
            }
            if (_editor.Live is { } live)
            {
                DrawLive(context, live);
            }
            DrawDrag(context);
        }
        if (_gesture == Gesture.Box)
        {
            context.DrawRectangle(BoxFill, BoxPen, new Rect(_start, _last).Normalize());
        }
    }

    // The state that plays, with its progress through this play; the state that it fades from, by what is left of the
    // fade; and the last transition that it took, bright during its fade. A node that the document does not have, as when
    // it has changed since it cooked, has no place to show.
    void DrawLive(DrawingContext context, AnimatorView view)
    {
        var fade = AnimationGraphEditor.FadeOf(view);
        if (_geometry.FindTransition((int)view.Transition) is { } taken)
        {
            DrawArrow(context, taken, fade < 1 ? LivePen : LastTakenPen, fade < 1 ? LiveBrush : LastTakenBrush);
            var g = taken.Glyph;
            context.DrawRectangle(null, fade < 1 ? LivePen : LastTakenPen, new Rect(g.X, g.Y, g.Width, g.Height).Inflate(1), 10, 10);
        }
        if (fade < 1 && _geometry.Find((int)view.Source) is { } source)
        {
            var b = source.Bounds;
            context.DrawRectangle(null, new Pen(new SolidColorBrush(LiveColor, 1 - fade), 3), new Rect(b.X, b.Y, b.Width, b.Height).Inflate(2), 6, 6);
        }
        if (_geometry.Find((int)view.State) is { } state)
        {
            var b = state.Bounds;
            var pen = fade < 1 ? new Pen(new SolidColorBrush(LiveColor, fade), 3) : LivePen;
            context.DrawRectangle(null, pen, new Rect(b.X, b.Y, b.Width, b.Height).Inflate(2), 6, 6);
            var play = view.Progress - Math.Floor(view.Progress);
            context.FillRectangle(LiveBrush, new Rect(b.X, b.Y + b.Height - 3, b.Width * play, 3));
        }
    }

    void DrawDrag(DrawingContext context)
    {
        if (_gesture == Gesture.Transition && _geometry.Find(_dragFrom) is { } state)
        {
            DrawLine(context, ArrowPen, state.Handle, _dragEnd);
            DrawHead(context, state.Handle, _dragEnd, ArrowBrush);
        }
        if (_gesture == Gesture.Link && _geometry.Find(_dragFrom) is { } blend)
        {
            DrawCurve(context, blend.BlendOutput, _dragEnd);
        }
    }

    static void DrawLine(DrawingContext context, IPen pen, Vec2 a, Vec2 b) => context.DrawLine(pen, new Point(a.X, a.Y), new Point(b.X, b.Y));

    static void DrawArrow(DrawingContext context, TransitionLayout t, IPen pen, IBrush head)
    {
        if (t.Start is { } start)
        {
            DrawLine(context, pen, start, t.Middle);
        }
        if (t.End is { } end)
        {
            DrawLine(context, pen, t.Middle, end);
            DrawHead(context, t.Middle, end, head);
        }
    }

    static void DrawHead(DrawingContext context, Vec2 from, Vec2 to, IBrush brush)
    {
        var d = to - from;
        var length = d.Length;
        if (length < 1)
        {
            return;
        }
        var along = d * (1 / length);
        var side = new Vec2(-along.Y, along.X) * (ArrowHead / 2);
        var back = to - along * ArrowHead;
        var geometry = new StreamGeometry();
        using (var g = geometry.Open())
        {
            g.BeginFigure(new Point(to.X, to.Y), true);
            g.LineTo(new Point(back.X + side.X, back.Y + side.Y));
            g.LineTo(new Point(back.X - side.X, back.Y - side.Y));
            g.EndFigure(true);
        }
        context.DrawGeometry(brush, null, geometry);
    }

    static void DrawCurve(DrawingContext context, Vec2 start, Vec2 end)
    {
        var bend = Math.Max(40, Math.Abs(end.X - start.X) * 0.5);
        var geometry = new StreamGeometry();
        using (var g = geometry.Open())
        {
            g.BeginFigure(new Point(start.X, start.Y), false);
            g.CubicBezierTo(new Point(start.X + bend, start.Y), new Point(end.X - bend, end.Y), new Point(end.X, end.Y));
            g.EndFigure(false);
        }
        context.DrawGeometry(null, LinkPen, geometry);
    }

    void DrawNode(DrawingContext context, AnimationNodeLayout layout, bool selected, bool error)
    {
        var b = layout.Bounds;
        var rect = new Rect(b.X, b.Y, b.Width, b.Height);
        var isState = layout.Node.Kind == AnimationGraphNodeKind.State;
        var header = isState ? StateHeader : BlendHeader;
        context.DrawRectangle(NodeBody, NodeBorder, rect, 4, 4);
        context.DrawRectangle(header, null, new Rect(b.X, b.Y, b.Width, AnimationGraphGeometry.HeaderHeight), 4, 4);
        context.FillRectangle(header, new Rect(b.X, b.Y + AnimationGraphGeometry.HeaderHeight - 4, b.Width, 4));
        var name = _editor.Label(layout.Node.Id);
        var title = isState && layout.Node.Get("name") == _editor.Document.Graph.Entry ? $"▶ {name}" : name;
        DrawText(context, title, new Point(b.X + 8, b.Y + 5), 12, Text, b.Width - 24, bold: true);
        var rows = isState ? StateRows(layout.Node) : BlendRows(layout.Node);
        var y = b.Y + AnimationGraphGeometry.HeaderHeight + 2;
        foreach (var (row, dim) in rows)
        {
            DrawText(context, row, new Point(b.X + 12, y), 11, dim ? DimText : Text, b.Width - 20);
            y += AnimationGraphGeometry.RowHeight;
        }
        if (isState)
        {
            DrawPin(context, layout.Handle, ArrowBrush, false);
            DrawPin(context, layout.MotionInput, LinkBrush, _geometry.Links.Any(l => l.State == layout.Node.Id));
        }
        else
        {
            DrawPin(context, layout.BlendOutput, LinkBrush, _geometry.Links.Any(l => l.Blend == layout.Node.Id));
        }
        if (selected || error)
        {
            context.DrawRectangle(null, error ? ErrorBorder : SelectedBorder, rect.Inflate(1), 5, 5);
        }
    }

    static void DrawPin(DrawingContext context, Vec2 at, IBrush brush, bool filled) =>
        context.DrawEllipse(filled ? brush : NodeBody, new Pen(brush, 1.5), new Point(at.X, at.Y), AnimationGraphGeometry.PinRadius, AnimationGraphGeometry.PinRadius);

    static IEnumerable<(string Text, bool Dim)> StateRows(AnimationGraphNode state)
    {
        var motion = state.Get("motion");
        yield return (GraphValue.Parse(motion ?? "") is GraphLink ? "blend" : motion ?? "no motion", motion == null);
        var details = new List<string>();
        if (state.Get("speed") is { } speed)
        {
            details.Add($"× {speed}");
        }
        details.Add(state.Get("loop") == "false" ? "once" : "loops");
        yield return (string.Join("  ·  ", details), true);
    }

    static IEnumerable<(string Text, bool Dim)> BlendRows(AnimationGraphNode blend)
    {
        yield return ($"by {blend.Get("parameter") ?? "no parameter"}", true);
        foreach (var (_, clip, at) in AnimationGraphEditor.InputsOf(blend))
        {
            yield return ($"{clip ?? "no clip"}  at {at ?? "?"}", false);
        }
    }

    static void DrawGlyph(DrawingContext context, TransitionLayout t, bool selected, bool error)
    {
        var g = t.Glyph;
        var rect = new Rect(g.X, g.Y, g.Width, g.Height);
        context.DrawRectangle(GlyphBody, NodeBorder, rect, 9, 9);
        var label = t.Node.Get("when") ?? (t.Node.Get("exit_time") is { } exit ? $"after {exit}" : "");
        if (t.Node.Get("from") == "any")
        {
            label = label == "" ? "any" : $"any: {label}";
        }
        DrawText(context, label, new Point(g.X + 8, g.Y + 3), 11, Text, g.Width - 14);
        if (selected || error)
        {
            context.DrawRectangle(null, error ? ErrorBorder : SelectedBorder, rect.Inflate(1), 10, 10);
        }
    }

    static SelectMode ModeOf(KeyModifiers modifiers) =>
        modifiers.HasFlag(KeyModifiers.Shift) ? SelectMode.Add : modifiers.HasFlag(KeyModifiers.Control) ? SelectMode.Toggle : SelectMode.Replace;

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        if (_gesture != Gesture.None)
        {
            return;
        }
        Focus();
        var point = e.GetCurrentPoint(this);
        _start = _last = point.Position;
        if (point.Properties.IsRightButtonPressed || point.Properties.IsMiddleButtonPressed)
        {
            _gesture = point.Properties.IsRightButtonPressed ? Gesture.PanClick : Gesture.Pan;
        }
        else if (point.Properties.IsLeftButtonPressed)
        {
            var hit = _geometry.HitTest(ToCanvas(point.Position));
            _dragEnd = ToCanvas(point.Position);
            _detachedFrom = null;
            switch (hit.Kind)
            {
                case AnimationGraphHitKind.StateHandle:
                    (_gesture, _dragFrom) = (Gesture.Transition, hit.Node);
                    break;
                case AnimationGraphHitKind.BlendOutput:
                    (_gesture, _dragFrom) = (Gesture.Link, hit.Node);
                    break;
                case AnimationGraphHitKind.MotionInput when _geometry.Links.FirstOrDefault(l => l.State == hit.Node) is { Blend: not 0 } link:
                    // A linked state gives up its link, which the drag then carries from its blend.
                    (_gesture, _dragFrom, _detachedFrom) = (Gesture.Link, link.Blend, hit.Node);
                    break;
                case AnimationGraphHitKind.Node or AnimationGraphHitKind.Transition or AnimationGraphHitKind.MotionInput:
                    if (!_editor.Selection.Contains(hit.Node) || e.KeyModifiers != KeyModifiers.None)
                    {
                        _editor.Select([hit.Node], ModeOf(e.KeyModifiers));
                    }
                    _pressed = hit.Node;
                    _gesture = Gesture.Click;
                    break;
                default:
                    _pressed = 0;
                    _gesture = Gesture.Click;
                    break;
            }
        }
        if (_gesture != Gesture.None)
        {
            e.Pointer.Capture(this);
            e.Handled = true;
        }
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        var position = e.GetPosition(this);
        var delta = position - _last;
        _last = position;
        var moved = position - _start;
        var far = Gestures.MovedPast(moved);
        switch (_gesture)
        {
            case Gesture.PanClick when far:
                _gesture = Gesture.Pan;
                break;
            case Gesture.Pan:
                _view = _view.Pan(delta.X, delta.Y);
                InvalidateVisual();
                break;
            case Gesture.Click when far:
                if (_pressed != 0)
                {
                    _moveStarts = _editor.MoveStarts();
                    _editor.BeginMove();
                    _gesture = Gesture.Move;
                }
                else
                {
                    _gesture = Gesture.Box;
                }
                break;
            case Gesture.Move:
                _editor.MoveSelected(_moveStarts, _view.ToCanvasDelta(moved.X, moved.Y));
                break;
            case Gesture.Box:
                InvalidateVisual();
                break;
            case Gesture.Transition or Gesture.Link:
                _dragEnd = ToCanvas(position);
                InvalidateVisual();
                break;
        }
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);
        var position = e.GetPosition(this);
        switch (_gesture)
        {
            case Gesture.PanClick:
                OpenAddMenu(ToCanvas(position));
                break;
            case Gesture.Click:
                if (_pressed == 0)
                {
                    _editor.Select([], ModeOf(e.KeyModifiers) == SelectMode.Replace ? SelectMode.Replace : SelectMode.Add);
                }
                else if (e.KeyModifiers == KeyModifiers.None)
                {
                    _editor.Select([_pressed]);
                }
                break;
            case Gesture.Move:
                _editor.EndMove();
                break;
            case Gesture.Box:
                _editor.Select(_geometry.InBox(ToCanvas(_start), ToCanvas(position)), ModeOf(e.KeyModifiers));
                break;
            case Gesture.Transition:
                if (StateAt(ToCanvas(position)) is { } to && _editor.AddTransition(_dragFrom, to) == null && to != _dragFrom)
                {
                    _shell.Console.Add(Model.LogLevel.Warning, "animation graph: a transition goes between two states with names");
                }
                break;
            case Gesture.Link:
                _editor.MoveBlendLink(_dragFrom, _detachedFrom, StateAt(ToCanvas(position)));
                break;
        }
        _gesture = Gesture.None;
        e.Pointer.Capture(null);
        InvalidateVisual();
    }

    // The state at a point, on its body or a pin of it.
    int? StateAt(Vec2 at)
    {
        var hit = _geometry.HitTest(at);
        return hit.Kind is AnimationGraphHitKind.Node or AnimationGraphHitKind.StateHandle or AnimationGraphHitKind.MotionInput
            && _geometry.Find(hit.Node) is { Node.Kind: AnimationGraphNodeKind.State } ? hit.Node : null;
    }

    void OpenAddMenu(Vec2 at)
    {
        var state = new MenuItem { Header = "Add State" };
        state.Click += (_, _) => _editor.AddState(at.X, at.Y);
        var blend = new MenuItem { Header = "Add Blend" };
        blend.Click += (_, _) => _editor.AddBlend(at.X, at.Y);
        var menu = new MenuFlyout { Placement = PlacementMode.Pointer };
        menu.Items.Add(state);
        menu.Items.Add(blend);
        menu.ShowAt(this, showAtPointer: true);
    }

    protected override void OnPointerCaptureLost(PointerCaptureLostEventArgs e)
    {
        base.OnPointerCaptureLost(e);
        if (_gesture == Gesture.Move)
        {
            _editor.EndMove();
        }
        _gesture = Gesture.None;
        InvalidateVisual();
    }

    protected override void OnPointerWheelChanged(PointerWheelEventArgs e)
    {
        base.OnPointerWheelChanged(e);
        var at = e.GetPosition(this);
        _view = _view.ZoomAbout(at.X, at.Y, Math.Pow(Canvas2DView.WheelStep, e.Delta.Y), MinZoom, MaxZoom);
        InvalidateVisual();
        e.Handled = true;
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        switch (e.Key)
        {
            case Key.Delete or Key.Back:
                _editor.DeleteSelected();
                break;
            case Key.F when e.KeyModifiers == KeyModifiers.None:
                Frame();
                break;
            case Key.Space or Key.Tab when e.KeyModifiers == KeyModifiers.None:
                OpenAddMenu(ToCanvas(_last));
                break;
            case Key.Escape when _gesture == Gesture.Move:
                _editor.EndMove(cancel: true);
                _gesture = Gesture.None;
                break;
            default:
                return;
        }
        e.Handled = true;
    }
}
