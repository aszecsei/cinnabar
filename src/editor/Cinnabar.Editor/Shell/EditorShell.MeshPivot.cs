using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// Keep Planar, Select Linked, Grow and Shrink, and Edit Pivot (see docs/editor/mesh-editing.md#mesh-mode), which
/// moves an entity's Transform and every vertex of its mesh by the inverse, so the geometry stays where it is.
/// </summary>
public sealed partial class EditorShell
{
    /// <summary>A Move drag keeps the faces that it would bend planar, by moving their other vertices.</summary>
    public bool KeepPlanar { get; private set; }

    /// <summary>The gizmo moves the edited mesh's pivot: its entity's Transform, with the vertices moved the other way.</summary>
    public bool EditPivot { get; private set; }

    public void ToggleKeepPlanar()
    {
        KeepPlanar = !KeepPlanar;
        OnMeshModeChanged();
    }

    public void ToggleEditPivot()
    {
        EditPivot = !EditPivot;
        CancelGizmo();
        OnMeshModeChanged();
    }

    /// <summary>Select Linked: everything the selected elements reach through their neighbors.</summary>
    public void SelectLinked() => SetMeshSelection(MeshSelection.Linked(FindMeshData));

    /// <summary>Grow: the selection and its neighbors.</summary>
    public void GrowSelection() => SetMeshSelection(MeshSelection.Grown(FindMeshData));

    /// <summary>Shrink: the selection without its boundary.</summary>
    public void ShrinkSelection() => SetMeshSelection(MeshSelection.Shrunk(FindMeshData));

    /// <summary>The edited mesh whose pivot Edit Pivot moves: the selected entity's, else the first edited.</summary>
    public (string Guid, ulong Entity)? PivotMesh()
    {
        if (!InMeshMode)
        {
            return null;
        }
        if (SelectedSceneEntity is { } selected && _editedMeshes.FirstOrDefault(m => m.Value == selected.Id) is { Key: not null } own)
        {
            return (own.Key, own.Value);
        }
        return _editedMeshes.Count > 0 ? (_editedMeshes.First().Key, _editedMeshes.First().Value) : null;
    }

    // The pivot gizmo's pose: the entity's world position with the world's axes.
    (long[] Pivot, Quat Axes)? PivotGizmoPose() =>
        EditPivot && _pending == null && PivotMesh() is var (_, entity) && Scene?.Expanded.Flat.Find(entity) is { } document && SceneEdits.WorldPose(Scene.Expanded.Flat, document) is { } pose
            ? (pose.Position, Quat.Identity) : null;

    bool PressPivotGizmo(Vec2 pixel, long[] pivot)
    {
        if (PivotMesh() is not var (guid, entity) || FindMeshData(guid) is not { } mesh || PlacementOf(guid) is not { } placement || Scene == null)
        {
            return false;
        }
        var poseEdit = new PoseEdit(Scene.Expanded.Flat, [entity]);
        if (poseEdit.IsEmpty)
        {
            return false;
        }
        var (width, height) = FrameSize;
        _gizmo.Start(new GizmoDrag(Link.Protocol.GizmoKind.Translate, HotPart, Camera, Camera.RelativeTo(pivot), Quat.Identity, pixel, width, height),
            new PivotDrag(this, poseEdit, pivot, guid, mesh, placement), "Edit Pivot");
        return true;
    }

    // An Edit Pivot drag: the mesh being moved under its entity, from the start of the drag.
    sealed class PivotDrag(EditorShell shell, PoseEdit poseEdit, long[] rawPivot, string guid, MeshData start, MeshPlacement placement) : IGizmoTarget
    {
        readonly Vec3 _pivot = shell.Camera.RelativeTo(rawPivot);

        public IReadOnlyList<Operation> Drag(GizmoDrag drag, Vec2 pixel, bool snap)
        {
            var translation = drag.Update(pixel, null).Translation;
            if (snap)
            {
                // The pivot lands on the grid, not the drag's delta.
                translation = shell.Camera.RelativeTo(shell.SnapToGrid(_pivot + translation)) - _pivot;
            }
            return shell.PivotOperations(poseEdit, rawPivot, guid, start, placement, _pivot, translation);
        }
    }

    // The entity moved by a translation in view space, and the vertices moved by its inverse in the mesh's space.
    List<Operation> PivotOperations(PoseEdit poseEdit, long[] rawPivot, string guid, MeshData start, MeshPlacement placement, Vec3 pivot, Vec3 translation)
    {
        var ops = poseEdit.Apply(new GizmoChange(translation, Quat.Identity, new Vec3(1, 1, 1)), rawPivot, Quat.Identity);
        var local = placement.ToLocal(pivot + translation) - placement.ToLocal(pivot);
        var after = start.With(vertices: start.Vertices.Select(v => v - local));
        ops.Add(new MeshOperation(guid, FindMeshData(guid) ?? start, after, Meshes));
        return ops;
    }

    /// <summary>Center Pivot: puts the entity at its mesh's bounds' center, with the geometry where it is.</summary>
    public bool CenterPivot() => MovePivot("Center Pivot", (mesh, placement, pivot) =>
    {
        if (mesh.Vertices.Length == 0)
        {
            return Vec3.Zero;
        }
        var min = new Vec3(mesh.Vertices.Min(v => v.X), mesh.Vertices.Min(v => v.Y), mesh.Vertices.Min(v => v.Z));
        var max = new Vec3(mesh.Vertices.Max(v => v.X), mesh.Vertices.Max(v => v.Y), mesh.Vertices.Max(v => v.Z));
        return placement.ToView((min + max) / 2) - pivot;
    });

    /// <summary>Pivot to Grid: snaps the entity's position to the grid, with the geometry where it is.</summary>
    public bool PivotToGrid() => MovePivot("Pivot to Grid", (_, _, pivot) => Camera.RelativeTo(SnapToGrid(pivot)) - pivot);

    // Moves the pivot mesh's entity by a translation in view space, as one undo entry.
    bool MovePivot(string label, Func<MeshData, MeshPlacement, Vec3, Vec3> translation)
    {
        CommitPendingDistance();
        if (PivotMesh() is not var (guid, entity) || FindMeshData(guid) is not { } mesh || PlacementOf(guid) is not { } placement || Scene is not { InTransaction: false }
            || Scene.Expanded.Flat.Find(entity) is not { } document || SceneEdits.WorldPose(Scene.Expanded.Flat, document) is not { } pose)
        {
            return false;
        }
        var pivot = Camera.RelativeTo(pose.Position);
        var t = translation(mesh, placement, pivot);
        if (t.Length < 1e-9)
        {
            Console.Add(LogLevel.Info, $"mesh: {label.ToLowerInvariant()} changed nothing");
            return false;
        }
        var ops = PivotOperations(new PoseEdit(Scene.Expanded.Flat, [entity]), pose.Position, guid, mesh, placement, pivot, t);
        return Edit(label, [.. ops]);
    }
}
