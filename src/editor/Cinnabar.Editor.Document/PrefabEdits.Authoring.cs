namespace Cinnabar.Editor.Document;

/// <summary>Duplicating entities and making prefabs from them.</summary>
public static partial class PrefabEdits
{
    /// <summary>
    /// Copies an entity and its descendants with new scene IDs, under the same parent, as one undo entry's operations,
    /// and the copy's ID. An instance's root copies as a new instance with its override blocks on the new instance's
    /// paths; a prefab's entity under another, which the copy cannot instantiate, copies as plain entities, as the
    /// expansion gives them. A reference inside the copied entities to one of them refers to its copy.
    /// </summary>
    public static (Operation[] Operations, ulong Copy) Duplicate(SceneDocument document, ulong id)
    {
        var expansion = document.Expanded;
        var top = expansion.Flat.Find(id) ?? throw new InvalidOperationException($"the scene has no entity {id:x16}");
        var originals = new List<SceneEntity> { top };
        originals.AddRange(SceneEdits.Descendants(expansion.Flat, id));
        var taken = new HashSet<ulong>(expansion.Flat.Entities.Select(e => e.Id));
        ulong Fresh()
        {
            ulong fresh;
            do
            {
                fresh = SceneEntity.NewId();
            } while (!taken.Add(fresh));
            return fresh;
        }
        // An instance copies whole when its root is among the copied entities and the copy can name the prefab: an
        // outermost instance, whose root is the instance block.
        var instances = new Dictionary<ulong, ulong>();
        foreach (var e in originals.Where(e => expansion.InstanceOf(e.Id) is { IsInstanceRoot: true }))
        {
            instances[e.Id] = Fresh();
        }
        var ids = new Dictionary<ulong, ulong>();
        var paths = new Dictionary<ulong, IReadOnlyList<ulong>>();
        foreach (var e in originals)
        {
            if (expansion.InstanceOf(e.Id) is { } info && instances.TryGetValue(info.Instance, out var to))
            {
                IReadOnlyList<ulong> path = [to, .. info.Path.Skip(1)];
                ids[e.Id] = ScenePath.Id(path);
                paths[ids[e.Id]] = path;
            }
            else
            {
                ids[e.Id] = Fresh();
            }
        }
        SceneValue Remap(SceneValue v) => v.Kind == SceneValueKind.Entity && ids.TryGetValue(v.Entity, out var to)
            ? (paths.TryGetValue(to, out var path) && path.Count > 1 ? SceneValue.EntityRef(path) : SceneValue.EntityRef(to))
            : v;
        void RemapFields(SceneEntity e)
        {
            for (var i = 0; i < e.Components.Count; i++)
            {
                e.Components[i] = e.Components[i] with { Fields = [.. e.Components[i].Fields.Select(f => f with { Value = Remap(f.Value) })] };
            }
            for (var i = 0; i < e.Behaviours.Count; i++)
            {
                e.Behaviours[i] = e.Behaviours[i] with { Fields = [.. e.Behaviours[i].Fields.Select(f => f with { Value = Remap(f.Value) })] };
            }
        }
        var ops = new List<Operation>();
        foreach (var e in originals)
        {
            var info = expansion.InstanceOf(e.Id);
            if (info is { IsInstanceRoot: true })
            {
                var to = instances[e.Id];
                var blocks = BlocksOf(document.Scene, e.Id).Select(b =>
                {
                    var copy = b.Path == null ? b.Copy(to) : CopyBlock(b, [to, .. b.Path.Skip(1)]);
                    if (b.Path == null)
                    {
                        copy.Parent = ids.GetValueOrDefault(b.Parent, b.Parent);
                        copy.ParentPath = paths.GetValueOrDefault(copy.Parent) is { Count: > 1 } p ? p : b.Parent == copy.Parent ? b.ParentPath : null;
                    }
                    else if (copy.Keys.HasFlag(SceneKeys.Parent))
                    {
                        copy.Parent = ids.GetValueOrDefault(b.Parent, b.Parent);
                        copy.ParentPath = paths.GetValueOrDefault(copy.Parent);
                    }
                    RemapFields(copy);
                    return copy;
                }).ToList();
                ops.Add(new BlockOperation(document, to, [], blocks));
            }
            else if (info != null && instances.ContainsKey(info.Instance))
            {
                // It comes with its instance's copy.
            }
            else
            {
                var copy = e.Copy(ids[e.Id]);
                copy.Parent = ids.GetValueOrDefault(e.Parent, e.Parent);
                copy.ParentPath = paths.GetValueOrDefault(copy.Parent) is { Count: > 1 } p ? p : PathOf(expansion, copy.Parent);
                RemapFields(copy);
                ops.Add(new CreateEntity(copy));
            }
        }
        return ([.. ops], ids[id]);
    }

    // An override block on another path, with the same overrides.
    static SceneEntity CopyBlock(SceneEntity b, IReadOnlyList<ulong> path)
    {
        var copy = new SceneEntity(path) { Name = b.Name, Parent = b.Parent, ParentPath = b.ParentPath, Active = b.Active, Keys = b.Keys, Removed = b.Removed };
        copy.Components.AddRange(b.Components.Select(c => c.Copy()));
        copy.Behaviours.AddRange(b.Behaviours.Select(x => x.Copy()));
        copy.UnknownKeys.AddRange(b.UnknownKeys);
        copy.RemovedComponents.AddRange(b.RemovedComponents);
        copy.RemovedBehaviours.AddRange(b.RemovedBehaviours);
        return copy;
    }

    /// <summary>
    /// Makes a prefab of a plain entity and its descendants, and replaces them in the scene with an instance of it, as
    /// one undo entry's operations: the prefab, a new document in the set with a fresh GUID, which its first save writes
    /// to <paramref name="path"/> with its <c>.meta</c> file, has the entities with their scene IDs and the root at the
    /// origin; the instance takes the root's ID and its pose; and every reference elsewhere in the scene to one of the
    /// entities becomes a path. The entities' scene IDs become their paths', so the host gets the difference.
    /// </summary>
    public static (Operation[] Operations, PrefabDocument Prefab) MakePrefab(SceneDocument document, ulong id, string path)
    {
        if (document.Expanded.InstanceOf(id) != null)
        {
            throw new InvalidOperationException("the entity is inside an instance. Unpack it first, or make a prefab of a plain entity.");
        }
        var root = document.Scene.Find(id) ?? throw new InvalidOperationException($"the scene has no entity {id:x16}");
        // The blocks of the tree: the plain entities under the root, and the instances among them with their overrides.
        var tree = new HashSet<ulong> { id };
        foreach (var d in SceneEdits.Descendants(document.Expanded.Flat, id))
        {
            tree.Add(d.Id);
        }
        var blocks = document.Scene.Entities.Where(e => e.Path == null ? tree.Contains(e.Id) : tree.Contains(e.Path[0])).ToList();
        var guid = Convert.ToHexStringLower(Guid.NewGuid().ToByteArray());
        var prefab = new Scene();
        foreach (var b in blocks)
        {
            var copy = b.Clone();
            if (b.Id == id)
            {
                copy.Parent = 0;
                copy.ParentPath = null;
                copy.Components.RemoveAll(c => c.Id is SceneEdits.LocalTransformId);
                copy.Components.RemoveAll(c => c.Id is SceneEdits.TransformId);
                copy.Components.Insert(0, new SceneComponent(SceneEdits.TransformId, "Transform", SceneEdits.TransformFields(Pose.Identity)));
            }
            // A prefab refers to nothing outside itself.
            foreach (var list in copy.Components.Select(c => c.Fields).Concat(copy.Behaviours.Select(x => x.Fields)))
            {
                for (var i = 0; i < list.Count; i++)
                {
                    if (list[i].Value is { Kind: SceneValueKind.Entity } v && v.Entity != 0 && !tree.Contains(v.Entity) && !blocks.Any(x => x.Id == v.Entity))
                    {
                        list[i] = list[i] with { Value = SceneValue.EntityRef(0) };
                    }
                }
            }
            prefab.Entities.Add(copy);
        }
        var document2 = new PrefabDocument(path, guid, prefab, null);
        var instance = new SceneEntity(id) { Prefab = guid, Parent = root.Parent, ParentPath = root.ParentPath };
        instance.Components.AddRange(root.Components.Where(c => c.Id is SceneEdits.TransformId or SceneEdits.LocalTransformId).Select(c => c.Copy()));
        // The rest of the scene names the tree's entities by their paths in the instance.
        IReadOnlyList<ulong> Rerooted(IReadOnlyList<ulong> p) =>
            p[0] == id ? p : tree.Contains(p[0]) ? [id, .. p] : p;
        var changed = new List<SceneEntity>();
        foreach (var e in document.Scene.Entities.Where(e => !blocks.Contains(e)))
        {
            var copy = e.Clone();
            var any = false;
            if (copy.Parent != 0 && copy.Parent != id && tree.Contains(copy.Parent) || copy.ParentPath is { } pp && tree.Contains(pp[0]) && pp[0] != id)
            {
                var np = Rerooted(copy.ParentPath ?? [copy.Parent]);
                copy.ParentPath = np;
                copy.Parent = ScenePath.Id(np);
                any = true;
            }
            foreach (var list in copy.Components.Select(c => c.Fields).Concat(copy.Behaviours.Select(x => x.Fields)))
            {
                for (var i = 0; i < list.Count; i++)
                {
                    if (list[i].Value is { Kind: SceneValueKind.Entity } v && v.Entity != id && (v.Path is { } vp ? tree.Contains(vp[0]) && vp[0] != id : tree.Contains(v.Entity)))
                    {
                        list[i] = list[i] with { Value = SceneValue.EntityRef(Rerooted(v.Path ?? [v.Entity])) };
                        any = true;
                    }
                }
            }
            if (any)
            {
                changed.Add(copy);
            }
        }
        return ([
            new PrefabSetOperation(document.Prefabs, guid, document2),
            new BlockOperation(document, id, [.. blocks.Select(b => b.Id), .. changed.Select(c => c.Id)], [instance, .. changed]),
        ], document2);
    }
}
