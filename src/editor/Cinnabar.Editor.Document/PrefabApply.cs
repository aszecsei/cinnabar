namespace Cinnabar.Editor.Document;

/// <summary>
/// Edits that carry an instance's overrides into a prefab, or drop them (see docs/editor/prefabs.md#editing-an-instance):
/// Apply and Apply All, Revert All, and Make Variant. Each gives the operations of one undo entry, a
/// <see cref="PrefabOperation"/> of the prefab with the scene's edits, so undo brings both back.
/// </summary>
public static partial class PrefabEdits
{
    /// <summary>
    /// Whether a prefab contains another, itself or through the instances inside it, as the prefabs of the document's
    /// set have them.
    /// </summary>
    public static bool Contains(SceneDocument document, string prefab, string other, int depth = 0)
    {
        if (prefab == other)
        {
            return true;
        }
        if (depth > PrefabExpansion.Depth || document.Prefabs.SceneOf(prefab) is not { } scene)
        {
            return false;
        }
        return scene.Entities.Any(e => e.Prefab != "" && Contains(document, e.Prefab, other, depth + 1));
    }

    // A working copy of a prefab as a document, whose routed operations make the prefab's next snapshot, with the
    // same override rules as the scene's.
    static SceneDocument Working(SceneDocument document, PrefabDocument prefab) =>
        new(prefab.Path, prefab.Scene.Clone(), g => document.Prefabs.Find(g)) { PrefabGuid = prefab.Guid };

    // The instance's prefab, with its root's ID in it.
    static (PrefabDocument Prefab, ulong Root) PrefabOf(SceneDocument document, ulong instance)
    {
        var block = document.Scene.Find(instance);
        if (block is not { Prefab: not "" } || document.Prefabs.Find(block.Prefab) is not { } prefab
            || PrefabExpansion.RootOf(prefab.Scene) is not ({ } root, 1))
        {
            throw new InvalidOperationException("the instance's prefab is not open, or does not have one root");
        }
        return (prefab, root.Id);
    }

    // Where an entity of the scene is in the prefab: the instance's root is the prefab's root, and an entity on a path
    // from the instance is on the rest of the path. moved holds the entities that the edit carries into the prefab,
    // which keep their IDs. Null for an entity outside, which a prefab cannot refer to.
    static Func<SceneValue, SceneValue?> Mapper(SceneDocument document, ulong instance, ulong root, IReadOnlySet<ulong> moved) => v =>
    {
        if (v.Kind != SceneValueKind.Entity || v.Entity == 0)
        {
            return v;
        }
        if (v.Entity == instance)
        {
            return SceneValue.EntityRef(root);
        }
        var info = document.Expanded.InstanceOf(v.Entity);
        if (info?.Instance == instance)
        {
            return SceneValue.EntityRef([.. info.Path.Skip(1)]);
        }
        if (moved.Contains(v.Entity) || info != null && moved.Contains(info.Instance))
        {
            return v;
        }
        return null;
    };

    /// <summary>
    /// Applies one overridden field of an instance's entity to the prefab that the instance names: the prefab takes
    /// the value, for the entity on the same path in it, and the override goes, so every instance has the value.
    /// </summary>
    public static Operation[] Apply(SceneDocument document, ulong id, ulong component, string? script, string field)
    {
        var info = document.Expanded.InstanceOf(id) ?? throw new InvalidOperationException($"{id:x16} is not inside an instance");
        if (info.IsInstanceRoot && script == null && component is SceneEdits.TransformId or SceneEdits.LocalTransformId)
        {
            throw new InvalidOperationException("the pose of an instance's root is the scene's, which no prefab has");
        }
        var (prefab, root) = PrefabOf(document, info.Instance);
        var flat = document.Expanded.Flat.Find(id)!;
        var fields = script == null ? flat.Components.Find(c => c.Id == component)?.Fields : flat.Behaviours.Find(b => b.Script == script)?.Fields;
        if (fields?.Find(f => f.Name == field) is not { } set)
        {
            throw new InvalidOperationException($"the entity has no {field} to apply");
        }
        if (Mapper(document, info.Instance, root, new HashSet<ulong>())(set.Value) is not { } value)
        {
            throw new InvalidOperationException($"{field} refers to an entity outside the instance, which its prefab cannot");
        }
        var working = Working(document, prefab);
        var local = info.IsInstanceRoot ? root : ScenePath.Id([.. info.Path.Skip(1)]);
        var target = working.Expanded.Flat.Find(local) ?? throw new InvalidOperationException("the prefab no longer has the entity");
        if (script == null)
        {
            working.Apply("", target.Components.Any(c => c.Id == component)
                ? new SetField(local, component, field, value)
                : new AddComponent(local, new SceneComponent(component, flat.Components.Find(c => c.Id == component)!.Name, [new SceneField(field, value)])));
        }
        else
        {
            working.Apply("", target.Behaviours.Any(b => b.Script == script)
                ? new SetBehaviourField(local, script, field, value)
                : new AddBehaviour(local, new SceneBehaviour(script, [new SceneField(field, value)]), int.MaxValue));
        }
        return [
            new PrefabOperation(document, prefab.Guid, prefab.Scene, working.Scene),
            script == null ? new SetField(id, component, field, null) : new SetBehaviourField(id, script, field, null),
        ];
    }

    // The instance's override blocks, the entities that the scene added to it, the top ones each under one of the
    // instance's entities, and every block of them: the scene's plain entities and the instances added among them.
    static (List<SceneEntity> Overrides, List<SceneEntity> AddedTops, List<SceneEntity> AddedBlocks, HashSet<ulong> Moved) Parts(SceneDocument document, ulong instance)
    {
        var expansion = document.Expanded;
        var overrides = BlocksOf(document.Scene, instance);
        var tops = new List<SceneEntity>();
        var blocks = new List<SceneEntity>();
        var moved = new HashSet<ulong>();
        foreach (var e in SceneEdits.Descendants(expansion.Flat, instance))
        {
            var info = expansion.InstanceOf(e.Id);
            if (info?.Instance == instance || info != null && !info.IsInstanceRoot)
            {
                continue;
            }
            moved.Add(e.Id);
            if (expansion.InstanceOf(e.Parent)?.Instance == instance || e.Parent == instance)
            {
                tops.Add(document.Scene.Find(e.Id)!);
            }
            blocks.AddRange(info == null ? [document.Scene.Find(e.Id)!] : BlocksOf(document.Scene, e.Id));
        }
        return (overrides, tops, blocks, moved);
    }

    // The instance block without its overrides: the prefab, the parent and the pose, which are the scene's.
    static SceneEntity Bare(SceneEntity block)
    {
        var bare = new SceneEntity(block.Id) { Prefab = block.Prefab, Parent = block.Parent, ParentPath = block.ParentPath };
        bare.Components.AddRange(block.Components.Where(c => c.Id is SceneEdits.TransformId or SceneEdits.LocalTransformId).Select(c => c.Copy()));
        return bare;
    }

    // The scene's blocks outside the instance, with each reference and parent that names an entity that moved into the
    // instance's prefab rewritten, as <instance>#<entity>, or with a prefix for a path through an instance that moved.
    static List<SceneEntity> Reroute(SceneDocument document, ulong instance, IReadOnlySet<ulong> moved, IReadOnlySet<ulong> skip, Func<IReadOnlyList<ulong>, IReadOnlyList<ulong>> under)
    {
        var expansion = document.Expanded;
        IReadOnlyList<ulong>? PathOf(ulong id) =>
            moved.Contains(id) ? under([id]) : expansion.InstanceOf(id) is { } info && moved.Contains(info.Instance) ? under(info.Path) : null;
        var changed = new List<SceneEntity>();
        foreach (var e in document.Scene.Entities.Where(e => !skip.Contains(e.Id)))
        {
            var copy = e.Clone();
            var any = false;
            if (copy.Parent != 0 && PathOf(copy.Parent) is { } parent)
            {
                copy.Parent = ScenePath.Id(parent);
                copy.ParentPath = parent.Count > 1 ? parent : null;
                any = true;
            }
            foreach (var list in copy.Components.Select(c => c.Fields).Concat(copy.Behaviours.Select(b => b.Fields)))
            {
                for (var i = 0; i < list.Count; i++)
                {
                    if (list[i].Value is { Kind: SceneValueKind.Entity, Entity: not 0 } v && PathOf(v.Entity) is { } path)
                    {
                        list[i] = list[i] with { Value = SceneValue.EntityRef(path) };
                        any = true;
                    }
                }
            }
            if (any)
            {
                changed.Add(copy);
            }
        }
        return changed;
    }

    /// <summary>
    /// Applies every override of an instance to the prefab that it names: the keys, fields, components and behaviours
    /// of its entities, the removals, and the entities that the scene added to it, which the prefab then has with
    /// their scene IDs. The instance keeps its pose and parent, and a field that refers to an entity outside the
    /// instance, which a prefab cannot, stays an override. An added instance of a prefab that contains this one is
    /// refused.
    /// </summary>
    public static Operation[] ApplyAll(SceneDocument document, ulong instance)
    {
        var (prefab, root) = PrefabOf(document, instance);
        var (overrides, tops, added, moved) = Parts(document, instance);
        foreach (var b in added.Where(b => b.Prefab != ""))
        {
            if (Contains(document, b.Prefab, prefab.Guid))
            {
                throw new InvalidOperationException($"an instance added to it contains {prefab.Title}, which cannot contain itself");
            }
        }
        var map = Mapper(document, instance, root, moved);
        var working = Working(document, prefab);
        var kept = new List<SceneEntity>();
        var removed = new List<ulong>();
        void Run(params Operation[] ops)
        {
            if (ops.Length > 0)
            {
                working.Apply("", ops);
            }
        }
        foreach (var block in overrides.OrderBy(b => b.Path?.Count ?? 0))
        {
            var local = block.Path == null ? root : ScenePath.Id([.. block.Path.Skip(1)]);
            if (working.Expanded.Flat.Find(local) is not { } target)
            {
                continue;
            }
            var keep = block.Path == null ? Bare(block) : new SceneEntity(block.Path);
            if (block.Removed)
            {
                removed.Add(local);
            }
            if (block.Keys.HasFlag(SceneKeys.Name))
            {
                Run(new Rename(local, block.Name));
            }
            if (block.Keys.HasFlag(SceneKeys.Active))
            {
                Run(new SetActive(local, block.Active));
            }
            if (block.Path != null && block.Keys.HasFlag(SceneKeys.Parent) && map(SceneValue.EntityRef(block.ParentPath ?? [block.Parent])) is { } parent)
            {
                Run(SceneEdits.Reparent(working.Expanded.Flat, local, parent.Entity).Take(1).ToArray());
            }
            Run([.. block.RemovedComponents.Where(c => target.Components.Any(x => x.Id == c)).Select(c => new RemoveComponent(local, c))]);
            Run([.. block.RemovedBehaviours.Where(s => target.Behaviours.Any(x => x.Script == s)).Select(s => new RemoveBehaviour(local, s))]);
            foreach (var c in block.Components.Where(c => block.Path != null || c.Id is not (SceneEdits.TransformId or SceneEdits.LocalTransformId)))
            {
                var fields = Split(c.Fields, map, out var outside);
                if (outside.Count > 0)
                {
                    keep.Components.Add(new SceneComponent(c.Id, c.Name, outside));
                }
                if (working.Expanded.Flat.Find(local)!.Components.All(x => x.Id != c.Id))
                {
                    Run(new AddComponent(local, new SceneComponent(c.Id, c.Name, fields)));
                }
                else
                {
                    Run([.. fields.Select(f => new SetField(local, c.Id, f.Name, f.Value))]);
                }
            }
            foreach (var b in block.Behaviours)
            {
                var fields = Split(b.Fields, map, out var outside);
                if (outside.Count > 0)
                {
                    keep.Behaviours.Add(new SceneBehaviour(b.Script, outside));
                }
                if (working.Expanded.Flat.Find(local)!.Behaviours.All(x => x.Script != b.Script))
                {
                    Run(new AddBehaviour(local, new SceneBehaviour(b.Script, fields), int.MaxValue));
                }
                else
                {
                    Run([.. fields.Select(f => new SetBehaviourField(local, b.Script, f.Name, f.Value))]);
                }
            }
            if (block.Path == null || keep.Components.Count + keep.Behaviours.Count > 0)
            {
                kept.Add(keep);
            }
        }
        // The added entities join the prefab with their IDs, under the same entities there.
        var into = added.Select(b =>
        {
            var copy = b.Clone();
            if (copy.Path == null && map(SceneValue.EntityRef(copy.ParentPath ?? [copy.Parent])) is { } parent)
            {
                copy.Parent = parent.Entity;
                copy.ParentPath = parent.Path;
            }
            MapFields(copy, map);
            return copy;
        }).ToList();
        if (into.Count > 0)
        {
            Run(new BlockOperation(working, 0, [], into));
        }
        foreach (var local in removed)
        {
            if (working.Expanded.Flat.Find(local) != null)
            {
                Run(DestroyTree(working, local));
            }
        }
        var skip = overrides.Concat(added).Select(b => b.Id).ToHashSet();
        var rest = Reroute(document, instance, moved, skip, path => [instance, .. path]);
        return [
            new PrefabOperation(document, prefab.Guid, prefab.Scene, working.Scene),
            new BlockOperation(document, instance, [.. skip, .. rest.Select(r => r.Id)], [.. kept, .. rest]),
        ];
    }

    // The fields that a prefab can take, mapped into it, and in outside those that refer to an entity outside the instance.
    static List<SceneField> Split(List<SceneField> fields, Func<SceneValue, SceneValue?> map, out List<SceneField> outside)
    {
        var inside = new List<SceneField>();
        outside = [];
        foreach (var f in fields)
        {
            if (map(f.Value) is { } v)
            {
                inside.Add(f with { Value = v });
            }
            else
            {
                outside.Add(f);
            }
        }
        return inside;
    }

    // An entity's references mapped into the prefab; one to an entity outside it becomes none.
    static void MapFields(SceneEntity e, Func<SceneValue, SceneValue?> map)
    {
        foreach (var list in e.Components.Select(c => c.Fields).Concat(e.Behaviours.Select(b => b.Fields)))
        {
            for (var i = 0; i < list.Count; i++)
            {
                list[i] = list[i] with { Value = map(list[i].Value) ?? SceneValue.EntityRef(0) };
            }
        }
    }

    /// <summary>
    /// Drops every override of an instance, as Revert All: its entities take the prefab's values again, and the
    /// entities that the scene added to it go. The instance keeps its pose and parent.
    /// </summary>
    public static Operation[] RevertAll(SceneDocument document, ulong instance)
    {
        var block = document.Scene.Find(instance) ?? throw new InvalidOperationException($"the scene has no instance {instance:x16}");
        var (overrides, tops, _, _) = Parts(document, instance);
        var ops = new List<Operation>();
        foreach (var top in tops)
        {
            ops.AddRange(DestroyTree(document, top.Id));
        }
        ops.Add(new BlockOperation(document, instance, [.. overrides.Select(o => o.Id)], [Bare(block)]));
        return [.. ops];
    }

    /// <summary>
    /// Makes a variant of an instance's prefab, as Make Variant: a new prefab document, written at the next save, whose
    /// root is an instance of the prefab with the instance's overrides and the entities that the scene added to it;
    /// and the scene's instance becomes an instance of the variant with its pose alone. A variant points only at the
    /// prefab that it varies, so it cannot make a cycle.
    /// </summary>
    public static (Operation[] Operations, PrefabDocument Variant) MakeVariant(SceneDocument document, ulong instance, string path)
    {
        var block = document.Scene.Find(instance);
        if (block is not { Prefab: not "" })
        {
            throw new InvalidOperationException($"{instance:x16} is not an instance");
        }
        var (overrides, _, added, moved) = Parts(document, instance);
        var root = SceneEntity.NewId();
        var guid = Convert.ToHexStringLower(System.Guid.NewGuid().ToByteArray());
        var scene = new Scene();
        // The variant's root is the instance block with the instance's root overrides, at the origin.
        var top = block.Copy(root);
        top.Parent = 0;
        top.ParentPath = null;
        top.Components.RemoveAll(c => c.Id is SceneEdits.TransformId or SceneEdits.LocalTransformId);
        top.Components.Insert(0, new SceneComponent(SceneEdits.TransformId, "Transform", SceneEdits.TransformFields(Pose.Identity)));
        // In the variant the instance's entities are on paths from its root, and the added entities keep their IDs.
        IReadOnlyList<ulong> InVariant(IReadOnlyList<ulong> p) => p[0] == instance ? [root, .. p.Skip(1)] : p;
        SceneValue? Map(SceneValue v)
        {
            if (v.Kind != SceneValueKind.Entity || v.Entity == 0)
            {
                return v;
            }
            if (v.Entity == instance)
            {
                return SceneValue.EntityRef(root);
            }
            if (document.Expanded.InstanceOf(v.Entity) is { } info && (info.Instance == instance || moved.Contains(info.Instance)))
            {
                return SceneValue.EntityRef(InVariant(info.Path));
            }
            return moved.Contains(v.Entity) ? v : null;
        }
        // A field that refers to an entity outside the instance, which a prefab cannot, stays the scene's override, on
        // the path through the variant's root.
        var instanceBlock = Bare(block);
        instanceBlock.Prefab = guid;
        var kept = new List<SceneEntity>();
        void Keep(SceneEntity copy, SceneEntity into)
        {
            for (var i = 0; i < copy.Components.Count; i++)
            {
                var inside = Split(copy.Components[i].Fields, Map, out var outside);
                copy.Components[i] = copy.Components[i] with { Fields = inside };
                if (outside.Count > 0)
                {
                    into.Components.Add(new SceneComponent(copy.Components[i].Id, copy.Components[i].Name, outside));
                }
            }
            for (var i = 0; i < copy.Behaviours.Count; i++)
            {
                var inside = Split(copy.Behaviours[i].Fields, Map, out var outside);
                copy.Behaviours[i] = copy.Behaviours[i] with { Fields = inside };
                if (outside.Count > 0)
                {
                    into.Behaviours.Add(new SceneBehaviour(copy.Behaviours[i].Script, outside));
                }
            }
        }
        Keep(top, instanceBlock);
        scene.Entities.Add(top);
        foreach (var o in overrides.Where(o => o.Path != null))
        {
            var copy = CopyBlock(o, InVariant(o.Path!));
            if (copy.Keys.HasFlag(SceneKeys.Parent) && Map(SceneValue.EntityRef(o.ParentPath ?? [o.Parent])) is { } parent)
            {
                copy.Parent = parent.Entity;
                copy.ParentPath = parent.Path;
            }
            var keep = new SceneEntity([instance, .. copy.Path!]);
            Keep(copy, keep);
            if (keep.Components.Count + keep.Behaviours.Count > 0)
            {
                kept.Add(keep);
            }
            scene.Entities.Add(copy);
        }
        foreach (var b in added)
        {
            var copy = b.Clone();
            if (copy.Path == null && Map(SceneValue.EntityRef(copy.ParentPath ?? [copy.Parent])) is { } parent)
            {
                copy.Parent = parent.Entity;
                copy.ParentPath = parent.Path;
            }
            MapFields(copy, Map);
            scene.Entities.Add(copy);
        }
        var variant = new PrefabDocument(path, guid, scene, null);
        var skip = overrides.Concat(added).Select(b => b.Id).ToHashSet();
        // The scene names the original's entities through the variant's root now, and the added ones in the variant.
        var rest = Reroute(document, instance, moved, skip, p => [instance, .. p]);
        foreach (var e in document.Scene.Entities.Where(e => !skip.Contains(e.Id)))
        {
            var copy = rest.Find(r => r.Id == e.Id) ?? e.Clone();
            if (RewritePaths(copy, p => p.Count >= 2 && p[0] == instance && !moved.Contains(p[1]) && p[1] != root ? [instance, root, .. p.Skip(1)] : p) && !rest.Contains(copy))
            {
                rest.Add(copy);
            }
        }
        return ([
            new PrefabSetOperation(document.Prefabs, guid, variant),
            new BlockOperation(document, instance, [.. skip, .. rest.Select(r => r.Id)], [instanceBlock, .. kept, .. rest]),
        ], variant);
    }
}
