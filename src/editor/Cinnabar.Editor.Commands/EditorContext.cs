namespace Cinnabar.Editor.Commands;

/// <summary>
/// The named conditions that are true now, such as <c>host.running</c>. A contextual ribbon tab shows only while its
/// context is active.
/// </summary>
public sealed class EditorContext
{
    readonly HashSet<string> _active = [];

    public event Action? Changed;

    public bool IsActive(string key) => _active.Contains(key);

    public void Set(string key, bool active)
    {
        if (active ? _active.Add(key) : _active.Remove(key))
        {
            Changed?.Invoke();
        }
    }
}
