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
/// What the game draws over the edited meshes: the overlay sent when the mode, the selection or the hover changes.
/// </summary>
public sealed partial class MeshSession
{
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
}
