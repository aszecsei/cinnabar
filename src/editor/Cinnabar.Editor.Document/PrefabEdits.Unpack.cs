namespace Cinnabar.Editor.Document;

/// <summary>Unpacking instances into plain entities.</summary>
public static partial class PrefabEdits
{
    /// <summary>
    /// Makes an instance's entities plain entities of the scene, with their current values, through every nesting:
    /// Unpack Completely. Their scene IDs are their paths' IDs, so the host's world does not change.
    /// </summary>
    public static Operation[] UnpackCompletely(SceneDocument document, ulong instance)
    {
        var expansion = document.Expanded;
        if (expansion.InstanceOf(instance) is not { IsInstanceRoot: true })
        {
            throw new InvalidOperationException($"{instance:x16} is not an instance's root");
        }
        var entities = expansion.Flat.Entities.Where(e => expansion.InstanceOf(e.Id)?.Instance == instance).Select(e =>
        {
            var copy = e.Clone();
            copy.ParentPath = PathOf(expansion, copy.Parent) is { } p && p[0] != instance ? p : null;
            return copy;
        }).ToList();
        var flatIds = entities.Select(e => e.Id).ToHashSet();
        return [new BlockOperation(document, instance, [.. BlocksOf(document.Scene, instance).Select(b => b.Id)], entities), .. Unpathed(document, flatIds)];
    }

    /// <summary>
    /// Makes an instance's own level plain entities of the scene: its prefab's entities with the scene's overrides, while
    /// the instances inside the prefab stay instances, with their overrides on paths from them. The nested instances'
    /// entities have new paths, so their scene IDs change, and the host gets the difference.
    /// </summary>
    public static Operation[] Unpack(SceneDocument document, ulong instance)
    {
        var block = document.Scene.Find(instance);
        if (block is not { Prefab: not "" } || document.Prefabs.SceneOf(block.Prefab) is not { } prefab || PrefabExpansion.RootOf(prefab) is not ({ } root, 1))
        {
            return UnpackCompletely(document, instance);
        }
        // A path inside the instance, from the scene's side: <instance>#<a> is the plain entity or the inner instance
        // a's new ID, and <instance>#<a>#<rest> is <a's new ID>#<rest>, a path from the inner instance.
        ulong Remap(ulong id) => id == root.Id ? instance : ScenePath.Id(instance, id);
        IReadOnlyList<ulong> Outer(IReadOnlyList<ulong> path) =>
            path.Count >= 2 && path[0] == instance ? [ScenePath.Id(instance, path[1]), .. path.Skip(2)] : path;
        // A path in the prefab, rooted at the instance.
        IReadOnlyList<ulong> Inner(IReadOnlyList<ulong> path) => [Remap(path[0]), .. path.Skip(1)];
        var known = prefab.Entities.Select(e => e.Id).ToHashSet();
        SceneValue InnerValue(SceneValue v) => v.Kind != SceneValueKind.Entity || v.Entity == 0 ? v
            : !known.Contains(v.Entity) ? SceneValue.EntityRef(0)
            : SceneValue.EntityRef(Inner(v.Path ?? [v.Entity]));
        void SetParent(SceneEntity e, IReadOnlyList<ulong>? path)
        {
            e.Parent = path == null ? 0 : ScenePath.Id(path);
            e.ParentPath = path is { Count: > 1 } ? path : null;
        }
        // The prefab's blocks on the scene's side, by the ID that the scene's overrides of them have.
        var blocks = new List<SceneEntity>();
        var byOuterId = new Dictionary<ulong, SceneEntity>();
        foreach (var e in prefab.Entities)
        {
            SceneEntity copy;
            if (e.Path == null)
            {
                copy = e.Copy(Remap(e.Id));
                if (e.Id == root.Id)
                {
                    copy.Components.RemoveAll(c => c.Id is SceneEdits.TransformId or SceneEdits.LocalTransformId);
                    copy.Parent = block.Parent;
                    copy.ParentPath = block.ParentPath;
                }
                else
                {
                    SetParent(copy, e.Parent == 0 ? null : Inner(e.ParentPath ?? [e.Parent]));
                }
                byOuterId[e.Id == root.Id ? instance : ScenePath.Id(instance, e.Id)] = copy;
            }
            else
            {
                copy = CopyBlock(e, Inner(e.Path));
                if (copy.Keys.HasFlag(SceneKeys.Parent))
                {
                    SetParent(copy, e.Parent == 0 ? null : Inner(e.ParentPath ?? [e.Parent]));
                }
                byOuterId[ScenePath.Id([instance, .. e.Path])] = copy;
            }
            foreach (var list in copy.Components.Select(c => c.Fields).Concat(copy.Behaviours.Select(b => b.Fields)))
            {
                for (var i = 0; i < list.Count; i++)
                {
                    list[i] = list[i] with { Value = InnerValue(list[i].Value) };
                }
            }
            blocks.Add(copy);
        }
        // The scene's overrides go over the block of the entity they name, or onto a path from an inner instance.
        foreach (var o in BlocksOf(document.Scene, instance))
        {
            if (o.Path == null)
            {
                // The instance block: the root's overrides and its pose.
                var r = byOuterId[instance];
                PrefabExpansion.ApplyOverride(r, o);
                continue;
            }
            if (byOuterId.TryGetValue(o.Id, out var target))
            {
                if (target.Path != null || target.Prefab != "")
                {
                    MergeBlock(target, o);
                }
                else
                {
                    PrefabExpansion.ApplyOverride(target, o);
                    if (o.Keys.HasFlag(SceneKeys.Parent))
                    {
                        SetParent(target, o.Parent == 0 ? null : Outer(o.ParentPath ?? [o.Parent]));
                    }
                    target.Removed = o.Removed;
                }
            }
            else if (o.Path.Count > 2)
            {
                blocks.Add(CopyBlock(o, Outer(o.Path)));
            }
            // An override of an entity that the prefab no longer has did nothing, and goes.
        }
        blocks = DropRemovedBlocks(blocks);
        foreach (var b in blocks)
        {
            RewritePaths(b, Outer);
        }
        var ops = new List<Operation> { new BlockOperation(document, instance, [.. BlocksOf(document.Scene, instance).Select(b => b.Id)], blocks) };
        // The rest of the scene names the inner instances' entities by paths from them.
        var changed = new List<SceneEntity>();
        foreach (var e in document.Scene.Entities.Where(e => e.Id != instance && e.Path?[0] != instance))
        {
            var copy = e.Clone();
            if (RewritePaths(copy, Outer))
            {
                changed.Add(copy);
            }
        }
        if (changed.Count > 0)
        {
            ops.Add(new BlockOperation(document, 0, [.. changed.Select(c => c.Id)], changed));
        }
        return [.. ops];
    }

    // The blocks without the plain entities and instances that are removed, the blocks under them, and the overrides
    // of instances that are gone.
    static List<SceneEntity> DropRemovedBlocks(List<SceneEntity> blocks)
    {
        var byId = blocks.Where(b => b.Path == null).ToDictionary(b => b.Id);
        bool Gone(SceneEntity b, int depth)
        {
            if (depth > 64)
            {
                return false;
            }
            if (b.Path != null)
            {
                return !byId.TryGetValue(b.Path[0], out var owner) || Gone(owner, depth + 1);
            }
            if (b.Removed)
            {
                return true;
            }
            var anchor = b.ParentPath?[0] ?? b.Parent;
            return anchor != 0 && byId.TryGetValue(anchor, out var parent) && Gone(parent, depth + 1);
        }
        var kept = blocks.Where(b => !Gone(b, 0)).ToList();
        foreach (var b in kept.Where(b => b.Path == null))
        {
            b.Removed = false;
        }
        return kept;
    }

    // An override over another of the same entity: its keys, components and behaviours over the block's.
    static void MergeBlock(SceneEntity block, SceneEntity over)
    {
        var removed = over.RemovedComponents.Where(id => !block.RemovedComponents.Contains(id)).ToList();
        PrefabExpansion.ApplyOverride(block, over);
        block.RemovedComponents.AddRange(removed);
        block.RemovedBehaviours.AddRange(over.RemovedBehaviours.Where(s => !block.RemovedBehaviours.Contains(s)));
        block.Keys |= over.Keys;
        if (over.Keys.HasFlag(SceneKeys.Parent))
        {
            block.Parent = over.Parent;
            block.ParentPath = over.ParentPath;
        }
        block.Removed |= over.Removed;
    }

    // Rewrites the paths that an entity's parent and references are written as. True if any changed.
    static bool RewritePaths(SceneEntity e, Func<IReadOnlyList<ulong>, IReadOnlyList<ulong>> rewrite)
    {
        var changed = false;
        if (e.ParentPath is { } pp && rewrite(pp) is var np && !np.SequenceEqual(pp))
        {
            e.ParentPath = np.Count > 1 ? np : null;
            e.Parent = ScenePath.Id(np);
            changed = true;
        }
        foreach (var list in e.Components.Select(c => c.Fields).Concat(e.Behaviours.Select(b => b.Fields)))
        {
            for (var i = 0; i < list.Count; i++)
            {
                if (list[i].Value.Path is { } path && rewrite(path) is var to && !to.SequenceEqual(path))
                {
                    list[i] = list[i] with { Value = SceneValue.EntityRef(to) };
                    changed = true;
                }
            }
        }
        return changed;
    }

    // The scene's references and parents that name entities by paths that are now plain IDs.
    static Operation[] Unpathed(SceneDocument document, HashSet<ulong> ids)
    {
        var changed = new List<SceneEntity>();
        foreach (var e in document.Scene.Entities)
        {
            var copy = e.Clone();
            if (Unpath(copy, ids))
            {
                changed.Add(copy);
            }
        }
        return changed.Count == 0 ? [] : [new BlockOperation(document, 0, [.. changed.Select(c => c.Id)], changed)];
    }

    static bool Unpath(SceneEntity e, HashSet<ulong> ids)
    {
        var changed = false;
        if (e.ParentPath != null && ids.Contains(e.Parent))
        {
            e.ParentPath = null;
            changed = true;
        }
        foreach (var list in e.Components.Select(c => c.Fields).Concat(e.Behaviours.Select(b => b.Fields)))
        {
            for (var i = 0; i < list.Count; i++)
            {
                if (list[i].Value is { Path: not null } v && ids.Contains(v.Entity))
                {
                    list[i] = list[i] with { Value = SceneValue.EntityRef(v.Entity) };
                    changed = true;
                }
            }
        }
        return changed;
    }
}
