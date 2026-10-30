using Wire = Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Document;

/// <summary>The diff of two flat scenes as operations on the host's world.</summary>
public static partial class PrefabExpansion
{
    /// <summary>
    /// The operations that turn the host's world from one flat scene into another: destroys of the entities that
    /// vanished, the deepest first; creates of those that appeared, each after its parent; and for the rest, the
    /// changes of their names, parents, activity, components, fields and behaviours.
    /// </summary>
    public static List<Wire.Operation> Diff(IReadOnlyList<SceneEntity> before, IReadOnlyList<SceneEntity> after)
    {
        var ops = new List<Wire.Operation>();
        var old = before.GroupBy(e => e.Id).ToDictionary(g => g.Key, g => g.First());
        var now = after.GroupBy(e => e.Id).ToDictionary(g => g.Key, g => g.First());
        int DepthIn(Dictionary<ulong, SceneEntity> scene, SceneEntity e)
        {
            var depth = 0;
            for (var p = e.Parent; p != 0 && depth < 64 && scene.TryGetValue(p, out var parent); p = parent.Parent)
            {
                depth++;
            }
            return depth;
        }
        foreach (var e in before.Where(e => !now.ContainsKey(e.Id)).OrderByDescending(e => DepthIn(old, e)))
        {
            ops.Add(Op(Wire.OperationKind.DestroyEntity, e.Id));
        }
        foreach (var e in after.Where(e => !old.ContainsKey(e.Id)).OrderBy(e => DepthIn(now, e)))
        {
            ops.Add(Op(Wire.OperationKind.CreateEntity, e.Id, created: [SceneSnapshot.Entity(e)]));
        }
        foreach (var e in after)
        {
            if (!old.TryGetValue(e.Id, out var was))
            {
                continue;
            }
            if (was.Name != e.Name)
            {
                ops.Add(Op(Wire.OperationKind.Rename, e.Id, name: e.Name));
            }
            if (was.Parent != e.Parent)
            {
                ops.Add(Op(Wire.OperationKind.SetParent, e.Id, parent: e.Parent));
            }
            if (was.Active != e.Active)
            {
                ops.Add(Op(Wire.OperationKind.SetActive, e.Id, active: e.Active));
            }
            foreach (var c in was.Components.Where(c => e.Components.All(x => x.Id != c.Id)))
            {
                ops.Add(Op(Wire.OperationKind.RemoveComponent, e.Id, component: c.Id));
            }
            foreach (var c in e.Components)
            {
                if (was.Components.Find(x => x.Id == c.Id) is not { } prior)
                {
                    ops.Add(Op(Wire.OperationKind.AddComponent, e.Id, components: [SceneSnapshot.Component(c)]));
                    continue;
                }
                foreach (var (name, value) in FieldChanges(prior.Fields, c.Fields))
                {
                    ops.Add(value == null
                        ? Op(Wire.OperationKind.ResetField, e.Id, component: c.Id, fields: [new Wire.SceneField(name, SceneSnapshot.Value(SceneValue.Of(false)))])
                        : Op(Wire.OperationKind.SetField, e.Id, component: c.Id, fields: [new Wire.SceneField(name, SceneSnapshot.Value(value))]));
                }
            }
            foreach (var b in was.Behaviours.Where(b => e.Behaviours.All(x => x.Script != b.Script)))
            {
                ops.Add(Op(Wire.OperationKind.RemoveBehaviour, e.Id, script: b.Script));
            }
            foreach (var b in e.Behaviours)
            {
                if (was.Behaviours.Find(x => x.Script == b.Script) is not { } prior)
                {
                    ops.Add(Op(Wire.OperationKind.AddBehaviour, e.Id, script: b.Script, fields: [.. b.Fields.Select(SceneSnapshot.Field)]));
                    continue;
                }
                foreach (var (name, value) in FieldChanges(prior.Fields, b.Fields))
                {
                    ops.Add(value == null
                        ? Op(Wire.OperationKind.ResetBehaviourField, e.Id, script: b.Script, fields: [new Wire.SceneField(name, SceneSnapshot.Value(SceneValue.Of(false)))])
                        : Op(Wire.OperationKind.SetBehaviourField, e.Id, script: b.Script, fields: [new Wire.SceneField(name, SceneSnapshot.Value(value))]));
                }
            }
        }
        return ops;
    }

    // The fields that changed, with their new values, or null for one that is gone.
    static IEnumerable<(string Name, SceneValue? Value)> FieldChanges(List<SceneField> before, List<SceneField> after)
    {
        foreach (var f in before.Where(f => after.All(x => x.Name != f.Name)))
        {
            yield return (f.Name, null);
        }
        foreach (var f in after)
        {
            if (before.Find(x => x.Name == f.Name) is not { } prior || prior.Value != f.Value)
            {
                yield return (f.Name, f.Value);
            }
        }
    }

    static Wire.Operation Op(Wire.OperationKind kind, ulong entity, Wire.SceneEntity[]? created = null, string name = "",
        ulong parent = 0, bool active = false, ulong component = 0, Wire.SceneComponent[]? components = null, string? script = null,
        Wire.SceneField[]? fields = null) =>
        new(kind, entity, created ?? [], name, parent, active, component, components ?? [],
            script == null ? new byte[16] : Convert.FromHexString(script), fields ?? []);
}
