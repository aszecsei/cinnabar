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
/// Picking in mesh mode: the element under the mouse, the hover, and the click and box picks that select.
/// </summary>
public sealed partial class MeshSession
{
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
}
