using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;

namespace Cinnabar.Editor.Tools;

/// <summary>What a behavior tree's node is, which its shape on the canvas shows.</summary>
public enum TreeShape
{
    /// <summary>A sequence, a selector or a parallel, which runs its children.</summary>
    Composite,
    Action,
    Wait,
    Set,
    Condition,

    /// <summary>A kind that a behavior tree does not have, which the cooker reports.</summary>
    Unknown,
}

/// <summary>
/// A node as the canvas draws it: its decorators as bands across its top, its header, the rows that say what it does,
/// and, for a composite, the foot that a drag to another node makes a child from.
/// </summary>
public sealed record TreeNodeLayout(DecisionNode Node, GraphRect Bounds, IReadOnlyList<string> Bands, IReadOnlyList<string> Rows)
{
    public TreeShape Shape => BehaviorTreeGeometry.ShapeOf(Node.Kind);

    /// <summary>The header, under the bands, which names the node.</summary>
    public GraphRect Header => new(Bounds.X, Bounds.Y + Bands.Count * BehaviorTreeGeometry.RowHeight, Bounds.Width, BehaviorTreeGeometry.HeaderHeight);

    /// <summary>The handle under a composite, which a drag to another node makes a child from.</summary>
    public GraphRect Foot => new(Bounds.X + Bounds.Width / 2 - BehaviorTreeGeometry.FootWidth / 2, Bounds.Y + Bounds.Height, BehaviorTreeGeometry.FootWidth, BehaviorTreeGeometry.FootHeight);

    /// <summary>Where the edges to its children leave: the middle of its foot.</summary>
    public Vec2 Bottom => new(Bounds.X + Bounds.Width / 2, Bounds.Y + Bounds.Height + (Shape == TreeShape.Composite ? BehaviorTreeGeometry.FootHeight : 0));

    /// <summary>Where the edge from its parent arrives: the middle of its top.</summary>
    public Vec2 Top => new(Bounds.X + Bounds.Width / 2, Bounds.Y);
}

/// <summary>An edge from a composite to one of its children, and the child's place among its siblings, from 1.</summary>
public readonly record struct TreeEdgeLayout(int Parent, int Child, int Order, Vec2 Start, Vec2 End);

public enum TreeHitKind
{
    None,
    Node,
    Foot,
}

/// <summary>What is at a point of the canvas, and the node that it belongs to.</summary>
public readonly record struct TreeHit(TreeHitKind Kind, int Node = 0);

/// <summary>
/// Where a behavior tree's nodes and edges are on the canvas (see docs/editor/decision-editor.md#the-canvas), and what is
/// at a point, so the hit tests run without a window. A node is where its <c>position</c> puts it. A node without one gets
/// its place in the tree laid out from the top down, its children left to right in their order, which is not written,
/// so a file does not change by being opened.
/// </summary>
public sealed class BehaviorTreeGeometry : IGraphLayout
{
    public const double NodeWidth = 180;
    public const double HeaderHeight = 26;
    public const double RowHeight = 18;
    public const double FootWidth = 36;
    public const double FootHeight = 10;
    // The steps of the laid out tree, across and down.
    public const double Across = 210;
    public const double Down = 150;

    static readonly HashSet<string> Composites = ["sequence", "selector", "parallel"];

    readonly List<TreeNodeLayout> _nodes;

    BehaviorTreeGeometry(List<TreeNodeLayout> nodes, List<TreeEdgeLayout> edges)
    {
        _nodes = nodes;
        Edges = edges;
    }

    /// <summary>The nodes in the file's order.</summary>
    public IReadOnlyList<TreeNodeLayout> Nodes => _nodes;

    public IReadOnlyList<TreeEdgeLayout> Edges { get; }

    public static TreeShape ShapeOf(string kind) => kind switch
    {
        _ when Composites.Contains(kind) => TreeShape.Composite,
        "action" => TreeShape.Action,
        "wait" => TreeShape.Wait,
        "set" => TreeShape.Set,
        "condition" => TreeShape.Condition,
        _ => TreeShape.Unknown,
    };

    /// <summary>Whether a node of a kind runs children.</summary>
    public static bool IsComposite(string kind) => Composites.Contains(kind);

    /// <summary>A node's decorators, each a band's words, in the order that they apply.</summary>
    public static IReadOnlyList<string> BandsOf(DecisionNode node)
    {
        var bands = new List<string>();
        if (node.Get("when") is { } when)
        {
            bands.Add(node.Get("abort") is { } abort and not "none" ? $"when {when} · abort {abort}" : $"when {when}");
        }
        else if (node.Get("abort") is { } abort)
        {
            bands.Add($"abort {abort}");
        }
        if (node.Get("cooldown") is { } cooldown)
        {
            bands.Add($"cooldown {Seconds(cooldown)}");
        }
        if (node.Get("time_limit") is { } limit)
        {
            bands.Add($"time limit {Seconds(limit)}");
        }
        if (node.Get("repeat") is { } repeat)
        {
            bands.Add(repeat == "forever" ? "repeat forever" : $"repeat {repeat}×");
        }
        if (node.Get("invert") == "true")
        {
            bands.Add("invert");
        }
        if (node.Get("force") is { } force)
        {
            bands.Add($"force {force}");
        }
        return bands;
    }

    /// <summary>The rows under a node's header that say what it does.</summary>
    public static IReadOnlyList<string> RowsOf(DecisionNode node) => ShapeOf(node.Kind) switch
    {
        TreeShape.Composite when node.Kind == "parallel" => [$"policy {node.Get("policy") ?? "?"}"],
        TreeShape.Action => [node.Get("action") ?? "No action"],
        TreeShape.Wait => [node.Get("seconds") is { } seconds ? Seconds(seconds) : "No time"],
        TreeShape.Set => node.Writes.Count == 0 ? ["No writes"] : [.. node.Writes.Select(w => $"{w.Key} = {w.Value}")],
        TreeShape.Condition => [node.Get("condition") ?? "No condition"],
        _ => [],
    };

    // A time is a number of seconds or a key's name.
    static string Seconds(string time) => GraphNumbers.TryParse(time) is { Values: [_] } ? $"{time} s" : time;

    public static BehaviorTreeGeometry Of(DecisionFile file)
    {
        var nodes = file.Nodes.ToList();
        var byId = nodes.ToDictionary(n => n.Id);
        var children = nodes.ToDictionary(n => n.Id, n => IsComposite(n.Kind) ? n.Ids("children").Where(byId.ContainsKey).ToList() : []);
        var laidOut = LayOut(nodes, children);
        var layouts = new List<TreeNodeLayout>();
        foreach (var node in nodes)
        {
            var bands = BandsOf(node);
            var rows = RowsOf(node);
            var height = HeaderHeight + (bands.Count + rows.Count) * RowHeight + (rows.Count > 0 ? 4 : 0);
            var (x, y) = node.Position ?? laidOut[node.Id];
            layouts.Add(new TreeNodeLayout(node, new GraphRect(x, y, NodeWidth, height), bands, rows));
        }
        var find = layouts.ToDictionary(l => l.Node.Id);
        var edges = new List<TreeEdgeLayout>();
        foreach (var parent in layouts)
        {
            var order = 0;
            foreach (var child in children[parent.Node.Id])
            {
                edges.Add(new TreeEdgeLayout(parent.Node.Id, child, ++order, parent.Bottom, find[child].Top));
            }
        }
        return new BehaviorTreeGeometry(layouts, edges);
    }

    // The places of the nodes in a tree laid out from the top down: each leaf in the next column, and each composite over
    // the middle of its children. The roots are the nodes that no node lists, in the file's order, and a node that no root
    // reaches, as in a cycle, starts a tree of its own after them.
    static Dictionary<int, (double X, double Y)> LayOut(List<DecisionNode> nodes, Dictionary<int, List<int>> children)
    {
        var listed = children.Values.SelectMany(c => c).ToHashSet();
        var places = new Dictionary<int, (double X, double Y)>();
        var column = 0;
        double Place(int id, int depth)
        {
            places[id] = (0, depth * Down);
            var xs = new List<double>();
            foreach (var child in children[id])
            {
                if (!places.ContainsKey(child))
                {
                    xs.Add(Place(child, depth + 1));
                }
            }
            var x = xs.Count == 0 ? column++ * Across : (xs[0] + xs[^1]) / 2;
            places[id] = (x, depth * Down);
            return x;
        }
        foreach (var root in nodes.Where(n => !listed.Contains(n.Id)))
        {
            Place(root.Id, 0);
        }
        foreach (var node in nodes)
        {
            if (!places.ContainsKey(node.Id))
            {
                Place(node.Id, 0);
            }
        }
        return places;
    }

    public TreeNodeLayout? Find(int id) => _nodes.Find(n => n.Node.Id == id);

    /// <summary>The topmost thing at a point: a composite's foot, then a node, the later in the file over the earlier.</summary>
    public TreeHit HitTest(Vec2 p)
    {
        for (var k = _nodes.Count - 1; k >= 0; k--)
        {
            var n = _nodes[k];
            if (n.Shape == TreeShape.Composite && n.Foot.Contains(p))
            {
                return new TreeHit(TreeHitKind.Foot, n.Node.Id);
            }
            if (n.Bounds.Contains(p))
            {
                return new TreeHit(TreeHitKind.Node, n.Node.Id);
            }
        }
        return new TreeHit(TreeHitKind.None);
    }

    /// <summary>The nodes that a box touches.</summary>
    public IEnumerable<int> InBox(Vec2 a, Vec2 b)
    {
        var box = GraphRect.Between(a, b);
        return _nodes.Where(n => n.Bounds.Intersects(box)).Select(n => n.Node.Id);
    }

    /// <summary>The rectangle around every node and foot, or null for a tree without nodes.</summary>
    public GraphRect? Extent()
    {
        if (_nodes.Count == 0)
        {
            return null;
        }
        var x0 = _nodes.Min(n => n.Bounds.X);
        var y0 = _nodes.Min(n => n.Bounds.Y);
        var x1 = _nodes.Max(n => n.Bounds.X + n.Bounds.Width);
        var y1 = _nodes.Max(n => n.Bounds.Y + n.Bounds.Height + FootHeight);
        return new GraphRect(x0, y0, x1 - x0, y1 - y0);
    }
}
