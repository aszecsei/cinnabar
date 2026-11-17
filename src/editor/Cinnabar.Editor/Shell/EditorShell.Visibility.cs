using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Shell;

/// <summary>Forwards to <see cref="SceneVisibility"/>, which holds the hidden and locked entities.</summary>
public sealed partial class EditorShell
{
    public const string SceneViewsFileName = SceneVisibility.FileName;

    public SceneVisibility Visibility { get; }

    /// <summary>An entity was hidden, shown, locked or unlocked.</summary>
    public event Action? VisibilityChanged
    {
        add => Visibility.Changed += value;
        remove => Visibility.Changed -= value;
    }

    /// <summary>Whether the user hid this entity of the active scene itself.</summary>
    public bool IsHidden(ulong sceneId) => Visibility.IsHidden(ActiveNumber, sceneId);

    /// <summary>Whether the user locked this entity of the active scene itself.</summary>
    public bool IsLocked(ulong sceneId) => Visibility.IsLocked(ActiveNumber, sceneId);

    /// <summary>Whether the user hid this entity of any open scene itself.</summary>
    public bool IsHidden(EntityNode node) => Visibility.IsHidden(node.Scene, node.SceneId);

    /// <summary>Whether the user locked this entity of any open scene itself.</summary>
    public bool IsLocked(EntityNode node) => Visibility.IsLocked(node.Scene, node.SceneId);

    public bool IsHiddenInTree(ulong handle) => Visibility.IsHiddenInTree(handle);

    public bool IsLockedInTree(ulong handle) => Visibility.IsLockedInTree(handle);

    public bool HasHidden => Visibility.HasHidden;

    /// <summary>Hides or shows entities of the active scene by scene ID.</summary>
    public void SetHidden(IEnumerable<ulong> sceneIds, bool hidden) => Visibility.SetHidden(sceneIds.Select(id => (ActiveNumber, id)), hidden);

    /// <summary>Locks or unlocks entities of the active scene by scene ID.</summary>
    public void SetLocked(IEnumerable<ulong> sceneIds, bool locked) => Visibility.SetLocked(sceneIds.Select(id => (ActiveNumber, id)), locked);

    /// <summary>Hides or shows an entity of any open scene.</summary>
    public void SetHidden(EntityNode node, bool hidden) => Visibility.SetHidden([(node.Scene, node.SceneId)], hidden);

    /// <summary>Locks or unlocks an entity of any open scene.</summary>
    public void SetLocked(EntityNode node, bool locked) => Visibility.SetLocked([(node.Scene, node.SceneId)], locked);

    /// <summary>
    /// Whether a selected entity is the scene's, in any mode: what is hidden and locked is the editor's, not the
    /// document's, so Hide, Lock and Frame Selected work while the game plays too, when the document has no selection.
    /// </summary>
    public bool HasSceneSelection => Selection.Entities.Any(h => World.Find(h) is { SceneId: not 0 });

    public void ToggleHideSelected() => Visibility.ToggleHideSelected();

    public void ToggleLockSelected() => Visibility.ToggleLockSelected();

    public void ShowAll() => Visibility.ShowAll();

    bool Pickable(ulong handle) => Visibility.Pickable(handle);
}
