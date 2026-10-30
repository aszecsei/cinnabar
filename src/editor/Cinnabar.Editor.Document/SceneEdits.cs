using Cinnabar.Editor.Maths;

namespace Cinnabar.Editor.Document;

/// <summary>
/// Edits that take more than one operation: destroying an entity with its descendants, duplicating, creating, and
/// reparenting without moving. Each gives the operations, which the caller applies as one undo entry.
/// </summary>
public static class SceneEdits
{
    public const ulong TransformId = 1;
    public const ulong LocalTransformId = 2;
    public const ulong PreviousTransformId = 4;
    /// <summary>The engine's Volume (see docs/world/volumes.md#volumes).</summary>
    public const ulong VolumeId = 42;
    /// <summary>The renderer's Mesh_Renderer (see docs/rendering/assets.md#components).</summary>
    public const ulong MeshRendererId = 33;
    /// <summary>The renderer's Directional_Light (see docs/rendering/lighting-and-shadows.md#lights-and-clusters).</summary>
    public const ulong DirectionalLightId = 34;
    /// <summary>The renderer's Fog setting (see docs/rendering/fog.md#volumetric-fog).</summary>
    public const ulong FogId = 38;
    /// <summary>The renderer's Environment setting (see docs/rendering/sky.md#sky).</summary>
    public const ulong EnvironmentId = 49;
    /// <summary>A volume's setting's override flag is a field of its own in a scene, which only false needs (see docs/world/volumes.md#volumes).</summary>
    public const string OverrideSuffix = ".override";

    /// <summary>Sets a field in a list, or removes it with a null value, and returns the old value or null.</summary>
    public static SceneValue? Put(List<SceneField> fields, string name, SceneValue? value)
    {
        var at = fields.FindIndex(f => f.Name == name);
        var old = at >= 0 ? fields[at].Value : null;
        if (value == null)
        {
            if (at >= 0)
            {
                fields.RemoveAt(at);
            }
        }
        else if (at >= 0)
        {
            fields[at] = new SceneField(name, value);
        }
        else
        {
            fields.Add(new SceneField(name, value));
        }
        return old;
    }

    /// <summary>The entity's descendants, each after its parent.</summary>
    public static List<SceneEntity> Descendants(Scene scene, ulong id)
    {
        var result = new List<SceneEntity>();
        var children = scene.Entities.ToLookup(e => e.Parent);
        void Visit(ulong parent)
        {
            foreach (var child in children[parent].OrderBy(c => c.Id))
            {
                result.Add(child);
                Visit(child.Id);
            }
        }
        Visit(id);
        return result;
    }

    /// <summary>Destroys an entity and its descendants, the deepest first, so undo creates each after its parent.</summary>
    public static Operation[] DestroyTree(Scene scene, ulong id) =>
        [.. Enumerable.Reverse(Descendants(scene, id)).Select(d => new DestroyEntity(d.Id)), new DestroyEntity(id)];

    /// <summary>
    /// Copies an entity and its descendants with new scene IDs, under the same parent. A reference from inside the
    /// copied entities to one of them refers to its copy.
    /// </summary>
    public static (Operation[] Operations, ulong Copy) Duplicate(Scene scene, ulong id)
    {
        var originals = new List<SceneEntity> { scene.Find(id) ?? throw new InvalidOperationException($"the scene has no entity {id:x16}") };
        originals.AddRange(Descendants(scene, id));
        var ids = new Dictionary<ulong, ulong>();
        foreach (var e in originals)
        {
            ulong fresh;
            do
            {
                fresh = SceneEntity.NewId();
            } while (scene.Find(fresh) != null || ids.ContainsValue(fresh));
            ids[e.Id] = fresh;
        }
        SceneValue Remap(SceneValue v) =>
            v.Kind == SceneValueKind.Entity && ids.TryGetValue(v.Entity, out var to) ? SceneValue.EntityRef(to) : v;
        var ops = originals.Select(e =>
        {
            var copy = e.Copy(ids[e.Id]);
            copy.Parent = ids.GetValueOrDefault(e.Parent, e.Parent);
            for (var i = 0; i < copy.Components.Count; i++)
            {
                copy.Components[i] = copy.Components[i] with { Fields = [.. copy.Components[i].Fields.Select(f => f with { Value = Remap(f.Value) })] };
            }
            for (var i = 0; i < copy.Behaviours.Count; i++)
            {
                copy.Behaviours[i] = copy.Behaviours[i] with { Fields = [.. copy.Behaviours[i].Fields.Select(f => f with { Value = Remap(f.Value) })] };
            }
            return (Operation)new CreateEntity(copy);
        }).ToArray();
        return (ops, ids[id]);
    }

    /// <summary>A new root entity named "Entity", with a Transform at a position, facing as the world does.</summary>
    public static CreateEntity NewEntity(Scene scene, long[] position)
    {
        ulong id;
        do
        {
            id = SceneEntity.NewId();
        } while (scene.Find(id) != null);
        var entity = new SceneEntity(id) { Name = "Entity" };
        entity.Components.Add(new SceneComponent(TransformId, "Transform", TransformFields(new Pose(position, Quat.Identity, [1, 1, 1]))));
        return new CreateEntity(entity);
    }

    /// <summary>
    /// Gives an entity a new parent, or none with 0, without moving it: its Local_Transform is set so its world pose
    /// stays, and as a root it keeps its world pose in its Transform. An entity without a pose only changes parent.
    /// </summary>
    public static Operation[] Reparent(Scene scene, ulong id, ulong parent)
    {
        var entity = scene.Find(id) ?? throw new InvalidOperationException($"the scene has no entity {id:x16}");
        var ops = new List<Operation> { new SetParent(id, parent) };
        if (WorldPose(scene, entity) is not { } world)
        {
            return [.. ops];
        }
        var hasLocal = entity.Components.Any(c => c.Id == LocalTransformId);
        ops.Add(SetComponent(entity, TransformId, "Transform", TransformFields(world)));
        if (parent == 0)
        {
            if (hasLocal)
            {
                ops.Add(new RemoveComponent(id, LocalTransformId));
            }
            return [.. ops];
        }
        var newParent = scene.Find(parent) ?? throw new InvalidOperationException($"the scene has no entity {parent:x16}");
        var p = WorldPose(scene, newParent) ?? Pose.Identity;
        ops.Add(SetComponent(entity, LocalTransformId, "Local_Transform", LocalFields(Pose.Relative(p, world))));
        return [.. ops];
    }

    // The whole component as the fields give it: an Add_Component replaces it on the document and on the host.
    static Operation SetComponent(SceneEntity entity, ulong id, string name, List<SceneField> fields)
    {
        var existing = entity.Components.Find(c => c.Id == id);
        var merged = existing?.Copy() ?? new SceneComponent(id, name, []);
        foreach (var f in fields)
        {
            Put(merged.Fields, f.Name, f.Value);
        }
        return new AddComponent(entity.Id, merged);
    }

    /// <summary>
    /// The world pose that the scene gives an entity: a root's Transform, or its parent's world pose composed with its
    /// Local_Transform, as the engine's propagation does. Null for an entity with neither.
    /// </summary>
    public static Pose? WorldPose(Scene scene, SceneEntity entity, int depth = 0)
    {
        var local = entity.Components.Find(c => c.Id == LocalTransformId);
        if (entity.Parent != 0 && local != null && depth < 64 && scene.Find(entity.Parent) is { } parent)
        {
            var p = WorldPose(scene, parent, depth + 1) ?? Pose.Identity;
            var (offset, rotation, scale) = (Vector(local.Fields, "offset", 0), Rotation(local.Fields), Vector(local.Fields, "scale", 0));
            return p.Compose(offset, rotation, scale);
        }
        var transform = entity.Components.Find(c => c.Id == TransformId);
        if (transform == null)
        {
            return null;
        }
        var position = transform.Fields.Find(f => f.Name == "position")?.Value;
        long[] raw = position is { Kind: SceneValueKind.Number, Numbers.Count: 3 } && position.Numbers.All(n => n.IsInteger)
            ? [.. position.Numbers.Select(n => (long)n.Integer!.Value)]
            : [0, 0, 0];
        return new Pose(raw, Rotation(transform.Fields), Vector(transform.Fields, "scale", 0));
    }

    static double[] Vector(List<SceneField> fields, string name, double missing)
    {
        var v = fields.Find(f => f.Name == name)?.Value;
        return v is { Kind: SceneValueKind.Number, Numbers.Count: 3 } ? [.. v.Numbers.Select(n => n.Float)] : [missing, missing, missing];
    }

    // A rotation that the scene does not set is zero, which is no rotation at all, so the math takes it as identity.
    static Quat Rotation(List<SceneField> fields)
    {
        var v = fields.Find(f => f.Name == "rotation")?.Value;
        if (v is not { Kind: SceneValueKind.Number, Numbers.Count: 4 })
        {
            return Quat.Identity;
        }
        var q = new Quat(v.Numbers[0].Float, v.Numbers[1].Float, v.Numbers[2].Float, v.Numbers[3].Float);
        return q.Length < 1e-9 ? Quat.Identity : q.Normalized();
    }

    public static List<SceneField> TransformFields(Pose pose) =>
    [
        new("position", SceneValue.Of([.. pose.Position.Select(SceneNumber.Of)])),
        new("rotation", Floats(pose.Rotation.X, pose.Rotation.Y, pose.Rotation.Z, pose.Rotation.W)),
        new("scale", Floats(pose.Scale)),
    ];

    static List<SceneField> LocalFields((double[] Offset, Quat Rotation, double[] Scale) local) =>
    [
        new("offset", Floats(local.Offset)),
        new("rotation", Floats(local.Rotation.X, local.Rotation.Y, local.Rotation.Z, local.Rotation.W)),
        new("scale", Floats(local.Scale)),
    ];

    /// <summary>Numbers as the game's f32 fields hold them, so the file shows the short form of each.</summary>
    public static SceneValue Floats(params double[] values) => SceneValue.Of([.. values.Select(v => SceneNumber.Of((double)(float)v))]);
}

/// <summary>A world pose: a position in raw units of 2^-24 m, a rotation and a scale, as the engine's Transform.</summary>
public sealed record Pose(long[] Position, Quat Rotation, double[] Scale)
{
    public const double Unit = 1 << 24;

    public static Pose Identity => new([0, 0, 0], Quat.Identity, [1, 1, 1]);

    /// <summary>The world pose of a child with this parent, as the engine's <c>compose</c> gives it.</summary>
    public Pose Compose(double[] offset, Quat rotation, double[] scale)
    {
        var moved = Rotation.Rotate([offset[0] * Scale[0], offset[1] * Scale[1], offset[2] * Scale[2]]);
        return new Pose(
            [.. Position.Select((p, i) => p + (long)Math.Round(moved[i] * Unit))],
            (Rotation * rotation).Normalized(),
            [Scale[0] * scale[0], Scale[1] * scale[1], Scale[2] * scale[2]]);
    }

    /// <summary>The Local_Transform that puts a child at a world pose under a parent: the inverse of <see cref="Compose"/>.</summary>
    public static (double[] Offset, Quat Rotation, double[] Scale) Relative(Pose parent, Pose child)
    {
        static double Divide(double a, double b) => b == 0 ? 0 : a / b;
        double[] delta = [.. child.Position.Select((p, i) => (p - parent.Position[i]) / Unit)];
        var unrotated = parent.Rotation.Conjugate.Rotate(delta);
        return (
            [Divide(unrotated[0], parent.Scale[0]), Divide(unrotated[1], parent.Scale[1]), Divide(unrotated[2], parent.Scale[2])],
            (parent.Rotation.Conjugate * child.Rotation).Normalized(),
            [Divide(child.Scale[0], parent.Scale[0]), Divide(child.Scale[1], parent.Scale[1]), Divide(child.Scale[2], parent.Scale[2])]);
    }
}
