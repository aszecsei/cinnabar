using System.Globalization;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;

namespace Cinnabar.Editor.Mesh;

/// <summary>A cutter of a cut target, as the cut reads it: its entity, its fields, its volume and its world pose.</summary>
public sealed record CutterInput(SceneEntity Entity, CutterFields Fields, MeshData Volume, Pose Pose);

/// <summary>
/// What a cut target's mesh is derived from (see docs/editor/mesh-editing.md#cut-meshes): its source mesh at its pose,
/// and the cutters that cut it, in the scene's order.
/// </summary>
public sealed record CutInputs(SceneEntity Target, string Source, MeshData SourceMesh, Pose Pose, IReadOnlyList<CutterInput> Cutters)
{
    /// <summary>
    /// The hash of the inputs, which <c>Cut_Target.inputs_hash</c> keeps: the source's and the cutters' meshes as
    /// their files write them, the cutters' fields and their poses relative to the target. GUIDs are not in it, so a
    /// source changed on disk changes it. It is 32 bits, which the scene's numbers hold exactly in the game too, since it
    /// only tells a stale cut from a current one. 0 while nothing cuts the target, which no hash of inputs is.
    /// </summary>
    public uint Hash()
    {
        if (Cutters.Count == 0)
        {
            return 0;
        }
        var text = new StringBuilder();
        text.Append("source\n").Append(Text(SourceMesh));
        foreach (var c in Cutters)
        {
            var f = c.Fields;
            text.Append("cutter ").Append(f.Shape).Append(' ').Append(f.CapMaterial).Append('\n');
            text.Append(Text(c.Volume));
            var m = MeshPlacement.Between(c.Pose, Pose);
            foreach (var v in (ReadOnlySpan<Vec3>)[m.X, m.Y, m.Z, m.Origin])
            {
                text.Append(Number(v.X)).Append(' ').Append(Number(v.Y)).Append(' ').Append(Number(v.Z)).Append('\n');
            }
        }
        var hash = BitConverter.ToUInt32(SHA256.HashData(Encoding.UTF8.GetBytes(text.ToString())), 0);
        return hash == 0 ? 1 : hash;
    }

    // A mesh's file text, kept for each snapshot, since every step of every edit hashes the scene's targets again.
    static readonly ConditionalWeakTable<MeshData, string> Texts = [];

    /// <summary>A mesh's file text, kept for each snapshot.</summary>
    public static string Text(MeshData mesh) => Texts.GetValue(mesh, MeshFile.Write);

    // To a tenth of a micrometer, far under the plane tolerance, so noise in the last bit of a double does not count.
    static string Number(double v) => Math.Round(v, 7).ToString("R", CultureInfo.InvariantCulture);
}

/// <summary>A cut's result: none, since nothing cuts the target; the cut mesh; or a refusal with its reason.</summary>
public abstract record CutResult
{
    CutResult() { }

    /// <summary>No cutter cuts the target, so its mesh is its source.</summary>
    public sealed record Uncut : CutResult;

    /// <summary>
    /// The source with every cutter subtracted, in the target's space, the slots whose material the cut set, which
    /// the target's <c>Mesh_Renderer</c> draws, and the map of the mesh back onto the source.
    /// </summary>
    public sealed record Cut(MeshData Mesh, IReadOnlyDictionary<int, string> Slots, CutMap Map) : CutResult;

    /// <summary>A cutter that the boolean refused, or a ninth material, with the reason.</summary>
    public sealed record Refused(string Reason) : CutResult;
}

/// <summary>What a cut target's <c>Collider</c> follows: see <see cref="MeshCuts.CollisionOf"/>.</summary>
public enum CollisionCut
{
    Source,
    Render,
    Own,
}

/// <summary>Derives cut targets' meshes from their sources and their cutters (see docs/editor/mesh-editing.md#cut-meshes).</summary>
public static class MeshCuts
{
    /// <summary>
    /// The inputs of every cut target of an expanded scene, in the scene's order: each entity with a
    /// <c>Cut_Target</c> whose editable mesh <paramref name="meshOf"/> gives, with the cutters that cut it. A target
    /// that no cutter cuts has none.
    /// </summary>
    public static IReadOnlyList<CutInputs> Plan(Expansion expansion, Func<string, MeshData?> meshOf)
    {
        var flat = expansion.Flat;
        var cutters = new Dictionary<ulong, List<CutterInput>>();
        foreach (var entity in flat.Entities)
        {
            if (entity.Components.Find(c => c.Id == SceneEdits.MeshCutterId) is not { } component
                || SceneEdits.WorldPose(flat, entity) is not { } pose
                || Volume(CutterFields.Of(component), meshOf) is not { } volume)
            {
                continue;
            }
            var input = new CutterInput(entity, CutterFields.Of(component), volume, pose);
            foreach (var target in MeshCutters.Targets(expansion, entity, meshOf))
            {
                (cutters.TryGetValue(target.Id, out var list) ? list : cutters[target.Id] = []).Add(input);
            }
        }
        var result = new List<CutInputs>();
        foreach (var entity in flat.Entities)
        {
            if (MeshCutters.TargetLayer(entity) == null || MeshCutters.EditableMesh(entity) is not { } source
                || meshOf(source) is not { } mesh || SceneEdits.WorldPose(flat, entity) is not { } pose)
            {
                continue;
            }
            result.Add(new CutInputs(entity, source, mesh, pose, cutters.GetValueOrDefault(entity.Id) ?? []));
        }
        return result;
    }

    /// <summary>A cutter's volume in its own space, before its pose: its box, or its mesh. Null for a mesh that <paramref name="meshOf"/> does not give.</summary>
    public static MeshData? Volume(CutterFields cutter, Func<string, MeshData?> meshOf) =>
        cutter.Shape == CutterShape.Box ? Primitives.Block(-cutter.Extents, cutter.Extents)
        : cutter.Mesh != "" ? meshOf(cutter.Mesh) : null;

    /// <summary>
    /// The source with each cutter subtracted in turn, as Carve does (see docs/editor/mesh-editing.md#booleans), or with
    /// those that <paramref name="only"/> passes. The faces that a cutter makes take its cap slot (<see cref="CapSlots"/>).
    /// </summary>
    public static CutResult Derive(CutInputs inputs, Func<CutterInput, bool>? only = null)
    {
        var cutters = Enumerable.Range(0, inputs.Cutters.Count).Where(i => only?.Invoke(inputs.Cutters[i]) ?? true).ToList();
        if (cutters.Count == 0)
        {
            return new CutResult.Uncut();
        }
        var (slots, refusal) = CapSlots(inputs);
        if (slots == null)
        {
            return new CutResult.Refused(refusal!);
        }
        var mesh = inputs.SourceMesh;
        // Each face's source face, or ~i for a face that cutter i made, composed over the steps.
        var origin = Enumerable.Range(0, mesh.Faces.Length).ToArray();
        var named = new Dictionary<int, string>();
        foreach (var i in cutters)
        {
            var cutter = inputs.Cutters[i];
            var result = MeshBoolean.Subtract(mesh, inputs.Pose, cutter.Volume, cutter.Pose, slots[i]);
            if (result.Reason is { } reason)
            {
                return new CutResult.Refused($"{cutter.Entity.Name}: {reason}");
            }
            if (ReferenceEquals(result.Mesh, mesh))
            {
                continue;
            }
            origin = [.. result.SourceFace.Select(f => f >= 0 ? origin[f] : ~i)];
            var material = CapMaterial(cutter);
            mesh = material != "" ? result.Mesh.With(materials: result.Mesh.Materials.SetItem(slots[i], material)) : result.Mesh;
            if (material != "")
            {
                named[slots[i]] = material;
            }
        }
        var labels = inputs.Cutters.Select(c => c.Entity.Name.Length > 0 ? c.Entity.Name : $"{c.Entity.Id:x16}").ToList();
        return new CutResult.Cut(mesh, named, new CutMap(inputs.SourceMesh, mesh, origin, labels));
    }

    /// <summary>
    /// What a target's <c>Collider</c> follows: the source, since no cutter cuts collision; the render result, since
    /// every cutter does; or a result of its own, cut by only the cutters that do.
    /// </summary>
    public static CollisionCut CollisionOf(CutInputs inputs) =>
        inputs.Cutters.Count(c => c.Fields.CutsCollision) is var n && n == 0 ? CollisionCut.Source
        : n == inputs.Cutters.Count ? CollisionCut.Render : CollisionCut.Own;

    /// <summary>
    /// The slot of each cutter's cap faces, by the face-material rules: the source's slot that names its material,
    /// else a slot that no face of the source and no other cap uses, or 0 for a cutter with no material. A ninth
    /// material gives the reason instead. The slots come from the inputs alone, so the shell sets the target's
    /// <c>Mesh_Renderer</c> slots before the boolean runs.
    /// </summary>
    public static (IReadOnlyList<int>? Slots, string? Reason) CapSlots(CutInputs inputs)
    {
        var used = inputs.SourceMesh.Faces.Select(f => f.Slot).ToHashSet();
        var assigned = new Dictionary<string, int>();
        var slots = new List<int>();
        foreach (var cutter in inputs.Cutters)
        {
            var material = CapMaterial(cutter);
            if (material == "")
            {
                slots.Add(0);
                continue;
            }
            if (!assigned.TryGetValue(material, out var slot))
            {
                slot = inputs.SourceMesh.Materials.IndexOf(material);
                if (slot < 0)
                {
                    slot = Enumerable.Range(0, MeshData.MaxSlots).FirstOrDefault(s => !used.Contains(s) && !assigned.ContainsValue(s), -1);
                }
                if (slot < 0)
                {
                    return (null, $"{cutter.Entity.Name}: a mesh has {MeshData.MaxSlots} materials, and every slot is in use");
                }
                assigned[material] = slot;
            }
            slots.Add(slot);
        }
        return (slots, null);
    }

    /// <summary>The material of a cutter's cap faces: its <c>cap_material</c>, else its mesh's first material, or "".</summary>
    public static string CapMaterial(CutterInput cutter) =>
        cutter.Fields.CapMaterial != "" ? cutter.Fields.CapMaterial
        : cutter.Fields.Shape == CutterShape.Mesh ? cutter.Volume.Materials.FirstOrDefault(m => m != "") ?? "" : "";
}
