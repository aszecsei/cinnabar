using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Model;
using Wire = Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The landscape tools' foliage (see docs/editor/landscape.md#foliage): the Scatter and Erase brushes place and take
/// away instances of a foliage layer, a child of the terrain with an <c>Instanced_Mesh_Renderer</c>, whose instance
/// set is an <c>.instances</c> file. The host draws the set from the editor's instances while it is edited, as it draws
/// the maps.
/// </summary>
public sealed partial class LandscapeSession
{
    /// <summary>The <c>Instanced_Mesh_Renderer</c>'s stable ID.</summary>
    public const ulong InstancedMeshRendererId = 53;

    /// <summary>The densities that the shelf offers, in instances on 100 square meters.</summary>
    public static readonly IReadOnlyList<double> Densities = [1, 2, 5, 10, 20, 50];

    /// <summary>The least and the most of an instance's random scale.</summary>
    public const double ScaleMin = 0.8, ScaleMax = 1.2;

    readonly Dictionary<string, FoliageSet> _sets = [];
    int _foliageSeed = 1;

    // A foliage stroke under way: its set, the terrain and its pose, the foliage layer's entity and pose, the instances
    // before it and now, its random numbers, and whether its first dab made the set, which the release names.
    sealed record FoliageStroking(FoliageSet Set, LandscapeSurface Surface, Pose Pose, ulong Entity, Pose LayerPose,
        IReadOnlyList<FoliageInstance> Before, List<FoliageInstance> Now, Random Random, bool NewSet);

    /// <summary>How many instances Scatter puts on 100 square meters.</summary>
    public double Density { get; private set; } = 10;

    public void SetDensity(double density) => Set(() => Density = Math.Max(density, 0.01));

    /// <summary>The open foliage sets, by GUID.</summary>
    public IReadOnlyCollection<FoliageSet> Sets => _sets.Values;

    bool IsFoliageLayer(SceneEntity entity) =>
        entity.Parent != 0 && entity.Components.Any(c => c.Id == InstancedMeshRendererId);

    /// <summary>
    /// The foliage layer that Scatter and Erase paint: the selected entity, when it is a foliage layer of the terrain,
    /// else the terrain's first one, or null when it has none.
    /// </summary>
    public SceneEntity? FoliageLayer(LandscapeSurface surface)
    {
        if (shell.SelectedSceneEntities is [var selected] && IsFoliageLayer(selected) && selected.Parent == surface.Entity)
        {
            return selected;
        }
        return shell.Scene?.Expanded.Flat.Entities.FirstOrDefault(e => e.Parent == surface.Entity && IsFoliageLayer(e));
    }

    static string InstancesOf(SceneEntity layer) =>
        layer.Components.First(c => c.Id == InstancedMeshRendererId).Fields.FirstOrDefault(f => f.Name == "instances")?.Value is { Kind: SceneValueKind.Asset } v ? v.Asset : "";

    // A foliage stroke and its first dab, or null when the terrain has no foliage layer whose set the brush can paint.
    Painting.OnFoliage? BeginFoliage(LandscapeSurface surface, Pose pose, LandscapeHit hit)
    {
        if (FoliageLayer(surface) is not { } layer)
        {
            shell.Console.Add(LogLevel.Warning, "landscape: the terrain has no foliage layer. Add a child entity with an Instanced_Mesh_Renderer that names the foliage's mesh.");
            return null;
        }
        if (shell.Scene?.Expanded.Flat is not { } flat || SceneEdits.WorldPose(flat, layer) is not { } layerPose)
        {
            return null;
        }
        var guid = InstancesOf(layer);
        var newSet = false;
        FoliageSet? set;
        if (guid == "")
        {
            set = NewSet(surface, layer);
            newSet = set != null;
        }
        else
        {
            set = OpenSet(guid);
        }
        if (set == null)
        {
            return null;
        }
        if (!set.IsLive)
        {
            SendSet(set);
        }
        var painting = new Painting.OnFoliage(this, Brush, Layer,
            new FoliageStroking(set, surface, pose, layer.Id, layerPose, set.Instances, [.. set.Instances], new Random(_foliageSeed++), newSet));
        Dab(painting, hit);
        return painting;
    }

    void DragFoliage(Painting.OnFoliage painting, Vec2 pixel)
    {
        var f = painting.Stroking;
        if (Pick(f.Surface, f.Pose, pixel) is not { } hit)
        {
            return;
        }
        Dab(painting, hit);
        Hover(pixel);
    }

    void EndFoliage(Painting.OnFoliage painting)
    {
        var f = painting.Stroking;
        var ops = new List<Operation>();
        if (f.NewSet)
        {
            ops.Add(new SetField(f.Entity, InstancedMeshRendererId, "instances", SceneValue.AssetRef(f.Set.Guid)));
        }
        if (!f.Now.SequenceEqual(f.Before))
        {
            ops.Add(new FoliageOperation(f.Set, f.Before, f.Set.Instances));
        }
        if (ops.Count == 0 || !shell.Edit(painting.Brush == LandscapeBrush.Erase ? "Erase Foliage" : "Scatter Foliage", [.. ops]))
        {
            CancelFoliage(painting);
            return;
        }
        _painting = null;
        Changed?.Invoke();
    }

    void CancelFoliage(Painting.OnFoliage painting)
    {
        var f = painting.Stroking;
        _painting = null;
        f.Set.Set(f.Before);
        if (f.NewSet)
        {
            CloseSet(f.Set);
        }
    }

    // One dab at a hit: Scatter adds instances in the brush's circle until it holds the density's share, no nearer each
    // other than half the spacing that the density gives, where the terrain has no hole; Erase takes away those in it.
    void Dab(Painting.OnFoliage painting, LandscapeHit hit)
    {
        var f = painting.Stroking;
        var center = new Vec2(hit.Local.X, hit.Local.Z);
        bool Inside(FoliageInstance i, double radius) => (TerrainPoint(f, i.Position) is var p) && (new Vec2(p.X, p.Z) - center).Length <= radius;
        if (painting.Brush == LandscapeBrush.Erase)
        {
            if (f.Now.RemoveAll(i => Inside(i, Radius)) > 0)
            {
                f.Set.Set([.. f.Now]);
            }
            return;
        }
        var spacing = Math.Sqrt(100 / Density) / 2;
        var near = f.Now.Where(i => Inside(i, Radius + spacing)).Select(i => TerrainPoint(f, i.Position)).Select(p => new Vec2(p.X, p.Z)).ToList();
        var target = Density / 100 * Math.PI * Radius * Radius;
        var wanted = (int)Math.Round((target - near.Count(p => (p - center).Length <= Radius)) * Strength);
        var height = HeightOf(f.Surface)?.Grid;
        var mask = MaskOf(f.Surface)?.Grid;
        var added = 0;
        for (var attempt = 0; attempt < wanted * 4 && added < wanted; attempt++)
        {
            var angle = f.Random.NextDouble() * 2 * Math.PI;
            var distance = Radius * Math.Sqrt(f.Random.NextDouble());
            var point = center + new Vec2(Math.Cos(angle), Math.Sin(angle)) * distance;
            var (u, v) = f.Surface.UvOf(point.X, point.Y);
            if (u is < 0 or > 1 || v is < 0 or > 1 || (mask != null && mask.Nearest(u, v) == 0) || near.Any(p => (p - point).Length < spacing))
            {
                continue;
            }
            var y = height != null ? f.Surface.HeightOf(height.Sample(u, v)) : f.Surface.Low;
            var yaw = f.Random.NextDouble() * 2 * Math.PI;
            var scale = ScaleMin + (ScaleMax - ScaleMin) * f.Random.NextDouble();
            f.Now.Add(new FoliageInstance(LayerPoint(f, new Vec3(point.X, y, point.Y)), Rotations.AxisAngle(Vec3.UnitY, yaw), new Vec3(scale, scale, scale)));
            near.Add(point);
            added++;
        }
        if (added > 0)
        {
            f.Set.Set([.. f.Now]);
        }
    }

    // A point in the foliage layer's space, in the terrain's space, and back: each through the world, relative to the
    // terrain's position.
    static Vec3 TerrainPoint(FoliageStroking f, Vec3 layerLocal)
    {
        var relative = Vec3.Between(f.Pose.Position, f.LayerPose.Position) + f.LayerPose.Rotation.Rotate(Vec3.Scale(layerLocal, Vec3.From(f.LayerPose.Scale)));
        return Unscaled(f.Pose.Rotation.Conjugate.Rotate(relative), f.Pose.Scale);
    }

    static Vec3 LayerPoint(FoliageStroking f, Vec3 terrainLocal)
    {
        var relative = f.Pose.Rotation.Rotate(Vec3.Scale(terrainLocal, Vec3.From(f.Pose.Scale))) - Vec3.Between(f.Pose.Position, f.LayerPose.Position);
        return Unscaled(f.LayerPose.Rotation.Conjugate.Rotate(relative), f.LayerPose.Scale);
    }

    static Vec3 Unscaled(Vec3 v, double[] scale) => new(Divide(v.X, scale[0]), Divide(v.Y, scale[1]), Divide(v.Z, scale[2]));

    FoliageSet? OpenSet(string guid)
    {
        if (_sets.TryGetValue(guid, out var open))
        {
            return open;
        }
        if (shell.Assets.Find(guid) is not { } asset || shell.Assets.FullPath(asset) is not { } path)
        {
            return null;
        }
        if (!path.EndsWith(InstancesFile.Extension, StringComparison.OrdinalIgnoreCase))
        {
            shell.Console.Add(LogLevel.Error, $"landscape: the foliage layer's instance set is {path}, which the foliage brushes cannot paint: they paint {InstancesFile.Extension} files");
            return null;
        }
        var (set, problem) = FoliageSet.Open(guid, path);
        if (set == null)
        {
            shell.Console.Add(LogLevel.Error, $"landscape: cannot read {path}: {problem}");
            return null;
        }
        AddSet(set);
        return set;
    }

    // A new .instances file for a foliage layer without one, beside the terrain's height map or the scene, named for the
    // layer. Its file and .meta are written when it saves.
    FoliageSet? NewSet(LandscapeSurface surface, SceneEntity layer)
    {
        var beside = HeightOf(surface)?.Path ?? shell.Scene?.Path;
        if (beside == null)
        {
            return null;
        }
        var name = string.Concat((layer.Name.Length > 0 ? layer.Name : $"{layer.Id:x16}").Select(c => char.IsLetterOrDigit(c) ? char.ToLowerInvariant(c) : '_'));
        var directory = Path.GetDirectoryName(beside)!;
        var path = Path.Combine(directory, name + InstancesFile.Extension);
        for (var n = 2; File.Exists(path) || _sets.Values.Any(s => string.Equals(s.Path, path, StringComparison.OrdinalIgnoreCase)); n++)
        {
            path = Path.Combine(directory, $"{name}_{n}{InstancesFile.Extension}");
        }
        var set = new FoliageSet(System.Guid.NewGuid().ToString("N"), path);
        AddSet(set);
        return set;
    }

    void AddSet(FoliageSet set)
    {
        _sets[set.Guid] = set;
        set.Changed += SendSet;
        Changed?.Invoke();
    }

    void CloseSet(FoliageSet set)
    {
        ReleaseSet(set);
        set.Changed -= SendSet;
        _sets.Remove(set.Guid);
        Changed?.Invoke();
    }

    // The whole set goes to the host at each change: a set is small next to a map.
    void SendSet(FoliageSet set)
    {
        set.Sent();
        var instances = set.Instances;
        var positions = new float[instances.Count * 3];
        var rotations = new float[instances.Count * 4];
        var scales = new float[instances.Count * 3];
        for (var i = 0; i < instances.Count; i++)
        {
            var (p, r, s) = (instances[i].Position, instances[i].Rotation, instances[i].Scale);
            (positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2]) = ((float)p.X, (float)p.Y, (float)p.Z);
            (rotations[i * 4], rotations[i * 4 + 1], rotations[i * 4 + 2], rotations[i * 4 + 3]) = ((float)r.X, (float)r.Y, (float)r.Z, (float)r.W);
            (scales[i * 3], scales[i * 3 + 1], scales[i * 3 + 2]) = ((float)s.X, (float)s.Y, (float)s.Z);
        }
        shell.Host.Send(new Wire.LiveInstances(Convert.FromHexString(set.Guid), positions, rotations, scales));
        Changed?.Invoke();
    }

    void ReleaseSet(FoliageSet set)
    {
        if (set.Release())
        {
            shell.Host.Send(new Wire.ReleaseLiveInstances(Convert.FromHexString(set.Guid)));
        }
    }

    // Saves every dirty set that a foliage layer of the scene names, with a new set's .meta.
    bool SaveSets()
    {
        var named = shell.Scene?.Expanded.Flat.Entities.Where(e => e.Components.Any(c => c.Id == InstancedMeshRendererId)).Select(InstancesOf).ToHashSet() ?? [];
        return SnapshotSaves.SaveDirty(_sets.Values.Where(s => named.Contains(s.Guid)), "landscape", shell.Console);
    }

    void ReleaseCookedSets()
    {
        foreach (var set in SnapshotSaves.Cooked(_sets.Values, shell.Assets))
        {
            ReleaseSet(set);
        }
    }

    void SendLiveSets()
    {
        foreach (var set in _sets.Values.Where(s => s.IsLive))
        {
            SendSet(set);
        }
    }

    void CloseSets()
    {
        foreach (var set in _sets.Values.ToList())
        {
            CloseSet(set);
        }
    }
}
