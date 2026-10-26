namespace Cinnabar.Editor.Shell;

/// <summary>
/// The selected entities, by handle, in the order they were selected. The last is the primary one, which the gizmo
/// sits on and the properties panel names. The shell keeps their scene IDs, so a resync, which gives every entity a
/// new handle, keeps the selection (see docs/editor/document-and-scenes.md#document-model).
/// </summary>
public sealed class Selection
{
    List<ulong> _entities = [];

    public IReadOnlyList<ulong> Entities => _entities;

    /// <summary>The primary entity, or 0 for none.</summary>
    public ulong Entity => _entities.Count > 0 ? _entities[^1] : 0;

    public int Count => _entities.Count;

    public bool IsEmpty => _entities.Count == 0;

    /// <summary>The old and the new entities.</summary>
    public event Action<IReadOnlyList<ulong>, IReadOnlyList<ulong>>? Changed;

    public bool Contains(ulong entity) => _entities.Contains(entity);

    /// <summary>Selects one entity, or none with 0.</summary>
    public void Select(ulong entity) => Set(entity == 0 ? [] : [entity]);

    /// <summary>Selects these entities, the last as the primary one.</summary>
    public void Set(IEnumerable<ulong> entities)
    {
        var next = entities.Where(e => e != 0).Distinct().ToList();
        if (next.SequenceEqual(_entities))
        {
            return;
        }
        var old = _entities;
        _entities = next;
        Changed?.Invoke(old, next);
    }

    /// <summary>Adds entities, as Shift does. One that is selected already becomes the primary one.</summary>
    public void Add(IEnumerable<ulong> entities)
    {
        var added = entities.ToList();
        Set([.. _entities.Where(e => !added.Contains(e)), .. added]);
    }

    /// <summary>Selects an entity that is not selected, and deselects one that is, as Ctrl does.</summary>
    public void Toggle(ulong entity) => Set(Contains(entity) ? _entities.Where(e => e != entity) : [.. _entities, entity]);

    public void Remove(IEnumerable<ulong> entities)
    {
        var removed = entities.ToHashSet();
        Set(_entities.Where(e => !removed.Contains(e)));
    }

    public void Clear() => Set([]);
}
