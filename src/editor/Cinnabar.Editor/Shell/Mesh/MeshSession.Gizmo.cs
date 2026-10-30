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

/// <summary>
/// The gizmo in mesh mode: its kind, its pose and the grid it snaps to, the press that starts a drag of the sub-selection, and that drag.
/// </summary>
public sealed partial class MeshSession
{
    /// <summary>The gizmo while a distance is pending: Move, whatever the tool.</summary>
    internal GizmoKind ActiveGizmoKind => InMeshMode && (Tools.HasPendingDistance || Pivot.EditPivot) ? GizmoKind.Translate : Gizmo.KindOf(_shell.Tool);

    /// <summary>The gizmo's pivot and axes in mesh mode: the selected vertices' centroid, with the primary mesh's axes in local space.</summary>
    internal (long[] Pivot, Quat Axes)? MeshGizmoPose()
    {
        if (Pivot.PivotGizmoPose() is { } pivotPose)
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
        if (Pivot.EditPivot)
        {
            return Pivot.PressPivotGizmo(pixel, pivot);
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
                if (_session.Pivot.KeepPlanar)
                {
                    after = MeshTools.KeepPlanar(after, vertices);
                }
                ops.Add(new MeshOperation(guid, _session.FindMeshData(guid) ?? start, after, _session.Meshes));
            }
            return ops;
        }
    }
}
