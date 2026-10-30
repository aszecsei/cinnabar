using Cinnabar.Editor.Document;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Tools;
using GizmoKind = Cinnabar.Editor.Link.Protocol.GizmoKind;
using GizmoPart = Cinnabar.Editor.Link.Protocol.GizmoPart;
using GizmoState = Cinnabar.Editor.Link.Protocol.GizmoState;
using PickRequest = Cinnabar.Editor.Link.Protocol.PickRequest;
using PickResult = Cinnabar.Editor.Link.Protocol.PickResult;
using SetSelection = Cinnabar.Editor.Link.Protocol.SetSelection;

namespace Cinnabar.Editor.Shell;

/// <summary>How a click or a box in the viewport changes the selection.</summary>
public enum SelectMode
{
    /// <summary>The hits become the selection.</summary>
    Replace,
    /// <summary>Shift: the hits join the selection.</summary>
    Add,
    /// <summary>Ctrl: each hit joins the selection, or leaves it if it was selected.</summary>
    Toggle,
}

/// <summary>
/// The viewport's tools (see docs/editor/viewport.md#viewport): the editor's camera, picking, and the gizmo with its drags and
/// snapping. The camera, the selection and the gizmo go to the game, which draws them. The viewport's controls turn
/// input into calls here, in pixels of the host's frame, so tests can drive the tools without a window.
/// </summary>
public sealed partial class EditorShell
{
    readonly Dictionary<uint, Action<PickResult>> _picks = [];
    uint _nextPick;
    string _sentGizmo = "";
    GizmoDrag? _drag;
    PoseEdit? _poseEdit;
    long[] _dragPivot = [0, 0, 0];
    Quat _dragAxes = Quat.Identity;

    public EditorCamera Camera { get; } = new();

    public Tool Tool { get; private set; } = Tool.Move;

    public Space Space { get; private set; } = Space.World;

    /// <summary>Gizmo drags round to <see cref="Snapping"/>'s steps. Ctrl during a drag does the opposite.</summary>
    public bool Snap { get; private set; }

    public Snapping Snapping { get; set; } = Snapping.Default;

    /// <summary>The gizmo part under the mouse, or the one that a drag holds.</summary>
    public GizmoPart HotPart { get; private set; }

    public bool IsDraggingGizmo => _drag != null;

    /// <summary>The tool, the space, snapping or the hot part changed.</summary>
    public event Action? ToolsChanged;

    public void SetTool(Tool tool)
    {
        CancelGizmo();
        Tool = tool;
        OnToolsChanged();
    }

    public void ToggleSpace()
    {
        Space = Space == Space.World ? Space.Local : Space.World;
        OnToolsChanged();
    }

    public void ToggleSnap()
    {
        Snap = !Snap;
        OnToolsChanged();
    }

    void OnToolsChanged()
    {
        SendGizmo();
        Commands.InvalidateAll();
        ToolsChanged?.Invoke();
    }

    /// <summary>The frame's size in pixels: the host's, or before its first frame, the viewport's.</summary>
    public (double Width, double Height) FrameSize
    {
        get
        {
            var size = Viewport.FrameSize is { Width: > 0, Height: > 0 } frame ? frame : Viewport.RequestedSize;
            return (Math.Max(size.Width, 1), Math.Max(size.Height, 1));
        }
    }

    /// <summary>
    /// Selects what is drawn at a pixel of the frame. A click on nothing clears the selection, unless it adds. In mesh
    /// mode, the editor picks the element itself, at once.
    /// </summary>
    public void PickAt(Vec2 pixel, SelectMode mode)
    {
        if (InMeshMode)
        {
            PickMeshAt(pixel, mode);
            return;
        }
        Pick((int)Math.Floor(pixel.X), (int)Math.Floor(pixel.Y), 1, 1, mode);
    }

    /// <summary>Selects what is drawn in a rectangle of the frame, between two corners.</summary>
    public void PickBox(Vec2 a, Vec2 b, SelectMode mode)
    {
        if (InMeshMode)
        {
            PickMeshBox(a, b, mode);
            return;
        }
        var (x0, y0) = ((int)Math.Floor(Math.Min(a.X, b.X)), (int)Math.Floor(Math.Min(a.Y, b.Y)));
        var (x1, y1) = ((int)Math.Ceiling(Math.Max(a.X, b.X)), (int)Math.Ceiling(Math.Max(a.Y, b.Y)));
        Pick(x0, y0, Math.Max(x1 - x0, 1), Math.Max(y1 - y0, 1), mode);
    }

    void Pick(int x, int y, int width, int height, SelectMode mode) =>
        Pick(x, y, width, height, result => OnPicked(result, mode, width == 1 && height == 1));

    /// <summary>
    /// Finds what is drawn at a pixel of the frame without selecting it, and calls back with the answer a few frames
    /// later. Returns false without a linked host, which never answers.
    /// </summary>
    public bool PickPixel(Vec2 pixel, Action<PickResult> then) => Pick((int)Math.Floor(pixel.X), (int)Math.Floor(pixel.Y), 1, 1, then);

    bool Pick(int x, int y, int width, int height, Action<PickResult> then)
    {
        if (!Host.Linked)
        {
            return false;
        }
        var id = ++_nextPick;
        _picks[id] = then;
        Host.Send(new PickRequest(id, x, y, width, height));
        return true;
    }

    // The handle of the outermost root of the instance that an entity is inside, or the entity's own.
    ulong InstanceRootOf(ulong handle, ulong sceneId) =>
        IsEditing && InstanceOf(sceneId) is { IsInstanceRoot: false } info && World.FindScene(info.Instance) is { } root ? root.Handle : handle;

    void OnPicked(PickResult result, SelectMode mode, bool click)
    {
        // Locked entities are drawn but not picked. A pick leaves the camera's pivot where it is: it is ahead of the
        // camera, and what was clicked usually is not. An instance is one thing to pick, so a hit inside one picks its
        // outermost root; a double click picks the entity itself.
        var hits = result.Hits.Where(h => Pickable(h.Entity)).Select(h => InstanceRootOf(h.Entity, h.SceneId)).Distinct().ToList();
        switch (mode)
        {
            case SelectMode.Replace:
                Selection.Set(hits);
                break;
            case SelectMode.Add:
                Selection.Add(hits);
                break;
            case SelectMode.Toggle:
                foreach (var hit in hits)
                {
                    Selection.Toggle(hit);
                }
                break;
        }
    }

    /// <summary>
    /// The gizmo's pivot and axes: the primary entity's world pose in the document, or in mesh mode the sub-selection's
    /// centroid, or null for no gizmo.
    /// </summary>
    public (long[] Pivot, Quat Axes)? GizmoPose()
    {
        if (InMeshMode)
        {
            return MeshGizmoPose();
        }
        if (ActiveGizmoKind == GizmoKind.None || Scene == null || SelectedSceneEntity is not { } primary
            || SceneEdits.WorldPose(Scene.Expanded.Flat, primary) is not { } pose)
        {
            return null;
        }
        // Scaling is along the entity's own axes.
        var local = Space == Space.Local || Tool == Tool.Scale;
        return (pose.Position, local ? pose.Rotation : Quat.Identity);
    }

    /// <summary>Highlights the gizmo part under the mouse.</summary>
    public void HoverGizmo(Vec2 pixel)
    {
        if (_drag != null)
        {
            return;
        }
        var part = GizmoPart.None;
        if (GizmoPose() is var (pivot, axes))
        {
            var (width, height) = FrameSize;
            part = Gizmo.HitTest(ActiveGizmoKind, Camera, Camera.RelativeTo(pivot), axes, pixel, width, height);
        }
        if (part != HotPart)
        {
            HotPart = part;
            OnToolsChanged();
        }
    }

    /// <summary>
    /// Starts a drag if the press is on a gizmo part, and reports whether it is. <paramref name="extrude"/> is Shift,
    /// which in mesh mode extrudes the selection first and drags the distance.
    /// </summary>
    public bool PressGizmo(Vec2 pixel, bool extrude = false)
    {
        HoverGizmo(pixel);
        if (HotPart == GizmoPart.None || GizmoPose() is not var (pivot, axes) || Scene == null)
        {
            return false;
        }
        if (InMeshMode)
        {
            return PressMeshGizmo(pixel, extrude);
        }
        var ids = Selection.Entities.Select(h => World.Find(h)?.SceneId ?? 0).Where(id => id != 0);
        _poseEdit = new PoseEdit(Scene.Expanded.Flat, ids);
        if (_poseEdit.IsEmpty)
        {
            _poseEdit = null;
            return false;
        }
        var (width, height) = FrameSize;
        _drag = new GizmoDrag(Gizmo.KindOf(Tool), HotPart, Camera, Camera.RelativeTo(pivot), axes, pixel, width, height);
        (_dragPivot, _dragAxes) = (pivot, axes);
        var count = _poseEdit.Moved.Count();
        var verb = Tool switch { Tool.Rotate => "Rotate", Tool.Scale => "Scale", _ => "Move" };
        BeginEdit(count == 1 ? $"{verb} {Label(Scene.Expanded.Flat.Find(_poseEdit.Moved.First())!)}" : $"{verb} {count} Entities");
        SendGizmo();
        return true;
    }

    /// <summary>Moves the drag to a pixel. <paramref name="invertSnap"/> is Ctrl, which snaps when snapping is off and the other way round.</summary>
    public void DragGizmo(Vec2 pixel, bool invertSnap)
    {
        if (_meshDrag != null || _textureDrag != null || _pivotDrag != null || _pending != null)
        {
            DragMeshGizmo(pixel, invertSnap);
            return;
        }
        if (_drag == null || _poseEdit == null)
        {
            return;
        }
        var change = _drag.Update(pixel, Snap != invertSnap ? Snapping : null);
        var ops = _poseEdit.Apply(change, _dragPivot, _dragAxes);
        if (ops.Count > 0 && Scene is { InTransaction: true })
        {
            try
            {
                Scene.Preview(ops);
            }
            catch (InvalidOperationException e)
            {
                Console.Add(LogLevel.Error, $"edit: {e.Message}");
            }
        }
    }

    public void ReleaseGizmo()
    {
        if (_drag == null)
        {
            return;
        }
        _drag = null;
        _poseEdit = null;
        _meshDrag = null;
        _textureDrag = null;
        _pivotDrag = null;
        var pending = _pending != null;
        _pending = null;
        CommitEdit();
        SendGizmo();
        if (pending)
        {
            OnMeshModeChanged();
        }
    }

    /// <summary>Ends a drag and puts the selection back where it was.</summary>
    public void CancelGizmo()
    {
        if (_drag == null)
        {
            return;
        }
        _drag = null;
        _poseEdit = null;
        _meshDrag = null;
        _textureDrag = null;
        _pivotDrag = null;
        var pending = _pending != null;
        _pending = null;
        CancelEdit();
        SendGizmo();
        if (pending)
        {
            MeshSelection = MeshSelection.Pruned(FindMeshData);
            OnMeshModeChanged();
        }
    }

    /// <summary>Moves the camera so the selected entities fill the view.</summary>
    public void FrameSelected()
    {
        if (Scene == null)
        {
            return;
        }
        var entities = Selection.Entities.Select(h => World.Find(h)?.SceneId ?? 0).Select(id => Scene.Expanded.Flat.Find(id)).OfType<SceneEntity>();
        Frame(entities);
    }

    /// <summary>Moves the camera so the whole scene fills the view.</summary>
    public void FrameScene()
    {
        if (Scene != null)
        {
            Frame(Scene.Expanded.Flat.Entities);
        }
    }

    void Frame(IEnumerable<SceneEntity> entities)
    {
        if (Bounds(entities) is var (center, radius))
        {
            Camera.Frame(center, radius);
        }
    }

    // The middle of the box around the entities' positions, and a radius that takes in each one with half a meter of
    // its scale around it, or null for entities without a pose.
    (long[] Center, double Radius)? Bounds(IEnumerable<SceneEntity> entities)
    {
        var poses = Scene == null ? [] : entities.Select(e => SceneEdits.WorldPose(Scene.Expanded.Flat, e)).OfType<Pose>().ToList();
        if (poses.Count == 0)
        {
            return null;
        }
        var origin = poses[0].Position;
        var offsets = poses.Select(p => Vec3.Between(origin, p.Position)).ToList();
        var min = new Vec3(offsets.Min(o => o.X), offsets.Min(o => o.Y), offsets.Min(o => o.Z));
        var max = new Vec3(offsets.Max(o => o.X), offsets.Max(o => o.Y), offsets.Max(o => o.Z));
        var middle = (min + max) * 0.5;
        var radius = poses.Select((p, i) => (offsets[i] - middle).Length + Math.Max(p.Scale.Max(Math.Abs), 0.1) * 0.5).Max();
        return (middle.Offset(origin), radius);
    }

    /// <summary>Alt-orbit turns about the selection's middle instead of the pivot ahead, as Unreal's option does.</summary>
    public bool OrbitSelection { get; private set; }

    public void ToggleOrbitSelection()
    {
        OrbitSelection = !OrbitSelection;
        OnToolsChanged();
    }

    /// <summary>Orbits by pixels of mouse movement: about the selection with <see cref="OrbitSelection"/>, and otherwise about the pivot ahead.</summary>
    public void Orbit(double dx, double dy)
    {
        if (OrbitSelection && Bounds(SelectedSceneEntities) is var (center, _))
        {
            Camera.OrbitAround(center, dx, dy);
        }
        else
        {
            Camera.Orbit(dx, dy);
        }
    }

    void SendCamera()
    {
        Host.Send(Camera.ToMessage());
        SendGizmo();
    }

    void SendSelection() => Host.Send(new SetSelection([.. Selection.Entities]));

    // The gizmo state when it changes: its pose follows the document, and its size the camera and the frame.
    void SendGizmo()
    {
        var state = new GizmoState(GizmoKind.None, [0, 0, 0], [0, 0, 0, 1], 0, GizmoPart.None, false);
        if (GizmoPose() is var (pivot, axes))
        {
            var size = Gizmo.Size(Camera, Camera.RelativeTo(pivot), FrameSize.Height);
            state = new GizmoState(ActiveGizmoKind, pivot, [(float)axes.X, (float)axes.Y, (float)axes.Z, (float)axes.W], (float)size, HotPart, _drag != null);
        }
        var key = $"{state.Kind}|{string.Join(",", state.Position)}|{string.Join(",", state.Rotation)}|{state.Size}|{state.Hot}|{state.Dragging}";
        if (key != _sentGizmo && Host.Linked)
        {
            _sentGizmo = key;
            Host.Send(state);
        }
    }

    // A new link knows none of the tools' state.
    void SendViewportTools()
    {
        _sentGizmo = "";
        _picks.Clear();
        _aimingSun = false;
        SendCamera();
        SendSelection();
        ResendHidden();
        SendViewportSettings();
        ResendMeshOverlay();
    }

    void OnPickResult(PickResult result)
    {
        if (_picks.Remove(result.Id, out var then))
        {
            then(result);
        }
    }
}
