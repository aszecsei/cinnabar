using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Tools;
using AssetKind = Cinnabar.Editor.Link.Cook.AssetKind;

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
        if (InContext)
        {
            _shell.Console.Add(Model.LogLevel.Info, $"cutscene: {InContextCameraRefusal}");
            return;
        }
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

    /// <summary>The engine's cinematic camera prefab, in engine content (see docs/editor/cutscene-editor.md#new-camera-from-view).</summary>
    public const string EngineCameraPrefab = "c1a3e0d5b2f84e7a9d6c4b8e2f1a7c35";

    /// <summary>
    /// The prefab that New Camera from View spawns: the engine's cinematic camera, or when the asset index does not have it,
    /// the first prefab, by name, whose root has a Cinematic_Camera. Null when there is none.
    /// </summary>
    public string? CameraPrefab() =>
        _shell.Assets.Find(EngineCameraPrefab) is { Kind: AssetKind.Prefab } ? EngineCameraPrefab
        : KnownPrefabs().Select(p => p.Guid).FirstOrDefault(g => _shell.PrefabRootHas(g, Panels.CinematicCameraText.CinematicCameraId));

    /// <summary>
    /// The pose and the vertical field of view of what a scene view shows: the camera that the game drew it through, or
    /// its editor camera. Null for the Game view and for an orthographic editor camera, which has no lens.
    /// </summary>
    public (long[] Position, Quat Rotation, double VerticalFov)? ViewPose(EditorViewport view)
    {
        if (!view.HasCamera)
        {
            return null;
        }
        if (_shell.Looks[view.Index] is ViewLook.Through { Shown: { Camera: true } shown })
        {
            var r = shown.Rotation;
            return ([.. shown.Position], new Quat(r[0], r[1], r[2], r[3]), shown.VerticalFov);
        }
        var camera = view.Camera;
        return camera.IsOrthographic ? null : ([.. camera.Position], camera.Rotation, camera.VerticalFov);
    }

    /// <summary>Why New Camera from View cannot run in a view, or null when it can.</summary>
    public string? NewCameraRefusal(EditorViewport view)
    {
        if (Document.InTransaction)
        {
            return "An edit of the cutscene is under way.";
        }
        if (!view.HasCamera)
        {
            return "Make a scene view active: the Game view draws from the game's camera.";
        }
        if (ViewPose(view) == null)
        {
            return "The view is orthographic, so it has no lens to copy.";
        }
        return CameraPrefab() == null ? "No prefab with a Cinematic Camera is in the project or the engine." : null;
    }

    /// <summary>
    /// Adds a camera where a scene view looks from, as one undo entry (see docs/editor/cutscene-editor.md#new-camera-from-view):
    /// a binding that spawns <see cref="CameraPrefab"/> with the view's pose, its transform keyed at the playhead, its
    /// focal length keyed to the view's field of view on the prefab's sensor, and a cut to it at the playhead when no cut
    /// is there. Selects its row, and gives its ID, or null when it cannot run.
    /// </summary>
    public int? NewCameraFromView(EditorViewport view)
    {
        if (NewCameraRefusal(view) != null || ViewPose(view) is not { } pose || CameraPrefab() is not { } prefab)
        {
            return null;
        }
        var sensor = _shell.PrefabRootNumber(prefab, Panels.CinematicCameraText.CinematicCameraId, "sensor_height") ?? Lens.DefaultSensorHeight;
        var focal = Math.Round(Lens.FocalLength(pose.VerticalFov, sensor), 2);
        var tick = Playhead;
        var id = 0;
        Key("New Camera", f =>
        {
            id = CutsceneBindings.AddSpawnAt(f, prefab, "Camera", pose.Position, tick);
            CutsceneBindings.SetRotation(f, id, pose.Rotation);
            CutsceneKeying.SetKeys(f, new KeyTarget.Pose(id, PosePart.Rotation), tick, [0, 0, 0], "Transform");
            CutsceneKeying.SetKeys(f, new KeyTarget.Property(id, Panels.CinematicCameraText.CinematicCameraId, "focal_length", PropertyShape.Number),
                tick, [focal], "Lens");
            CutsceneEdits.AddCut(f, tick, id);
        });
        if (id == 0)
        {
            return null;
        }
        SelectBindings([id]);
        return id;
    }

    void TakePreviewForLook()
    {
        if (_shell.CutscenePreview.Owner != this)
        {
            _shell.CutscenePreview.Take(this);
        }
    }
}
