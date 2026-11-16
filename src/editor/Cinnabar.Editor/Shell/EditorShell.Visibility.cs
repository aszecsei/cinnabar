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

    public bool IsHidden(ulong sceneId) => Visibility.IsHidden(sceneId);

    public bool IsLocked(ulong sceneId) => Visibility.IsLocked(sceneId);

    public bool IsHiddenInTree(ulong handle) => Visibility.IsHiddenInTree(handle);

    public bool IsLockedInTree(ulong handle) => Visibility.IsLockedInTree(handle);

    public bool HasHidden => Visibility.HasHidden;

    public void SetHidden(IEnumerable<ulong> sceneIds, bool hidden) => Visibility.SetHidden(sceneIds, hidden);

    public void SetLocked(IEnumerable<ulong> sceneIds, bool locked) => Visibility.SetLocked(sceneIds, locked);

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
