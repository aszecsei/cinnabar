using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;

namespace Cinnabar.Editor.Tools;

/// <summary>What a behavior tree's or an HTN domain's node is, which its shape on the canvas shows.</summary>
public enum TreeShape
{
    /// <summary>A sequence, a selector or a parallel, which runs its children.</summary>
    Composite,
    Action,
    Wait,
    Set,
    Condition,

    /// <summary>An HTN compound task, which its methods break down.</summary>
    Task,

    /// <summary>An HTN method, a way to do its task by its subtasks.</summary>
    Method,

    /// <summary>A kind that a behavior tree or an HTN domain does not have, which the cooker reports.</summary>
    Unknown,
}

/// <summary>
/// A node as the canvas draws it: its decorators as bands across its top, its header, the rows that say what it does,
/// and, for a node with children, the foot that a drag to another node makes a child from.
/// </summary>
public sealed record TreeNodeLayout(DecisionNode Node, GraphRect Bounds, IReadOnlyList<string> Bands, IReadOnlyList<string> Rows, bool HasFoot)
{
    public TreeShape Shape => BehaviorTreeGeometry.ShapeOf(Node.Kind);

    /// <summary>The header, under the bands, which names the node.</summary>
    public GraphRect Header => new(Bounds.X, Bounds.Y + Bands.Count * BehaviorTreeGeometry.RowHeight, Bounds.Width, BehaviorTreeGeometry.HeaderHeight);

    /// <summary>The handle under a node with children, which a drag to another node makes a child from.</summary>
    public GraphRect Foot => new(Bounds.X + Bounds.Width / 2 - BehaviorTreeGeometry.FootWidth / 2, Bounds.Y + Bounds.Height, BehaviorTreeGeometry.FootWidth, BehaviorTreeGeometry.FootHeight);

    /// <summary>Where the edges to its children leave: the middle of its foot.</summary>
    public Vec2 Bottom => new(Bounds.X + Bounds.Width / 2, Bounds.Y + Bounds.Height + (HasFoot ? BehaviorTreeGeometry.FootHeight : 0));

    /// <summary>Where the edge from its parent arrives: the middle of its top.</summary>
    public Vec2 Top => new(Bounds.X + Bounds.Width / 2, Bounds.Y);
}

/// <summary>An edge from a node to one of its children, and the child's place among its siblings, from 1.</summary>
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
/// Where a behavior tree's or an HTN domain's nodes and edges are on the canvas (see
/// docs/editor/decision-editor.md#the-canvas), and what is at a point, so the hit tests run without a window. A node's
/// children are a composite's <c>children</c>, a task's <c>methods</c> and a method's <c>subtasks</c> (see
/// <see cref="ChildrenKey"/>). A node is where its <c>position</c> puts it. A node without one gets its place in the tree
/// laid out from the top down, its children left to right in their order, which is not written, so a file does not
/// change by being opened.
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
        "task" => TreeShape.Task,
        "method" => TreeShape.Method,
        _ => TreeShape.Unknown,
    };

    /// <summary>Whether a node of a kind runs children.</summary>
    public static bool IsComposite(string kind) => Composites.Contains(kind);

    /// <summary>
    /// The field that lists a node's children in a technique: a behavior tree's composite's <c>children</c>, which it
    /// runs in order, an HTN task's <c>methods</c>, in their order of preference, and an HTN method's <c>subtasks</c>, in
    /// their order. Null for a node without children. A composite has children in a file of any technique, so a tree
    /// without its <c>technique</c> line still draws as one.
    /// </summary>
    public static string? ChildrenKey(string? technique, string kind) => (technique, kind) switch
    {
        ("htn", "task") => "methods",
        ("htn", "method") => "subtasks",
        _ when IsComposite(kind) => "children",
        _ => null,
    };

    /// <summary>The fields that list IDs of nodes, which a delete takes the deleted nodes out of.</summary>
    public static readonly IReadOnlyList<string> ListKeys = ["children", "methods", "subtasks", "considerations"];

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
        TreeShape.Method => [node.Get("preconditions") is { } preconditions ? $"if {preconditions}" : "always"],
        _ => [],
    };

    // An HTN action's rows: its action, and its preconditions and effects.
    static IReadOnlyList<string> PlanActionRows(DecisionNode node)
    {
        var rows = new List<string> { node.Get("action") ?? "No action" };
        if (node.Get("preconditions") is { } preconditions)
        {
            rows.Add($"if {preconditions}");
        }
        if (node.Get("effects") is { } effects)
        {
            rows.Add($"then {effects}");
        }
        return rows;
    }

    // A time is a number of seconds or a key's name.
    static string Seconds(string time) => GraphNumbers.TryParse(time) is { Values: [_] } ? $"{time} s" : time;

    public static BehaviorTreeGeometry Of(DecisionFile file)
    {
        var technique = file.Technique;
        var nodes = file.Nodes.ToList();
        var byId = nodes.ToDictionary(n => n.Id);
        var children = nodes.ToDictionary(n => n.Id, n => ChildrenKey(technique, n.Kind) is { } key ? n.Ids(key).Where(byId.ContainsKey).ToList() : []);
        var laidOut = LayOut(nodes, children, technique == "htn" ? RootOf(file) : null);
        var layouts = new List<TreeNodeLayout>();
        foreach (var node in nodes)
        {
            var bands = BandsOf(node);
            var rows = technique == "htn" && node.Kind == "action" ? PlanActionRows(node) : RowsOf(node);
            var height = HeaderHeight + (bands.Count + rows.Count) * RowHeight + (rows.Count > 0 ? 4 : 0);
            var (x, y) = node.Position ?? laidOut[node.Id];
            layouts.Add(new TreeNodeLayout(node, new GraphRect(x, y, NodeWidth, height), bands, rows, ChildrenKey(technique, node.Kind) != null));
        }
        var find = layouts.ToDictionary(l => l.Node.Id);
        var edges = new List<TreeEdgeLayout>();
        foreach (var parent in layouts)
        {
            var order = 0;
            // A child that a parent lists twice, as a method may a subtask, has an edge for each.
            foreach (var child in children[parent.Node.Id])
            {
                edges.Add(new TreeEdgeLayout(parent.Node.Id, child, ++order, parent.Bottom, find[child].Top));
            }
        }
        return new BehaviorTreeGeometry(layouts, edges);
    }

    // The ID of an HTN domain's root task, or null.
    static int? RootOf(DecisionFile file)
    {
        var text = file.Setting("root")?.Trim();
        if (text == null)
        {
            return null;
        }
        var hex = text.StartsWith("0x", StringComparison.OrdinalIgnoreCase);
        return int.TryParse(hex ? text[2..] : text, hex ? System.Globalization.NumberStyles.HexNumber : System.Globalization.NumberStyles.None,
            System.Globalization.CultureInfo.InvariantCulture, out var id) ? id : null;
    }

    // The places of the nodes in a tree laid out from the top down: each leaf in the next column, and each parent over
    // the middle of its children. The roots are an HTN domain's root, then the nodes that no node lists, in the file's
    // order, and a node that no root reaches, as in a cycle, starts a tree of its own after them. A node that several
    // parents list, as a subtask may be, or that recurs, has its place under the first that reaches it.
    static Dictionary<int, (double X, double Y)> LayOut(List<DecisionNode> nodes, Dictionary<int, List<int>> children, int? root)
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
        if (root is { } r && children.ContainsKey(r))
        {
            Place(r, 0);
        }
        foreach (var top in nodes.Where(n => !listed.Contains(n.Id) && !places.ContainsKey(n.Id)))
        {
            Place(top.Id, 0);
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

    /// <summary>The topmost thing at a point: a foot, then a node, the later in the file over the earlier.</summary>
    public TreeHit HitTest(Vec2 p)
    {
        for (var k = _nodes.Count - 1; k >= 0; k--)
        {
            var n = _nodes[k];
            if (n.HasFoot && n.Foot.Contains(p))
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
