using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Graphs;
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
/// own units under a pan and a zoom, with the gestures of every graph canvas (NodeGraphCanvas). Its own drags take a
/// transition from a state's rim to another state, and a tether from a blend's foot to a state; a tether dragged off a
/// state's chip comes away.
/// </summary>
public sealed class AnimationGraphCanvas : NodeGraphCanvas
{
    const double ArrowHead = 8;
    const double StateCorner = 10;
    const double BlendCorner = 2;

    static readonly IBrush NodeBody = new SolidColorBrush(Color.Parse("#2A2A2E"));
    static readonly IPen NodeBorder = new Pen(new SolidColorBrush(Color.Parse("#3C3C42")), 1);
    // A state's rim: where its transitions start and end, brighter where a press or a drop would take it.
    static readonly IBrush Rim = new SolidColorBrush(Color.Parse("#3F4F63"));
    static readonly IBrush RimHot = new SolidColorBrush(Color.Parse("#8FA9C7"));
    static readonly IBrush ChipBody = new SolidColorBrush(Color.Parse("#222226"));
    static readonly IPen SelectedBorder = new Pen(new SolidColorBrush(Palette.Accent), 2);
    static readonly IPen ErrorBorder = new Pen(new SolidColorBrush(Palette.Error), 2, new DashStyle([3, 2], 0));
    static readonly IBrush Text = new SolidColorBrush(Color.Parse("#E4E4E8"));
    static readonly IBrush DimText = new SolidColorBrush(Color.Parse("#8A8A92"));
    static readonly IBrush BlendHeader = new SolidColorBrush(Color.Parse("#39303F"));
    static readonly IBrush ArrowBrush = new SolidColorBrush(Color.Parse("#A8A8B0"));
    static readonly IPen ArrowPen = new Pen(ArrowBrush, 1.5);
    // A blend's tether: dotted, and with no head, since nothing travels along it as a transition does.
    static readonly IBrush TetherBrush = new SolidColorBrush(Color.Parse("#D97AB5"));
    static readonly IPen TetherPen = new Pen(TetherBrush, 1.5, new DashStyle([1, 3], 0), PenLineCap.Round);
    static readonly IPen TetherEdge = new Pen(TetherBrush, 1);
    static readonly IBrush FeedBody = new SolidColorBrush(Color.Parse("#2F2530"));
    static readonly Cursor CrossCursor = new(StandardCursorType.Cross);
    static readonly Cursor HandCursor = new(StandardCursorType.Hand);
    static readonly IBrush GlyphBody = new SolidColorBrush(Color.Parse("#323238"));
    // The live view: what plays, what it fades from, and the transition between them.
    static readonly Color LiveColor = Color.Parse("#5BC47F");
    static readonly IBrush LiveBrush = new SolidColorBrush(LiveColor);
    static readonly IPen LivePen = new Pen(LiveBrush, 3);
    static readonly IPen LiveRim = new Pen(LiveBrush, AnimationGraphGeometry.RimWidth);
    static readonly IBrush LastTakenBrush = new SolidColorBrush(LiveColor, 0.45);
    static readonly IPen LastTakenPen = new Pen(LastTakenBrush, 2);

    // The canvas's own drags: a transition from a state's rim, and a blend's tether.
    enum Drag
    {
        None,
        Transition,
        Link,
    }

    readonly EditorShell _shell;
    readonly AnimationGraphEditor _editor;
    AnimationGraphGeometry _geometry;
    Drag _drag;
    // The state whose rim the mouse is on.
    int _rimUnderMouse;
    // A drag from a state's rim or a blend's feed, and the state that a tether came off, if any.
    int _dragFrom;
    int? _detachedFrom;
    Vec2 _dragEnd;

    public AnimationGraphCanvas(EditorShell shell, AnimationGraphEditor editor)
        : base(editor)
    {
        _shell = shell;
        _editor = editor;
        _geometry = editor.Geometry();
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

    protected override IGraphLayout Layout => _geometry;

    protected override void DrawGraph(DrawingContext context)
    {
        var problems = _editor.Problems.Where(p => p.Error && p.Node != null).Select(p => p.Node!.Value).ToHashSet();
        foreach (var t in _geometry.Transitions)
        {
            DrawArrow(context, t, ArrowPen, ArrowBrush);
        }
        // What plays, in the preview or the game. The last transition's arrow goes under its glyph, like the others, so
        // its words stay whole.
        var live = _editor.ShownView;
        if (live != null && _geometry.FindTransition((int)live.Transition) is { } taken)
        {
            var fading = AnimationGraphEditor.FadeOf(live) < 1;
            DrawArrow(context, taken, fading ? LivePen : LastTakenPen, fading ? LiveBrush : LastTakenBrush);
        }
        foreach (var link in _geometry.Links)
        {
            DrawLine(context, TetherPen, link.Start, link.End);
        }
        foreach (var node in _geometry.Nodes)
        {
            DrawNode(context, node, _editor.Selection.Contains(node.Node.Id), problems.Contains(node.Node.Id));
        }
        foreach (var t in _geometry.Transitions)
        {
            DrawGlyph(context, t, _editor.Selection.Contains(t.Node.Id), problems.Contains(t.Node.Id));
        }
        if (live != null)
        {
            DrawLive(context, live);
        }
        DrawDrag(context);
    }

    // The state that plays, with its progress through this play; the state that it fades from, by what is left of the
    // fade; and the glyph of the last transition that it took, bright during its fade. A node that the document does not
    // have, as when it has changed since it cooked, has no place to show.
    void DrawLive(DrawingContext context, AnimatorView view)
    {
        var fade = AnimationGraphEditor.FadeOf(view);
        if (_geometry.FindTransition((int)view.Transition) is { } taken)
        {
            var g = taken.Glyph;
            context.DrawRectangle(null, fade < 1 ? LivePen : LastTakenPen, new Rect(g.X, g.Y, g.Width, g.Height).Inflate(1), 10, 10);
        }
        if (fade < 1 && _geometry.Find((int)view.Source) is { } source)
        {
            DrawLiveRim(context, source, new Pen(new SolidColorBrush(LiveColor, 1 - fade), AnimationGraphGeometry.RimWidth));
        }
        if (_geometry.Find((int)view.State) is { } state)
        {
            var b = state.Bounds;
            DrawLiveRim(context, state, fade < 1 ? new Pen(new SolidColorBrush(LiveColor, fade), AnimationGraphGeometry.RimWidth) : LiveRim);
            var play = view.Progress - Math.Floor(view.Progress);
            context.FillRectangle(LiveBrush, new Rect(b.X + StateCorner, b.Y + b.Height - 3, (b.Width - 2 * StateCorner) * play, 3));
        }
    }

    static void DrawLiveRim(DrawingContext context, AnimationNodeLayout state, IPen pen)
    {
        var half = AnimationGraphGeometry.RimWidth / 2;
        var b = state.Bounds;
        context.DrawRectangle(null, pen, new Rect(b.X, b.Y, b.Width, b.Height).Inflate(half), StateCorner + half, StateCorner + half);
    }

    void DrawDrag(DrawingContext context)
    {
        if (_drag == Drag.Transition && _geometry.Find(_dragFrom) is { } state)
        {
            // Over another state, it shows where the arrow will land: on the rim, and not on what the state says.
            var target = StateAt(_dragEnd) is { } over && over != _dragFrom ? _geometry.Find(over) : null;
            var toward = target == null ? _dragEnd : new Vec2(target.Bounds.X + target.Bounds.Width / 2, target.Bounds.Y + target.Bounds.Height / 2);
            var start = state.EdgeToward(toward);
            var end = target?.EdgeToward(start) ?? _dragEnd;
            DrawLine(context, ArrowPen, start, end);
            DrawHead(context, start, end, ArrowBrush);
        }
        if (_drag == Drag.Link && _geometry.Find(_dragFrom) is { } blend)
        {
            DrawLine(context, TetherPen, blend.EdgeToward(_dragEnd), _dragEnd);
        }
    }

    // Whether a state's rim lights: the mouse is on it, or a transition being dragged would land on it.
    bool RimIsHot(int state) =>
        Idle ? _rimUnderMouse == state : _drag == Drag.Transition && (state == _dragFrom || StateAt(_dragEnd) == state);

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

    void DrawNode(DrawingContext context, AnimationNodeLayout layout, bool selected, bool error)
    {
        if (layout.Node.Kind == AnimationGraphNodeKind.State)
        {
            DrawState(context, layout, selected, error);
        }
        else
        {
            DrawBlend(context, layout, selected, error);
        }
    }

    // A state is a place in the machine: a rounded body in a rim, which its transitions' arrows land on.
    void DrawState(DrawingContext context, AnimationNodeLayout layout, bool selected, bool error)
    {
        var b = layout.Bounds;
        var rect = new Rect(b.X, b.Y, b.Width, b.Height);
        var rim = AnimationGraphGeometry.RimWidth;
        var outer = rect.Inflate(rim);
        context.DrawRectangle(RimIsHot(layout.Node.Id) ? RimHot : Rim, null, outer, StateCorner + rim, StateCorner + rim);
        context.DrawRectangle(NodeBody, null, rect, StateCorner, StateCorner);
        var name = _editor.Label(layout.Node.Id);
        var title = layout.Node.Get("name") == _editor.Document.Graph.Entry ? $"▶ {name}" : name;
        DrawText(context, title, new Point(b.X + 12, b.Y + 5), 13, Text, b.Width - 24, bold: true);

        // What it plays: a clip, or the blend that its tether comes from, in the tether's color.
        var chip = layout.Chip;
        var chipRect = new Rect(chip.X, chip.Y, chip.Width, chip.Height);
        var link = _geometry.Links.FirstOrDefault(l => l.State == layout.Node.Id);
        var linked = link.Blend != 0;
        var landing = _drag == Drag.Link && StateAt(_dragEnd) == layout.Node.Id;
        context.DrawRectangle(ChipBody, linked || landing ? TetherEdge : NodeBorder, chipRect, 3, 3);
        var motion = layout.Node.Get("motion");
        var chipText = linked ? _editor.Label(link.Blend) : motion ?? "No motion";
        DrawText(context, chipText, new Point(chip.X + 6, chip.Y + 3), 11, linked ? TetherBrush : motion == null ? DimText : Text, chip.Width - 12);

        var plays = layout.Node.Get("loop") == "false" ? "Plays once" : "Loops";
        var speed = layout.Node.Get("speed") is { } s ? $"{plays} at {s}×" : plays;
        DrawText(context, speed, new Point(b.X + 12, chip.Y + chip.Height + 2), 11, DimText, b.Width - 24);
        if (selected || error)
        {
            context.DrawRectangle(null, error ? ErrorBorder : SelectedBorder, outer.Inflate(1), StateCorner + rim + 1, StateCorner + rim + 1);
        }
    }

    // A blend is not a place in the machine: nothing arrives at it, and it feeds the states that play it from its foot.
    void DrawBlend(DrawingContext context, AnimationNodeLayout layout, bool selected, bool error)
    {
        var b = layout.Bounds;
        var rect = new Rect(b.X, b.Y, b.Width, b.Height);
        context.DrawRectangle(NodeBody, NodeBorder, rect, BlendCorner, BlendCorner);
        context.FillRectangle(BlendHeader, new Rect(b.X, b.Y, b.Width, AnimationGraphGeometry.HeaderHeight));
        DrawText(context, _editor.Label(layout.Node.Id), new Point(b.X + 8, b.Y + 5), 12, Text, b.Width - 16, bold: true);
        var y = b.Y + AnimationGraphGeometry.HeaderHeight + 2;
        foreach (var (_, clip, at) in AnimationGraphEditor.InputsOf(layout.Node))
        {
            DrawText(context, clip ?? "No clip", new Point(b.X + 8, y), 11, Text, b.Width / 2);
            DrawText(context, at == null ? "" : $"at {at}", new Point(b.X + b.Width / 2 + 24, y), 11, DimText, b.Width / 2 - 28);
            y += AnimationGraphGeometry.RowHeight;
        }

        var feed = layout.Feed;
        var states = _geometry.Links.Where(l => l.Blend == layout.Node.Id).Select(l => _editor.Label(l.State)).ToList();
        context.FillRectangle(FeedBody, new Rect(feed.X + 1, feed.Y, feed.Width - 2, feed.Height - 1));
        var words = states.Count == 0 ? "Drag to a state" : $"Plays in {string.Join(", ", states)}";
        DrawText(context, words, new Point(feed.X + 8, feed.Y + 3), 11, TetherBrush, feed.Width - 16);
        if (selected || error)
        {
            context.DrawRectangle(null, error ? ErrorBorder : SelectedBorder, rect.Inflate(1), BlendCorner, BlendCorner);
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
        var inside = g.Width - 14;
        DrawText(context, label, new Point(g.X + 7 + Math.Max(0, (inside - TextWidth(label, 11)) / 2), g.Y + 3), 11, Text, inside);
        if (selected || error)
        {
            context.DrawRectangle(null, error ? ErrorBorder : SelectedBorder, rect.Inflate(1), 10, 10);
        }
    }

    protected override CanvasPress PressAt(Vec2 at, KeyModifiers modifiers)
    {
        var hit = _geometry.HitTest(at, View.Zoom);
        _dragEnd = at;
        _detachedFrom = null;
        switch (hit.Kind)
        {
            case AnimationGraphHitKind.StateRim:
                (_drag, _dragFrom) = (Drag.Transition, hit.Node);
                return new CanvasPress(CanvasPressKind.Connect);
            case AnimationGraphHitKind.BlendFeed:
                (_drag, _dragFrom) = (Drag.Link, hit.Node);
                return new CanvasPress(CanvasPressKind.Connect);
            case AnimationGraphHitKind.MotionChip when _geometry.Links.FirstOrDefault(l => l.State == hit.Node) is { Blend: not 0 } link:
                // A state's chip gives up its tether, which the drag then carries from its blend.
                (_drag, _dragFrom, _detachedFrom) = (Drag.Link, link.Blend, hit.Node);
                return new CanvasPress(CanvasPressKind.Connect);
            case AnimationGraphHitKind.Node or AnimationGraphHitKind.Transition or AnimationGraphHitKind.MotionChip:
                return new CanvasPress(CanvasPressKind.Select, hit.Node);
            default:
                return new CanvasPress(CanvasPressKind.Empty);
        }
    }

    protected override void ConnectMoved(Vec2 at) => _dragEnd = at;

    protected override void EndConnect(Vec2 at)
    {
        var drag = _drag;
        _drag = Drag.None;
        if (drag == Drag.Transition)
        {
            if (StateAt(at) is { } to && _editor.AddTransition(_dragFrom, to) == null && to != _dragFrom)
            {
                _shell.Console.Add(Model.LogLevel.Warning, "animation graph: a transition goes between two states with names");
            }
        }
        else if (drag == Drag.Link)
        {
            _editor.MoveBlendLink(_dragFrom, _detachedFrom, StateAt(at));
        }
    }

    protected override void CancelConnect() => _drag = Drag.None;

    protected override void Hover(Vec2 at) => ShowWhatAPressWouldTake(at);

    // A rim lights and the cursor changes where a press would start a connection, since nothing else there says so.
    void ShowWhatAPressWouldTake(Vec2 at)
    {
        var hit = _geometry.HitTest(at, View.Zoom);
        var rim = hit.Kind == AnimationGraphHitKind.StateRim ? hit.Node : 0;
        Cursor = hit.Kind switch
        {
            AnimationGraphHitKind.StateRim => CrossCursor,
            AnimationGraphHitKind.BlendFeed => HandCursor,
            AnimationGraphHitKind.MotionChip when _geometry.Links.Any(l => l.State == hit.Node) => HandCursor,
            _ => Cursor.Default,
        };
        if (rim != _rimUnderMouse)
        {
            _rimUnderMouse = rim;
            InvalidateVisual();
        }
    }

    protected override void HoverEnded()
    {
        if (_rimUnderMouse != 0)
        {
            _rimUnderMouse = 0;
            InvalidateVisual();
        }
    }

    // The state at a point, on its body, its chip or its rim.
    int? StateAt(Vec2 at)
    {
        var hit = _geometry.HitTest(at, View.Zoom);
        return hit.Kind is AnimationGraphHitKind.Node or AnimationGraphHitKind.StateRim or AnimationGraphHitKind.MotionChip
            && _geometry.Find(hit.Node) is { Node.Kind: AnimationGraphNodeKind.State } ? hit.Node : null;
    }

    protected override void OpenAddMenu(Vec2 at)
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
}
