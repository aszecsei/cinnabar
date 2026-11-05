namespace Cinnabar.Editor.Document;

/// <summary>
/// An entity of a prefab's expansion, as the content browser shows it and a scene can take a part of the prefab from it:
/// where it is in the prefab, and what it draws.
/// </summary>
public sealed record PrefabNode(
    ulong Id,
    string Name,
    ulong Parent,
    int Depth,
    IReadOnlyList<ulong> Children,
    Pose Pose,
    double[] Anchor,
    string Mesh,
    IReadOnlyList<string> Materials);

/// <summary>
/// A prefab's entities as a tree (see docs/editor/prefabs.md#panels-and-the-viewport), from its expansion, so the entities of
/// nested instances are in it, with the IDs that a part's <c>node</c> names. A pose is in the prefab's space, in which the
/// root stands at the origin, as an instance replaces the root's own pose.
/// </summary>
public sealed class PrefabTree
{
    readonly Dictionary<ulong, PrefabNode> _nodes = [];

    PrefabTree(ulong root) => Root = root;

    public ulong Root { get; }

    public PrefabNode? Find(ulong id) => _nodes.GetValueOrDefault(id);

    public IEnumerable<PrefabNode> Nodes => _nodes.Values;

    /// <summary>A prefab's tree, or null when it does not have one root.</summary>
    public static PrefabTree? Of(Scene prefab, Func<string, Scene?> prefabs, string guid = "")
    {
        if (PrefabExpansion.RootOf(prefab) is not ({ } root, 1))
        {
            return null;
        }
        var flat = PrefabExpansion.Expand(prefab, prefabs, guid).Flat;
        var tree = new PrefabTree(root.Id);
        var children = flat.Entities.ToLookup(e => e.Parent);
        // A root's own pose is the instance's, so it does not count.
        var origin = flat.Find(root.Id) is { } r ? SceneEdits.WorldPose(flat, r) ?? Pose.Identity : Pose.Identity;
        var poses = new Dictionary<ulong, Pose>();
        foreach (var e in flat.Entities)
        {
            var world = e.Id == root.Id ? origin : SceneEdits.WorldPose(flat, e) ?? origin;
            var (offset, rotation, scale) = Pose.Relative(origin, world);
            poses[e.Id] = Pose.Identity.Compose(offset, rotation, scale);
        }
        void Visit(SceneEntity e, int depth)
        {
            var renderer = e.Components.Find(c => c.Id == SceneEdits.MeshRendererId);
            var mesh = renderer?.Fields.Find(f => f.Name == "mesh")?.Value is { Kind: SceneValueKind.Asset } m ? m.Asset : "";
            var materials = renderer == null ? [] : renderer.Fields
                .Where(f => f.Name.StartsWith("materials.", StringComparison.Ordinal) && f.Value.Kind == SceneValueKind.Asset && f.Value.Asset != "")
                .Select(f => f.Value.Asset).Distinct().ToList();
            var kids = children[e.Id].Where(c => c.Id != e.Id).ToList();
            tree._nodes[e.Id] = new PrefabNode(e.Id, e.Name, e.Id == root.Id ? 0 : e.Parent, depth, [.. kids.Select(k => k.Id)], poses[e.Id], [0, 0, 0], mesh, materials);
            foreach (var child in kids)
            {
                Visit(child, depth + 1);
            }
        }
        if (flat.Find(root.Id) is { } top)
        {
            Visit(top, 0);
        }
        // What a part is held by: the mean of the pivots of what it draws, in its own space.
        foreach (var node in tree._nodes.Values.ToList())
        {
            var pivots = new List<double[]>();
            void Gather(PrefabNode n)
            {
                if (n.Mesh != "")
                {
                    var (offset, _, _) = Pose.Relative(node.Pose, n.Pose);
                    pivots.Add(offset);
                }
                foreach (var c in n.Children)
                {
                    Gather(tree._nodes[c]);
                }
            }
            Gather(node);
            if (pivots.Count > 0)
            {
                tree._nodes[node.Id] = node with
                {
                    Anchor = [pivots.Average(p => p[0]), pivots.Average(p => p[1]), pivots.Average(p => p[2])],
                };
            }
        }
        return tree;
    }
}
