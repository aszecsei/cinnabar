using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;

namespace Cinnabar.Editor.Mesh;

/// <summary>The shape of a Mesh_Cutter's volume, as <c>asset_format.Mesh_Cutter_Shape</c> names it.</summary>
public enum CutterShape
{
    Box,
    Mesh,
}

/// <summary>
/// A Mesh_Cutter's fields, as <c>asset_format.Mesh_Cutter</c> has them (see
/// docs/editor/mesh-editing.md#cutters-and-cut-targets). A field that the scene leaves out has the default of
/// <c>DEFAULT_MESH_CUTTER</c>.
/// </summary>
public sealed record CutterFields(CutterShape Shape, Vec3 Extents, string Mesh, string CapMaterial, uint Layers, bool CutsCollision)
{
    /// <summary>In meters, for an extent of 0, as <c>MESH_CUTTER_DEFAULT_EXTENT</c>.</summary>
    public const double DefaultExtent = 0.5;

    public static CutterFields Default { get; } = new(CutterShape.Box, new Vec3(DefaultExtent, DefaultExtent, DefaultExtent), "", "", 0, true);

    /// <summary>The fields of a Mesh_Cutter component, over the defaults. A value of another kind than its field's is left out, as the game leaves it.</summary>
    public static CutterFields Of(SceneComponent component)
    {
        var f = Default;
        foreach (var field in component.Fields)
        {
            var v = field.Value;
            f = field.Name switch
            {
                "shape" when v.Kind == SceneValueKind.Name && Enum.TryParse<CutterShape>(v.Text, out var shape) => f with { Shape = shape },
                "extents" when v is { Kind: SceneValueKind.Number, Numbers.Count: 3 } =>
                    f with { Extents = new Vec3(Extent(v.Numbers[0].Float), Extent(v.Numbers[1].Float), Extent(v.Numbers[2].Float)) },
                "mesh" when v.Kind == SceneValueKind.Asset => f with { Mesh = v.Asset },
                "cap_material" when v.Kind == SceneValueKind.Asset => f with { CapMaterial = v.Asset },
                "layers" when v is { Kind: SceneValueKind.Number, Numbers.Count: 1 } && v.Numbers[0].Float >= 0 => f with { Layers = (uint)v.Numbers[0].Float },
                "cuts_collision" when v.Kind == SceneValueKind.Bool => f with { CutsCollision = v.Bool },
                _ => f,
            };
        }
        return f;
    }

    static double Extent(double e) => e > 0 ? e : DefaultExtent;

    /// <summary>Whether the cutter cuts the targets of a layer: bit i cuts layer i, and a mask of 0 cuts every layer.</summary>
    public bool Cuts(int layer) => Layers == 0 || (layer is >= 0 and < 32 && (Layers & (1u << layer)) != 0);
}

/// <summary>Finds the meshes that a Mesh_Cutter cuts (see docs/editor/mesh-editing.md#cutters-and-cut-targets).</summary>
public static class MeshCutters
{
    /// <summary>A Cut_Target's layer, or null for an entity without one, which no cutter cuts.</summary>
    public static int? TargetLayer(SceneEntity entity)
    {
        if (entity.Components.Find(c => c.Id == SceneEdits.CutTargetId) is not { } target)
        {
            return null;
        }
        var layer = target.Fields.Find(f => f.Name == "layer")?.Value;
        return layer is { Kind: SceneValueKind.Number, Numbers.Count: 1 } && layer.Numbers[0].Float >= 0 ? (int)layer.Numbers[0].Float : 0;
    }

    /// <summary>
    /// The bounds of a cutter's volume in its own space, before its scale: its box, or its mesh's vertices. Null for a
    /// mesh that <paramref name="meshOf"/> does not give.
    /// </summary>
    public static (Vec3 Min, Vec3 Max)? Bounds(CutterFields cutter, Func<string, MeshData?> meshOf)
    {
        if (cutter.Shape == CutterShape.Box)
        {
            return (-cutter.Extents, cutter.Extents);
        }
        return cutter.Mesh != "" && meshOf(cutter.Mesh) is { Vertices.Length: > 0 } mesh ? MeshBoolean.Bounds(mesh.Vertices) : null;
    }

    /// <summary>
    /// The entities of an expanded scene that a cutter cuts, in the scene's order. An entity is cut when it has a
    /// Cut_Target whose layer is in the cutter's mask, its editable mesh (<see cref="EditableMesh"/>) is one that
    /// <paramref name="meshOf"/> gives, the bounds of the two meet, and it is not in the cutter's own instance. <paramref name="meshOf"/> gives
    /// the mesh of a GUID, or null for a model's mesh or a missing one, which cannot be cut.
    /// </summary>
    public static IReadOnlyList<SceneEntity> Targets(Expansion expansion, SceneEntity cutter, Func<string, MeshData?> meshOf)
    {
        var flat = expansion.Flat;
        if (cutter.Components.Find(c => c.Id == SceneEdits.MeshCutterId) is not { } component
            || SceneEdits.WorldPose(flat, cutter) is not { } cutterPose)
        {
            return [];
        }
        var fields = CutterFields.Of(component);
        if (Bounds(fields, meshOf) is not var (cutMin, cutMax))
        {
            return [];
        }
        var own = OwnInstance(expansion, cutter.Id);
        var result = new List<SceneEntity>();
        foreach (var entity in flat.Entities)
        {
            if (entity.Id == cutter.Id || TargetLayer(entity) is not { } layer || !fields.Cuts(layer)
                || (own != null && expansion.InstanceOf(entity.Id) is { } inst && StartsWith(inst.Path, own))
                || EditableMesh(entity) is not { } guid || meshOf(guid) is not { Vertices.Length: > 0 } mesh
                || SceneEdits.WorldPose(flat, entity) is not { } pose)
            {
                continue;
            }
            // The cutter's box corners in the target's space, whose bounds hold the cutter wherever it turns.
            var toTarget = MeshPlacement.Between(cutterPose, pose);
            var corners = Enumerable.Range(0, 8).Select(i => toTarget.Apply(new Vec3(
                (i & 1) == 0 ? cutMin.X : cutMax.X, (i & 2) == 0 ? cutMin.Y : cutMax.Y, (i & 4) == 0 ? cutMin.Z : cutMax.Z)));
            var (aMin, aMax) = MeshBoolean.Bounds(corners);
            var (bMin, bMax) = MeshBoolean.Bounds(mesh.Vertices);
            var pad = new Vec3(MeshBoolean.PlaneEpsilon, MeshBoolean.PlaneEpsilon, MeshBoolean.PlaneEpsilon);
            if (MeshBoolean.Overlap(aMin - pad, aMax + pad, bMin, bMax))
            {
                result.Add(entity);
            }
        }
        return result;
    }

    // The path of the innermost instance that holds an entity, which its own instance's entities start with: the
    // instance that it is the root of, or the one that its prefab places it in. Null for an entity of the scene. An
    // instance whose root is no flat entity is a variant's base, whose root is the variant's: the variant is the
    // instance then, so a frame that the variant adds is the door's own too.
    static IReadOnlyList<ulong>? OwnInstance(Expansion expansion, ulong id)
    {
        if (expansion.InstanceOf(id) is not { } inst)
        {
            return null;
        }
        var path = inst.Prefab != "" ? inst.Path : inst.Path.Take(inst.Path.Count - 1).ToArray();
        while (path.Count > 1 && expansion.Flat.Find(ScenePath.Id(path)) == null)
        {
            path = path.Take(path.Count - 1).ToArray();
        }
        return path;
    }

    static bool StartsWith(IReadOnlyList<ulong> path, IReadOnlyList<ulong> prefix) =>
        path.Count >= prefix.Count && prefix.Select((id, i) => path[i] == id).All(b => b);

    /// <summary>
    /// The mesh that a cut of an entity starts from: its <c>Cut_Target</c>'s source while cutters cut it, else what its
    /// <c>Mesh_Renderer</c> names. Null for neither.
    /// </summary>
    public static string? EditableMesh(SceneEntity entity) => SourceOf(entity) ?? RendererMesh(entity);

    /// <summary>A <c>Cut_Target</c>'s source, which it has while cutters cut it, or null.</summary>
    public static string? SourceOf(SceneEntity entity) =>
        Asset(entity.Components.Find(c => c.Id == SceneEdits.CutTargetId)?.Fields.Find(f => f.Name == "source")?.Value);

    /// <summary>The <c>Cut_Target</c>'s <c>inputs_hash</c>, or 0.</summary>
    public static uint HashOf(SceneEntity entity) =>
        entity.Components.Find(c => c.Id == SceneEdits.CutTargetId)?.Fields.Find(f => f.Name == "inputs_hash")?.Value
            is { Kind: SceneValueKind.Number, Numbers.Count: 1 } v && v.Numbers[0].Float is >= 0 and <= uint.MaxValue ? (uint)v.Numbers[0].Float : 0;

    /// <summary>A hash as a field's value.</summary>
    public static SceneValue HashValue(uint hash) => SceneValue.Of(new SceneNumber(hash, hash));

    /// <summary>What an entity's <c>Mesh_Renderer</c> names, or null.</summary>
    public static string? RendererMesh(SceneEntity entity) =>
        Asset(entity.Components.Find(c => c.Id == SceneEdits.MeshRendererId)?.Fields.Find(f => f.Name == "mesh")?.Value);

    static string? Asset(SceneValue? value) => value is { Kind: SceneValueKind.Asset, Asset.Length: > 0 } v ? v.Asset : null;
}
