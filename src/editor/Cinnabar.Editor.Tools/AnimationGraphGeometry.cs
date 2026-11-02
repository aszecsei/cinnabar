using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;

namespace Cinnabar.Editor.Tools;

/// <summary>
/// A state or a blend as the canvas draws it. A state's rim, around its bounds, is where its transitions start and end,
/// and its chip names what it plays. A blend is not a place in the state machine: it has no rim, and its feed, along its
/// foot, is what links it to the states that play it.
/// </summary>
public sealed record AnimationNodeLayout(AnimationGraphNode Node, GraphRect Bounds)
{
    /// <summary>The rectangle that a state's rim goes around the outside of.</summary>
    public GraphRect Outer => Node.Kind == AnimationGraphNodeKind.State ? Bounds.Inflate(AnimationGraphGeometry.RimWidth) : Bounds;

    /// <summary>The row of a state that names what it plays.</summary>
    public GraphRect Chip => new(Bounds.X + 8, Bounds.Y + AnimationGraphGeometry.HeaderHeight + 2, Bounds.Width - 16, AnimationGraphGeometry.RowHeight);

    /// <summary>The strip along a blend's foot that says which states play it, which a drag links to another.</summary>
    public GraphRect Feed => new(Bounds.X, Bounds.Y + Bounds.Height - AnimationGraphGeometry.RowHeight, Bounds.Width, AnimationGraphGeometry.RowHeight);

    /// <summary>The point of the node's outside on the way from its middle to another point.</summary>
    public Vec2 EdgeToward(Vec2 point) => AnimationGraphGeometry.EdgeOf(Outer, point, new Vec2(0, 0));
}

/// <summary>
/// A transition as the canvas draws it: its glyph, at its position or else on its arrow, and an arrow through it from
/// its from state, unless it comes from any state or names no state that the graph has, to its to state.
/// </summary>
public sealed record TransitionLayout(AnimationGraphNode Node, GraphRect Glyph, Vec2? Start, Vec2? End)
{
    public Vec2 Middle => new(Glyph.X + Glyph.Width / 2, Glyph.Y + Glyph.Height / 2);
}

/// <summary>A tether from a blend to a state that plays it.</summary>
public readonly record struct MotionLinkLayout(int Blend, int State, Vec2 Start, Vec2 End);

public enum AnimationGraphHitKind
{
    None,
    Node,
    Transition,
    StateRim,
    BlendFeed,
    MotionChip,
}

/// <summary>What is at a point of the canvas, and the node that it belongs to.</summary>
public readonly record struct AnimationGraphHit(AnimationGraphHitKind Kind, int Node = 0);

/// <summary>
/// Where an animation graph's nodes, links and transitions are on the canvas (see docs/editor/animation-graph-editor.md#animation-graph-editor),
/// and what is at a point, so the hit tests run without a window. A node without a position gets a place below the
/// others, which is not written, so a file does not change by being opened.
/// </summary>
public sealed class AnimationGraphGeometry
{
    public const double NodeWidth = 180;
    public const double HeaderHeight = 24;
    public const double RowHeight = 20;
    public const double RimWidth = 6;
    public const double GlyphWidth = 104;
    public const double GlyphHeight = 20;
    // A press this close to a state's body, on screen, takes its rim, however far the view is zoomed out.
    const double RimReach = 8;
    // A press this close to an arrow takes its transition.
    const double ArrowReach = 5;
    // Arrows between the same two states are this far apart, so their glyphs do not touch.
    const double ArrowLane = GlyphHeight + 6;
    const double GlyphGap = 4;
    const double UnplacedStep = 220;
    const double UnplacedGap = 60;

    readonly List<AnimationNodeLayout> _nodes;
    readonly List<TransitionLayout> _transitions;

    AnimationGraphGeometry(List<AnimationNodeLayout> nodes, List<TransitionLayout> transitions, List<MotionLinkLayout> links)
    {
        _nodes = nodes;
        _transitions = transitions;
        Links = links;
    }

    /// <summary>The states and the blends in drawing order: a later one is over an earlier one.</summary>
    public IReadOnlyList<AnimationNodeLayout> Nodes => _nodes;

    /// <summary>The transitions in the file's order.</summary>
    public IReadOnlyList<TransitionLayout> Transitions => _transitions;

    public IReadOnlyList<MotionLinkLayout> Links { get; }

    public static AnimationGraphGeometry Of(AnimationGraphFile file)
    {
        var drawn = file.Nodes.Where(n => n.Kind != AnimationGraphNodeKind.Transition).ToList();
        var placed = drawn.Where(n => n.Position != null).Select(n => n.Position!.Value).ToList();
        var left = placed.Count == 0 ? 0 : placed.Min(p => p.X);
        var below = placed.Count == 0 ? 0 : placed.Max(p => p.Y) + 200 + UnplacedGap;
        var unplaced = 0;
        var nodes = new List<AnimationNodeLayout>();
        foreach (var node in drawn)
        {
            var (x, y) = node.Position ?? (left + UnplacedStep * unplaced++, below);
            nodes.Add(new AnimationNodeLayout(node, new GraphRect(x, y, NodeWidth, HeightOf(node))));
        }

        var states = nodes.Where(n => n.Node.Kind == AnimationGraphNodeKind.State && n.Node.Get("name") != null)
            .GroupBy(n => n.Node.Get("name")!).ToDictionary(g => g.Key, g => g.First());
        var links = new List<MotionLinkLayout>();
        foreach (var state in nodes.Where(n => n.Node.Kind == AnimationGraphNodeKind.State))
        {
            if (GraphValue.Parse(state.Node.Get("motion") ?? "") is GraphLink { Output: "pose" } link
                && nodes.Find(n => n.Node.Id == link.Node && n.Node.Kind == AnimationGraphNodeKind.Blend1D) is { } blend)
            {
                var (blendMiddle, stateMiddle) = (CenterOf(blend.Bounds), CenterOf(state.Bounds));
                links.Add(new MotionLinkLayout(blend.Node.Id, state.Node.Id, blend.EdgeToward(stateMiddle), state.EdgeToward(blendMiddle)));
            }
        }

        return new AnimationGraphGeometry(nodes, LayOutTransitions(file, states, nodes), links);
    }

    static double HeightOf(AnimationGraphNode node)
    {
        if (node.Kind == AnimationGraphNodeKind.State)
        {
            return HeaderHeight + 2 * RowHeight + 6;
        }
        var inputs = node.Fields.Count(f => f.Key.StartsWith("input.", StringComparison.Ordinal));
        // Its inputs and its feed.
        return HeaderHeight + (Math.Max(inputs, 1) + 1) * RowHeight + 4;
    }

    static List<TransitionLayout> LayOutTransitions(AnimationGraphFile file, Dictionary<string, AnimationNodeLayout> states, List<AnimationNodeLayout> nodes)
    {
        var transitions = file.Nodes.Where(n => n.Kind == AnimationGraphNodeKind.Transition).ToList();
        // Each pair of states, whichever way, shares its lanes, so an arrow and the one back do not lie on each other.
        var lanes = new Dictionary<(int, int), List<AnimationGraphNode>>();
        (int, int)? PairOf(AnimationGraphNode t)
        {
            var from = t.Get("from") is { } f && states.TryGetValue(f, out var a) ? a : null;
            var to = t.Get("to") is { } g && states.TryGetValue(g, out var b) ? b : null;
            if (from == null || to == null || from == to)
            {
                return null;
            }
            return (Math.Min(from.Node.Id, to.Node.Id), Math.Max(from.Node.Id, to.Node.Id));
        }
        foreach (var t in transitions)
        {
            if (PairOf(t) is { } pair)
            {
                if (!lanes.TryGetValue(pair, out var list))
                {
                    lanes[pair] = list = [];
                }
                list.Add(t);
            }
        }

        var layouts = new List<TransitionLayout>();
        var loose = 0;
        var looseY = nodes.Count == 0 ? 0 : nodes.Max(n => n.Bounds.Y + n.Bounds.Height) + UnplacedGap;
        var fromAny = new Dictionary<string, int>();
        foreach (var t in transitions)
        {
            var from = t.Get("from") is { } f && states.TryGetValue(f, out var a) ? a : null;
            var to = t.Get("to") is { } g && states.TryGetValue(g, out var b) ? b : null;
            Vec2 middle;
            var offset = new Vec2(0, 0);
            if (PairOf(t) is { } pair && from != null && to != null)
            {
                var (low, high) = (nodes.Find(n => n.Node.Id == pair.Item1)!, nodes.Find(n => n.Node.Id == pair.Item2)!);
                var along = CenterOf(high.Bounds) - CenterOf(low.Bounds);
                var length = Math.Max(along.Length, 1);
                var side = new Vec2(-along.Y / length, along.X / length);
                var list = lanes[pair];
                var turn = list.IndexOf(t) - (list.Count - 1) / 2.0;
                offset = side * (turn * ArrowLane);
                // Where the lanes alone do not part two glyphs, as on a slope, the glyphs also step along their arrows.
                var ahead = along * (1 / length);
                var step = Math.Abs(ahead.Y) < 0.01 ? 0 : Math.Max(0, GlyphHeight + GlyphGap - Math.Abs(side.Y) * ArrowLane) / Math.Abs(ahead.Y);
                middle = (CenterOf(from.Bounds) + CenterOf(to.Bounds)) * 0.5 + offset + ahead * (turn * step);
            }
            else if (t.Get("from") == "any" && to != null)
            {
                // Above the state that it goes to, side by side when there are more.
                var seen = fromAny.GetValueOrDefault(t.Get("to")!);
                fromAny[t.Get("to")!] = seen + 1;
                middle = new Vec2(to.Bounds.X + NodeWidth / 2 + seen * (GlyphWidth + 8), to.Bounds.Y - GlyphHeight - 32);
            }
            else if (from != null)
            {
                middle = new Vec2(from.Bounds.X + NodeWidth + GlyphWidth, from.Bounds.Y + 24);
            }
            else
            {
                middle = new Vec2(GlyphWidth / 2 + loose++ * (GlyphWidth + 8), looseY);
            }
            if (t.Position is { } position)
            {
                middle = new Vec2(position.X, position.Y);
            }
            var glyph = new GraphRect(middle.X - GlyphWidth / 2, middle.Y - GlyphHeight / 2, GlyphWidth, GlyphHeight);
            // An arrow that goes through its own position leaves its lane there.
            var start = from == null ? (Vec2?)null : EdgeOf(from.Outer, t.Position != null ? middle : CenterOf(to?.Bounds ?? glyph) + offset, offset);
            var end = to == null ? (Vec2?)null : EdgeOf(to.Outer, t.Position != null ? middle : CenterOf(from?.Bounds ?? glyph) + offset, offset);
            layouts.Add(new TransitionLayout(t, glyph, start, end));
        }
        return layouts;
    }

    static Vec2 CenterOf(GraphRect r) => new(r.X + r.Width / 2, r.Y + r.Height / 2);

    // The point of a rectangle's edge on the way from its middle, moved along a lane, to another point.
    internal static Vec2 EdgeOf(GraphRect r, Vec2 toward, Vec2 offset)
    {
        var center = CenterOf(r) + offset;
        var d = toward - center;
        var across = d.X > 0 ? (r.X + r.Width - center.X) / d.X : d.X < 0 ? (r.X - center.X) / d.X : double.PositiveInfinity;
        var down = d.Y > 0 ? (r.Y + r.Height - center.Y) / d.Y : d.Y < 0 ? (r.Y - center.Y) / d.Y : double.PositiveInfinity;
        return center + d * Math.Clamp(Math.Min(across, down), 0, 1);
    }

    public AnimationNodeLayout? Find(int id) => _nodes.Find(n => n.Node.Id == id);

    public TransitionLayout? FindTransition(int id) => _transitions.Find(t => t.Node.Id == id);

    /// <summary>
    /// The topmost thing at a point: a transition's glyph, a node with its chip, feed or rim, then an arrow. The zoom
    /// keeps a rim as easy to press when the view is far out.
    /// </summary>
    public AnimationGraphHit HitTest(Vec2 p, double zoom = 1)
    {
        foreach (var t in Enumerable.Reverse(_transitions))
        {
            if (t.Glyph.Contains(p))
            {
                return new AnimationGraphHit(AnimationGraphHitKind.Transition, t.Node.Id);
            }
        }
        var reach = Math.Max(RimWidth, RimReach / zoom);
        for (var k = _nodes.Count - 1; k >= 0; k--)
        {
            var n = _nodes[k];
            if (n.Node.Kind == AnimationGraphNodeKind.State)
            {
                if (n.Chip.Contains(p))
                {
                    return new AnimationGraphHit(AnimationGraphHitKind.MotionChip, n.Node.Id);
                }
                if (!n.Bounds.Contains(p) && n.Bounds.Inflate(reach).Contains(p))
                {
                    return new AnimationGraphHit(AnimationGraphHitKind.StateRim, n.Node.Id);
                }
            }
            else if (n.Feed.Contains(p))
            {
                return new AnimationGraphHit(AnimationGraphHitKind.BlendFeed, n.Node.Id);
            }
            if (n.Bounds.Contains(p))
            {
                return new AnimationGraphHit(AnimationGraphHitKind.Node, n.Node.Id);
            }
        }
        foreach (var t in Enumerable.Reverse(_transitions))
        {
            if (t.Start is { } start && DistanceToSegment(p, start, t.Middle) <= ArrowReach)
            {
                return new AnimationGraphHit(AnimationGraphHitKind.Transition, t.Node.Id);
            }
            if (t.End is { } end && DistanceToSegment(p, t.Middle, end) <= ArrowReach)
            {
                return new AnimationGraphHit(AnimationGraphHitKind.Transition, t.Node.Id);
            }
        }
        return new AnimationGraphHit(AnimationGraphHitKind.None);
    }

    static double DistanceToSegment(Vec2 p, Vec2 a, Vec2 b)
    {
        var ab = b - a;
        var squared = ab.X * ab.X + ab.Y * ab.Y;
        if (squared == 0)
        {
            return (p - a).Length;
        }
        var u = Math.Clamp(((p.X - a.X) * ab.X + (p.Y - a.Y) * ab.Y) / squared, 0, 1);
        return (p - (a + ab * u)).Length;
    }

    /// <summary>The nodes and the transitions' glyphs that a box touches.</summary>
    public IEnumerable<int> InBox(Vec2 a, Vec2 b)
    {
        var box = GraphRect.Between(a, b);
        return _nodes.Where(n => n.Bounds.Intersects(box)).Select(n => n.Node.Id)
            .Concat(_transitions.Where(t => t.Glyph.Intersects(box)).Select(t => t.Node.Id));
    }

    /// <summary>The rectangle around every node and glyph, or null for an empty graph.</summary>
    public GraphRect? Extent()
    {
        var rects = _nodes.Select(n => n.Bounds).Concat(_transitions.Select(t => t.Glyph)).ToList();
        if (rects.Count == 0)
        {
            return null;
        }
        var x0 = rects.Min(r => r.X);
        var y0 = rects.Min(r => r.Y);
        var x1 = rects.Max(r => r.X + r.Width);
        var y1 = rects.Max(r => r.Y + r.Height);
        return new GraphRect(x0, y0, x1 - x0, y1 - y0);
    }
}
