using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;

namespace Cinnabar.Editor.Tools;

/// <summary>A rectangle of the graph's canvas, in its units.</summary>
public readonly record struct GraphRect(double X, double Y, double Width, double Height)
{
    public bool Contains(Vec2 p) => p.X >= X && p.X <= X + Width && p.Y >= Y && p.Y <= Y + Height;

    public bool Intersects(GraphRect r) => X < r.X + r.Width && r.X < X + Width && Y < r.Y + r.Height && r.Y < Y + Height;

    public static GraphRect Between(Vec2 a, Vec2 b) => new(Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Abs(b.X - a.X), Math.Abs(b.Y - a.Y));
}

/// <summary>A node as the canvas draws it: its rectangle, and its inputs on the left and its outputs on the right, a row each.</summary>
public sealed record NodeLayout(GraphNode Node, GraphRect Bounds, IReadOnlyList<GraphPin> Inputs, IReadOnlyList<GraphPin> Outputs)
{
    public Vec2 InputAt(int i) => new(Bounds.X, Bounds.Y + GraphGeometry.HeaderHeight + (i + 0.5) * GraphGeometry.RowHeight);

    public Vec2 OutputAt(int i) => new(Bounds.X + Bounds.Width, Bounds.Y + GraphGeometry.HeaderHeight + (i + 0.5) * GraphGeometry.RowHeight);

    public int InputIndex(string name) => Inputs.ToList().FindIndex(p => p.Name == name);

    public int OutputIndex(string name) => Outputs.ToList().FindIndex(p => p.Name == name);
}

public enum GraphHitKind
{
    None,
    Node,
    Input,
    Output,
}

/// <summary>What is at a point of the canvas: a node, or one of its inputs or outputs by name.</summary>
public readonly record struct GraphHit(GraphHitKind Kind, int Node = 0, string Pin = "");

/// <summary>A link as the canvas draws it, from an output to an input, in the output's type.</summary>
public readonly record struct LinkLayout(int From, string Output, int To, string Input, Vec2 Start, Vec2 End, PinType Type);

/// <summary>
/// Where a graph's nodes and links are on the canvas (see docs/editor.md#material-editor), and what is at a point, so
/// the node editor's hit tests run without a window.
/// </summary>
public sealed class GraphGeometry
{
    public const double NodeWidth = 180;
    public const double HeaderHeight = 24;
    public const double RowHeight = 20;
    public const double PinRadius = 5;
    // A press this close to a pin's middle takes the pin.
    const double PinReach = 9;

    readonly List<NodeLayout> _nodes;

    GraphGeometry(List<NodeLayout> nodes, List<LinkLayout> links)
    {
        _nodes = nodes;
        Links = links;
    }

    /// <summary>The nodes in drawing order: a later one is over an earlier one.</summary>
    public IReadOnlyList<NodeLayout> Nodes => _nodes;

    public IReadOnlyList<LinkLayout> Links { get; }

    public static GraphGeometry Of(MaterialGraph graph, MaterialCatalog catalog)
    {
        var nodes = new List<NodeLayout>();
        foreach (var node in graph.Nodes)
        {
            var (inputs, outputs) = catalog.PinsOf(graph, node);
            var rows = Math.Max(Math.Max(inputs.Count, outputs.Count), 1);
            nodes.Add(new NodeLayout(node, new GraphRect(node.X, node.Y, NodeWidth, HeaderHeight + rows * RowHeight + 6), inputs, outputs));
        }
        var links = new List<LinkLayout>();
        foreach (var to in nodes)
        {
            foreach (var (name, value) in to.Node.Fields)
            {
                if (value is not GraphLink link || nodes.Find(n => n.Node.Id == link.Node) is not { } from)
                {
                    continue;
                }
                var output = from.OutputIndex(link.Output);
                var input = to.InputIndex(name);
                if (output < 0 || input < 0)
                {
                    continue;
                }
                links.Add(new LinkLayout(from.Node.Id, link.Output, to.Node.Id, name, from.OutputAt(output), to.InputAt(input), from.Outputs[output].Type));
            }
        }
        return new GraphGeometry(nodes, links);
    }

    public NodeLayout? Find(int id) => _nodes.Find(n => n.Node.Id == id);

    /// <summary>The topmost thing at a point: a pin, then a node.</summary>
    public GraphHit HitTest(Vec2 p)
    {
        for (var k = _nodes.Count - 1; k >= 0; k--)
        {
            var n = _nodes[k];
            for (var i = 0; i < n.Inputs.Count; i++)
            {
                if ((n.InputAt(i) - p).Length <= PinReach)
                {
                    return new GraphHit(GraphHitKind.Input, n.Node.Id, n.Inputs[i].Name);
                }
            }
            for (var i = 0; i < n.Outputs.Count; i++)
            {
                if ((n.OutputAt(i) - p).Length <= PinReach)
                {
                    return new GraphHit(GraphHitKind.Output, n.Node.Id, n.Outputs[i].Name);
                }
            }
            if (n.Bounds.Contains(p))
            {
                return new GraphHit(GraphHitKind.Node, n.Node.Id);
            }
        }
        return new GraphHit(GraphHitKind.None);
    }

    /// <summary>The nodes that a box touches.</summary>
    public IEnumerable<int> InBox(Vec2 a, Vec2 b)
    {
        var box = GraphRect.Between(a, b);
        return _nodes.Where(n => n.Bounds.Intersects(box)).Select(n => n.Node.Id);
    }

    /// <summary>Whether an output can link to an input: a texture only to a texture, numbers to numbers, and never to its own node.</summary>
    public static bool CanLink(PinType output, PinType input) => (output == PinType.Texture) == (input == PinType.Texture);

    /// <summary>The rectangle around every node, or null for an empty graph.</summary>
    public GraphRect? Extent()
    {
        if (_nodes.Count == 0)
        {
            return null;
        }
        var x0 = _nodes.Min(n => n.Bounds.X);
        var y0 = _nodes.Min(n => n.Bounds.Y);
        var x1 = _nodes.Max(n => n.Bounds.X + n.Bounds.Width);
        var y1 = _nodes.Max(n => n.Bounds.Y + n.Bounds.Height);
        return new GraphRect(x0, y0, x1 - x0, y1 - y0);
    }
}
