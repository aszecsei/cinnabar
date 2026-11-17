using Cinnabar.Editor.Document;
using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// What the outliner keeps that is not the world's (see docs/editor/shell-and-panels.md#outliner): the rows that the
/// user collapsed. It is the shell's, so a view that docking makes again has it, and a scene entity is in it by its
/// scene and scene ID, so it stays collapsed when a resync, as Stop makes, gives every entity a new handle. An entity
/// that the game spawned has only its handle, and is expanded again after a resync, as it is another entity then. With
/// several scenes open, a scene's heading collapses too.
/// </summary>
public sealed class OutlinerState
{
    readonly HashSet<(uint Scene, ulong Id)> _collapsedScene = [];
    readonly HashSet<ulong> _collapsedSpawned = [];
    readonly HashSet<SceneDocument> _collapsedHeadings = [];

    public bool IsCollapsed(EntityNode node) =>
        node.SceneId != 0 ? _collapsedScene.Contains((node.Scene, node.SceneId)) : _collapsedSpawned.Contains(node.Handle);

    public bool IsCollapsed(SceneDocument scene) => _collapsedHeadings.Contains(scene);

    /// <summary>Collapses an expanded row, and expands a collapsed one.</summary>
    public void Toggle(EntityNode node)
    {
        if (node.SceneId != 0)
        {
            Flip(_collapsedScene, (node.Scene, node.SceneId));
        }
        else
        {
            Flip(_collapsedSpawned, node.Handle);
        }
    }

    /// <summary>Collapses an expanded scene's heading, and expands a collapsed one.</summary>
    public void Toggle(SceneDocument scene) => Flip(_collapsedHeadings, scene);

    static void Flip<T>(HashSet<T> set, T key)
    {
        if (!set.Remove(key))
        {
            set.Add(key);
        }
    }
}
