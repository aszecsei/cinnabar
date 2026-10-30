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
    readonly Dictionary<string, ulong> _editedMeshes = [];
    MeshItem? _hovered;
    string _sentOverlay = "";
    BlockDrag? _blockDrag;

    public bool InMeshMode { get; private set; }

    /// <summary>Whether mesh mode is on and the editor is in its Edit mode.</summary>
    public bool CanEditInMeshMode => InMeshMode && _shell.IsEditing;

    public MeshElement MeshElement { get; private set; } = MeshElement.Faces;

    public MeshSelection MeshSelection { get; private set; } = MeshSelection.Empty;

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

    /// <summary>Drops the selected elements that the meshes no longer have, without sending anything.</summary>
    internal void PruneMeshSelection() => MeshSelection = MeshSelection.Pruned(FindMeshData);

    /// <summary>Selects a tool step's result, in its kind if it has one, and sends the overlay.</summary>
    internal void PreviewMeshSelection(MeshElement? kind, IEnumerable<MeshItem> items)
    {
        MeshElement = kind ?? MeshElement;
        MeshSelection = new MeshSelection(MeshElement, [.. items]);
        SendMeshOverlay();
    }

    /// <summary>Adds a mesh file that a tool made to the edited meshes, with the entity that places it.</summary>
    internal void AddEditedMesh(string guid, ulong sceneId) => _editedMeshes[guid] = sceneId;

    /// <summary>Select Linked: everything the selected elements reach through their neighbors.</summary>
    public void SelectLinked() => SetMeshSelection(MeshSelection.Linked(FindMeshData));

    /// <summary>Grow: the selection and its neighbors.</summary>
    public void GrowSelection() => SetMeshSelection(MeshSelection.Grown(FindMeshData));

    /// <summary>Shrink: the selection without its boundary.</summary>
    public void ShrinkSelection() => SetMeshSelection(MeshSelection.Shrunk(FindMeshData));

    internal MeshData? FindMeshData(string guid) => Meshes.Find(guid)?.Data;

    // "3 Faces", or "1 Face", for the undo history.
    string ElementsLabel(int count) => $"{count} {(count == 1 ? MeshElement.ToString().TrimEnd('s') : MeshElement.ToString())}";

    // The placement of an edited mesh relative to the camera, from its entity's pose in the document.
    internal MeshPlacement? PlacementOf(string guid) =>
        _shell.Scene != null && _editedMeshes.TryGetValue(guid, out var id) && _shell.Scene.Expanded.Flat.Find(id) is { } entity && SceneEdits.WorldPose(_shell.Scene.Expanded.Flat, entity) is { } pose
            ? MeshPlacement.Of(pose, _shell.Camera.Position) : null;

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
}
