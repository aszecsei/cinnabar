using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// What the outliner keeps that is not the world's (see docs/editor/shell-and-panels.md#outliner): the rows that the
/// user collapsed. It is the shell's, so a view that docking makes again has it, and a scene entity is in it by its
/// scene ID, so it stays collapsed when a resync, as Stop makes, gives every entity a new handle. An entity that the
/// game spawned has only its handle, and is expanded again after a resync, as it is another entity then.
/// </summary>
public sealed class OutlinerState
{
    readonly HashSet<ulong> _collapsedScene = [];
    readonly HashSet<ulong> _collapsedSpawned = [];

    public bool IsCollapsed(EntityNode node) => node.SceneId != 0 ? _collapsedScene.Contains(node.SceneId) : _collapsedSpawned.Contains(node.Handle);

    /// <summary>Collapses an expanded row, and expands a collapsed one.</summary>
    public void Toggle(EntityNode node)
    {
        var (set, key) = node.SceneId != 0 ? (_collapsedScene, node.SceneId) : (_collapsedSpawned, node.Handle);
        if (!set.Remove(key))
        {
            set.Add(key);
        }
    }
}
