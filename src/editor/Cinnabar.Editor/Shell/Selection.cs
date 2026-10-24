namespace Cinnabar.Editor.Shell;

/// <summary>
/// The selected entity, by handle. One entity for now; multi-select comes with editing. Selection moves to the
/// document with scenes (see docs/editor.md#document-model).
/// </summary>
public sealed class Selection
{
    public ulong Entity { get; private set; }

    public bool IsEmpty => Entity == 0;

    /// <summary>The old and the new entity.</summary>
    public event Action<ulong, ulong>? Changed;

    public void Select(ulong entity)
    {
        if (entity != Entity)
        {
            var old = Entity;
            Entity = entity;
            Changed?.Invoke(old, entity);
        }
    }

    public void Clear() => Select(0);
}
