using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Materials;

/// <summary>
/// The material editor's node canvas (see docs/editor/material-editor.md#material-editor): the graph's nodes and links, drawn in the
/// canvas's own units under a pan and a zoom. The left button selects nodes, drags them, drags a box, and drags a link
/// from a pin to a pin; a link dragged off an input comes away. The right or middle button pans, and a right click
/// without a drag, Space or Tab adds a node. The wheel zooms about the mouse. Delete deletes the selected nodes,
/// Ctrl+D duplicates them, and F frames the graph.
/// </summary>
public sealed class GraphCanvas : Control
{
    const double MinZoom = 0.2;
    const double MaxZoom = 2;

    static readonly Typeface Font = new("Inter");
    static readonly IBrush CanvasBrush = new SolidColorBrush(Color.Parse("#1C1C1F"));
    static readonly IPen MinorGrid = new Pen(new SolidColorBrush(Color.Parse("#242428")), 1);
    static readonly IPen MajorGrid = new Pen(new SolidColorBrush(Color.Parse("#2C2C31")), 1);
    static readonly IBrush NodeBody = new SolidColorBrush(Color.Parse("#2A2A2E"));
    static readonly IPen NodeBorder = new Pen(new SolidColorBrush(Color.Parse("#3C3C42")), 1);
    static readonly IPen SelectedBorder = new Pen(new SolidColorBrush(Palette.Accent), 2);
    static readonly IPen ErrorBorder = new Pen(new SolidColorBrush(Palette.Error), 2, new DashStyle([3, 2], 0));
    static readonly IBrush Text = new SolidColorBrush(Color.Parse("#E4E4E8"));
    static readonly IBrush DimText = new SolidColorBrush(Color.Parse("#8A8A92"));
    static readonly IBrush BoxFill = new SolidColorBrush(Color.Parse("#22E34234"));
    static readonly IPen BoxPen = new Pen(new SolidColorBrush(Palette.Accent), 1);

    enum Gesture
    {
        None,
        Click,
        Move,
        Box,
        Link,
        Pan,
        PanClick,
    }

    readonly EditorShell _shell;
    readonly MaterialEditor _editor;
    readonly NodePicker _picker;
    GraphGeometry _geometry;
    Canvas2DView _view = new(new Vec2(-200, -150), 1);
    Gesture _gesture;
    Point _start;
    Point _last;
    int _pressed;
    Dictionary<int, Vec2> _moveStarts = [];
    // A link being dragged: from an output, or back from an input, and the input that it came off, if any.
    (int Node, string Pin, bool FromOutput) _linkStart;
    (int Node, string Input)? _detached;
    Vec2 _linkEnd;
    bool _framed;

    public GraphCanvas(EditorShell shell, MaterialEditor editor)
    {
        _shell = shell;
        _editor = editor;
        _geometry = editor.Geometry();
        Focusable = true;
        ClipToBounds = true;
        _picker = new NodePicker(editor);
        _picker.Picked += OnPicked;
        AttachedToVisualTree += (_, _) =>
        {
            _editor.Changed += OnChanged;
            _editor.SelectionChanged += InvalidateVisual;
            _editor.ProblemsChanged += InvalidateVisual;
            _shell.Assets.Changed += OnChanged;
            OnChanged();
        };
        DetachedFromVisualTree += (_, _) =>
        {
            _editor.Changed -= OnChanged;
            _editor.SelectionChanged -= InvalidateVisual;
            _editor.ProblemsChanged -= InvalidateVisual;
            _shell.Assets.Changed -= OnChanged;
        };
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
        context.FillRectangle(CanvasBrush, new Rect(Bounds.Size));
        DrawGrid(context);
        using (context.PushTransform(Matrix.CreateTranslation(-_view.Offset.X, -_view.Offset.Y) * Matrix.CreateScale(_view.Zoom, _view.Zoom)))
        {
            foreach (var link in _geometry.Links)
            {
                DrawLink(context, link.Start, link.End, link.Type);
            }
            if (_gesture == Gesture.Link && PinPoint(_linkStart) is { } from)
            {
                var (start, end) = _linkStart.FromOutput ? (from.Point, _linkEnd) : (_linkEnd, from.Point);
                DrawLink(context, start, end, from.Type);
            }
            var problems = _editor.Problems.Where(p => p.Error && p.Node != null).Select(p => p.Node!.Value).ToHashSet();
            foreach (var node in _geometry.Nodes)
            {
                DrawNode(context, node, _editor.Selection.Contains(node.Node.Id), problems.Contains(node.Node.Id));
            }
        }
        if (_gesture == Gesture.Box)
        {
            var box = new Rect(_start, _last).Normalize();
            context.DrawRectangle(BoxFill, BoxPen, box);
        }
    }

    void DrawGrid(DrawingContext context)
    {
        var step = 20.0;
        var topLeft = ToCanvas(default);
        var bottomRight = ToCanvas(new Point(Bounds.Width, Bounds.Height));
        if (step * _view.Zoom < 6)
        {
            step = 100;
        }
        for (var x = Math.Floor(topLeft.X / step) * step; x <= bottomRight.X; x += step)
        {
            var vx = (x - _view.Offset.X) * _view.Zoom;
            context.DrawLine(Math.Abs(x % 100) < 0.5 ? MajorGrid : MinorGrid, new Point(vx, 0), new Point(vx, Bounds.Height));
        }
        for (var y = Math.Floor(topLeft.Y / step) * step; y <= bottomRight.Y; y += step)
        {
            var vy = (y - _view.Offset.Y) * _view.Zoom;
            context.DrawLine(Math.Abs(y % 100) < 0.5 ? MajorGrid : MinorGrid, new Point(0, vy), new Point(Bounds.Width, vy));
        }
    }

    static void DrawLink(DrawingContext context, Vec2 start, Vec2 end, PinType type)
    {
        var bend = Math.Max(40, Math.Abs(end.X - start.X) * 0.5);
        var geometry = new StreamGeometry();
        using (var g = geometry.Open())
        {
            g.BeginFigure(new Point(start.X, start.Y), false);
            g.CubicBezierTo(new Point(start.X + bend, start.Y), new Point(end.X - bend, end.Y), new Point(end.X, end.Y));
            g.EndFigure(false);
        }
        context.DrawGeometry(null, new Pen(PinBrush(type), 2), geometry);
    }

    void DrawNode(DrawingContext context, NodeLayout layout, bool selected, bool error)
    {
        var b = layout.Bounds;
        var rect = new Rect(b.X, b.Y, b.Width, b.Height);
        context.DrawRectangle(NodeBody, NodeBorder, rect, 4, 4);
        var kind = _editor.Catalog.Kind(layout.Node.Kind);
        var header = new Rect(b.X, b.Y, b.Width, GraphGeometry.HeaderHeight);
        context.DrawRectangle(HeaderBrush(kind?.Category ?? ""), null, header, 4, 4);
        context.FillRectangle(HeaderBrush(kind?.Category ?? ""), new Rect(b.X, b.Y + GraphGeometry.HeaderHeight - 4, b.Width, 4));
        DrawText(context, Title(layout.Node, kind), new Point(b.X + 8, b.Y + 5), 12, Text, b.Width - 16, bold: true);
        var linked = layout.Node.Fields.Where(f => f.Value is GraphLink).Select(f => f.Name).ToHashSet();
        var linkedOutputs = _geometry.Links.Where(l => l.From == layout.Node.Id).Select(l => l.Output).ToHashSet();
        for (var i = 0; i < layout.Inputs.Count; i++)
        {
            var pin = layout.Inputs[i];
            var at = layout.InputAt(i);
            DrawPin(context, at, pin.Type, linked.Contains(pin.Name));
            var label = MaterialEditor.Humanize(pin.Name);
            DrawText(context, label, new Point(at.X + 10, at.Y - 8), 11, Text, b.Width / 2 - 10);
            if (!linked.Contains(pin.Name) && InputValue(layout.Node, pin) is { } value)
            {
                DrawText(context, value, new Point(at.X + 10 + Measure(label, 11) + 6, at.Y - 8), 11, DimText, b.Width - Measure(label, 11) - 30);
            }
        }
        for (var i = 0; i < layout.Outputs.Count; i++)
        {
            var pin = layout.Outputs[i];
            var at = layout.OutputAt(i);
            DrawPin(context, at, pin.Type, linkedOutputs.Contains(pin.Name));
            var label = layout.Outputs.Count == 1 && pin.Name is "out" or "value" ? TypeName(pin.Type) : pin.Name;
            DrawText(context, label, new Point(at.X - 10 - Measure(label, 11), at.Y - 8), 11, layout.Outputs.Count == 1 ? DimText : Text, b.Width / 2);
        }
        if (selected || error)
        {
            context.DrawRectangle(null, error ? ErrorBorder : SelectedBorder, rect.Inflate(1), 5, 5);
        }
    }

    // What a node's header says: a parameter's or a function's name, a constant's value, or its kind.
    string Title(GraphNode node, NodeInfo? kind) => node.Kind switch
    {
        "scalar" or "vector2" or "vector3" or "vector4" or "color" when node.Get("value") is GraphNumbers n => $"{kind?.Label}  {n.Write()}",
        "uv" => $"UV{(node.Get("set") is GraphNumbers set ? set.Write() : "0")}",
        "switch" when node.Get("switch") is GraphText s => $"Switch: {s.Text}",
        "custom" => "Custom HLSL",
        _ => _editor.Label(node.Id),
    };

    // An unlinked input's value as the node shows it: its own, or what it defaults to.
    static string? InputValue(GraphNode node, GraphPin pin) => node.Get(pin.Name) switch
    {
        GraphNumbers n => n.Write(),
        _ when pin.Type == PinType.Texture => null,
        _ => MaterialCatalog.DefaultText(pin),
    };

    static string TypeName(PinType type) => type switch
    {
        PinType.Float => "float",
        PinType.Float2 => "float2",
        PinType.Float3 => "float3",
        PinType.Float4 => "float4",
        PinType.Texture => "texture",
        _ => "any",
    };

    static void DrawPin(DrawingContext context, Vec2 at, PinType type, bool linked)
    {
        var brush = PinBrush(type);
        context.DrawEllipse(linked ? brush : NodeBody, new Pen(brush, 1.5), new Point(at.X, at.Y), GraphGeometry.PinRadius, GraphGeometry.PinRadius);
    }

    static void DrawText(DrawingContext context, string text, Point at, double size, IBrush brush, double maxWidth, bool bold = false)
    {
        var formatted = new FormattedText(text, CultureInfo.CurrentCulture, FlowDirection.LeftToRight,
            bold ? new Typeface(Font.FontFamily, FontStyle.Normal, FontWeight.SemiBold) : Font, size, brush)
        {
            MaxTextWidth = Math.Max(maxWidth, 1),
            MaxLineCount = 1,
            Trimming = TextTrimming.CharacterEllipsis,
        };
        context.DrawText(formatted, at);
    }

    static double Measure(string text, double size) =>
        new FormattedText(text, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, Font, size, Brushes.White).Width;

    public static IBrush PinBrush(PinType type) => type switch
    {
        PinType.Float => new SolidColorBrush(Color.Parse("#A8A8B0")),
        PinType.Float2 => new SolidColorBrush(Color.Parse("#7BC47F")),
        PinType.Float3 => new SolidColorBrush(Color.Parse("#E8C84A")),
        PinType.Float4 => new SolidColorBrush(Color.Parse("#D97AB5")),
        PinType.Texture => new SolidColorBrush(Color.Parse("#E8894A")),
        _ => new SolidColorBrush(Color.Parse("#E4E4E8")),
    };

    static IBrush HeaderBrush(string category) => new SolidColorBrush(Color.Parse(category switch
    {
        "Output" => "#7A2E2A",
        "Inputs" => "#2E4A66",
        "Textures" => "#6A3F2A",
        "Math" => "#3A5A34",
        "Vector" => "#4E3E6A",
        "Logic" => "#6A5A24",
        "Function" => "#2E5E5E",
        _ => "#5A3254",
    }));

    // Where a pin is, and its type.
    (Vec2 Point, PinType Type)? PinPoint((int Node, string Pin, bool FromOutput) pin)
    {
        if (_geometry.Find(pin.Node) is not { } node)
        {
            return null;
        }
        if (pin.FromOutput)
        {
            var i = node.OutputIndex(pin.Pin);
            return i < 0 ? null : (node.OutputAt(i), node.Outputs[i].Type);
        }
        var j = node.InputIndex(pin.Pin);
        return j < 0 ? null : (node.InputAt(j), node.Inputs[j].Type);
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
            switch (hit.Kind)
            {
                case GraphHitKind.Output:
                    StartLink(hit.Node, hit.Pin, fromOutput: true, null);
                    break;
                case GraphHitKind.Input:
                    // A linked input gives up its link, which the drag then carries from its output.
                    if (_editor.Document.Graph.Find(hit.Node)?.Get(hit.Pin) is GraphLink link)
                    {
                        StartLink(link.Node, link.Output, fromOutput: true, (hit.Node, hit.Pin));
                    }
                    else
                    {
                        StartLink(hit.Node, hit.Pin, fromOutput: false, null);
                    }
                    break;
                case GraphHitKind.Node:
                    if (e.ClickCount == 2)
                    {
                        OpenFunction(hit.Node);
                        return;
                    }
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

    void StartLink(int node, string pin, bool fromOutput, (int, string)? detached)
    {
        _linkStart = (node, pin, fromOutput);
        _detached = detached;
        _linkEnd = ToCanvas(_start);
        _gesture = Gesture.Link;
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
                    _moveStarts = _editor.Selection.Select(_editor.Document.Graph.Find).OfType<GraphNode>().ToDictionary(n => n.Id, n => new Vec2(n.X, n.Y));
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
            case Gesture.Link:
                _linkEnd = ToCanvas(position);
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
                _picker.Open(this, ToCanvas(position), null);
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
            case Gesture.Link:
                EndLink(ToCanvas(position));
                break;
        }
        _gesture = Gesture.None;
        e.Pointer.Capture(null);
        InvalidateVisual();
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

    // A link that ends on a pin of the other side links them. One that came off an input and ends nowhere is gone, and
    // one that ends on nothing else opens the node picker, whose node it then links to.
    void EndLink(Vec2 at)
    {
        var hit = _geometry.HitTest(at);
        var start = PinPoint(_linkStart);
        if (_linkStart.FromOutput && hit.Kind == GraphHitKind.Input && start is { } output && TypeOf(hit) is { } inputType
            && GraphGeometry.CanLink(output.Type, inputType))
        {
            if (_detached is { } old && (old.Node, old.Input) != (hit.Node, hit.Pin))
            {
                _editor.MoveLink(old.Node, old.Input, _linkStart.Node, _linkStart.Pin, hit.Node, hit.Pin);
            }
            else if (_detached == null && !_editor.Link(_linkStart.Node, _linkStart.Pin, hit.Node, hit.Pin))
            {
                _shell.Console.Add(Panels.LogLevel.Warning, "material: that link would make a loop");
            }
            return;
        }
        if (!_linkStart.FromOutput && hit.Kind == GraphHitKind.Output && start is { } input && TypeOf(hit) is { } outputType
            && GraphGeometry.CanLink(outputType, input.Type))
        {
            if (!_editor.Link(hit.Node, hit.Pin, _linkStart.Node, _linkStart.Pin))
            {
                _shell.Console.Add(Panels.LogLevel.Warning, "material: that link would make a loop");
            }
            return;
        }
        if (_detached is { } detached)
        {
            _editor.SetField(detached.Node, detached.Input, null);
            return;
        }
        if (hit.Kind == GraphHitKind.None)
        {
            _picker.Open(this, at, _linkStart);
        }
    }

    PinType? TypeOf(GraphHit hit)
    {
        if (_geometry.Find(hit.Node) is not { } node)
        {
            return null;
        }
        return hit.Kind == GraphHitKind.Input
            ? node.InputIndex(hit.Pin) is var i and >= 0 ? node.Inputs[i].Type : null
            : node.OutputIndex(hit.Pin) is var o and >= 0 ? node.Outputs[o].Type : null;
    }

    // A node from the picker, linked to the pin that a link was dragged from, by its first pin that fits.
    void OnPicked(string kind, Vec2 at, (int Node, string Pin, bool FromOutput)? from)
    {
        var id = _editor.AddNode(kind, at.X, at.Y - GraphGeometry.HeaderHeight);
        if (from is not { } pin || PinPoint(pin) is not { } start)
        {
            return;
        }
        _geometry = _editor.Geometry();
        if (_geometry.Find(id) is not { } added)
        {
            return;
        }
        if (pin.FromOutput && added.Inputs.FirstOrDefault(p => GraphGeometry.CanLink(start.Type, p.Type)) is { } input)
        {
            _editor.Link(pin.Node, pin.Pin, id, input.Name);
        }
        else if (!pin.FromOutput && added.Outputs.FirstOrDefault(p => GraphGeometry.CanLink(p.Type, start.Type)) is { } output)
        {
            _editor.Link(id, output.Name, pin.Node, pin.Pin);
        }
    }

    void OpenFunction(int id)
    {
        if (_editor.Document.Graph.Find(id) is { Kind: "function" } node && node.Get("function") is GraphAsset asset && _shell.Assets.Find(asset.Guid) is { } function)
        {
            _shell.OpenMaterial(function);
        }
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
            case Key.D when e.KeyModifiers == KeyModifiers.Control:
                _editor.DuplicateSelected();
                break;
            case Key.F when e.KeyModifiers == KeyModifiers.None:
                Frame();
                break;
            case Key.Space or Key.Tab when e.KeyModifiers == KeyModifiers.None:
                _picker.Open(this, ToCanvas(_last), null);
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
