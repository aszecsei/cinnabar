using Wire = Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Document;

/// <summary>
/// Replaces blocks of the scene, as the file has them: it takes out the blocks with the IDs in
/// <paramref name="Remove"/> and puts <paramref name="Add"/> in their place. Every edit of an instance is one: an
/// override, an instance created or removed, an unpack. Its wire form is the difference that it makes to the
/// document's expansion, which it finds when it applies, so the host gets plain entities. Steps with the same
/// <paramref name="Key"/> on the same entity replace each other, as a drag's do.
/// </summary>
public sealed record BlockOperation(SceneDocument Document, ulong Id, IReadOnlyList<ulong> Remove, IReadOnlyList<SceneEntity> Add, string Key = "") : Operation(Id)
{
    IReadOnlyList<Wire.Operation> _wires = [];

    public override Operation Apply(Scene scene)
    {
        var before = Document.Expanded.Flat.Entities.ToList();
        var at = scene.Entities.Count;
        var removed = new List<SceneEntity>();
        foreach (var id in Remove)
        {
            if (scene.Find(id) is { } block)
            {
                at = Math.Min(at, scene.Entities.IndexOf(block));
                scene.Entities.Remove(block);
                removed.Add(block);
            }
        }
        foreach (var block in Add)
        {
            if (scene.Find(block.Id) != null)
            {
                scene.Entities.InsertRange(Math.Min(at, scene.Entities.Count), removed);
                throw new InvalidOperationException($"the scene already has an entity {block.Id:x16}");
            }
        }
        scene.Entities.InsertRange(Math.Min(at, scene.Entities.Count), Add.Select(b => b.Clone()));
        Document.Invalidate();
        _wires = PrefabExpansion.Diff(before, Document.Expanded.Flat.Entities);
        return new BlockOperation(Document, Id, [.. Add.Select(b => b.Id)], removed, Key);
    }

    public override Wire.Operation? ToWire() => null;

    public override IReadOnlyList<Wire.Operation> ToWires() => _wires;

    public override bool IsReplacedBy(Operation later) => Key != "" && later is BlockOperation b && b.Id == Id && b.Key == Key;
}

/// <summary>
/// Edits of a scene with instances (see docs/editor/prefabs.md#editing-an-instance): what an operation on an
/// instance's entity writes in its block, and the edits that take the expansion to make: destroying a tree, duplicating,
/// creating an instance, unpacking one, and making a prefab.
/// </summary>
public static partial class PrefabEdits
{
    /// <summary>
    /// The operation that the document applies for one on a flat entity. On a plain entity it is the same, with any
    /// reference to an instance's entity written as its path. On an instance's entity it is a <see cref="BlockOperation"/>
    /// on the entity's block: its instance block for the root, and its override block, made if it has none, for
    /// any other, with only what differs from the prefab.
    /// </summary>
    public static Operation Route(SceneDocument document, Operation op)
    {
        if (op is BlockOperation or PrefabSetOperation or PrefabOperation || op.Entity == 0)
        {
            return op;
        }
        var expansion = document.Expanded;
        if (expansion.InstanceOf(op.Entity) is not { } info)
        {
            return Plain(document, op);
        }
        if (op is DestroyEntity && info.IsInstanceRoot)
        {
            return RemoveInstance(document, op.Entity);
        }
        var existing = document.Scene.Find(op.Entity);
        var block = existing?.Clone() ?? new SceneEntity(info.Path);
        var flat = expansion.Flat.Find(op.Entity) ?? throw new InvalidOperationException($"the scene has no entity {op.Entity:x16}");
        var prefab = Base(document, op.Entity, info);
        var key = "";
        switch (op)
        {
            case SetField f:
                SetIn(block.Components, f.Component, flat.Components.Find(c => c.Id == f.Component)?.Name ?? "", f.Field, Pathed(document, f.Value),
                    prefab?.Components.Any(c => c.Id == f.Component) == true);
                key = $"field {f.Component} {f.Field}";
                break;
            case AddComponent a:
                block.RemovedComponents.Remove(a.Component.Id);
                block.Components.RemoveAll(c => c.Id == a.Component.Id);
                var component = a.Component with { Fields = Differing(prefab?.Components.Find(c => c.Id == a.Component.Id)?.Fields, a.Component.Fields, document) };
                if (component.Fields.Count > 0 || prefab?.Components.Any(c => c.Id == a.Component.Id) != true)
                {
                    var at = block.Components.FindIndex(c => c.Id > component.Id);
                    block.Components.Insert(at < 0 ? block.Components.Count : at, component);
                }
                key = $"component {a.Component.Id}";
                break;
            case RemoveComponent r:
                block.Components.RemoveAll(c => c.Id == r.Component);
                if (prefab?.Components.Any(c => c.Id == r.Component) == true && !block.RemovedComponents.Contains(r.Component))
                {
                    block.RemovedComponents.Add(r.Component);
                }
                break;
            case SetBehaviourField f:
                var behaviour = block.Behaviours.Find(b => b.Script == f.Script);
                if (behaviour == null)
                {
                    behaviour = new SceneBehaviour(f.Script, []);
                    block.Behaviours.Add(behaviour);
                }
                SceneEdits.Put(behaviour.Fields, f.Field, Pathed(document, f.Value));
                if (behaviour.Fields.Count == 0 && prefab?.Behaviours.Any(b => b.Script == f.Script) == true)
                {
                    block.Behaviours.Remove(behaviour);
                }
                key = $"behaviour {f.Script} {f.Field}";
                break;
            case AddBehaviour a:
                block.RemovedBehaviours.Remove(a.Behaviour.Script);
                block.Behaviours.RemoveAll(b => b.Script == a.Behaviour.Script);
                var fields = Differing(prefab?.Behaviours.Find(b => b.Script == a.Behaviour.Script)?.Fields, a.Behaviour.Fields, document);
                if (fields.Count > 0 || prefab?.Behaviours.Any(b => b.Script == a.Behaviour.Script) != true)
                {
                    block.Behaviours.Add(new SceneBehaviour(a.Behaviour.Script, fields));
                }
                break;
            case RemoveBehaviour r:
                block.Behaviours.RemoveAll(b => b.Script == r.Script);
                if (prefab?.Behaviours.Any(b => b.Script == r.Script) == true && !block.RemovedBehaviours.Contains(r.Script))
                {
                    block.RemovedBehaviours.Add(r.Script);
                }
                break;
            case Rename r:
                block.Name = r.Name;
                block.Keys = prefab != null && prefab.Name == r.Name ? block.Keys & ~SceneKeys.Name : block.Keys | SceneKeys.Name;
                key = "name";
                break;
            case SetActive s:
                block.Active = s.Active;
                block.Keys = prefab != null && prefab.Active == s.Active ? block.Keys & ~SceneKeys.Active : block.Keys | SceneKeys.Active;
                break;
            case SetParent p:
                CheckParent(expansion, op.Entity, p.Parent);
                if (!info.IsInstanceRoot && expansion.InstanceOf(p.Parent)?.Instance != info.Instance)
                {
                    throw new InvalidOperationException($"{Label(flat)} is the prefab's, so it stays inside its instance. Unpack the instance to move it out.");
                }
                block.Parent = p.Parent;
                block.ParentPath = PathOf(expansion, p.Parent);
                if (!info.IsInstanceRoot)
                {
                    block.Keys = prefab != null && prefab.Parent == p.Parent ? block.Keys & ~SceneKeys.Parent : block.Keys | SceneKeys.Parent;
                }
                break;
            case DestroyEntity:
                block.Removed = true;
                break;
            default:
                throw new InvalidOperationException($"{op.GetType().Name} cannot edit {Label(flat)}, which is inside an instance");
        }
        IReadOnlyList<SceneEntity> add = IsEmptyOverride(block) ? [] : [block];
        return new BlockOperation(document, op.Entity, existing != null ? [op.Entity] : [], add, key);
    }

    // An operation on a plain entity, with its references to an instance's entities as paths, refused where it would
    // take an entity into an instance that it is not an added entity of.
    static Operation Plain(SceneDocument document, Operation op)
    {
        var expansion = document.Expanded;
        switch (op)
        {
            case SetField f:
                return f with { Value = Pathed(document, f.Value) };
            case SetBehaviourField f:
                return f with { Value = Pathed(document, f.Value) };
            case AddComponent a:
                return a with { Component = a.Component with { Fields = [.. a.Component.Fields.Select(x => x with { Value = Pathed(document, x.Value)! })] } };
            case AddBehaviour a:
                return a with { Behaviour = a.Behaviour with { Fields = [.. a.Behaviour.Fields.Select(x => x with { Value = Pathed(document, x.Value)! })] } };
            case CreateEntity c:
                var created = c.Created.Clone();
                created.ParentPath = PathOf(expansion, created.Parent);
                foreach (var list in created.Components.Select(x => x.Fields).Concat(created.Behaviours.Select(x => x.Fields)))
                {
                    for (var i = 0; i < list.Count; i++)
                    {
                        list[i] = list[i] with { Value = Pathed(document, list[i].Value)! };
                    }
                }
                return new CreateEntity(created);
            case SetParent p:
                CheckParent(expansion, p.Id, p.Parent);
                var into = expansion.InstanceOf(p.Parent)?.Instance;
                var now = InstanceAbove(expansion, p.Id);
                if (into != null && into != now)
                {
                    throw new InvalidOperationException("an entity outside an instance cannot move into it. Add a new entity to the instance instead.");
                }
                return p with { ParentPath = PathOf(expansion, p.Parent) };
        }
        return op;
    }

    // The outermost instance that an entity is an added entity of, through its parents, or null.
    static ulong? InstanceAbove(Expansion expansion, ulong id)
    {
        var e = expansion.Flat.Find(id);
        for (var depth = 0; e != null && e.Parent != 0 && depth < 64; depth++)
        {
            if (expansion.InstanceOf(e.Parent) is { } info)
            {
                return info.Instance;
            }
            e = expansion.Flat.Find(e.Parent);
        }
        return null;
    }

    static void CheckParent(Expansion expansion, ulong id, ulong parent)
    {
        for (var (p, depth) = (parent, 0); p != 0 && depth < 256; depth++)
        {
            if (p == id)
            {
                throw new InvalidOperationException("an entity cannot be its own ancestor");
            }
            p = expansion.Flat.Find(p)?.Parent ?? 0;
        }
    }

    static IReadOnlyList<ulong>? PathOf(Expansion expansion, ulong id) =>
        expansion.InstanceOf(id) is { Path.Count: > 1 } info ? info.Path : null;

    // A reference to an instance's entity written as its path, so the file keeps it as the prefab changes.
    static SceneValue? Pathed(SceneDocument document, SceneValue? value) =>
        value is { Kind: SceneValueKind.Entity, Path: null } && PathOf(document.Expanded, value.Entity) is { } path ? SceneValue.EntityRef(path) : value;

    // Sets a component's field in a block, making the component if the block lacks it. A field set back to none
    // leaves a component of the prefab that has no other override out of the block, since it no longer differs.
    static void SetIn(List<SceneComponent> components, ulong id, string name, string field, SceneValue? value, bool prefabHas)
    {
        var component = components.Find(c => c.Id == id);
        if (component == null)
        {
            if (value == null)
            {
                return;
            }
            component = new SceneComponent(id, name, []);
            var at = components.FindIndex(c => c.Id > id);
            components.Insert(at < 0 ? components.Count : at, component);
        }
        SceneEdits.Put(component.Fields, field, value);
        if (component.Fields.Count == 0 && prefabHas)
        {
            components.Remove(component);
        }
    }

    // The fields that differ from the prefab's, which an override writes.
    static List<SceneField> Differing(List<SceneField>? prefab, List<SceneField> fields, SceneDocument document) =>
        [.. fields.Where(f => prefab?.Find(p => p.Name == f.Name)?.Value != f.Value).Select(f => f with { Value = Pathed(document, f.Value)! })];

    static bool IsEmptyOverride(SceneEntity block) =>
        block.Path != null && block.Keys == SceneKeys.None && !block.Removed && block.Components.Count == 0 && block.Behaviours.Count == 0
        && block.RemovedComponents.Count == 0 && block.RemovedBehaviours.Count == 0 && block.UnknownKeys.Count == 0;

    /// <summary>
    /// The entity as its prefab gives it, without what its own block overrides: what Reset returns a field to. For
    /// an instance's root, that is the prefab's root without a pose, since the pose is the scene's. Null when the
    /// entity is not inside an instance.
    /// </summary>
    public static SceneEntity? Base(SceneDocument document, ulong id, InstanceEntity? info = null)
    {
        info ??= document.Expanded.InstanceOf(id);
        if (info == null)
        {
            return null;
        }
        var scene = new Scene();
        foreach (var e in document.Scene.Entities)
        {
            if (e.Id != id)
            {
                scene.Entities.Add(e);
            }
            else if (info.IsInstanceRoot)
            {
                scene.Entities.Add(new SceneEntity(e.Id) { Prefab = e.Prefab, Parent = e.Parent });
            }
        }
        return PrefabExpansion.Expand(scene, document.Prefabs.SceneOf).Flat.Find(id);
    }

    /// <summary>The instance's blocks: its instance block and every override block on a path from it.</summary>
    public static List<SceneEntity> BlocksOf(Scene scene, ulong instance) =>
        [.. scene.Entities.Where(e => e.Id == instance || e.Path?[0] == instance)];

    /// <summary>Takes an instance out of the scene, its instance block with its override blocks.</summary>
    public static BlockOperation RemoveInstance(SceneDocument document, ulong instance) =>
        new(document, instance, [.. BlocksOf(document.Scene, instance).Select(b => b.Id)], []);

    /// <summary>
    /// Destroys an entity with its descendants, as one undo entry's operations. The scene's own entities go one by one,
    /// the deepest first; an instance's root takes its instance and its blocks with it; and a prefab's entity is
    /// removed with <c>removed = true</c>, which takes its descendants in the prefab with it.
    /// </summary>
    public static Operation[] DestroyTree(SceneDocument document, ulong id)
    {
        var expansion = document.Expanded;
        var ops = new List<Operation>();
        foreach (var e in Enumerable.Reverse(SceneEdits.Descendants(expansion.Flat, id)).Append(expansion.Flat.Find(id)).OfType<SceneEntity>())
        {
            switch (expansion.InstanceOf(e.Id))
            {
                case null:
                    ops.Add(new DestroyEntity(e.Id));
                    break;
                case { IsInstanceRoot: true }:
                    ops.Add(RemoveInstance(document, e.Id));
                    break;
                case not null when e.Id == id:
                    ops.Add(new DestroyEntity(e.Id));
                    break;
            }
        }
        return [.. ops];
    }

    /// <summary>
    /// A new instance of a prefab under a parent, or at the root with 0, with its root's pose: a Transform at the root,
    /// or a Local_Transform under a parent.
    /// </summary>
    public static BlockOperation CreateInstance(SceneDocument document, string prefab, ulong parent, SceneComponent pose, ulong id = 0)
    {
        while (id == 0 || document.Scene.Find(id) != null || document.Expanded.Flat.Find(id) != null)
        {
            id = SceneEntity.NewId();
        }
        var block = new SceneEntity(id) { Prefab = prefab, Parent = parent, ParentPath = PathOf(document.Expanded, parent) };
        block.Components.Add(pose);
        return new BlockOperation(document, id, [], [block]);
    }

    /// <summary>
    /// Copies an entity and its descendants with new scene IDs, under the same parent, as one undo entry's operations,
    /// and the copy's ID. An instance's root copies as a new instance with its override blocks on the new instance's
    /// paths; a prefab's entity under another, which the copy cannot instantiate, copies as plain entities, as the
    /// expansion gives them. A reference inside the copied entities to one of them refers to its copy.
    /// </summary>
    public static (Operation[] Operations, ulong Copy) Duplicate(SceneDocument document, ulong id)
    {
        var expansion = document.Expanded;
        var top = expansion.Flat.Find(id) ?? throw new InvalidOperationException($"the scene has no entity {id:x16}");
        var originals = new List<SceneEntity> { top };
        originals.AddRange(SceneEdits.Descendants(expansion.Flat, id));
        var taken = new HashSet<ulong>(expansion.Flat.Entities.Select(e => e.Id));
        ulong Fresh()
        {
            ulong fresh;
            do
            {
                fresh = SceneEntity.NewId();
            } while (!taken.Add(fresh));
            return fresh;
        }
        // An instance copies whole when its root is among the copied entities and the copy can name the prefab: an
        // outermost instance, whose root is the instance block.
        var instances = new Dictionary<ulong, ulong>();
        foreach (var e in originals.Where(e => expansion.InstanceOf(e.Id) is { IsInstanceRoot: true }))
        {
            instances[e.Id] = Fresh();
        }
        var ids = new Dictionary<ulong, ulong>();
        var paths = new Dictionary<ulong, IReadOnlyList<ulong>>();
        foreach (var e in originals)
        {
            if (expansion.InstanceOf(e.Id) is { } info && instances.TryGetValue(info.Instance, out var to))
            {
                IReadOnlyList<ulong> path = [to, .. info.Path.Skip(1)];
                ids[e.Id] = ScenePath.Id(path);
                paths[ids[e.Id]] = path;
            }
            else
            {
                ids[e.Id] = Fresh();
            }
        }
        SceneValue Remap(SceneValue v) => v.Kind == SceneValueKind.Entity && ids.TryGetValue(v.Entity, out var to)
            ? (paths.TryGetValue(to, out var path) && path.Count > 1 ? SceneValue.EntityRef(path) : SceneValue.EntityRef(to))
            : v;
        void RemapFields(SceneEntity e)
        {
            for (var i = 0; i < e.Components.Count; i++)
            {
                e.Components[i] = e.Components[i] with { Fields = [.. e.Components[i].Fields.Select(f => f with { Value = Remap(f.Value) })] };
            }
            for (var i = 0; i < e.Behaviours.Count; i++)
            {
                e.Behaviours[i] = e.Behaviours[i] with { Fields = [.. e.Behaviours[i].Fields.Select(f => f with { Value = Remap(f.Value) })] };
            }
        }
        var ops = new List<Operation>();
        foreach (var e in originals)
        {
            var info = expansion.InstanceOf(e.Id);
            if (info is { IsInstanceRoot: true })
            {
                var to = instances[e.Id];
                var blocks = BlocksOf(document.Scene, e.Id).Select(b =>
                {
                    var copy = b.Path == null ? b.Copy(to) : CopyBlock(b, [to, .. b.Path.Skip(1)]);
                    if (b.Path == null)
                    {
                        copy.Parent = ids.GetValueOrDefault(b.Parent, b.Parent);
                        copy.ParentPath = paths.GetValueOrDefault(copy.Parent) is { Count: > 1 } p ? p : b.Parent == copy.Parent ? b.ParentPath : null;
                    }
                    else if (copy.Keys.HasFlag(SceneKeys.Parent))
                    {
                        copy.Parent = ids.GetValueOrDefault(b.Parent, b.Parent);
                        copy.ParentPath = paths.GetValueOrDefault(copy.Parent);
                    }
                    RemapFields(copy);
                    return copy;
                }).ToList();
                ops.Add(new BlockOperation(document, to, [], blocks));
            }
            else if (info != null && instances.ContainsKey(info.Instance))
            {
                // It comes with its instance's copy.
            }
            else
            {
                var copy = e.Copy(ids[e.Id]);
                copy.Parent = ids.GetValueOrDefault(e.Parent, e.Parent);
                copy.ParentPath = paths.GetValueOrDefault(copy.Parent) is { Count: > 1 } p ? p : PathOf(expansion, copy.Parent);
                RemapFields(copy);
                ops.Add(new CreateEntity(copy));
            }
        }
        return ([.. ops], ids[id]);
    }

    // An override block on another path, with the same overrides.
    static SceneEntity CopyBlock(SceneEntity b, IReadOnlyList<ulong> path)
    {
        var copy = new SceneEntity(path) { Name = b.Name, Parent = b.Parent, ParentPath = b.ParentPath, Active = b.Active, Keys = b.Keys, Removed = b.Removed };
        copy.Components.AddRange(b.Components.Select(c => c.Copy()));
        copy.Behaviours.AddRange(b.Behaviours.Select(x => x.Copy()));
        copy.UnknownKeys.AddRange(b.UnknownKeys);
        copy.RemovedComponents.AddRange(b.RemovedComponents);
        copy.RemovedBehaviours.AddRange(b.RemovedBehaviours);
        return copy;
    }

    /// <summary>
    /// Makes an instance's entities plain entities of the scene, with their current values, through every nesting:
    /// Unpack Completely. Their scene IDs are their paths' IDs, so the host's world does not change.
    /// </summary>
    public static Operation[] UnpackCompletely(SceneDocument document, ulong instance)
    {
        var expansion = document.Expanded;
        if (expansion.InstanceOf(instance) is not { IsInstanceRoot: true })
        {
            throw new InvalidOperationException($"{instance:x16} is not an instance's root");
        }
        var entities = expansion.Flat.Entities.Where(e => expansion.InstanceOf(e.Id)?.Instance == instance).Select(e =>
        {
            var copy = e.Clone();
            copy.ParentPath = PathOf(expansion, copy.Parent) is { } p && p[0] != instance ? p : null;
            return copy;
        }).ToList();
        var flatIds = entities.Select(e => e.Id).ToHashSet();
        return [new BlockOperation(document, instance, [.. BlocksOf(document.Scene, instance).Select(b => b.Id)], entities), .. Unpathed(document, flatIds)];
    }

    /// <summary>
    /// Makes an instance's own level plain entities of the scene: its prefab's entities with the scene's overrides, while
    /// the instances inside the prefab stay instances, with their overrides on paths from them. The nested instances'
    /// entities have new paths, so their scene IDs change, and the host gets the difference.
    /// </summary>
    public static Operation[] Unpack(SceneDocument document, ulong instance)
    {
        var block = document.Scene.Find(instance);
        if (block is not { Prefab: not "" } || document.Prefabs.SceneOf(block.Prefab) is not { } prefab || PrefabExpansion.RootOf(prefab) is not ({ } root, 1))
        {
            return UnpackCompletely(document, instance);
        }
        // A path inside the instance, from the scene's side: <instance>#<a> is the plain entity or the inner instance
        // a's new ID, and <instance>#<a>#<rest> is <a's new ID>#<rest>, a path from the inner instance.
        ulong Remap(ulong id) => id == root.Id ? instance : ScenePath.Id(instance, id);
        IReadOnlyList<ulong> Outer(IReadOnlyList<ulong> path) =>
            path.Count >= 2 && path[0] == instance ? [ScenePath.Id(instance, path[1]), .. path.Skip(2)] : path;
        // A path in the prefab, rooted at the instance.
        IReadOnlyList<ulong> Inner(IReadOnlyList<ulong> path) => [Remap(path[0]), .. path.Skip(1)];
        var known = prefab.Entities.Select(e => e.Id).ToHashSet();
        SceneValue InnerValue(SceneValue v) => v.Kind != SceneValueKind.Entity || v.Entity == 0 ? v
            : !known.Contains(v.Entity) ? SceneValue.EntityRef(0)
            : SceneValue.EntityRef(Inner(v.Path ?? [v.Entity]));
        void SetParent(SceneEntity e, IReadOnlyList<ulong>? path)
        {
            e.Parent = path == null ? 0 : ScenePath.Id(path);
            e.ParentPath = path is { Count: > 1 } ? path : null;
        }
        // The prefab's blocks on the scene's side, by the ID that the scene's overrides of them have.
        var blocks = new List<SceneEntity>();
        var byOuterId = new Dictionary<ulong, SceneEntity>();
        foreach (var e in prefab.Entities)
        {
            SceneEntity copy;
            if (e.Path == null)
            {
                copy = e.Copy(Remap(e.Id));
                if (e.Id == root.Id)
                {
                    copy.Components.RemoveAll(c => c.Id is SceneEdits.TransformId or SceneEdits.LocalTransformId);
                    copy.Parent = block.Parent;
                    copy.ParentPath = block.ParentPath;
                }
                else
                {
                    SetParent(copy, e.Parent == 0 ? null : Inner(e.ParentPath ?? [e.Parent]));
                }
                byOuterId[e.Id == root.Id ? instance : ScenePath.Id(instance, e.Id)] = copy;
            }
            else
            {
                copy = CopyBlock(e, Inner(e.Path));
                if (copy.Keys.HasFlag(SceneKeys.Parent))
                {
                    SetParent(copy, e.Parent == 0 ? null : Inner(e.ParentPath ?? [e.Parent]));
                }
                byOuterId[ScenePath.Id([instance, .. e.Path])] = copy;
            }
            foreach (var list in copy.Components.Select(c => c.Fields).Concat(copy.Behaviours.Select(b => b.Fields)))
            {
                for (var i = 0; i < list.Count; i++)
                {
                    list[i] = list[i] with { Value = InnerValue(list[i].Value) };
                }
            }
            blocks.Add(copy);
        }
        // The scene's overrides go over the block of the entity they name, or onto a path from an inner instance.
        foreach (var o in BlocksOf(document.Scene, instance))
        {
            if (o.Path == null)
            {
                // The instance block: the root's overrides and its pose.
                var r = byOuterId[instance];
                PrefabExpansion.ApplyOverride(r, o);
                continue;
            }
            if (byOuterId.TryGetValue(o.Id, out var target))
            {
                if (target.Path != null || target.Prefab != "")
                {
                    MergeBlock(target, o);
                }
                else
                {
                    PrefabExpansion.ApplyOverride(target, o);
                    if (o.Keys.HasFlag(SceneKeys.Parent))
                    {
                        SetParent(target, o.Parent == 0 ? null : Outer(o.ParentPath ?? [o.Parent]));
                    }
                    target.Removed = o.Removed;
                }
            }
            else if (o.Path.Count > 2)
            {
                blocks.Add(CopyBlock(o, Outer(o.Path)));
            }
            // An override of an entity that the prefab no longer has did nothing, and goes.
        }
        blocks = DropRemovedBlocks(blocks);
        foreach (var b in blocks)
        {
            RewritePaths(b, Outer);
        }
        var ops = new List<Operation> { new BlockOperation(document, instance, [.. BlocksOf(document.Scene, instance).Select(b => b.Id)], blocks) };
        // The rest of the scene names the inner instances' entities by paths from them.
        var changed = new List<SceneEntity>();
        foreach (var e in document.Scene.Entities.Where(e => e.Id != instance && e.Path?[0] != instance))
        {
            var copy = e.Clone();
            if (RewritePaths(copy, Outer))
            {
                changed.Add(copy);
            }
        }
        if (changed.Count > 0)
        {
            ops.Add(new BlockOperation(document, 0, [.. changed.Select(c => c.Id)], changed));
        }
        return [.. ops];
    }

    // The blocks without the plain entities and instances that are removed, the blocks under them, and the overrides
    // of instances that are gone.
    static List<SceneEntity> DropRemovedBlocks(List<SceneEntity> blocks)
    {
        var byId = blocks.Where(b => b.Path == null).ToDictionary(b => b.Id);
        bool Gone(SceneEntity b, int depth)
        {
            if (depth > 64)
            {
                return false;
            }
            if (b.Path != null)
            {
                return !byId.TryGetValue(b.Path[0], out var owner) || Gone(owner, depth + 1);
            }
            if (b.Removed)
            {
                return true;
            }
            var anchor = b.ParentPath?[0] ?? b.Parent;
            return anchor != 0 && byId.TryGetValue(anchor, out var parent) && Gone(parent, depth + 1);
        }
        var kept = blocks.Where(b => !Gone(b, 0)).ToList();
        foreach (var b in kept.Where(b => b.Path == null))
        {
            b.Removed = false;
        }
        return kept;
    }

    // An override over another of the same entity: its keys, components and behaviours over the block's.
    static void MergeBlock(SceneEntity block, SceneEntity over)
    {
        var removed = over.RemovedComponents.Where(id => !block.RemovedComponents.Contains(id)).ToList();
        PrefabExpansion.ApplyOverride(block, over);
        block.RemovedComponents.AddRange(removed);
        block.RemovedBehaviours.AddRange(over.RemovedBehaviours.Where(s => !block.RemovedBehaviours.Contains(s)));
        block.Keys |= over.Keys;
        if (over.Keys.HasFlag(SceneKeys.Parent))
        {
            block.Parent = over.Parent;
            block.ParentPath = over.ParentPath;
        }
        block.Removed |= over.Removed;
    }

    // Rewrites the paths that an entity's parent and references are written as. True if any changed.
    static bool RewritePaths(SceneEntity e, Func<IReadOnlyList<ulong>, IReadOnlyList<ulong>> rewrite)
    {
        var changed = false;
        if (e.ParentPath is { } pp && rewrite(pp) is var np && !np.SequenceEqual(pp))
        {
            e.ParentPath = np.Count > 1 ? np : null;
            e.Parent = ScenePath.Id(np);
            changed = true;
        }
        foreach (var list in e.Components.Select(c => c.Fields).Concat(e.Behaviours.Select(b => b.Fields)))
        {
            for (var i = 0; i < list.Count; i++)
            {
                if (list[i].Value.Path is { } path && rewrite(path) is var to && !to.SequenceEqual(path))
                {
                    list[i] = list[i] with { Value = SceneValue.EntityRef(to) };
                    changed = true;
                }
            }
        }
        return changed;
    }

    // The scene's references and parents that name entities by paths that are now plain IDs.
    static Operation[] Unpathed(SceneDocument document, HashSet<ulong> ids)
    {
        var changed = new List<SceneEntity>();
        foreach (var e in document.Scene.Entities)
        {
            var copy = e.Clone();
            if (Unpath(copy, ids))
            {
                changed.Add(copy);
            }
        }
        return changed.Count == 0 ? [] : [new BlockOperation(document, 0, [.. changed.Select(c => c.Id)], changed)];
    }

    static bool Unpath(SceneEntity e, HashSet<ulong> ids)
    {
        var changed = false;
        if (e.ParentPath != null && ids.Contains(e.Parent))
        {
            e.ParentPath = null;
            changed = true;
        }
        foreach (var list in e.Components.Select(c => c.Fields).Concat(e.Behaviours.Select(b => b.Fields)))
        {
            for (var i = 0; i < list.Count; i++)
            {
                if (list[i].Value is { Path: not null } v && ids.Contains(v.Entity))
                {
                    list[i] = list[i] with { Value = SceneValue.EntityRef(v.Entity) };
                    changed = true;
                }
            }
        }
        return changed;
    }

    /// <summary>
    /// Makes a prefab of a plain entity and its descendants, and replaces them in the scene with an instance of it, as
    /// one undo entry's operations: the prefab, a new document in the set with a fresh GUID, which its first save writes
    /// to <paramref name="path"/> with its <c>.meta</c> file, has the entities with their scene IDs and the root at the
    /// origin; the instance takes the root's ID and its pose; and every reference elsewhere in the scene to one of the
    /// entities becomes a path. The entities' scene IDs become their paths', so the host gets the difference.
    /// </summary>
    public static (Operation[] Operations, PrefabDocument Prefab) MakePrefab(SceneDocument document, ulong id, string path)
    {
        if (document.Expanded.InstanceOf(id) != null)
        {
            throw new InvalidOperationException("the entity is inside an instance. Unpack it first, or make a prefab of a plain entity.");
        }
        var root = document.Scene.Find(id) ?? throw new InvalidOperationException($"the scene has no entity {id:x16}");
        // The blocks of the tree: the plain entities under the root, and the instances among them with their overrides.
        var tree = new HashSet<ulong> { id };
        foreach (var d in SceneEdits.Descendants(document.Expanded.Flat, id))
        {
            tree.Add(d.Id);
        }
        var blocks = document.Scene.Entities.Where(e => e.Path == null ? tree.Contains(e.Id) : tree.Contains(e.Path[0])).ToList();
        var guid = Convert.ToHexStringLower(Guid.NewGuid().ToByteArray());
        var prefab = new Scene();
        foreach (var b in blocks)
        {
            var copy = b.Clone();
            if (b.Id == id)
            {
                copy.Parent = 0;
                copy.ParentPath = null;
                copy.Components.RemoveAll(c => c.Id is SceneEdits.LocalTransformId);
                copy.Components.RemoveAll(c => c.Id is SceneEdits.TransformId);
                copy.Components.Insert(0, new SceneComponent(SceneEdits.TransformId, "Transform", SceneEdits.TransformFields(Pose.Identity)));
            }
            // A prefab refers to nothing outside itself.
            foreach (var list in copy.Components.Select(c => c.Fields).Concat(copy.Behaviours.Select(x => x.Fields)))
            {
                for (var i = 0; i < list.Count; i++)
                {
                    if (list[i].Value is { Kind: SceneValueKind.Entity } v && v.Entity != 0 && !tree.Contains(v.Entity) && !blocks.Any(x => x.Id == v.Entity))
                    {
                        list[i] = list[i] with { Value = SceneValue.EntityRef(0) };
                    }
                }
            }
            prefab.Entities.Add(copy);
        }
        var document2 = new PrefabDocument(path, guid, prefab, null);
        var instance = new SceneEntity(id) { Prefab = guid, Parent = root.Parent, ParentPath = root.ParentPath };
        instance.Components.AddRange(root.Components.Where(c => c.Id is SceneEdits.TransformId or SceneEdits.LocalTransformId).Select(c => c.Copy()));
        // The rest of the scene names the tree's entities by their paths in the instance.
        IReadOnlyList<ulong> Rerooted(IReadOnlyList<ulong> p) =>
            p[0] == id ? p : tree.Contains(p[0]) ? [id, .. p] : p;
        var changed = new List<SceneEntity>();
        foreach (var e in document.Scene.Entities.Where(e => !blocks.Contains(e)))
        {
            var copy = e.Clone();
            var any = false;
            if (copy.Parent != 0 && copy.Parent != id && tree.Contains(copy.Parent) || copy.ParentPath is { } pp && tree.Contains(pp[0]) && pp[0] != id)
            {
                var np = Rerooted(copy.ParentPath ?? [copy.Parent]);
                copy.ParentPath = np;
                copy.Parent = ScenePath.Id(np);
                any = true;
            }
            foreach (var list in copy.Components.Select(c => c.Fields).Concat(copy.Behaviours.Select(x => x.Fields)))
            {
                for (var i = 0; i < list.Count; i++)
                {
                    if (list[i].Value is { Kind: SceneValueKind.Entity } v && v.Entity != id && (v.Path is { } vp ? tree.Contains(vp[0]) && vp[0] != id : tree.Contains(v.Entity)))
                    {
                        list[i] = list[i] with { Value = SceneValue.EntityRef(Rerooted(v.Path ?? [v.Entity])) };
                        any = true;
                    }
                }
            }
            if (any)
            {
                changed.Add(copy);
            }
        }
        return ([
            new PrefabSetOperation(document.Prefabs, guid, document2),
            new BlockOperation(document, id, [.. blocks.Select(b => b.Id), .. changed.Select(c => c.Id)], [instance, .. changed]),
        ], document2);
    }

    static string Label(SceneEntity e) => e.Name.Length > 0 ? e.Name : $"{e.Id:x16}";
}
