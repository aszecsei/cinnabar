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
    // What the mouse is over in mesh mode: an element of an edited mesh, with its index in the mesh that draws, or a
    // face that a cutter made on a cut wall, which cannot be selected.
    abstract record MeshHover
    {
        public sealed record Element(MeshItem Item, int Drawn) : MeshHover;

        public sealed record CutFace(string Cutter) : MeshHover;
    }

    // The mesh that draws an edited mesh: a cut wall's result, with its map onto the source, while the map is of the
    // source as it is now. Else the edited mesh itself, as for a refused cut or a drag's step that is not cut yet.
    (string Guid, MeshData Mesh, CutMap? Map) Drawn(string guid)
    {
        if (_shell.Scene is { } scene && _editedMeshes.TryGetValue(guid, out var id) && _shell.Cuts.MapOf(scene, id) is { } cut)
        {
            return (cut.Result, cut.Map.Result, cut.Map);
        }
        return (guid, FindMeshData(guid) ?? MeshData.Empty, null);
    }

    /// <summary>The element under a pixel in the current kind, or null: the editor's own pick, synchronous.</summary>
    public MeshItem? MeshElementAt(Vec2 pixel) => HitAt(pixel) is MeshHover.Element e ? e.Item : null;

    // What is under a pixel. On a cut wall the result is picked, and its element is mapped onto the source. A face that a
    // cutter made, or a vertex or an edge that the cut made, is no element of the source.
    MeshHover? HitAt(Vec2 pixel)
    {
        var (width, height) = _shell.FrameSize;
        var ray = _shell.Camera.Ray(pixel, width, height);
        MeshHover? best = null;
        var bestDistance = double.MaxValue;
        foreach (var guid in _editedMeshes.Keys)
        {
            if (FindMeshData(guid) == null || PlacementOf(guid) is not { } placement)
            {
                continue;
            }
            var (_, mesh, map) = Drawn(guid);
            var hit = MeshPick.Face(mesh, placement, ray, SelectThrough);
            int? index = MeshElement switch
            {
                MeshElement.Vertices => MeshPick.Vertex(mesh, placement, _shell.Camera, pixel, width, height, hit?.Distance),
                MeshElement.Edges => MeshPick.Edge(mesh, placement, _shell.Camera, pixel, width, height, hit?.Distance),
                _ => hit?.Face,
            };
            MeshHover? found = null;
            if (map != null && MeshElement == MeshElement.Faces && hit is { } h && map.Cutter(h.Face) is { } cutter)
            {
                found = new MeshHover.CutFace(cutter);
            }
            else if (index is { } i && (map == null ? i : map.SourceOf(MeshElement, i)) is { } source)
            {
                found = new MeshHover.Element(new MeshItem(guid, source), i);
            }
            if (found == null)
            {
                continue;
            }
            // Across meshes, the nearest face hit wins; an element without a face behind it counts as near.
            var distance = hit?.Distance ?? 0;
            if (distance < bestDistance)
            {
                best = found;
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
        var hovered = HitAt(pixel);
        if (hovered == _hover)
        {
            return;
        }
        // The status bar says which cutter made a face under the mouse.
        var status = _hover is MeshHover.CutFace || hovered is MeshHover.CutFace;
        _hover = hovered;
        SendMeshOverlay();
        if (status)
        {
            MeshModeChanged?.Invoke();
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
            if (FindMeshData(guid) != null && PlacementOf(guid) is { } placement)
            {
                var (_, mesh, map) = Drawn(guid);
                var picked = MeshPick.InBox(mesh, placement, _shell.Camera, MeshElement, min, max, width, height, SelectThrough);
                var sources = map == null ? picked : picked.Select(i => map.SourceOf(MeshElement, i)).OfType<int>().Distinct();
                items.AddRange(sources.Select(i => new MeshItem(guid, i)));
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
