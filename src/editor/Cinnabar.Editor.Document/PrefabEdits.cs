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

    static string Label(SceneEntity e) => e.Name.Length > 0 ? e.Name : $"{e.Id:x16}";
}
