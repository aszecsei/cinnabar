using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// A cutscene's cameras (see docs/editor/cutscene-editor.md#cameras): which bindings are cameras, and the scene views
/// that look through them.
/// </summary>
public sealed partial class CutsceneEditor
{
    /// <summary>A scene view's look, or which scene view is active, changed: a camera row's toggle may show another state.</summary>
    public event Action? LooksChanged;

    internal void OnLooksChanged() => LooksChanged?.Invoke();

    /// <summary>The engine's Camera component's ID.</summary>
    public const ulong CameraComponentId = 32;

    /// <summary>
    /// Whether a binding is a camera: a camera cut names it, the entity that it possesses has a Camera, or the root of
    /// the prefab that it spawns has one.
    /// </summary>
    public bool IsCamera(CutsceneBlock binding)
    {
        if (binding.Id is not { } id)
        {
            return false;
        }
        if (CutsceneEdits.CutCameras(File).Contains(id))
        {
            return true;
        }
        if (HandleOf(id) is { } handle && _shell.World.Find(handle) is { } node)
        {
            return node.Components.Contains(CameraComponentId);
        }
        return CutsceneBindings.SpawnOf(binding) is { } prefab && _shell.PrefabRootHas(prefab, CameraComponentId);
    }

    /// <summary>The bindings that are cameras, by ID and name, in the file's order.</summary>
    public IReadOnlyList<(int Id, string Name)> CameraBindings() =>
        [.. File.Bindings.Where(IsCamera).Select(b => (b.Id!.Value, b.Name ?? $"Binding {b.Id}"))];

    /// <summary>
    /// The scene view that the cutscene's look commands act in: the active one, or the first when the Game view is the
    /// settings view.
    /// </summary>
    int LookView => _shell.ActiveViewport.HasCamera ? _shell.ActiveViewport.Index : 0;

    /// <summary>
    /// Makes the active scene view look through a camera binding, or back through its editor camera when it already
    /// does. The tab takes the preview, since the view draws from the preview's camera.
    /// </summary>
    public void ToggleLookThrough(int binding)
    {
        var view = LookView;
        if (_shell.Looks[view] is ViewLook.Camera camera && camera.Owner == this && camera.Binding == binding)
        {
            _shell.Looks.LookThroughEditor(view);
            return;
        }
        TakePreviewForLook();
        _shell.Looks.LookThrough(view, this, binding);
    }

    /// <summary>Makes the active scene view follow the camera cuts, and takes the preview for this tab.</summary>
    public void LookThroughCuts()
    {
        TakePreviewForLook();
        _shell.Looks.LookThroughCuts(LookView, this);
    }

    /// <summary>Whether the active scene view looks through a binding of this cutscene.</summary>
    public bool LooksThrough(int binding) => _shell.Looks[LookView] is ViewLook.Camera camera && camera.Owner == this && camera.Binding == binding;

    void TakePreviewForLook()
    {
        if (_shell.CutscenePreview.Owner != this)
        {
            _shell.CutscenePreview.Take(this);
        }
    }
}
