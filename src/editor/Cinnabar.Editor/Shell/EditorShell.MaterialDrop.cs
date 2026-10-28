using Cinnabar.Editor.Document;
using Cinnabar.Editor.Panels;
using AssetKind = Cinnabar.Editor.Link.Cook.AssetKind;
using PickResult = Cinnabar.Editor.Link.Protocol.PickResult;

namespace Cinnabar.Editor.Shell;

/// <summary>A material slot of a scene entity's Mesh_Renderer: the one that a material dropped in the viewport sets.</summary>
public sealed record MaterialTarget(ulong SceneId, int Slot);

/// <summary>
/// Dropping a material from the content browser onto an entity in the viewport (see docs/editor/viewport.md#viewport): the
/// material shows on the submesh under the mouse while the drag is over it, as an open undo entry, and the drop
/// commits it.
/// </summary>
public sealed partial class EditorShell
{
    /// <summary>A Mesh_Renderer's material slots, one for each of its mesh's first submeshes (MAX_MATERIAL_SLOTS).</summary>
    public const int MaterialSlots = 8;

    MaterialTarget? _materialTarget;

    /// <summary>Whether an asset is one that a material slot takes: a material or a material instance.</summary>
    public bool IsMaterial(string guid) => Assets.Find(guid)?.Kind is AssetKind.Material or AssetKind.MaterialInstance;

    /// <summary>
    /// The slot that a one-pixel pick shows: the first hit that the viewport may pick, that the document has, and that
    /// has a Mesh_Renderer, with the submesh under the pixel. Null for none, or for a submesh past the slots.
    /// </summary>
    public MaterialTarget? MaterialTargetOf(PickResult result)
    {
        if (!IsEditing || Scene == null || result.Submesh is < 0 or >= MaterialSlots)
        {
            return null;
        }
        foreach (var hit in result.Hits)
        {
            if (hit.SceneId != 0 && Pickable(hit.Entity)
                && Scene.Expanded.Flat.Find(hit.SceneId) is { } entity && entity.Components.Any(c => c.Id == SceneEdits.MeshRendererId))
            {
                return new MaterialTarget(hit.SceneId, result.Submesh);
            }
        }
        return null;
    }

    /// <summary>
    /// Shows a material on a slot while a drag is over it, in an undo entry that stays open: a new target undoes the
    /// last one's, and null undoes it without showing another.
    /// </summary>
    public void PreviewMaterial(MaterialTarget? target, string guid)
    {
        if (target == _materialTarget)
        {
            return;
        }
        CancelMaterial();
        // Another drag's open entry, such as the gizmo's, is not the drop's.
        if (target == null || Scene is not { InTransaction: false } || !IsEditing)
        {
            return;
        }
        BeginEdit("Set Material");
        _materialTarget = target;
        PreviewEdit(new SetField(target.SceneId, SceneEdits.MeshRendererId, $"materials.{target.Slot}", SceneValue.AssetRef(guid)));
    }

    /// <summary>
    /// Drops a material where a one-pixel pick found: it sets the slot there as one undo entry, keeping the preview if
    /// it was the same slot. A drop on nothing that takes it goes to the console.
    /// </summary>
    public bool DropMaterial(PickResult result, string guid)
    {
        PreviewMaterial(MaterialTargetOf(result), guid);
        if (CommitMaterial())
        {
            return true;
        }
        Console.Add(LogLevel.Info, $"edit: a material drops onto an entity with a Mesh_Renderer, on one of its first {MaterialSlots} submeshes");
        return false;
    }

    /// <summary>Keeps the previewed material as one undo entry. Returns false when nothing was previewed.</summary>
    public bool CommitMaterial()
    {
        if (_materialTarget == null && _faceMaterialKey == null)
        {
            return false;
        }
        _materialTarget = null;
        _faceMaterialKey = null;
        if (Scene is not { InTransaction: true })
        {
            return false;
        }
        CommitEdit();
        return true;
    }

    /// <summary>Puts back the slot that the drag previewed a material on.</summary>
    public void CancelMaterial()
    {
        if (_materialTarget == null && _faceMaterialKey == null)
        {
            return;
        }
        _materialTarget = null;
        _faceMaterialKey = null;
        if (Scene is { InTransaction: true })
        {
            CancelEdit();
        }
    }
}
