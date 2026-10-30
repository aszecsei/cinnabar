using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Tools;
using AssetKind = Cinnabar.Editor.Link.Cook.AssetKind;
using GizmoKind = Cinnabar.Editor.Link.Protocol.GizmoKind;
using GizmoPart = Cinnabar.Editor.Link.Protocol.GizmoPart;
using Wire = Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Shell;

/// <summary>What the left button does in mesh mode besides selecting: creates a primitive by a drag on the grid, or takes the points of a Cut or a Draw.</summary>
public enum MeshTool
{
    Select,
    Create,
    Cut,
    Draw,
}

/// <summary>
/// Mesh mode (see docs/editor/mesh-editing.md#mesh-mode): the editor's mode, not the game's, in which the viewport
/// selects vertices, edges and faces of the edited mesh files and the gizmo moves them. The session owns the meshes, does
/// the picking itself from the documents, the camera and the entities' poses, and tells the game what to draw over
/// them as a Mesh_Overlay.
/// </summary>
public sealed partial class MeshSession
{
    /// <summary>The context that the Mesh tab shows in.</summary>
    public const string MeshContext = "mode.mesh";

    // The edited meshes: each mesh file's GUID and the entity that places it, by scene ID.
    internal readonly Dictionary<string, ulong> _editedMeshes = [];
    MeshItem? _hovered;
    string _sentOverlay = "";
    BlockDrag? _blockDrag;

    public bool InMeshMode { get; private set; }

    /// <summary>Whether mesh mode is on and the editor is in its Edit mode.</summary>
    public bool CanEditInMeshMode => InMeshMode && _shell.IsEditing;

    public MeshElement MeshElement { get; internal set; } = MeshElement.Faces;

    public MeshSelection MeshSelection { get; internal set; } = MeshSelection.Empty;

    /// <summary>The edited mesh files, by GUID, with the scene ID of the entity that places each.</summary>
    public IReadOnlyDictionary<string, ulong> EditedMeshes => _editedMeshes;

    public double GridSize { get; private set; } = MeshGrid.DefaultSize;

    public bool ShowGrid { get; private set; } = true;

    /// <summary>Box selection takes back faces and their elements too.</summary>
    public bool SelectThrough { get; private set; }

    public MeshTool MeshTool { get; private set; } = MeshTool.Select;

    public bool IsDraggingBlock => _blockDrag != null;

    /// <summary>The mode, the element kind, the sub-selection, the grid or the tool changed.</summary>
    public event Action? MeshModeChanged;

    /// <summary>The status bar's text for the mode: "Faces: 3 of 2 meshes", and what a tool waits for.</summary>
    public string MeshStatus
    {
        get
        {
            if (!InMeshMode)
            {
                return Tools.ToolPointCount > 0 ? $"{MeshTool}: {Tools.ToolPointCount} points, Enter applies" : "";
            }
            var status = $"{MeshElement}: {MeshSelection.Count} of {_editedMeshes.Count} {(_editedMeshes.Count == 1 ? "mesh" : "meshes")}";
            if (Tools.HasPendingDistance)
            {
                status += $"  ·  {Tools.PendingLabel}: drag the gizmo";
            }
            else if (Tools.ToolPointCount > 0)
            {
                status += $"  ·  {MeshTool}: {Tools.ToolPointCount} points, Enter applies";
            }
            return status;
        }
    }

    /// <summary>Whether the selected entities place mesh files, which Edit Mesh and Tab can edit.</summary>
    public bool CanEditMesh => _shell.CanEditScene && (InMeshMode || MeshEntities(_shell.SelectedSceneEntities).Count > 0);

    // The selected entities whose Mesh_Renderer names a mesh file, with the file's GUID. A glTF mesh is not one.
    List<(SceneEntity Entity, string Guid)> MeshEntities(IEnumerable<SceneEntity> entities)
    {
        var result = new List<(SceneEntity, string)>();
        foreach (var entity in entities)
        {
            if (MeshFileOf(entity) is { } guid)
            {
                result.Add((entity, guid));
            }
        }
        return result;
    }

    /// <summary>The mesh file that an entity's Mesh_Renderer names, or null for none or for a model's mesh.</summary>
    public string? MeshFileOf(SceneEntity entity)
    {
        var renderer = entity.Components.Find(c => c.Id == SceneEdits.MeshRendererId);
        var guid = renderer?.Fields.Find(f => f.Name == "mesh")?.Value is { Kind: SceneValueKind.Asset, Asset.Length: > 0 } v ? v.Asset : null;
        if (guid == null)
        {
            return null;
        }
        // A mesh the editor made and has not saved is in the set but not yet in the index.
        if (Meshes.Find(guid) != null)
        {
            return guid;
        }
        return _shell.Assets.Find(guid) is { Kind: AssetKind.Mesh } asset && !Cinnabar.Editor.Content.AssetIndex.IsSubasset(asset) ? guid : null;
    }

    /// <summary>Enters mesh mode with the selected entities' mesh files, or says in the console why it cannot.</summary>
    public void EnterMeshMode()
    {
        if (!_shell.IsEditing || _shell.Scene == null)
        {
            return;
        }
        var selected = _shell.SelectedSceneEntities;
        var meshes = MeshEntities(selected);
        if (meshes.Count == 0)
        {
            _shell.Console.Add(LogLevel.Warning, selected.Any(e => e.Components.Any(c => c.Id == SceneEdits.MeshRendererId))
                ? "mesh: the selected mesh is a model's, which cannot be edited. Build level geometry as a .mesh file."
                : "mesh: select an entity that places a .mesh file to edit it.");
            return;
        }
        _shell.CancelGizmo();
        _editedMeshes.Clear();
        foreach (var (entity, guid) in meshes)
        {
            if (OpenMesh(guid) != null)
            {
                _editedMeshes[guid] = entity.Id;
            }
        }
        if (_editedMeshes.Count == 0)
        {
            return;
        }
        InMeshMode = true;
        MeshSelection = new MeshSelection(MeshElement, []);
        _hovered = null;
        _shell.Context.Set(MeshContext, true);
        OnMeshModeChanged();
    }

    /// <summary>Leaves mesh mode. The meshes stay open and live until they are saved and cooked.</summary>
    public void LeaveMeshMode()
    {
        if (!InMeshMode)
        {
            return;
        }
        Tools.CancelPendingDistance();
        _shell.CancelGizmo();
        CancelBlock();
        Tools.CancelToolPoints();
        InMeshMode = false;
        MeshTool = MeshTool.Select;
        MeshSelection = new MeshSelection(MeshElement, []);
        _hovered = null;
        _editedMeshes.Clear();
        _shell.Context.Set(MeshContext, false);
        OnMeshModeChanged();
    }

    /// <summary>Tab: enters mesh mode with the selected meshes, or leaves it.</summary>
    public void ToggleMeshMode()
    {
        if (InMeshMode)
        {
            LeaveMeshMode();
        }
        else
        {
            EnterMeshMode();
        }
    }

    /// <summary>Escape in mesh mode: cancels a tool that waits, clears the sub-selection, or with none, leaves the mode.</summary>
    public void EscapeMeshMode()
    {
        if (_blockDrag != null)
        {
            CancelBlock();
        }
        else if (Tools.HasPendingDistance)
        {
            Tools.CancelPendingDistance();
        }
        else if (Tools.ToolPointCount > 0)
        {
            Tools.CancelToolPoints();
        }
        else if (MeshTool != MeshTool.Select)
        {
            SetMeshTool(MeshTool.Select);
        }
        else if (!MeshSelection.IsEmpty)
        {
            SetMeshSelection(MeshSelection.Clear());
        }
        else
        {
            LeaveMeshMode();
        }
    }

    /// <summary>Enters mesh mode on the entity at a pixel, as a double click does, once the pick answers.</summary>
    public void EnterMeshModeAt(Vec2 pixel)
    {
        if (InMeshMode || !_shell.IsEditing)
        {
            return;
        }
        _shell.PickPixel(pixel, result =>
        {
            var hits = result.Hits.Where(h => _shell.Pickable(h.Entity)).ToList();
            // A double click inside an instance first selects the entity under the mouse, which a click does not.
            if (hits.Count > 0 && _shell.InstanceOf(hits[0].SceneId) is { IsInstanceRoot: false } && !_shell.Selection.Contains(hits[0].Entity))
            {
                _shell.Selection.Set([hits[0].Entity]);
                return;
            }
            if (hits.Count == 0 || _shell.Scene?.Expanded.Flat.Find(hits[0].SceneId) is not { } entity || MeshFileOf(entity) == null)
            {
                return;
            }
            _shell.Selection.Select(hits[0].Entity);
            EnterMeshMode();
        });
    }

    public void SetMeshElement(MeshElement kind)
    {
        if (!InMeshMode || kind == MeshElement)
        {
            return;
        }
        Tools.CommitPendingDistance();
        _shell.CancelGizmo();
        MeshElement = kind;
        MeshSelection = MeshSelection.As(kind, FindMeshData);
        _hovered = null;
        OnMeshModeChanged();
    }

    public void SetMeshTool(MeshTool tool)
    {
        CancelBlock();
        Tools.CancelToolPoints();
        MeshTool = tool;
        OnMeshModeChanged();
    }

    public void ToggleShowGrid()
    {
        ShowGrid = !ShowGrid;
        OnMeshModeChanged();
    }

    public void ToggleSelectThrough()
    {
        SelectThrough = !SelectThrough;
        OnMeshModeChanged();
    }

    public void FinerGrid()
    {
        GridSize = MeshGrid.Finer(GridSize);
        OnMeshModeChanged();
    }

    public void CoarserGrid()
    {
        GridSize = MeshGrid.Coarser(GridSize);
        OnMeshModeChanged();
    }

    /// <summary>Selects every element of the current kind of every edited mesh.</summary>
    public void SelectAllMeshElements()
    {
        var items = _editedMeshes.Keys.SelectMany(guid => FindMeshData(guid) is { } mesh ? MeshSelection.All(guid, mesh, MeshElement) : []);
        SetMeshSelection(MeshSelection.With(items));
    }

    /// <summary>Sets the sub-selection, converted to the current kind, or with <paramref name="switchKind"/>, switching to its kind as a tool's result does.</summary>
    public void SetMeshSelection(MeshSelection selection, bool switchKind = false)
    {
        Tools.CommitPendingDistance();
        if (switchKind)
        {
            MeshElement = selection.Kind;
        }
        else if (selection.Kind != MeshElement)
        {
            selection = selection.As(MeshElement, FindMeshData);
        }
        _shell.CancelGizmo();
        MeshSelection = selection;
        OnMeshModeChanged();
    }

    internal MeshData? FindMeshData(string guid) => Meshes.Find(guid)?.Data;

    // "3 Faces", or "1 Face", for the undo history.
    string ElementsLabel(int count) => $"{count} {(count == 1 ? MeshElement.ToString().TrimEnd('s') : MeshElement.ToString())}";

    // The placement of an edited mesh relative to the camera, from its entity's pose in the document.
    internal MeshPlacement? PlacementOf(string guid) =>
        _shell.Scene != null && _editedMeshes.TryGetValue(guid, out var id) && _shell.Scene.Expanded.Flat.Find(id) is { } entity && SceneEdits.WorldPose(_shell.Scene.Expanded.Flat, entity) is { } pose
            ? MeshPlacement.Of(pose, _shell.Camera.Position) : null;

    /// <summary>The element under a pixel in the current kind, or null: the editor's own pick, synchronous.</summary>
    public MeshItem? MeshElementAt(Vec2 pixel)
    {
        var (width, height) = _shell.FrameSize;
        var ray = _shell.Camera.Ray(pixel, width, height);
        MeshItem? best = null;
        var bestDistance = double.MaxValue;
        foreach (var guid in _editedMeshes.Keys)
        {
            if (FindMeshData(guid) is not { } mesh || PlacementOf(guid) is not { } placement)
            {
                continue;
            }
            var hit = MeshPick.Face(mesh, placement, ray, SelectThrough);
            int? index = MeshElement switch
            {
                MeshElement.Vertices => MeshPick.Vertex(mesh, placement, _shell.Camera, pixel, width, height, hit?.Distance),
                MeshElement.Edges => MeshPick.Edge(mesh, placement, _shell.Camera, pixel, width, height, hit?.Distance),
                _ => hit?.Face,
            };
            if (index is not { } i)
            {
                continue;
            }
            // Across meshes, the nearest face hit wins; an element without a face behind it counts as near.
            var distance = hit?.Distance ?? 0;
            if (distance < bestDistance)
            {
                best = new MeshItem(guid, i);
                bestDistance = distance;
            }
        }
        return best;
    }

    /// <summary>Highlights the element under the mouse. The game hears of it only when it changes.</summary>
    public void HoverMesh(Vec2 pixel)
    {
        if (!InMeshMode || _shell.Gizmos.Target is MeshDrag)
        {
            return;
        }
        Tools.HoverCut(pixel);
        var hovered = MeshElementAt(pixel);
        if (hovered != _hovered)
        {
            _hovered = hovered;
            SendMeshOverlay();
        }
    }

    /// <summary>A click in mesh mode: selects the element under it, and a click on nothing clears, unless it adds or toggles.</summary>
    public void PickMeshAt(Vec2 pixel, SelectMode mode)
    {
        var hit = MeshElementAt(pixel);
        IEnumerable<MeshItem> items = hit is { } h ? [h] : [];
        if (MeshElement == MeshElement.Faces)
        {
            // The face clicked last is the active one, which Align to Face copies from and the texture gizmo aligns to.
            Texture.ActiveFace = hit;
        }
        ApplyMeshPick(items, mode);
    }

    /// <summary>A box in mesh mode: selects the elements inside it.</summary>
    public void PickMeshBox(Vec2 a, Vec2 b, SelectMode mode)
    {
        var (width, height) = _shell.FrameSize;
        var min = new Vec2(Math.Min(a.X, b.X), Math.Min(a.Y, b.Y));
        var max = new Vec2(Math.Max(a.X, b.X), Math.Max(a.Y, b.Y));
        var items = new List<MeshItem>();
        foreach (var guid in _editedMeshes.Keys)
        {
            if (FindMeshData(guid) is { } mesh && PlacementOf(guid) is { } placement)
            {
                items.AddRange(MeshPick.InBox(mesh, placement, _shell.Camera, MeshElement, min, max, width, height, SelectThrough).Select(i => new MeshItem(guid, i)));
            }
        }
        ApplyMeshPick(items, mode);
    }

    void ApplyMeshPick(IEnumerable<MeshItem> items, SelectMode mode)
    {
        SetMeshSelection(mode switch
        {
            SelectMode.Add => MeshSelection.Add(items),
            SelectMode.Toggle => MeshSelection.Toggle(items),
            _ => MeshSelection.With(items),
        });
    }

    /// <summary>The gizmo while a distance is pending: Move, whatever the tool.</summary>
    internal GizmoKind ActiveGizmoKind => InMeshMode && (Tools.HasPendingDistance || EditPivot) ? GizmoKind.Translate : Gizmo.KindOf(_shell.Tool);

    /// <summary>The gizmo's pivot and axes in mesh mode: the selected vertices' centroid, with the primary mesh's axes in local space.</summary>
    internal (long[] Pivot, Quat Axes)? MeshGizmoPose()
    {
        if (PivotGizmoPose() is { } pivotPose)
        {
            return pivotPose;
        }
        if (!InMeshMode || ActiveGizmoKind == GizmoKind.None || _shell.Scene == null || MeshSelection.IsEmpty)
        {
            return null;
        }
        var sum = Vec3.Zero;
        var count = 0;
        var origin = _shell.Camera.Position;
        Quat? primary = null;
        foreach (var guid in MeshSelection.Guids)
        {
            if (FindMeshData(guid) is not { } mesh || PlacementOf(guid) is not { } placement)
            {
                continue;
            }
            primary ??= placement.Rotation;
            foreach (var v in MeshSelection.VerticesOf(mesh, MeshSelection.Of(guid)))
            {
                sum += placement.ToView(mesh.Vertices[v]);
                count++;
            }
        }
        if (count == 0)
        {
            return null;
        }
        if (!Tools.HasPendingDistance && Texture.TextureGizmoAxes() is { } textureAxes)
        {
            return ((sum / count).Offset(origin), textureAxes);
        }
        var local = !Tools.HasPendingDistance && (_shell.Space == Space.Local || _shell.Tool == Tool.Scale);
        return ((sum / count).Offset(origin), local ? primary ?? Quat.Identity : Quat.Identity);
    }

    // The grid's plane: through the sub-selection's centroid, the selected entity or the camera's pivot, facing the
    // camera's nearest world axis.
    internal (long[] Origin, int Axis) GridPlane()
    {
        long[] origin = MeshGizmoPose()?.Pivot ?? (_shell.SelectedSceneEntity is { } entity && _shell.Scene != null && SceneEdits.WorldPose(_shell.Scene.Expanded.Flat, entity) is { } pose ? pose.Position : _shell.Camera.Pivot);
        return (SnapRaw(origin), MeshGrid.NearestAxis(_shell.Camera.Forward));
    }

    /// <summary>A raw World_Position rounded to the grid, in raw units, which the grid's sizes divide exactly.</summary>
    long[] SnapRaw(long[] position)
    {
        var step = (long)Math.Round(GridSize * Pose.Unit);
        return [.. position.Select(p => (long)Math.Round((double)p / step) * step)];
    }

    /// <summary>A position in meters relative to the camera, snapped to the world's grid, as a raw World_Position.</summary>
    internal long[] SnapToGrid(Vec3 relative)
    {
        // Snapping happens near a grid point, in small doubles, since world positions are too large for them.
        var anchor = SnapRaw(relative.Offset(_shell.Camera.Position));
        var local = relative + Vec3.Between(anchor, _shell.Camera.Position);
        return MeshGrid.Snap(local, GridSize).Offset(anchor);
    }

    internal bool PressMeshGizmo(Vec2 pixel, bool extrude)
    {
        // Shift at the start of a Move drag extrudes first, as in Hammer; the drag then sets the distance.
        if (extrude && !Tools.HasPendingDistance && _shell.Tool == Tool.Move && MeshElement != MeshElement.Vertices)
        {
            Tools.Extrude();
            _shell.HoverGizmo(pixel);
        }
        if (MeshGizmoPose() is not var (pivot, axes) || _shell.Scene == null)
        {
            return false;
        }
        var (width, height) = _shell.FrameSize;
        if (Tools.HasPendingDistance)
        {
            if (_shell.HotPart == GizmoPart.None)
            {
                return false;
            }
            _shell.Gizmos.Start(new GizmoDrag(GizmoKind.Translate, _shell.HotPart, _shell.Camera, _shell.Camera.RelativeTo(pivot), axes, pixel, width, height), new MeshToolRunner.DistanceDrag(Tools, this), null);
            return true;
        }
        if (EditPivot)
        {
            return PressPivotGizmo(pixel, pivot);
        }
        if (Texture.TextureGizmo && MeshElement == MeshElement.Faces)
        {
            // Transform Texture: the drag moves, turns or scales the selected faces' textures about the pivot.
            var textureDrag = new TextureMapper.TextureDrag(this, pivot);
            if (textureDrag.IsEmpty)
            {
                return false;
            }
            _shell.Gizmos.Start(new GizmoDrag(Gizmo.KindOf(_shell.Tool), _shell.HotPart, _shell.Camera, _shell.Camera.RelativeTo(pivot), axes, pixel, width, height), textureDrag,
                $"{_shell.Tool switch { Tool.Rotate => "Rotate", Tool.Scale => "Scale", _ => "Shift" }} Texture");
            return true;
        }
        var drag = new MeshDrag(this, pivot, axes);
        if (drag.IsEmpty)
        {
            return false;
        }
        var verb = _shell.Tool switch { Tool.Rotate => "Rotate", Tool.Scale => "Scale", _ => "Move" };
        _shell.Gizmos.Start(new GizmoDrag(Gizmo.KindOf(_shell.Tool), _shell.HotPart, _shell.Camera, _shell.Camera.RelativeTo(pivot), axes, pixel, width, height), drag,
            $"{verb} {ElementsLabel(MeshSelection.Count)}");
        return true;
    }

    /// <summary>Deletes the selected elements of each edited mesh, as one undo entry.</summary>
    public void DeleteMeshSelection()
    {
        if (!InMeshMode || MeshSelection.IsEmpty || _shell.Scene == null)
        {
            return;
        }
        var ops = new List<Operation>();
        foreach (var guid in MeshSelection.Guids)
        {
            if (FindMeshData(guid) is { } mesh)
            {
                ops.Add(new MeshOperation(guid, mesh, MeshTools.Delete(mesh, MeshElement, MeshSelection.Of(guid)), Meshes));
            }
        }
        if (_shell.Edit($"Delete {ElementsLabel(MeshSelection.Count)}", [.. ops]))
        {
            SetMeshSelection(MeshSelection.Clear());
        }
    }

    /// <summary>Starts a primitive: a drag on the grid plane from a pixel, which becomes its footprint.</summary>
    public bool BeginBlock(Vec2 pixel)
    {
        if (!_shell.IsEditing || _shell.Scene == null || MeshTool != MeshTool.Create)
        {
            return false;
        }
        Tools.CommitPendingDistance();
        var (origin, axis) = GridPlane();
        if (PointOnGrid(pixel, origin, axis) is not { } start)
        {
            return false;
        }
        _blockDrag = new BlockDrag(origin, axis, start, start);
        OnMeshModeChanged();
        return true;
    }

    public void DragBlock(Vec2 pixel)
    {
        if (_blockDrag is not { } drag || PointOnGrid(pixel, drag.Origin, drag.Axis) is not { } corner)
        {
            return;
        }
        _blockDrag = drag with { Corner = corner };
        OnMeshModeChanged();
    }

    /// <summary>Ends a Block drag: a new mesh and entity with the footprint, a grid cell high, or faces of the primary edited mesh.</summary>
    public void EndBlock(bool forceEntity = false)
    {
        if (_blockDrag is not { } drag)
        {
            return;
        }
        _blockDrag = null;
        var size = Vec3.Between(drag.Start, drag.Corner);
        if (size.Length < GridSize * 0.5)
        {
            OnMeshModeChanged();
            return;
        }
        // The block's height is a grid cell along the plane's axis, from the plane.
        var up = MeshGrid.AxisVector(drag.Axis) * GridSize;
        var min = new Vec3(Math.Min(size.X, 0), Math.Min(size.Y, 0), Math.Min(size.Z, 0));
        var max = new Vec3(Math.Max(size.X, 0), Math.Max(size.Y, 0), Math.Max(size.Z, 0)) + up;
        var corner = min.Offset(drag.Start);
        var primary = InMeshMode && !forceEntity ? _editedMeshes.Keys.FirstOrDefault(g => FindMeshData(g) != null && PlacementOf(g) != null) : null;
        Tools.MakePrimitive(corner, max - min, drag.Axis, primary);
    }

    public void CancelBlock()
    {
        if (_blockDrag != null)
        {
            _blockDrag = null;
            OnMeshModeChanged();
        }
    }

    /// <summary>The block being dragged: its footprint's corners as raw positions, or null.</summary>
    public (long[] Start, long[] Corner)? BlockFootprint => _blockDrag is { } d ? (d.Start, d.Corner) : null;

    internal long[]? PointOnGrid(Vec2 pixel, long[] origin, int axis)
    {
        var (width, height) = _shell.FrameSize;
        var ray = _shell.Camera.Ray(pixel, width, height);
        if (MeshGrid.HitPlane(_shell.Camera.RelativeTo(origin), MeshGrid.AxisVector(axis), ray) is not { } hit)
        {
            return null;
        }
        return SnapToGrid(hit);
    }

    // A name that no entity of the scene and no open mesh has: block, block_2 and on.
    internal string NewMeshName(string stem)
    {
        for (var n = 1; ; n++)
        {
            var name = n == 1 ? stem : $"{stem}_{n}";
            if (_shell.Scene!.Expanded.Flat.Entities.All(e => e.Name != name) && Meshes.Documents.All(d => Path.GetFileNameWithoutExtension(d.Path) != name))
            {
                return name;
            }
        }
    }

    internal void OnMeshModeChanged()
    {
        Tools.ForgetStalePrimitive();
        _shell.Commands.InvalidateAll();
        _shell.SendGizmo();
        SendMeshOverlay();
        MeshModeChanged?.Invoke();
    }

    // The overlay as the game draws it, sent when it changes: the mode's kind, each edited mesh's selected and hovered
    // elements, and the grid.
    internal void SendMeshOverlay()
    {
        var message = new Wire.MeshOverlay(false, Wire.MeshElement.Faces, [], false, 0, [0, 0, 0], 0);
        if (CanEditInMeshMode)
        {
            var meshes = new List<Wire.MeshOverlayMesh>();
            foreach (var (guid, sceneId) in _editedMeshes)
            {
                if (FindMeshData(guid) is not { } mesh)
                {
                    continue;
                }
                var handle = _shell.World.FindScene(sceneId)?.Handle ?? 0;
                var selected = MeshSelection.Of(guid).ToList();
                var hovered = _hovered is { } h && h.Guid == guid ? h.Index : -1;
                var edges = MeshElement == MeshElement.Edges ? selected.Where(e => e < mesh.Edges.Length).Select(e => new Wire.LiveEdge((uint)mesh.Edges[e].A, (uint)mesh.Edges[e].B)).ToArray() : [];
                var hoveredEdge = MeshElement == MeshElement.Edges && hovered >= 0 && hovered < mesh.Edges.Length ? mesh.Edges[hovered] : (MeshEdge?)null;
                meshes.Add(new Wire.MeshOverlayMesh(
                    Convert.FromHexString(guid),
                    handle,
                    MeshElement == MeshElement.Vertices ? [.. selected.Select(v => (uint)v)] : [],
                    edges,
                    MeshElement == MeshElement.Faces ? [.. selected.Select(f => (uint)f)] : [],
                    MeshElement == MeshElement.Vertices ? hovered : -1,
                    hoveredEdge is { } he ? new Wire.LiveEdge((uint)he.A, (uint)he.B) : new Wire.LiveEdge(0, 0),
                    hoveredEdge != null,
                    MeshElement == MeshElement.Faces ? hovered : -1,
                    Tools.ToolMarks(guid, mesh)));
            }
            var (origin, axis) = GridPlane();
            message = new Wire.MeshOverlay(true, (Wire.MeshElement)MeshElement, [.. meshes], ShowGrid, (float)GridSize, origin, (byte)axis);
        }
        var key = $"{message.Active}|{message.Element}|{message.Grid}|{message.GridSize}|{string.Join(",", message.GridOrigin)}|{message.GridAxis}|"
            + string.Join(";", message.Meshes.Select(m => $"{Convert.ToHexStringLower(m.Guid)}:{m.Entity}:{string.Join(",", m.SelectedVertices)}:{string.Join(",", m.SelectedEdges.Select(e => $"{e.A}-{e.B}"))}:{string.Join(",", m.SelectedFaces)}:{m.HoveredVertex}:{m.HasHoveredEdge}:{m.HoveredEdge.A}-{m.HoveredEdge.B}:{m.HoveredFace}:{string.Join(",", m.Marks)}"));
        if (key != _sentOverlay && _shell.Host.Linked)
        {
            _sentOverlay = key;
            _shell.Host.Send(message);
        }
    }

    // After a resync, the game has no overlay.
    internal void ResendMeshOverlay()
    {
        _sentOverlay = "";
        SendMeshOverlay();
    }

    /// <summary>The project's default mesh material, for new faces: <c>mesh.default_material</c>, or the engine's dev_gray.</summary>
    public string DefaultMeshMaterial =>
        ProjectSettings.Get(_shell.ProjectPath, "mesh.default_material") is { Length: 32 } guid && guid.All(Uri.IsHexDigit) ? guid.ToLowerInvariant() : DevGrayMaterial;

    /// <summary>The engine's dev_gray material instance (see docs/editor/mesh-editing.md#dev-materials).</summary>
    public const string DevGrayMaterial = "5a1c3e7f9b2d4f608a1c3e5f7a9b0c2d";

    // The dragged block's footprint: the grid plane and the two snapped corners.
    readonly record struct BlockDrag(long[] Origin, int Axis, long[] Start, long[] Corner);

    /// <summary>
    /// A gizmo drag of the sub-selection: the selected vertices of each edited mesh from the start of the drag, which
    /// each step moves, turns or scales about the pivot, in world space, and puts back into the mesh's space.
    /// </summary>
    sealed class MeshDrag : IGizmoTarget
    {
        readonly MeshSession _session;
        readonly long[] _pivot;
        readonly Quat _axes;
        readonly List<(string Guid, MeshData Start, List<int> Vertices, MeshPlacement Placement)> _meshes = [];

        public MeshDrag(MeshSession session, long[] pivot, Quat axes)
        {
            (_session, _pivot, _axes) = (session, pivot, axes);
            foreach (var guid in session.MeshSelection.Guids)
            {
                if (session.FindMeshData(guid) is { } mesh && session.PlacementOf(guid) is { } placement)
                {
                    var vertices = session.MeshSelection.VerticesOf(mesh, session.MeshSelection.Of(guid)).ToList();
                    if (vertices.Count > 0)
                    {
                        _meshes.Add((guid, mesh, vertices, placement));
                    }
                }
            }
        }

        public bool IsEmpty => _meshes.Count == 0;

        // A move snaps each vertex's world position to the grid, not the drag's delta; turns and scales snap as the
        // entity gizmo's do.
        public IReadOnlyList<Operation> Drag(GizmoDrag drag, Vec2 pixel, bool snap)
        {
            var move = _session.Shell.Tool == Tool.Move;
            return Apply(drag.Update(pixel, snap && !move ? _session.Shell.Snapping : null), snap && move);
        }

        public List<Operation> Apply(GizmoChange change, bool snapToGrid)
        {
            var ops = new List<Operation>();
            var pivot = _session.Shell.Camera.RelativeTo(_pivot);
            foreach (var (guid, start, vertices, placement) in _meshes)
            {
                var after = MeshTools.MoveVertices(start, vertices, v =>
                {
                    var offset = placement.ToView(v) - pivot;
                    var moved = offset;
                    if (change.Rotation != Quat.Identity)
                    {
                        moved = Vec3.From(change.Rotation.Rotate(moved.ToArray()));
                    }
                    if (change.Scale != new Vec3(1, 1, 1))
                    {
                        var local = Vec3.From(_axes.Conjugate.Rotate(moved.ToArray()));
                        moved = Vec3.From(_axes.Rotate(Vec3.Scale(local, change.Scale).ToArray()));
                    }
                    var world = pivot + moved + change.Translation;
                    if (snapToGrid)
                    {
                        world = _session.Shell.Camera.RelativeTo(_session.SnapToGrid(world));
                    }
                    return placement.ToLocal(world);
                });
                if (_session.KeepPlanar)
                {
                    after = MeshTools.KeepPlanar(after, vertices);
                }
                ops.Add(new MeshOperation(guid, _session.FindMeshData(guid) ?? start, after, _session.Meshes));
            }
            return ops;
        }
    }
}

/// <summary>
/// Adds a new mesh document to the set, as Block does for a new mesh, on the scene's undo stack beside the entity
/// that places it. Undo removes the document; a file it was saved to meanwhile stays, unreferenced.
/// </summary>
public sealed record CreateMesh(MeshDocument Document, MeshSet Meshes) : Operation(0)
{
    public override Operation Apply(Scene scene)
    {
        Meshes.Add(Document);
        return new RemoveMesh(Document, Meshes);
    }

    public override Wire.Operation? ToWire() => null;
}

public sealed record RemoveMesh(MeshDocument Document, MeshSet Meshes) : Operation(0)
{
    public override Operation Apply(Scene scene)
    {
        Meshes.Remove(Document.Guid);
        return new CreateMesh(Document, Meshes);
    }

    public override Wire.Operation? ToWire() => null;
}
