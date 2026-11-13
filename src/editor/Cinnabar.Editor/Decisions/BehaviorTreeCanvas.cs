using Avalonia;
using Avalonia.Input;
using Avalonia.Media;
using Cinnabar.Editor.Graphs;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using static Cinnabar.Editor.Materials.CanvasDrawing;

namespace Cinnabar.Editor.Decisions;

/// <summary>
/// The decision editor's canvas (see docs/editor/decision-editor.md#the-canvas): a behavior tree, or an HTN domain, from
/// the top down, its children left to right in their order, with the gestures of every graph canvas (NodeGraphCanvas).
/// Each kind of node has a shape of its own, and its decorators are bands across its top. A drag from a node's foot to a
/// node makes it a child, and to an empty place opens the add menu for a new child. The live view lights the nodes that
/// run and marks the last result of each that ran, or lights an HTN plan's path and its action that runs.
/// </summary>
public sealed class BehaviorTreeCanvas : NodeGraphCanvas
{
    const double Corner = 6;

    static readonly IBrush NodeBody = new SolidColorBrush(Color.Parse("#2A2A2E"));
    static readonly IPen NodeBorder = new Pen(new SolidColorBrush(Color.Parse("#3C3C42")), 1);
    static readonly IPen SelectedBorder = new Pen(new SolidColorBrush(Palette.Accent), 2);
    static readonly IPen ErrorBorder = new Pen(new SolidColorBrush(Palette.Error), 2, new DashStyle([3, 2], 0));
    static readonly IBrush Text = new SolidColorBrush(Color.Parse("#E4E4E8"));
    static readonly IBrush DimText = new SolidColorBrush(Color.Parse("#8A8A92"));
    static readonly IBrush BandBody = new SolidColorBrush(Color.Parse("#34343A"));
    static readonly IBrush BandText = new SolidColorBrush(Color.Parse("#C9B37A"));
    static readonly IBrush FootBody = new SolidColorBrush(Color.Parse("#4A4A52"));
    static readonly IBrush FootHot = new SolidColorBrush(Color.Parse("#8FA9C7"));
    static readonly IBrush EdgeBrush = new SolidColorBrush(Color.Parse("#A8A8B0"));
    static readonly IPen EdgePen = new Pen(EdgeBrush, 1.5);
    static readonly Cursor HandCursor = new(StandardCursorType.Hand);
    // The headers, by what the node is: composites run children, leaves act or test.
    static readonly IBrush CompositeHeader = new SolidColorBrush(Color.Parse("#2F3B4F"));
    static readonly IBrush ActionHeader = new SolidColorBrush(Color.Parse("#2F4A3A"));
    static readonly IBrush WaitHeader = new SolidColorBrush(Color.Parse("#3E3A2C"));
    static readonly IBrush SetHeader = new SolidColorBrush(Color.Parse("#3F2F44"));
    static readonly IBrush ConditionHeader = new SolidColorBrush(Color.Parse("#4A3A2A"));
    static readonly IBrush TaskHeader = new SolidColorBrush(Color.Parse("#2F3B4F"));
    static readonly IBrush MethodHeader = new SolidColorBrush(Color.Parse("#2E4148"));
    static readonly IBrush UnknownHeader = new SolidColorBrush(Color.Parse("#3A3A3E"));
    // The live view: what runs, and how each node that ran last ended.
    static readonly IBrush LiveBrush = new SolidColorBrush(Color.Parse("#5BC47F"));
    static readonly IPen LivePen = new Pen(LiveBrush, 3);
    static readonly IPen LiveEdge = new Pen(LiveBrush, 2.5);
    // An HTN plan's path, which its action that runs is on.
    static readonly IPen PathPen = new Pen(LiveBrush, 1.5, new DashStyle([4, 2], 0));
    static readonly IBrush SucceededBrush = new SolidColorBrush(Color.Parse("#5BC47F"));
    static readonly IBrush FailedBrush = new SolidColorBrush(Color.Parse("#D9534F"));
    static readonly IBrush AbortedBrush = new SolidColorBrush(Color.Parse("#C9A23F"));

    readonly EditorShell _shell;
    readonly DecisionEditor _editor;
    readonly NodePicker<int?> _picker;
    BehaviorTreeGeometry _geometry;
    // A drag from a composite's foot, and where it is now; and the foot that the mouse is on.
    int _dragFrom;
    Vec2 _dragEnd;
    int _footUnderMouse;

    public BehaviorTreeCanvas(EditorShell shell, DecisionEditor editor)
        : base(editor)
    {
        _shell = shell;
        _editor = editor;
        _geometry = editor.Geometry();
        _picker = new NodePicker<int?>(editor.Picks);
        _picker.Picked += (pick, at, parent) => _editor.AddPicked(pick, at, parent);
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
        var live = _editor.Live;
        var (path, running) = _editor.LivePath();
        var planned = _editor.LivePlan != null;
        foreach (var edge in _geometry.Edges)
        {
            DrawEdge(context, edge, path.Contains(edge.Parent) && path.Contains(edge.Child) ? LiveEdge : EdgePen);
        }
        foreach (var node in _geometry.Nodes)
        {
            var id = node.Node.Id;
            var result = live?.Nodes.FirstOrDefault(n => n.Id == id);
            var lit = running == id || (!planned && path.Contains(id)) ? LivePen : planned && path.Contains(id) ? PathPen : null;
            DrawNode(context, node, _editor.Selection.Contains(id), problems.Contains(id), lit, result);
        }
        if (Connecting && _geometry.Find(_dragFrom) is { } from)
        {
            var target = NodeAt(_dragEnd) is { } over && over != _dragFrom ? _geometry.Find(over) : null;
            DrawEdgeLine(context, EdgePen, from.Bottom, target?.Top ?? _dragEnd);
        }
    }

    // An edge leaves its parent's foot, turns across, and arrives at its child's top, with the child's place among its
    // siblings by the turn, since that is the order that the parent runs them in.
    static void DrawEdge(DrawingContext context, TreeEdgeLayout edge, IPen pen)
    {
        DrawEdgeLine(context, pen, edge.Start, edge.End);
        var middle = (edge.Start.Y + edge.End.Y) / 2;
        DrawText(context, edge.Order.ToString(System.Globalization.CultureInfo.InvariantCulture), new Point(edge.End.X + 4, middle + 2), 10, DimText, 20);
    }

    static void DrawEdgeLine(DrawingContext context, IPen pen, Vec2 start, Vec2 end)
    {
        var middle = (start.Y + end.Y) / 2;
        var geometry = new StreamGeometry();
        using (var g = geometry.Open())
        {
            g.BeginFigure(new Point(start.X, start.Y), false);
            g.LineTo(new Point(start.X, middle));
            g.LineTo(new Point(end.X, middle));
            g.LineTo(new Point(end.X, end.Y));
            g.EndFigure(false);
        }
        context.DrawGeometry(null, pen, geometry);
    }

    void DrawNode(DrawingContext context, TreeNodeLayout layout, bool selected, bool error, IPen? lit, AgentNode? live)
    {
        var b = layout.Bounds;
        var rect = new Rect(b.X, b.Y, b.Width, b.Height);
        var shape = Shape(layout.Shape, rect);
        context.DrawGeometry(NodeBody, NodeBorder, shape);
        using (context.PushGeometryClip(shape))
        {
            var y = b.Y;
            foreach (var band in layout.Bands)
            {
                context.FillRectangle(BandBody, new Rect(b.X, y, b.Width, BehaviorTreeGeometry.RowHeight - 1));
                DrawText(context, band, new Point(b.X + 10, y + 2), 11, BandText, b.Width - 20);
                y += BehaviorTreeGeometry.RowHeight;
            }
            var header = layout.Header;
            context.FillRectangle(HeaderBrush(layout.Shape), new Rect(header.X, header.Y, header.Width, header.Height));
            DrawText(context, Title(layout), new Point(header.X + 10, header.Y + 5), 13, Text, header.Width - 20, bold: true);
            y = header.Y + header.Height + 2;
            foreach (var row in layout.Rows)
            {
                DrawText(context, row, new Point(b.X + 10, y), 11, layout.Node.Get("action") == null && layout.Shape == TreeShape.Action ? DimText : Text, b.Width - 20);
                y += BehaviorTreeGeometry.RowHeight;
            }
        }
        if (layout.HasFoot)
        {
            var foot = layout.Foot;
            var hot = Idle ? _footUnderMouse == layout.Node.Id : Connecting && _dragFrom == layout.Node.Id;
            context.DrawRectangle(hot ? FootHot : FootBody, null, new Rect(foot.X, foot.Y, foot.Width, foot.Height), 0, 0);
        }
        if (lit != null)
        {
            context.DrawGeometry(null, lit, Shape(layout.Shape, rect.Inflate(3)));
        }
        if (live is { } result && ResultBrush(result.Last) is { } brush)
        {
            context.DrawEllipse(brush, null, new Point(b.X + b.Width - 10, layout.Header.Y + 13), 4, 4);
        }
        if (selected || error)
        {
            context.DrawGeometry(null, error ? ErrorBorder : SelectedBorder, Shape(layout.Shape, rect.Inflate(1)));
        }
    }

    // What a node's header says: an action's name, or the node's kind, with a composite's mark of how it runs, and a
    // task's or a method's ID, since a domain has several.
    string Title(TreeNodeLayout layout) => layout.Node.Kind switch
    {
        "sequence" => "→  Sequence",
        "selector" => "?  Selector",
        "parallel" => "⇉  Parallel",
        _ when layout.Shape is TreeShape.Task or TreeShape.Method => $"{_editor.Label(layout.Node.Id)} {layout.Node.Id}",
        _ => _editor.Label(layout.Node.Id),
    };

    static IBrush? ResultBrush(AgentResult result) => result switch
    {
        AgentResult.Succeeded => SucceededBrush,
        AgentResult.Failed => FailedBrush,
        AgentResult.Aborted => AbortedBrush,
        _ => null,
    };

    static IBrush HeaderBrush(TreeShape shape) => shape switch
    {
        TreeShape.Composite => CompositeHeader,
        TreeShape.Action => ActionHeader,
        TreeShape.Wait => WaitHeader,
        TreeShape.Set => SetHeader,
        TreeShape.Condition => ConditionHeader,
        TreeShape.Task => TaskHeader,
        TreeShape.Method => MethodHeader,
        _ => UnknownHeader,
    };

    // Each kind's outline: a composite or a task square, an action rounded, a method a little rounded, a wait a pill, a
    // condition with cut corners, a set with a notch.
    static Geometry Shape(TreeShape shape, Rect r)
    {
        switch (shape)
        {
            case TreeShape.Action:
                return new RectangleGeometry(r, Corner * 2, Corner * 2);
            case TreeShape.Wait:
                return new RectangleGeometry(r, 13, 13);
            case TreeShape.Method:
                return new RectangleGeometry(r, Corner, Corner);
            case TreeShape.Condition or TreeShape.Set:
                var cut = shape == TreeShape.Condition ? 12.0 : 6.0;
                var geometry = new StreamGeometry();
                using (var g = geometry.Open())
                {
                    g.BeginFigure(new Point(r.X + cut, r.Y), true);
                    g.LineTo(new Point(r.Right - cut, r.Y));
                    g.LineTo(new Point(r.Right, r.Y + cut));
                    g.LineTo(new Point(r.Right, r.Bottom - cut));
                    g.LineTo(new Point(r.Right - cut, r.Bottom));
                    g.LineTo(new Point(r.X + cut, r.Bottom));
                    g.LineTo(new Point(r.X, r.Bottom - cut));
                    g.LineTo(new Point(r.X, r.Y + cut));
                    g.EndFigure(true);
                }
                return geometry;
            default:
                return new RectangleGeometry(r, 2, 2);
        }
    }

    int? NodeAt(Vec2 at) => _geometry.HitTest(at) is { Kind: TreeHitKind.Node or TreeHitKind.Foot } hit ? hit.Node : null;

    protected override CanvasPress PressAt(Vec2 at, KeyModifiers modifiers)
    {
        var hit = _geometry.HitTest(at);
        switch (hit.Kind)
        {
            case TreeHitKind.Foot:
                (_dragFrom, _dragEnd) = (hit.Node, at);
                return new CanvasPress(CanvasPressKind.Connect);
            case TreeHitKind.Node:
                return new CanvasPress(CanvasPressKind.Select, hit.Node);
            default:
                return new CanvasPress(CanvasPressKind.Empty);
        }
    }

    protected override void ConnectMoved(Vec2 at) => _dragEnd = at;

    protected override void EndConnect(Vec2 at)
    {
        var from = _dragFrom;
        _dragFrom = 0;
        if (NodeAt(at) is not { } child)
        {
            // A drag to an empty place adds a child there.
            _picker.Open(this, at, from);
            return;
        }
        if (child != from && !_editor.AddChild(from, child))
        {
            var why = _editor.Technique == "htn" ? "a task lists methods, and a method tasks and actions" : "which is below it";
            _shell.Console.Add(Model.LogLevel.Warning, $"decision: {_editor.Label(child)} cannot be a child of {_editor.Label(from)}, {why}");
        }
    }

    protected override void CancelConnect() => _dragFrom = 0;

    // A foot lights and the cursor changes where a press would start a child, since nothing else there says so.
    protected override void Hover(Vec2 at)
    {
        var hit = _geometry.HitTest(at);
        var foot = hit.Kind == TreeHitKind.Foot ? hit.Node : 0;
        Cursor = foot != 0 ? HandCursor : Cursor.Default;
        if (foot != _footUnderMouse)
        {
            _footUnderMouse = foot;
            InvalidateVisual();
        }
    }

    protected override void HoverEnded()
    {
        if (_footUnderMouse != 0)
        {
            _footUnderMouse = 0;
            InvalidateVisual();
        }
    }

    protected override void OpenAddMenu(Vec2 at) => _picker.Open(this, at, null);
}
