using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Tools;
using Cinnabar.Editor.Viewport;
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
/// The viewport's tools (see docs/editor/viewport.md#viewport): picking, and the gizmo with its drags and snapping. The
/// cameras, the selection and the gizmo go to the game, which draws them. The viewport's controls turn input into calls
/// here, in pixels of the active scene view's frame (see <see cref="ActiveViewport"/>), so tests can drive the tools
/// without a window.
/// </summary>
public sealed partial class EditorShell
{
    readonly PendingReplies<Action<PickResult>> _picks = new();
    readonly GizmoController _gizmo;

    public Tool Tool { get; private set; } = Tool.Move;

    public Space Space { get; private set; } = Space.World;

    /// <summary>Gizmo drags round to <see cref="Snapping"/>'s steps. Ctrl during a drag does the opposite.</summary>
    public bool Snap { get; private set; }

    public Snapping Snapping { get; set; } = Snapping.Default;

    /// <summary>The gizmo part under the mouse, or the one that a drag holds.</summary>
    public GizmoPart HotPart { get; private set; }

    public bool IsDraggingGizmo => _gizmo.IsDragging;

    /// <summary>The tool, the space, snapping or the hot part changed.</summary>
    public event Action? ToolsChanged;

    public void SetTool(Tool tool)
    {
        if (tool is Tool.NavPath or Tool.Landscape && Mesh.InMeshMode)
        {
            return;
        }
        CancelGizmo();
        Landscape.CancelStroke();
        Tool = tool;
        if (tool != Tool.NavPath)
        {
            ClearNavProbe();
        }
        Landscape.Sync();
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

    /// <summary>
    /// Selects what is drawn at a pixel of the frame. A click on nothing clears the selection, unless it adds. In mesh
    /// mode, the editor picks the element itself, at once.
    /// </summary>
    public void PickAt(Vec2 pixel, SelectMode mode)
    {
        if (Mesh.InMeshMode)
        {
            Mesh.PickMeshAt(pixel, mode);
            return;
        }
        Pick((int)Math.Floor(pixel.X), (int)Math.Floor(pixel.Y), 1, 1, mode);
    }

    /// <summary>Selects what is drawn in a rectangle of the frame, between two corners.</summary>
    public void PickBox(Vec2 a, Vec2 b, SelectMode mode)
    {
        if (Mesh.InMeshMode)
        {
            Mesh.PickMeshBox(a, b, mode);
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
    public bool PickPixel(Vec2 pixel, Action<PickResult> then) => PickPixelIn(ActiveViewport.Index, pixel, then);

    /// <summary>As <see cref="PickPixel"/>, in a viewport that may not be the active one.</summary>
    public bool PickPixelIn(int viewport, Vec2 pixel, Action<PickResult> then) =>
        Pick(viewport, (int)Math.Floor(pixel.X), (int)Math.Floor(pixel.Y), 1, 1, then);

    bool Pick(int x, int y, int width, int height, Action<PickResult> then) => Pick(ActiveViewport.Index, x, y, width, height, then);

    bool Pick(int viewport, int x, int y, int width, int height, Action<PickResult> then)
    {
        if (!Host.Linked)
        {
            return false;
        }
        Host.Send(new PickRequest(_picks.Add(then), (uint)viewport, x, y, width, height));
        return true;
    }

    /// <summary>
    /// Finds the entity drawn in front at a pixel of the frame, as a click or a double click would pick it, and calls back
    /// with its handle when it is selected, or 0. Returns false without a linked host, which never answers.
    /// </summary>
    public bool PickSelectedAt(Vec2 pixel, Action<ulong> then) => PickPixel(pixel, result =>
    {
        var front = result.Hits.FirstOrDefault(h => Pickable(h.Entity));
        then(front == null ? 0 : ((ulong[])[InstanceRootOf(front.Entity, front.Scene, front.SceneId), front.Entity]).FirstOrDefault(Selection.Contains));
    });

    // The handle of the outermost root of the instance that an entity is inside, in its own scene, or the entity's own.
    ulong InstanceRootOf(ulong handle, uint scene, ulong sceneId) =>
        IsEditing && SceneByNumber(scene)?.Expanded.InstanceOf(sceneId) is { IsInstanceRoot: false } info && World.FindScene(scene, info.Instance) is { } root
            ? root.Handle : handle;

    void OnPicked(PickResult result, SelectMode mode, bool click)
    {
        // Locked entities are drawn but not picked. A pick leaves the camera's pivot where it is: it is ahead of the
        // camera, and what was clicked usually is not. An instance is one thing to pick, so a hit inside one picks its
        // outermost root; a double click picks the entity itself.
        var hits = result.Hits.Where(h => Pickable(h.Entity)).Select(h => InstanceRootOf(h.Entity, h.Scene, h.SceneId)).Distinct().ToList();
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
        if (Mesh.InMeshMode)
        {
            return Mesh.MeshGizmoPose();
        }
        if (Mesh.ActiveGizmoKind == GizmoKind.None || Scene == null || SelectedSceneEntity is not { } primary
            || (CutscenePose(Selection.Entity) ?? SceneEdits.WorldPose(Scene.Expanded.Flat, primary)) is not { } pose)
        {
            return null;
        }
        // Scaling is along the entity's own axes.
        var local = Gizmo.LocalAxes(Tool, Space);
        return (pose.Position, local ? pose.Rotation : Quat.Identity);
    }

    /// <summary>Highlights the gizmo part under the mouse.</summary>
    public void HoverGizmo(Vec2 pixel)
    {
        if (_gizmo.IsDragging)
        {
            return;
        }
        var part = GizmoPart.None;
        if (GizmoPose() is var (pivot, axes))
        {
            var (width, height) = FrameSize;
            part = Gizmo.HitTest(Mesh.ActiveGizmoKind, Camera, Camera.RelativeTo(pivot), axes, pixel, width, height);
        }
        // The gizmo is drawn over the selected probe's box handles, so it wins.
        var handle = part == GizmoPart.None ? HitProbeHandle(pixel) : null;
        if (part != HotPart || handle != HotHandle)
        {
            HotPart = part;
            HotHandle = handle;
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
        if (HotPart == GizmoPart.None && HotHandle is { } handle)
        {
            return PressProbeHandle(pixel, handle);
        }
        if (HotPart == GizmoPart.None || GizmoPose() is not var (pivot, axes) || Scene == null)
        {
            return false;
        }
        if (Mesh.InMeshMode)
        {
            return Mesh.PressMeshGizmo(pixel, extrude);
        }
        var handles = Selection.Entities.Select(h => (Handle: h, Id: ActiveSceneIdOf(h))).Where(e => e.Id != 0).ToDictionary(e => e.Id, e => e.Handle);
        var flat = Scene.Expanded.Flat;
        // A drag of entities that a cutscene holds goes to it, from the poses that the world shows (see
        // docs/editor/cutscene-editor.md#gizmo-keys).
        var route = Keying.PoseRoute([.. handles.Values]);
        switch (route)
        {
            case FieldRoute.Refused refused:
                Keying.Refuse("move the selection", refused.Why);
                return false;
            case FieldRoute.Possess possess:
                Keying.AskToPossess("move the selection", possess.Handle);
                return false;
        }
        var poseEdit = route is FieldRoute.Scene
            ? new PoseEdit(flat, handles.Keys)
            : new PoseEdit(flat, handles.Keys, e => (handles.TryGetValue(e.Id, out var h) ? Keying.ShownWorldPose(h) : null) ?? SceneEdits.WorldPose(flat, e));
        if (poseEdit.IsEmpty)
        {
            return false;
        }
        var (width, height) = FrameSize;
        var count = poseEdit.Moved.Count();
        var verb = Gizmo.VerbOf(Tool);
        var drag = new GizmoDrag(Gizmo.KindOf(Tool), HotPart, Camera, Camera.RelativeTo(pivot), axes, pixel, width, height);
        var target = new PoseTarget(this, poseEdit, pivot, axes);
        var label = count == 1 ? $"{verb} {Label(flat.Find(poseEdit.Moved.First())!)}" : $"{verb} {count} Entities";
        if (route is FieldRoute.Scene)
        {
            return _gizmo.Start(drag, target, label);
        }
        return Keying.BeginPoseDrag(label, handles, route is FieldRoute.Key) is { } edit && _gizmo.Start(drag, target, edit);
    }

    // The primary entity's pose as the world shows it, when a gizmo drag of it goes to the cutscene.
    Pose? CutscenePose(ulong handle) =>
        Keying.Cutscene != null && Keying.PoseRoute([handle]) is not (FieldRoute.Scene or FieldRoute.Possess) ? Keying.ShownWorldPose(handle) : null;

    /// <summary>Moves the drag to a pixel. <paramref name="invertSnap"/> is Ctrl, which snaps when snapping is off and the other way round.</summary>
    public void DragGizmo(Vec2 pixel, bool invertSnap) => _gizmo.Drag(pixel, Snap != invertSnap);

    public void ReleaseGizmo() => _gizmo.Release();

    /// <summary>Ends a drag and puts the selection back where it was.</summary>
    public void CancelGizmo() => _gizmo.Cancel();

    /// <summary>
    /// The tools that a left press in a scene view tries, in this order: the first that starts a drag has the press, and
    /// a press that none takes is a click. The gizmo is drawn over the rest, so it comes first.
    /// </summary>
    public IReadOnlyList<IViewportTool> LeftTools => field ??= [new GizmoTool(this), Mesh, Landscape];

    /// <summary>
    /// What Esc cancels in a scene view after the view's own look and drag (see docs/editor/viewport.md), in this
    /// order: a cutscene's armed pick of a binding's entity, then mesh mode's Escape, then a mesh tool's points, or
    /// else the mesh tool, which goes back to Select.
    /// </summary>
    public IReadOnlyList<(Func<bool> When, Action Run)> ViewportCancels =>
    [
        (() => BindingPicking, () => CancelBindingPicks()),
        (() => Mesh.InMeshMode, Mesh.EscapeMeshMode),
        (() => Mesh.Tools.ToolPointCount > 0, Mesh.Tools.CancelToolPoints),
        (() => Mesh.MeshTool != MeshTool.Select, () => Mesh.SetMeshTool(MeshTool.Select)),
    ];

    // The gizmo's and the probe handles' drags. A capture lost mid-drag commits, as a release does.
    sealed class GizmoTool(EditorShell shell) : IViewportTool
    {
        public IViewportDrag? TryBegin(Vec2 pixel, DragKeys keys) =>
            shell.PressGizmo(pixel, extrude: keys.Shift) && shell._gizmo.Current is { } token ? new Dragging(shell, token) : null;

        public void Hover(Vec2 pixel) => shell.HoverGizmo(pixel);

        sealed class Dragging(EditorShell shell, object token) : IViewportDrag
        {
            bool Live => shell._gizmo.Current == token;

            public void Move(Vec2 pixel, DragKeys keys)
            {
                if (Live)
                {
                    shell.DragGizmo(pixel, keys.Ctrl);
                }
            }

            public void End(DragKeys keys)
            {
                if (Live)
                {
                    shell.ReleaseGizmo();
                }
            }

            public void Cancel()
            {
                if (Live)
                {
                    shell.CancelGizmo();
                }
            }

            public void Lost() => End(default);
        }
    }

    // A drag of the selected entities: each step moves, turns or scales them about the pivot.
    sealed class PoseTarget(EditorShell shell, PoseEdit poseEdit, long[] pivot, Quat axes) : IGizmoTarget
    {
        public IReadOnlyList<Operation> Drag(GizmoDrag drag, Vec2 pixel, bool snap) =>
            poseEdit.Apply(drag.Update(pixel, snap ? shell.Snapping : null), pivot, axes);
    }

    /// <summary>Moves the camera so the selected entities fill the view.</summary>
    public void FrameSelected()
    {
        if (Scene == null)
        {
            return;
        }
        var entities = Selection.Entities.Select(h => ActiveSceneIdOf(h)).Select(id => Scene.Expanded.Flat.Find(id)).OfType<SceneEntity>();
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
            LeaveLook(ActiveViewport);
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

    /// <summary>Orbits the active viewport's camera by pixels of mouse movement.</summary>
    public void Orbit(double dx, double dy) => Orbit(Camera, dx, dy);

    /// <summary>Orbits a camera by pixels of mouse movement: about the selection with <see cref="OrbitSelection"/>, and otherwise about the pivot ahead.</summary>
    public void Orbit(EditorCamera camera, double dx, double dy)
    {
        if (OrbitSelection && Bounds(SelectedSceneEntities) is var (center, _))
        {
            camera.OrbitAround(center, dx, dy);
        }
        else
        {
            camera.Orbit(dx, dy);
        }
    }

    // A viewport that is not open in the game gets its camera when it opens.
    void SendCamera(EditorViewport viewport)
    {
        if (viewport.Opened != null)
        {
            Host.Send(viewport.Camera.ToMessage((uint)viewport.Index));
            SendGizmo();
        }
    }

    void SendSelection() => Host.Send(new SetSelection([.. Selection.Entities]));

    // The scene views that the game has open, which draw the editor's tools.
    IEnumerable<EditorViewport> OpenSceneViews => Viewports.Where(v => v.HasCamera && v.Opened != null);

    // Each open scene view's gizmo state when it changes: its pose follows the document, and its size the viewport's
    // camera and frame, so the gizmo is as large on screen in each. The hot part shows in all of them.
    void SendGizmo()
    {
        var pose = GizmoPose();
        foreach (var viewport in OpenSceneViews.ToList())
        {
            var index = (uint)viewport.Index;
            var state = new GizmoState(index, GizmoKind.None, [0, 0, 0], [0, 0, 0, 1], 0, GizmoPart.None, false);
            if (pose is var (pivot, axes))
            {
                var size = Gizmo.Size(viewport.Camera, viewport.Camera.RelativeTo(pivot), viewport.FrameSize.Height);
                state = new GizmoState(index, Mesh.ActiveGizmoKind, pivot, [(float)axes.X, (float)axes.Y, (float)axes.Z, (float)axes.W], (float)size, HotPart, _gizmo.IsDragging);
            }
            var key = $"{state.Kind}|{string.Join(",", state.Position)}|{string.Join(",", state.Rotation)}|{state.Size}|{state.Hot}|{state.Dragging}";
            if (key != viewport.Opened!.Gizmo && Host.Linked)
            {
                viewport.Opened = viewport.Opened with { Gizmo = key };
                Host.Send(state);
            }
        }
        SendBoxHandles();
    }

    // A new game state has no viewport open, and knows none of the tools' state, and answers none of the old state's
    // picks (see OnNewGameState). It hears of each viewport that is shown, its game size and the capture source.
    void SendViewportTools()
    {
        _picks.Clear();
        _aimingSun = false;
        foreach (var viewport in Viewports)
        {
            viewport.Opened = null;
            if (viewport.DrawSize is { } size)
            {
                OpenInGame(viewport, size);
            }
        }
        SendGameSize(resend: true);
        SendCaptureSource(resend: true);
        SendGizmo();
        SendSelection();
        Visibility.Resend();
        Mesh.ResendMeshOverlay();
        ResendNavProbe();
    }

    void OnPickResult(PickResult result)
    {
        if (_picks.TryTake(result.Id, out var then))
        {
            then(result);
        }
    }
}
