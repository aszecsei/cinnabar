using Avalonia;
using Avalonia.Input;
using Avalonia.Media;
using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Graphs;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using static Cinnabar.Editor.Materials.CanvasDrawing;

namespace Cinnabar.Editor.Materials;

/// <summary>
/// The material editor's node canvas (see docs/editor/material-editor.md#material-editor): the graph's nodes and links, with
/// the gestures of every graph canvas (NodeGraphCanvas). Its own drag takes a link from a pin to a pin; a link dragged
/// off an input comes away. A double click on a function node opens its function, and Ctrl+D duplicates the selected
/// nodes.
/// </summary>
public sealed class GraphCanvas : NodeGraphCanvas
{
    static readonly IBrush NodeBody = new SolidColorBrush(Color.Parse("#2A2A2E"));
    static readonly IPen NodeBorder = new Pen(new SolidColorBrush(Color.Parse("#3C3C42")), 1);
    static readonly IPen SelectedBorder = new Pen(new SolidColorBrush(Palette.Accent), 2);
    static readonly IPen ErrorBorder = new Pen(new SolidColorBrush(Palette.Error), 2, new DashStyle([3, 2], 0));
    static readonly IBrush Text = new SolidColorBrush(Color.Parse("#E4E4E8"));
    static readonly IBrush DimText = new SolidColorBrush(Color.Parse("#8A8A92"));

    // A link being dragged: from an output, or back from an input; the input that it came off, if any; and where it is.
    readonly record struct LinkDrag((int Node, string Pin, bool FromOutput) Start, (int Node, string Input)? Detached, Vec2 End);

    readonly EditorShell _shell;
    readonly MaterialEditor _editor;
    readonly NodePicker<(int Node, string Pin, bool FromOutput)?> _picker;
    GraphGeometry _geometry;
    LinkDrag? _link;

    public GraphCanvas(EditorShell shell, MaterialEditor editor)
        : base(editor, shell)
    {
        _shell = shell;
        _editor = editor;
        _geometry = editor.Geometry();
        _picker = new(() => editor.Catalog.KindsFor(editor.Document.Kind).Where(k => k.Kind != "output")
            .Select(k => new PickerEntry(k.Kind, k.Label, k.Category, k.Description)));
        _picker.Picked += OnPicked;
        new ViewSubscriptions(this, attached: OnChanged)
            .Add(() => _editor.Changed += OnChanged, () => _editor.Changed -= OnChanged)
            .Add(() => _editor.SelectionChanged += InvalidateVisual, () => _editor.SelectionChanged -= InvalidateVisual)
            .Add(() => _editor.ProblemsChanged += InvalidateVisual, () => _editor.ProblemsChanged -= InvalidateVisual)
            .Add(() => _shell.Assets.Changed += OnChanged, () => _shell.Assets.Changed -= OnChanged);
    }

    void OnChanged()
    {
        _geometry = _editor.Geometry();
        InvalidateVisual();
    }

    protected override IGraphLayout Layout => _geometry;

    protected override void DrawGraph(DrawingContext context)
    {
        foreach (var link in _geometry.Links)
        {
            DrawLink(context, link.Start, link.End, link.Type);
        }
        if (_link is { } drag && PinPoint(drag.Start) is { } from)
        {
            var (start, end) = drag.Start.FromOutput ? (from.Point, drag.End) : (drag.End, from.Point);
            DrawLink(context, start, end, from.Type);
        }
        var problems = _editor.Problems.Where(p => p.Error && p.Node != null).Select(p => p.Node!.Value).ToHashSet();
        foreach (var node in _geometry.Nodes)
        {
            DrawNode(context, node, _editor.Selection.Contains(node.Node.Id), problems.Contains(node.Node.Id));
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
                DrawText(context, value, new Point(at.X + 10 + TextWidth(label, 11) + 6, at.Y - 8), 11, DimText, b.Width - TextWidth(label, 11) - 30);
            }
        }
        for (var i = 0; i < layout.Outputs.Count; i++)
        {
            var pin = layout.Outputs[i];
            var at = layout.OutputAt(i);
            DrawPin(context, at, pin.Type, linkedOutputs.Contains(pin.Name));
            var label = layout.Outputs.Count == 1 && pin.Name is "out" or "value" ? TypeName(pin.Type) : pin.Name;
            DrawText(context, label, new Point(at.X - 10 - TextWidth(label, 11), at.Y - 8), 11, layout.Outputs.Count == 1 ? DimText : Text, b.Width / 2);
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

    protected override CanvasPress PressAt(Vec2 at, KeyModifiers modifiers, int clickCount)
    {
        var hit = _geometry.HitTest(at);
        switch (hit.Kind)
        {
            case GraphHitKind.Output:
                _link = new LinkDrag((hit.Node, hit.Pin, true), null, at);
                return new CanvasPress(CanvasPressKind.Connect);
            case GraphHitKind.Input:
                // A linked input gives up its link, which the drag then carries from its output.
                _link = _editor.Document.Graph.Find(hit.Node)?.Get(hit.Pin) is GraphLink link
                    ? new LinkDrag((link.Node, link.Output, true), (hit.Node, hit.Pin), at)
                    : new LinkDrag((hit.Node, hit.Pin, false), null, at);
                return new CanvasPress(CanvasPressKind.Connect);
            case GraphHitKind.Node when clickCount == 2:
                OpenFunction(hit.Node);
                return new CanvasPress(CanvasPressKind.Taken);
            case GraphHitKind.Node:
                return new CanvasPress(CanvasPressKind.Select, hit.Node);
            default:
                return new CanvasPress(CanvasPressKind.Empty);
        }
    }

    protected override void ConnectMoved(Vec2 at)
    {
        if (_link is { } drag)
        {
            _link = drag with { End = at };
        }
    }

    protected override void EndConnect(Vec2 at)
    {
        if (_link is { } drag)
        {
            _link = null;
            EndLink(drag, at);
        }
    }

    protected override void CancelConnect() => _link = null;

    // A link that ends on a pin of the other side links them. One that came off an input and ends nowhere is gone, and
    // one that ends on nothing else opens the node picker, whose node it then links to.
    void EndLink(LinkDrag drag, Vec2 at)
    {
        var hit = _geometry.HitTest(at);
        var (from, detached) = (drag.Start, drag.Detached);
        var start = PinPoint(from);
        if (from.FromOutput && hit.Kind == GraphHitKind.Input && start is { } output && TypeOf(hit) is { } inputType
            && GraphGeometry.CanLink(output.Type, inputType))
        {
            if (detached is { } old && (old.Node, old.Input) != (hit.Node, hit.Pin))
            {
                _editor.MoveLink(old.Node, old.Input, from.Node, from.Pin, hit.Node, hit.Pin);
            }
            else if (detached == null && !_editor.Link(from.Node, from.Pin, hit.Node, hit.Pin))
            {
                _shell.Console.Add(Model.LogLevel.Warning, "material: that link would make a loop");
            }
            return;
        }
        if (!from.FromOutput && hit.Kind == GraphHitKind.Output && start is { } input && TypeOf(hit) is { } outputType
            && GraphGeometry.CanLink(outputType, input.Type))
        {
            if (!_editor.Link(hit.Node, hit.Pin, from.Node, from.Pin))
            {
                _shell.Console.Add(Model.LogLevel.Warning, "material: that link would make a loop");
            }
            return;
        }
        if (detached is { } gone)
        {
            _editor.SetField(gone.Node, gone.Input, null);
            return;
        }
        if (hit.Kind == GraphHitKind.None)
        {
            _picker.Open(this, at, from);
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

    protected override void OpenAddMenu(Vec2 at) => _picker.Open(this, at, null);

    // Ctrl+D duplicates the selected nodes with the links between them.
    protected override ScopedCommand Duplicate => new(_editor.DuplicateSelected, () => _editor.Selection.Count > 0);
}
