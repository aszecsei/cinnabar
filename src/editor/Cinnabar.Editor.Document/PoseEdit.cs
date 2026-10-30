using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;

namespace Cinnabar.Editor.Tools;

/// <summary>
/// Moves, turns or scales entities of a scene by a gizmo's change, about a pivot (see docs/editor/viewport.md#viewport). It
/// keeps the world poses from the start of the drag, so each step is the change from the start, not from the step
/// before. An entity whose ancestor is also moved follows that ancestor and gets no operations of its own.
/// </summary>
public sealed class PoseEdit
{
    readonly List<(SceneEntity Entity, Pose Start, Pose? Parent)> _entities = [];

    public PoseEdit(Scene scene, IEnumerable<ulong> ids)
    {
        var chosen = ids.ToHashSet();
        foreach (var id in chosen)
        {
            if (scene.Find(id) is not { } entity || HasChosenAncestor(scene, entity, chosen) || SceneEdits.WorldPose(scene, entity) is not { } start)
            {
                continue;
            }
            var parent = IsChild(entity) && scene.Find(entity.Parent) is { } p ? SceneEdits.WorldPose(scene, p) ?? Pose.Identity : null;
            _entities.Add((entity, start, parent));
        }
    }

    /// <summary>The entities that the edit moves, without the ones that follow an ancestor.</summary>
    public IEnumerable<ulong> Moved => _entities.Select(e => e.Entity.Id);

    public bool IsEmpty => _entities.Count == 0;

    /// <summary>
    /// The operations that put each entity where the change takes it from the start. A move adds the translation; a
    /// turn turns about the pivot; a scale multiplies each entity's scale, and moves it away from the pivot along the
    /// gizmo's axes.
    /// </summary>
    public List<Operation> Apply(GizmoChange change, long[] pivot, Quat axes)
    {
        var ops = new List<Operation>();
        foreach (var (entity, start, parent) in _entities)
        {
            var offset = Vec3.Between(pivot, start.Position);
            var position = start.Position;
            var rotation = start.Rotation;
            var scale = start.Scale;
            var moved = false;
            if (change.Translation != Vec3.Zero)
            {
                position = change.Translation.Offset(start.Position);
                moved = true;
            }
            if (change.Rotation != Quat.Identity)
            {
                rotation = (change.Rotation * start.Rotation).Normalized();
                position = change.Rotation.Rotate(offset).Offset(pivot);
                moved = offset.Length > 1e-9;
            }
            if (change.Scale != new Vec3(1, 1, 1))
            {
                scale = [start.Scale[0] * change.Scale.X, start.Scale[1] * change.Scale.Y, start.Scale[2] * change.Scale.Z];
                var local = axes.Conjugate.Rotate(offset);
                position = axes.Rotate(Vec3.Scale(local, change.Scale)).Offset(pivot);
                moved = offset.Length > 1e-9;
            }
            var world = new Pose(position, rotation, scale);
            ops.AddRange(Fields(entity, world, parent, moved, change.Rotation != Quat.Identity, change.Scale != new Vec3(1, 1, 1)));
        }
        return ops;
    }

    // A root sets its Transform. A child with a Local_Transform sets that, relative to its parent's world pose, and
    // propagation writes its Transform.
    static IEnumerable<Operation> Fields(SceneEntity entity, Pose world, Pose? parent, bool moved, bool turned, bool scaled)
    {
        if (parent is { } p)
        {
            var (offset, rotation, scale) = Pose.Relative(p, world);
            if (moved)
            {
                yield return new SetField(entity.Id, SceneEdits.LocalTransformId, "offset", SceneEdits.Floats(offset));
            }
            if (turned)
            {
                yield return new SetField(entity.Id, SceneEdits.LocalTransformId, "rotation", SceneEdits.Floats(rotation.X, rotation.Y, rotation.Z, rotation.W));
            }
            if (scaled)
            {
                yield return new SetField(entity.Id, SceneEdits.LocalTransformId, "scale", SceneEdits.Floats(scale));
            }
            yield break;
        }
        if (moved)
        {
            yield return new SetField(entity.Id, SceneEdits.TransformId, "position", SceneValue.Of([.. world.Position.Select(SceneNumber.Of)]));
        }
        if (turned)
        {
            yield return new SetField(entity.Id, SceneEdits.TransformId, "rotation", SceneEdits.Floats(world.Rotation.X, world.Rotation.Y, world.Rotation.Z, world.Rotation.W));
        }
        if (scaled)
        {
            yield return new SetField(entity.Id, SceneEdits.TransformId, "scale", SceneEdits.Floats(world.Scale));
        }
    }

    static bool IsChild(SceneEntity entity) => entity.Parent != 0 && entity.Components.Any(c => c.Id == SceneEdits.LocalTransformId);

    static bool HasChosenAncestor(Scene scene, SceneEntity entity, HashSet<ulong> chosen)
    {
        var parent = entity.Parent;
        for (var depth = 0; parent != 0 && depth < 64; depth++)
        {
            if (chosen.Contains(parent))
            {
                return true;
            }
            parent = scene.Find(parent)?.Parent ?? 0;
        }
        return false;
    }
}
