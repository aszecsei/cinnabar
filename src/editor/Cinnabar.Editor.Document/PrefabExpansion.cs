using Wire = Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Document;

/// <summary>
/// Where a flat entity of an expansion comes from: its path, from the outermost instance's ID, and for the root of an
/// instance at any depth, the GUID of the prefab that it instantiates.
/// </summary>
public sealed record InstanceEntity(IReadOnlyList<ulong> Path, string Prefab)
{
    /// <summary>The outermost instance's ID, which is the scene's instance block.</summary>
    public ulong Instance => Path[0];

    /// <summary>True for the outermost instance's root, whose block is the instance block.</summary>
    public bool IsInstanceRoot => Path.Count == 1;
}

/// <summary>The flat scene that a scene expands to, where each of its entities comes from, and the expansion's problems.</summary>
public sealed class Expansion(Scene flat, IReadOnlyDictionary<ulong, InstanceEntity> instances, IReadOnlyList<SceneProblem> problems)
{
    /// <summary>The flat entities, with no instance blocks, no override blocks and no paths, in the order that the host loads them.</summary>
    public Scene Flat { get; } = flat;

    /// <summary>The flat entities that are inside an instance, by scene ID. A plain entity of the scene has none.</summary>
    public IReadOnlyDictionary<ulong, InstanceEntity> Instances { get; } = instances;

    public IReadOnlyList<SceneProblem> Problems { get; } = problems;

    public InstanceEntity? InstanceOf(ulong id) => Instances.GetValueOrDefault(id);
}

/// <summary>
/// Turns a scene's instances into plain entities (see docs/editor/prefabs.md#expansion). The cooker and the runtime do
/// the same with <c>asset_format.scene_expand</c>, and the two must agree: the fixture in
/// <c>lib/engine/asset/format/testdata/prefabs</c> holds both to one result.
/// </summary>
public static class PrefabExpansion
{
    /// <summary>The most levels of prefabs inside prefabs, a guard behind the check for cycles.</summary>
    public const int Depth = 8;

    /// <summary>
    /// Expands a scene. <paramref name="prefabs"/> gives a prefab's scene, as its file has it, by GUID, or null for
    /// one that is missing. <paramref name="self"/> is the GUID of the prefab being expanded, if the scene is one.
    /// </summary>
    public static Expansion Expand(Scene scene, Func<string, Scene?> prefabs, string self = "")
    {
        var x = new Expander(prefabs, self == "" ? 0 : 1);
        var flat = x.Entities(scene, self == "" ? [] : [self]);
        var result = new Scene();
        result.Entities.AddRange(flat.Select(f => f.Entity));
        var instances = new Dictionary<ulong, InstanceEntity>();
        foreach (var f in flat)
        {
            if (f.Path != null)
            {
                instances[f.Entity.Id] = new InstanceEntity(f.Path, f.Prefab);
            }
        }
        foreach (var group in result.Entities.GroupBy(e => e.Id).Where(g => g.Count() > 1))
        {
            x.Problems.Add(new SceneProblem(0, $"two entities have the scene ID {group.Key:x16} after expanding the prefabs", true));
        }
        return new Expansion(result, instances, x.Problems);
    }

    /// <summary>The prefab's root, the one block that is neither an override nor a child, and how many such blocks it has.</summary>
    public static (SceneEntity? Root, int Roots) RootOf(Scene prefab)
    {
        var roots = prefab.Entities.Where(e => e.Path == null && e.Parent == 0).ToList();
        return (roots.FirstOrDefault(), roots.Count);
    }

    // A flat entity, with its path from the outermost instance of the scene being expanded and the prefab it is the
    // root of, or none for a plain entity of that scene.
    sealed record Flat(SceneEntity Entity, IReadOnlyList<ulong>? Path, string Prefab);

    sealed class Expander(Func<string, Scene?> prefabs, int outermost)
    {
        public List<SceneProblem> Problems { get; } = [];
        ulong _instance;

        public List<Flat> Entities(Scene scene, IReadOnlyList<string> chain)
        {
            var isOutermost = chain.Count == outermost;
            var output = new List<Flat>();
            var ranges = new Dictionary<ulong, (int Start, int End)>();
            foreach (var e in scene.Entities.Where(e => e.Path == null))
            {
                var start = output.Count;
                if (e.Prefab == "")
                {
                    output.Add(new Flat(Plain(e.Copy(e.Id)), null, ""));
                }
                else
                {
                    if (isOutermost)
                    {
                        _instance = e.Id;
                    }
                    Place(output, e, chain, isOutermost);
                }
                ranges[e.Id] = (start, output.Count);
            }
            foreach (var e in scene.Entities.Where(e => e.Path != null))
            {
                var target = -1;
                if (ranges.TryGetValue(e.Path![0], out var r))
                {
                    // The root's overrides are the instance block's, so an override block names one of the others.
                    for (var i = r.Start + 1; i < r.End && target < 0; i++)
                    {
                        if (output[i].Entity.Id == e.Id)
                        {
                            target = i;
                        }
                    }
                }
                if (target < 0)
                {
                    if (isOutermost)
                    {
                        Problems.Add(new SceneProblem(0, $"the override {ScenePath.Format(e.Path)} names an entity that the instance does not have, so it is kept and does nothing", false));
                    }
                    continue;
                }
                var entity = output[target].Entity;
                ApplyOverride(entity, e);
                Plain(entity);
                if (e.Keys.HasFlag(SceneKeys.Parent))
                {
                    entity.Parent = e.Parent;
                }
                entity.Removed = e.Removed;
            }
            return DropRemoved(output);
        }

        void Place(List<Flat> output, SceneEntity block, IReadOnlyList<string> chain, bool isOutermost)
        {
            if (Prefab(block, chain, isOutermost) is not var (prefab, root))
            {
                var alone = Plain(block.Copy(block.Id));
                output.Add(new Flat(alone, [block.Id], block.Prefab));
                return;
            }
            var ids = prefab.Select(f => f.Entity.Id).ToHashSet();
            ulong Remap(ulong id) => id == root ? block.Id : ScenePath.Id(block.Id, id);
            IReadOnlyList<ulong> PathOf(Flat f) =>
                f.Entity.Id == root ? [block.Id] : f.Path is { } inner ? [block.Id, .. inner] : [block.Id, f.Entity.Id];
            var ordered = prefab.Where(f => f.Entity.Id == root).Concat(prefab.Where(f => f.Entity.Id != root));
            var first = true;
            foreach (var f in ordered)
            {
                var e = f.Entity.Copy(Remap(f.Entity.Id));
                if (f.Entity.Parent != 0 && ids.Contains(f.Entity.Parent))
                {
                    e.Parent = Remap(f.Entity.Parent);
                }
                foreach (var fields in e.Components.Select(c => c.Fields).Concat(e.Behaviours.Select(b => b.Fields)))
                {
                    RemapFields(fields, ids, Remap, isOutermost);
                }
                if (first)
                {
                    // The instance's pose and parent are the scene's.
                    e.Parent = block.Parent;
                    e.Components.RemoveAll(c => c.Id is SceneEdits.TransformId or SceneEdits.LocalTransformId);
                    ApplyOverride(e, block);
                }
                output.Add(new Flat(Plain(e), PathOf(f), first ? block.Prefab : f.Prefab));
                first = false;
            }
        }

        (List<Flat> Entities, ulong Root)? Prefab(SceneEntity block, IReadOnlyList<string> chain, bool isOutermost)
        {
            if (chain.Contains(block.Prefab))
            {
                Problems.Add(new SceneProblem(0, $"instance {_instance:x16}: the prefab {block.Prefab} contains itself: {string.Join(" contains ", chain)} contains {block.Prefab}", true));
                return null;
            }
            if (chain.Count >= Depth)
            {
                Problems.Add(new SceneProblem(0, $"instance {_instance:x16}: the prefab {block.Prefab} is more than {Depth} prefabs deep", true));
                return null;
            }
            if (prefabs(block.Prefab) is not { } scene)
            {
                if (isOutermost)
                {
                    Problems.Add(new SceneProblem(0, $"instance {block.Id:x16}: the prefab {block.Prefab} is missing or does not parse, so the instance is its root alone", false));
                }
                return null;
            }
            var (root, roots) = RootOf(scene);
            if (roots != 1)
            {
                if (isOutermost)
                {
                    Problems.Add(new SceneProblem(0, $"instance {block.Id:x16}: the prefab {block.Prefab} has {roots} roots, not one, so the instance is its root alone", false));
                }
                return null;
            }
            return (Entities(scene, [.. chain, block.Prefab]), root!.Id);
        }

        void RemapFields(List<SceneField> fields, HashSet<ulong> ids, Func<ulong, ulong> remap, bool isOutermost)
        {
            for (var i = 0; i < fields.Count; i++)
            {
                var v = fields[i].Value;
                if (v.Kind != SceneValueKind.Entity || v.Entity == 0)
                {
                    continue;
                }
                if (!ids.Contains(v.Entity))
                {
                    if (isOutermost)
                    {
                        Problems.Add(new SceneProblem(0, $"instance {_instance:x16}: the field {fields[i].Name} refers to {v.Entity:x16}, which its prefab does not have, so it is none", false));
                    }
                    fields[i] = fields[i] with { Value = SceneValue.EntityRef(0) };
                    continue;
                }
                fields[i] = fields[i] with { Value = SceneValue.EntityRef(remap(v.Entity)) };
            }
        }

        static List<Flat> DropRemoved(List<Flat> entities)
        {
            if (!entities.Any(f => f.Entity.Removed))
            {
                return entities;
            }
            var byId = entities.GroupBy(f => f.Entity.Id).ToDictionary(g => g.Key, g => g.First().Entity);
            bool Removed(SceneEntity e)
            {
                for (var (at, steps) = (e, 0); steps <= entities.Count; steps++)
                {
                    if (at.Removed)
                    {
                        return true;
                    }
                    if (at.Parent == 0 || !byId.TryGetValue(at.Parent, out var parent))
                    {
                        return false;
                    }
                    at = parent;
                }
                return false;
            }
            return [.. entities.Where(f => !Removed(f.Entity))];
        }
    }

    // A flat entity carries nothing of a block: no prefab, no keys, no removals, and its references are scene IDs.
    static SceneEntity Plain(SceneEntity e)
    {
        e.Prefab = "";
        e.Keys = SceneKeys.None;
        e.ParentPath = null;
        e.RemovedComponents.Clear();
        e.RemovedBehaviours.Clear();
        foreach (var fields in e.Components.Select(c => c.Fields).Concat(e.Behaviours.Select(b => b.Fields)))
        {
            for (var i = 0; i < fields.Count; i++)
            {
                if (fields[i].Value.Path != null)
                {
                    fields[i] = fields[i] with { Value = SceneValue.EntityRef(fields[i].Value.Entity) };
                }
            }
        }
        return e;
    }

    /// <summary>
    /// Applies a block's keys, removals, components and behaviours over an entity: the keys that it writes, the fields
    /// that it lists over the entity's, and the components and behaviours that the entity lacks added.
    /// </summary>
    public static void ApplyOverride(SceneEntity e, SceneEntity block)
    {
        if (block.Keys.HasFlag(SceneKeys.Name))
        {
            e.Name = block.Name;
        }
        if (block.Keys.HasFlag(SceneKeys.Active))
        {
            e.Active = block.Active;
        }
        e.Components.RemoveAll(c => block.RemovedComponents.Contains(c.Id));
        foreach (var c in block.Components)
        {
            var at = e.Components.FindIndex(x => x.Id >= c.Id);
            if (at >= 0 && e.Components[at].Id == c.Id)
            {
                e.Components[at] = e.Components[at] with { Fields = Merge(e.Components[at].Fields, c.Fields) };
            }
            else
            {
                e.Components.Insert(at < 0 ? e.Components.Count : at, c with { Fields = [.. c.Fields] });
            }
        }
        e.Behaviours.RemoveAll(b => block.RemovedBehaviours.Contains(b.Script));
        foreach (var b in block.Behaviours)
        {
            var at = e.Behaviours.FindIndex(x => x.Script == b.Script);
            if (at >= 0)
            {
                e.Behaviours[at] = e.Behaviours[at] with { Fields = Merge(e.Behaviours[at].Fields, b.Fields) };
            }
            else
            {
                e.Behaviours.Add(b with { Fields = [.. b.Fields] });
            }
        }
    }

    // The fields with each of over set: in its place if the fields have it, and after them if not.
    static List<SceneField> Merge(List<SceneField> fields, List<SceneField> over)
    {
        var result = new List<SceneField>(fields);
        foreach (var f in over)
        {
            var at = result.FindIndex(x => x.Name == f.Name);
            if (at >= 0)
            {
                result[at] = f;
            }
            else
            {
                result.Add(f);
            }
        }
        return result;
    }

    /// <summary>
    /// The operations that turn the host's world from one flat scene into another: destroys of the entities that
    /// vanished, the deepest first; creates of those that appeared, each after its parent; and for the rest, the
    /// changes of their names, parents, activity, components, fields and behaviours.
    /// </summary>
    public static List<Wire.Operation> Diff(IReadOnlyList<SceneEntity> before, IReadOnlyList<SceneEntity> after)
    {
        var ops = new List<Wire.Operation>();
        var old = before.GroupBy(e => e.Id).ToDictionary(g => g.Key, g => g.First());
        var now = after.GroupBy(e => e.Id).ToDictionary(g => g.Key, g => g.First());
        int DepthIn(Dictionary<ulong, SceneEntity> scene, SceneEntity e)
        {
            var depth = 0;
            for (var p = e.Parent; p != 0 && depth < 64 && scene.TryGetValue(p, out var parent); p = parent.Parent)
            {
                depth++;
            }
            return depth;
        }
        foreach (var e in before.Where(e => !now.ContainsKey(e.Id)).OrderByDescending(e => DepthIn(old, e)))
        {
            ops.Add(Op(Wire.OperationKind.DestroyEntity, e.Id));
        }
        foreach (var e in after.Where(e => !old.ContainsKey(e.Id)).OrderBy(e => DepthIn(now, e)))
        {
            ops.Add(Op(Wire.OperationKind.CreateEntity, e.Id, created: [SceneSnapshot.Entity(e)]));
        }
        foreach (var e in after)
        {
            if (!old.TryGetValue(e.Id, out var was))
            {
                continue;
            }
            if (was.Name != e.Name)
            {
                ops.Add(Op(Wire.OperationKind.Rename, e.Id, name: e.Name));
            }
            if (was.Parent != e.Parent)
            {
                ops.Add(Op(Wire.OperationKind.SetParent, e.Id, parent: e.Parent));
            }
            if (was.Active != e.Active)
            {
                ops.Add(Op(Wire.OperationKind.SetActive, e.Id, active: e.Active));
            }
            foreach (var c in was.Components.Where(c => e.Components.All(x => x.Id != c.Id)))
            {
                ops.Add(Op(Wire.OperationKind.RemoveComponent, e.Id, component: c.Id));
            }
            foreach (var c in e.Components)
            {
                if (was.Components.Find(x => x.Id == c.Id) is not { } prior)
                {
                    ops.Add(Op(Wire.OperationKind.AddComponent, e.Id, components: [SceneSnapshot.Component(c)]));
                    continue;
                }
                foreach (var (name, value) in FieldChanges(prior.Fields, c.Fields))
                {
                    ops.Add(value == null
                        ? Op(Wire.OperationKind.ResetField, e.Id, component: c.Id, fields: [new Wire.SceneField(name, SceneSnapshot.Value(SceneValue.Of(false)))])
                        : Op(Wire.OperationKind.SetField, e.Id, component: c.Id, fields: [new Wire.SceneField(name, SceneSnapshot.Value(value))]));
                }
            }
            foreach (var b in was.Behaviours.Where(b => e.Behaviours.All(x => x.Script != b.Script)))
            {
                ops.Add(Op(Wire.OperationKind.RemoveBehaviour, e.Id, script: b.Script));
            }
            foreach (var b in e.Behaviours)
            {
                if (was.Behaviours.Find(x => x.Script == b.Script) is not { } prior)
                {
                    ops.Add(Op(Wire.OperationKind.AddBehaviour, e.Id, script: b.Script, fields: [.. b.Fields.Select(SceneSnapshot.Field)]));
                    continue;
                }
                foreach (var (name, value) in FieldChanges(prior.Fields, b.Fields))
                {
                    ops.Add(value == null
                        ? Op(Wire.OperationKind.ResetBehaviourField, e.Id, script: b.Script, fields: [new Wire.SceneField(name, SceneSnapshot.Value(SceneValue.Of(false)))])
                        : Op(Wire.OperationKind.SetBehaviourField, e.Id, script: b.Script, fields: [new Wire.SceneField(name, SceneSnapshot.Value(value))]));
                }
            }
        }
        return ops;
    }

    // The fields that changed, with their new values, or null for one that is gone.
    static IEnumerable<(string Name, SceneValue? Value)> FieldChanges(List<SceneField> before, List<SceneField> after)
    {
        foreach (var f in before.Where(f => after.All(x => x.Name != f.Name)))
        {
            yield return (f.Name, null);
        }
        foreach (var f in after)
        {
            if (before.Find(x => x.Name == f.Name) is not { } prior || prior.Value != f.Value)
            {
                yield return (f.Name, f.Value);
            }
        }
    }

    static Wire.Operation Op(Wire.OperationKind kind, ulong entity, Wire.SceneEntity[]? created = null, string name = "",
        ulong parent = 0, bool active = false, ulong component = 0, Wire.SceneComponent[]? components = null, string? script = null,
        Wire.SceneField[]? fields = null) =>
        new(kind, entity, created ?? [], name, parent, active, component, components ?? [],
            script == null ? new byte[16] : Convert.FromHexString(script), fields ?? []);
}
