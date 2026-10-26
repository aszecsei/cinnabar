using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Model;

/// <summary>An entity as the editor sees it. The game owns the entity; this is a mirror, updated from the link.</summary>
public sealed class EntityNode
{
    public EntityNode(ulong handle) => Handle = handle;

    public ulong Handle { get; }
    /// <summary>The Name component's text, or "".</summary>
    public string Name { get; internal set; } = "";
    /// <summary>The scene ID of an entity that the scene made, or 0 for one that the game spawned.</summary>
    public ulong SceneId { get; internal set; }
    public ulong Parent { get; internal set; }
    public bool Active { get; internal set; }

    /// <summary>The component IDs, sorted.</summary>
    public IReadOnlyList<ulong> Components { get; internal set; } = [];

    internal List<EntityNode> ChildList { get; } = [];

    /// <summary>The children, in handle order.</summary>
    public IReadOnlyList<EntityNode> Children => ChildList;

    public uint Index => (uint)Handle;
    public uint Generation => (uint)(Handle >> 32);

    /// <summary>As the engine prints an entity: <c>Entity(3:1)</c> is index 3, generation 1.</summary>
    public static string Format(ulong handle) => handle == 0 ? "none" : $"Entity({(uint)handle}:{(uint)(handle >> 32)})";

    /// <summary>The name, or the handle as the engine prints it for an entity without one.</summary>
    public string Label => Name.Length > 0 ? Name : Format(Handle);

    public override string ToString() => Format(Handle);
}

/// <summary>
/// The editor's mirror of the game's world (see docs/editor/link.md#world): the component types, every entity with its
/// hierarchy, and the values of the watched entities. It changes only through <see cref="Apply"/>, with the game's
/// messages, and <see cref="Clear"/>. Use it on one thread.
/// </summary>
public sealed class WorldModel
{
    readonly Dictionary<ulong, ComponentType> _types = [];
    readonly Dictionary<ulong, EntityNode> _entities = [];
    readonly Dictionary<ulong, EntityNode> _bySceneId = [];
    readonly List<EntityNode> _roots = [];
    readonly Dictionary<ulong, EntityValues> _values = [];

    public IReadOnlyDictionary<ulong, ComponentType> Types => _types;

    public IReadOnlyCollection<EntityNode> Entities => _entities.Values;

    /// <summary>The entities without a parent, and those whose parent the editor does not know, in handle order.</summary>
    public IReadOnlyList<EntityNode> Roots => _roots;

    /// <summary>True after the first snapshot, until <see cref="Clear"/>.</summary>
    public bool HasWorld { get; private set; }

    public event Action? TypesChanged;

    /// <summary>The entities or the hierarchy changed. After a snapshot, everything did.</summary>
    public event Action? EntitiesChanged;

    /// <summary>A new snapshot replaced the world. The game knows no watches after it.</summary>
    public event Action? Reset;

    public event Action<ulong>? ValuesChanged;

    public EntityNode? Find(ulong handle) => _entities.GetValueOrDefault(handle);

    /// <summary>The entity that a scene made with this scene ID, or null.</summary>
    public EntityNode? FindScene(ulong sceneId) => sceneId == 0 ? null : _bySceneId.GetValueOrDefault(sceneId);

    public ComponentType? Type(ulong id) => _types.GetValueOrDefault(id);

    /// <summary>The newest values of a watched entity, or null before the first.</summary>
    public EntityValues? Values(ulong handle) => _values.GetValueOrDefault(handle);

    /// <summary>The component's name, or its ID in hex for a type that the game has not described.</summary>
    public string TypeName(ulong id) => _types.TryGetValue(id, out var t) ? t.Name : $"0x{id:x16}";

    /// <summary>Applies a game message, and returns false for a message that is not about the world.</summary>
    public bool Apply(ILinkMessage message)
    {
        switch (message)
        {
            case ComponentTypes types:
                _types.Clear();
                foreach (var t in types.Types)
                {
                    _types[t.Id] = t;
                }
                TypesChanged?.Invoke();
                return true;
            case EntitySnapshot snapshot:
                _entities.Clear();
                _values.Clear();
                foreach (var info in snapshot.Entities)
                {
                    Update(info);
                }
                HasWorld = true;
                RebuildHierarchy();
                Reset?.Invoke();
                EntitiesChanged?.Invoke();
                return true;
            case EntityDelta delta:
                foreach (var handle in delta.Destroyed)
                {
                    _entities.Remove(handle);
                    _values.Remove(handle);
                }
                foreach (var info in delta.Changed)
                {
                    Update(info);
                }
                RebuildHierarchy();
                EntitiesChanged?.Invoke();
                return true;
            case EntityValues values:
                if (_entities.ContainsKey(values.Entity))
                {
                    _values[values.Entity] = values;
                    ValuesChanged?.Invoke(values.Entity);
                }
                return true;
            default:
                return false;
        }
    }

    /// <summary>Forgets the world, as when the link closes.</summary>
    public void Clear()
    {
        _types.Clear();
        _entities.Clear();
        _roots.Clear();
        _bySceneId.Clear();
        _values.Clear();
        HasWorld = false;
        TypesChanged?.Invoke();
        Reset?.Invoke();
        EntitiesChanged?.Invoke();
    }

    void Update(EntityInfo info)
    {
        if (!_entities.TryGetValue(info.Entity, out var node))
        {
            node = new EntityNode(info.Entity);
            _entities[info.Entity] = node;
        }
        node.Name = info.Name;
        node.SceneId = info.SceneId;
        node.Parent = info.Parent;
        node.Active = info.Active;
        node.Components = info.Components;
    }

    // The hierarchy is rebuilt whole. Deltas come at most ten times a second, and sorting a few thousand entities is
    // far cheaper than keeping every move right incrementally.
    void RebuildHierarchy()
    {
        _roots.Clear();
        _bySceneId.Clear();
        foreach (var node in _entities.Values)
        {
            node.ChildList.Clear();
            if (node.SceneId != 0)
            {
                _bySceneId[node.SceneId] = node;
            }
        }
        foreach (var node in _entities.Values.OrderBy(n => n.Index).ThenBy(n => n.Generation))
        {
            if (node.Parent != 0 && _entities.TryGetValue(node.Parent, out var parent) && !IsAncestor(node, parent))
            {
                parent.ChildList.Add(node);
            }
            else
            {
                _roots.Add(node);
            }
        }
    }

    // A cycle never comes from the game, which refuses one, but a delta between two scans could show one for a moment.
    bool IsAncestor(EntityNode node, EntityNode of)
    {
        for (var n = of; n != null; n = n.Parent == 0 ? null : _entities.GetValueOrDefault(n.Parent))
        {
            if (n == node)
            {
                return true;
            }
        }
        return false;
    }
}
