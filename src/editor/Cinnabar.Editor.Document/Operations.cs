using Wire = Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Document;

/// <summary>
/// An edit of a scene (see docs/editor.md#document-model). <see cref="Apply"/> changes the document and returns the
/// operation that undoes it. The same operation goes to the host as <see cref="ToWire"/>. An operation that does not
/// fit the document, such as one for an entity that is not there, throws <see cref="InvalidOperationException"/> and
/// changes nothing.
/// </summary>
public abstract record Operation(ulong Entity)
{
    public abstract Operation Apply(Scene scene);

    public abstract Wire.Operation ToWire();

    /// <summary>
    /// True when <paramref name="later"/> replaces this operation, as each step of a drag replaces the step before:
    /// a transaction then keeps the later one, and this one's inverse.
    /// </summary>
    public virtual bool IsReplacedBy(Operation later) => false;

    /// <summary>The operation that a wire operation describes, as a game command returns them.</summary>
    public static Operation FromWire(Wire.Operation op)
    {
        string Script() => Convert.ToHexStringLower(op.Script);
        Link.Protocol.SceneField OnlyField() => op.Fields.Length == 1 ? op.Fields[0] : throw new InvalidOperationException($"{op.Kind} of {op.Entity:x16} has {op.Fields.Length} fields, not one");
        return op.Kind switch
        {
            Link.Protocol.OperationKind.CreateEntity when op.Created.Length == 1 => new CreateEntity(SceneSnapshot.FromWire(op.Created[0])),
            Link.Protocol.OperationKind.DestroyEntity => new DestroyEntity(op.Entity),
            Link.Protocol.OperationKind.Rename => new Rename(op.Entity, op.Name),
            Link.Protocol.OperationKind.SetParent => new SetParent(op.Entity, op.Parent),
            Link.Protocol.OperationKind.SetActive => new SetActive(op.Entity, op.Active),
            Link.Protocol.OperationKind.AddComponent when op.Components.Length == 1 => new AddComponent(op.Entity, SceneSnapshot.FromWire(op.Components[0])),
            Link.Protocol.OperationKind.RemoveComponent => new RemoveComponent(op.Entity, op.Component),
            Link.Protocol.OperationKind.SetField => new SetField(op.Entity, op.Component, OnlyField().Name, SceneSnapshot.FromWire(OnlyField().Value)),
            Link.Protocol.OperationKind.ResetField => new SetField(op.Entity, op.Component, OnlyField().Name, null),
            // The host attaches a new behaviour last, and so does the document.
            Link.Protocol.OperationKind.AddBehaviour => new AddBehaviour(op.Entity, new SceneBehaviour(Script(), [.. op.Fields.Select(SceneSnapshot.FromWire)]), int.MaxValue),
            Link.Protocol.OperationKind.RemoveBehaviour => new RemoveBehaviour(op.Entity, Script()),
            Link.Protocol.OperationKind.SetBehaviourField => new SetBehaviourField(op.Entity, Script(), OnlyField().Name, SceneSnapshot.FromWire(OnlyField().Value)),
            Link.Protocol.OperationKind.ResetBehaviourField => new SetBehaviourField(op.Entity, Script(), OnlyField().Name, null),
            _ => throw new InvalidOperationException($"{op.Kind} of {op.Entity:x16} does not have the parts it needs"),
        };
    }

    protected static SceneEntity Find(Scene scene, ulong id) =>
        scene.Find(id) ?? throw new InvalidOperationException($"the scene has no entity {id:x16}");

    protected static Wire.Operation Wire(Wire.OperationKind kind, ulong entity, Wire.SceneEntity[]? created = null, string name = "",
        ulong parent = 0, bool active = false, ulong component = 0, Wire.SceneComponent[]? components = null, string? script = null,
        Wire.SceneField[]? fields = null) =>
        new(kind, entity, created ?? [], name, parent, active, component, components ?? [],
            script == null ? new byte[16] : Convert.FromHexString(script), fields ?? []);
}

/// <summary>Adds an entity, with its components and behaviours. Its parent, if any, must be in the scene.</summary>
public sealed record CreateEntity(SceneEntity Created) : Operation(Created.Id)
{
    public override Operation Apply(Scene scene)
    {
        if (scene.Find(Created.Id) != null)
        {
            throw new InvalidOperationException($"the scene already has an entity {Created.Id:x16}");
        }
        scene.Entities.Add(Created.Clone());
        return new DestroyEntity(Created.Id);
    }

    public override Wire.Operation ToWire() => Wire(Link.Protocol.OperationKind.CreateEntity, Entity, created: [SceneSnapshot.Entity(Created)]);
}

/// <summary>
/// Removes one entity. The host destroys its descendants with it, so <see cref="SceneEdits.DestroyTree"/> destroys
/// them first, each with its own operation, so that undo brings them all back.
/// </summary>
public sealed record DestroyEntity(ulong Id) : Operation(Id)
{
    public override Operation Apply(Scene scene)
    {
        var entity = Find(scene, Id);
        scene.Entities.Remove(entity);
        return new CreateEntity(entity.Clone());
    }

    public override Wire.Operation ToWire() => Wire(Link.Protocol.OperationKind.DestroyEntity, Entity);
}

public sealed record Rename(ulong Id, string Name) : Operation(Id)
{
    public override Operation Apply(Scene scene)
    {
        var entity = Find(scene, Id);
        var old = entity.Name;
        entity.Name = Name;
        return this with { Name = old };
    }

    public override Wire.Operation ToWire() => Wire(Link.Protocol.OperationKind.Rename, Entity, name: Name);

    public override bool IsReplacedBy(Operation later) => later is Rename r && r.Id == Id;
}

/// <summary>Gives an entity a parent, or none with 0. It changes no transform: <see cref="SceneEdits.Reparent"/> does.</summary>
public sealed record SetParent(ulong Id, ulong Parent) : Operation(Id)
{
    public override Operation Apply(Scene scene)
    {
        var entity = Find(scene, Id);
        if (Parent != 0)
        {
            for (var p = Find(scene, Parent); ; p = Find(scene, p.Parent))
            {
                if (p.Id == Id)
                {
                    throw new InvalidOperationException("an entity cannot be its own ancestor");
                }
                if (p.Parent == 0)
                {
                    break;
                }
            }
        }
        var old = entity.Parent;
        entity.Parent = Parent;
        return this with { Parent = old };
    }

    public override Wire.Operation ToWire() => Wire(Link.Protocol.OperationKind.SetParent, Entity, parent: Parent);
}

public sealed record SetActive(ulong Id, bool Active) : Operation(Id)
{
    public override Operation Apply(Scene scene)
    {
        var entity = Find(scene, Id);
        var old = entity.Active;
        entity.Active = Active;
        return this with { Active = old };
    }

    public override Wire.Operation ToWire() => Wire(Link.Protocol.OperationKind.SetActive, Entity, active: Active);
}

/// <summary>Adds a component, or replaces the entity's component with the same ID.</summary>
public sealed record AddComponent(ulong Id, SceneComponent Component) : Operation(Id)
{
    public override Operation Apply(Scene scene)
    {
        var entity = Find(scene, Id);
        var at = entity.Components.FindIndex(c => c.Id == Component.Id);
        if (at >= 0)
        {
            var old = entity.Components[at];
            entity.Components[at] = Component.Copy();
            return this with { Component = old };
        }
        var before = entity.Components.FindIndex(c => c.Id > Component.Id);
        entity.Components.Insert(before < 0 ? entity.Components.Count : before, Component.Copy());
        return new RemoveComponent(Id, Component.Id);
    }

    public override Wire.Operation ToWire() =>
        Wire(Link.Protocol.OperationKind.AddComponent, Entity, components: [SceneSnapshot.Component(Component)]);
}

public sealed record RemoveComponent(ulong Id, ulong Component) : Operation(Id)
{
    public override Operation Apply(Scene scene)
    {
        var entity = Find(scene, Id);
        var at = entity.Components.FindIndex(c => c.Id == Component);
        if (at < 0)
        {
            throw new InvalidOperationException($"entity {Id:x16} has no component {Component}");
        }
        var old = entity.Components[at];
        entity.Components.RemoveAt(at);
        return new AddComponent(Id, old);
    }

    public override Wire.Operation ToWire() => Wire(Link.Protocol.OperationKind.RemoveComponent, Entity, component: Component);
}

/// <summary>Sets a component's field, or with a null value, removes it from the scene, so the field is zero.</summary>
public sealed record SetField(ulong Id, ulong Component, string Field, SceneValue? Value) : Operation(Id)
{
    public override Operation Apply(Scene scene)
    {
        var entity = Find(scene, Id);
        var component = entity.Components.Find(c => c.Id == Component)
            ?? throw new InvalidOperationException($"entity {Id:x16} has no component {Component} in the scene");
        return this with { Value = SceneEdits.Put(component.Fields, Field, Value) };
    }

    public override Wire.Operation ToWire() => Value == null
        ? Wire(Link.Protocol.OperationKind.ResetField, Entity, component: Component, fields: [new Wire.SceneField(Field, SceneSnapshot.Value(SceneValue.Of(false)))])
        : Wire(Link.Protocol.OperationKind.SetField, Entity, component: Component, fields: [new Wire.SceneField(Field, SceneSnapshot.Value(Value))]);

    public override bool IsReplacedBy(Operation later) =>
        later is SetField f && f.Id == Id && f.Component == Component && f.Field == Field;
}

/// <summary>Attaches a behaviour at a place in the entity's list. The host attaches it last; a resync puts it in place.</summary>
public sealed record AddBehaviour(ulong Id, SceneBehaviour Behaviour, int Index) : Operation(Id)
{
    public override Operation Apply(Scene scene)
    {
        var entity = Find(scene, Id);
        if (entity.Behaviours.Any(b => b.Script == Behaviour.Script))
        {
            throw new InvalidOperationException($"entity {Id:x16} already has the behaviour {Behaviour.Script}");
        }
        entity.Behaviours.Insert(Math.Clamp(Index, 0, entity.Behaviours.Count), Behaviour.Copy());
        return new RemoveBehaviour(Id, Behaviour.Script);
    }

    public override Wire.Operation ToWire() =>
        Wire(Link.Protocol.OperationKind.AddBehaviour, Entity, script: Behaviour.Script, fields: [.. Behaviour.Fields.Select(SceneSnapshot.Field)]);
}

public sealed record RemoveBehaviour(ulong Id, string Script) : Operation(Id)
{
    public override Operation Apply(Scene scene)
    {
        var entity = Find(scene, Id);
        var at = entity.Behaviours.FindIndex(b => b.Script == Script);
        if (at < 0)
        {
            throw new InvalidOperationException($"entity {Id:x16} has no behaviour {Script}");
        }
        var old = entity.Behaviours[at];
        entity.Behaviours.RemoveAt(at);
        return new AddBehaviour(Id, old, at);
    }

    public override Wire.Operation ToWire() => Wire(Link.Protocol.OperationKind.RemoveBehaviour, Entity, script: Script);
}

/// <summary>Sets a behaviour's field, or with a null value, removes it from the scene, so it has its class's default.</summary>
public sealed record SetBehaviourField(ulong Id, string Script, string Field, SceneValue? Value) : Operation(Id)
{
    public override Operation Apply(Scene scene)
    {
        var entity = Find(scene, Id);
        var behaviour = entity.Behaviours.Find(b => b.Script == Script)
            ?? throw new InvalidOperationException($"entity {Id:x16} has no behaviour {Script} in the scene");
        return this with { Value = SceneEdits.Put(behaviour.Fields, Field, Value) };
    }

    public override Wire.Operation ToWire() => Value == null
        ? Wire(Link.Protocol.OperationKind.ResetBehaviourField, Entity, script: Script, fields: [new Wire.SceneField(Field, SceneSnapshot.Value(SceneValue.Of(false)))])
        : Wire(Link.Protocol.OperationKind.SetBehaviourField, Entity, script: Script, fields: [new Wire.SceneField(Field, SceneSnapshot.Value(Value))]);

    public override bool IsReplacedBy(Operation later) =>
        later is SetBehaviourField f && f.Id == Id && f.Script == Script && f.Field == Field;
}
