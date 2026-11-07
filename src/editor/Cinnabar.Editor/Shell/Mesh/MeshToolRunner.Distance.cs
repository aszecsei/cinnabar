using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Tools;
using GizmoKind = Cinnabar.Editor.Link.Protocol.GizmoKind;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The mesh tools that take a distance: the tool that opens the undo entry and waits, the commit and the cancel, the gizmo drag
/// that sets the distance, and the tools that run through it.
/// </summary>
public sealed partial class MeshToolRunner
{
    /// <summary>
    /// Runs a tool that takes a distance: it opens the undo entry and waits for a drag of the gizmo, whose steps run
    /// the tool at the distance along the selection's normal, or by the drag's length for a width. Until the drag,
    /// nothing changes, and an entry without a drag leaves no history.
    /// </summary>
    public bool BeginDistanceTool(string label, Func<MeshData, IEnumerable<int>, double, ToolResult> run, bool magnitude = false, MeshElement? requires = null)
    {
        CommitPendingDistance();
        if (!CanRunMeshTool(requires) || _shell.Scene == null || _shell.OpenEdit != null)
        {
            return false;
        }
        var meshes = new Dictionary<string, (MeshData, IReadOnlyList<int>)>();
        var axis = Vec3.Zero;
        foreach (var guid in _session.MeshSelection.Guids)
        {
            if (_session.FindMeshData(guid) is not { } mesh || _session.PlacementOf(guid) is not { } placement)
            {
                continue;
            }
            var selected = _session.MeshSelection.Of(guid).ToList();
            meshes[guid] = (mesh, selected);
            foreach (var v in _session.MeshSelection.VerticesOf(mesh, selected))
            {
                foreach (var f in mesh.FacesOfVertex(v))
                {
                    axis += placement.NormalToView(mesh.FaceNormal(f));
                }
            }
        }
        if (meshes.Count == 0)
        {
            return false;
        }
        axis = axis.Length > 1e-9 ? axis.Normalized() : Vec3.UnitY;
        if (_shell.TryBeginEdit(label, "a mesh tool") is not { } edit)
        {
            return false;
        }
        var pending = new PendingDistance(edit, axis, magnitude, meshes, run);
        edit.Ended += committed => OnPendingEnded(pending, committed);
        _pending = pending;
        _session.OnMeshModeChanged();
        _shell.Console.Add(LogLevel.Info, $"mesh: {label.ToLowerInvariant()}: drag the gizmo for the {(magnitude ? "width" : "distance")}, or Escape");
        return true;
    }

    /// <summary>
    /// Ends a pending distance tool as it is: with its drag's last distance, or with no entry when nothing was dragged.
    /// A drag of its distance that is under way ends with it.
    /// </summary>
    public void CommitPendingDistance() => _pending?.Edit.Commit();

    /// <summary>Cancels a pending distance tool: the mesh is as before it.</summary>
    public void CancelPendingDistance() => _pending?.Edit.Cancel();

    // The pending tool's entry ended, by the tool, by the gizmo drag that set its distance, or by the shell.
    void OnPendingEnded(PendingDistance pending, bool committed)
    {
        if (_pending != pending)
        {
            return;
        }
        _pending = null;
        if (!committed)
        {
            _session.PruneMeshSelection();
            _shell.SendGizmo();
        }
        _session.OnMeshModeChanged();
    }

    // A gizmo drag with a distance pending: each step runs the tool at the change along the axis, or its length, on
    // every mesh, replacing the step before. Releasing commits the tool's entry, and Escape cancels it.
    internal sealed class DistanceDrag(MeshToolRunner tools, MeshSession session) : IGizmoTarget
    {
        MeshElement? _kind;
        List<MeshItem> _items = [];

        public IReadOnlyList<Operation> Drag(GizmoDrag drag, Vec2 pixel, bool snap)
        {
            if (tools._pending is not { } pending)
            {
                return [];
            }
            var change = drag.Update(pixel, null);
            var distance = pending.Magnitude ? change.Translation.Length : Vec3.Dot(change.Translation, pending.Axis);
            if (snap)
            {
                distance = Math.Round(distance / session.GridSize) * session.GridSize;
            }
            var ops = new List<Operation>();
            (_kind, _items) = (null, []);
            foreach (var (guid, (start, selected)) in pending.Meshes)
            {
                var result = pending.Run(start, selected, distance);
                ops.Add(new MeshOperation(guid, session.FindMeshData(guid) ?? start, result.Mesh, session.Meshes));
                _kind = result.Kind;
                _items.AddRange(result.Selected.Select(i => new MeshItem(guid, i)));
            }
            return ops;
        }

        public void Previewed()
        {
            session.PreviewMeshSelection(_kind, _items);
        }
    }
}
