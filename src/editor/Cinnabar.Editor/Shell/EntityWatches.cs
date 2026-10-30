using Cinnabar.Editor.Host;
using Cinnabar.Editor.Model;
using UnwatchEntity = Cinnabar.Editor.Link.Protocol.UnwatchEntity;
using WatchEntity = Cinnabar.Editor.Link.Protocol.WatchEntity;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// Entities that a panel other than the properties panel watches, by handle, with how many times, so a change of
/// the selection does not stop their values.
/// </summary>
public sealed class EntityWatches(Selection selection, HostSession host)
{
    readonly Dictionary<ulong, int> _counts = [];

    /// <summary>The handles that a panel watches.</summary>
    public IEnumerable<ulong> Handles => _counts.Keys;

    /// <summary>Whether a panel watches this entity.</summary>
    public bool Contains(ulong handle) => _counts.ContainsKey(handle);

    /// <summary>Watches an entity's values for a panel, as the selection's are, until as many <see cref="Unwatch"/>.</summary>
    public void Watch(ulong handle)
    {
        if (handle == 0)
        {
            return;
        }
        var count = _counts.GetValueOrDefault(handle);
        _counts[handle] = count + 1;
        if (count == 0 && !selection.Contains(handle))
        {
            host.Send(new WatchEntity(handle));
        }
    }

    public void Unwatch(ulong handle)
    {
        if (!_counts.TryGetValue(handle, out var count))
        {
            return;
        }
        if (count > 1)
        {
            _counts[handle] = count - 1;
            return;
        }
        _counts.Remove(handle);
        if (!selection.Contains(handle))
        {
            host.Send(new UnwatchEntity(handle));
        }
    }
}
