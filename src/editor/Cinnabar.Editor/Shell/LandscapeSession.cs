using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Tools;
using AssetStatus = Cinnabar.Editor.Link.Cook.AssetStatus;
using Wire = Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The landscape tools (see docs/editor/landscape.md): the Landscape tool's brushes on the selected terrain, a
/// <c>Surface_Renderer</c>'s height map and hole mask. The maps are documents beside the scene, as meshes are: a stroke
/// paints the editor's texels, which the host draws and collides with as live textures in place of the cooked blobs,
/// goes on the scene's undo stack as the tiles that it changed, and saves with the scene as the PNGs that the cooker
/// reads. A saved map is let go of once the daemon has cooked it.
/// </summary>
public sealed class LandscapeSession(EditorShell shell)
{
    /// <summary>The context that is set while the one selected entity of the scene is a surface.</summary>
    public const string TerrainContext = "selection.terrain";

    /// <summary>The radii that the shelf offers, in meters.</summary>
    public static readonly IReadOnlyList<double> Radii = [1, 2, 4, 8, 16, 32, 64];

    /// <summary>The strengths and falloffs that the shelf offers, from 0 to 1.</summary>
    public static readonly IReadOnlyList<double> Shares = [0.1, 0.25, 0.5, 0.75, 1];

    /// <summary>A dab every quarter of the radius along a drag.</summary>
    const double Spacing = 0.25;

    readonly Dictionary<string, LandscapeMap> _maps = [];
    Stroking? _stroke;
    Wire.LandscapeOverlay _overlay = new(false, [0, 0, 0], [0, 1, 0], 0, 0);

    // A stroke under way: its map, the surface and pose it paints, its revision, the last hit, and the hole mask that its
    // first hole made, which the release names in the surface.
    sealed record Stroking(LandscapeStroke Stroke, LandscapeMap Map, LandscapeSurface Surface, Pose Pose, int Before, int Revision, LandscapeHit Last, bool NewMask);

    public LandscapeBrush Brush { get; private set; } = LandscapeBrush.Raise;

    /// <summary>The brush's radius, in meters on the surface.</summary>
    public double Radius { get; private set; } = 8;

    public double Strength { get; private set; } = 0.5;

    public double Falloff { get; private set; } = 0.5;

    /// <summary>The open maps, by GUID.</summary>
    public IReadOnlyCollection<LandscapeMap> Maps => _maps.Values;

    public bool AnyDirty => _maps.Values.Any(m => m.IsDirty);

    public bool IsStroking => _stroke != null;

    /// <summary>The brush, a map, or its dirty state changed.</summary>
    public event Action? Changed;

    /// <summary>The selected terrain: the one selected entity of the scene, when it has a <c>Surface_Renderer</c>.</summary>
    public LandscapeSurface? Surface =>
        shell.SelectedSceneEntities is [var entity] ? LandscapeSurface.Of(entity) : null;

    /// <summary>Whether the Landscape tool paints: it is the tool, and a terrain is selected in Edit.</summary>
    public bool IsActive => shell.Tool == Tool.Landscape && shell.CanEditScene && !shell.Mesh.InMeshMode && Surface != null;

    public void SetBrush(LandscapeBrush brush) => Set(() => Brush = brush);

    public void SetRadius(double meters) => Set(() => Radius = Math.Max(meters, 0.01));

    public void SetStrength(double share) => Set(() => Strength = Math.Clamp(share, 0, 1));

    public void SetFalloff(double share) => Set(() => Falloff = Math.Clamp(share, 0, 1));

    void Set(Action change)
    {
        change();
        shell.Commands.InvalidateAll();
        Changed?.Invoke();
    }

    /// <summary>Follows the selection and the scene: the terrain context, and the brush, which goes with them.</summary>
    internal void Sync()
    {
        shell.Context.Set(TerrainContext, Surface != null);
        if (!IsActive)
        {
            HideOverlay();
        }
    }

    /// <summary>
    /// Starts a stroke at a pixel of the frame, on the selected terrain under it. Returns false when the tool does not
    /// paint or the terrain is not under the pixel, so the click selects instead.
    /// </summary>
    public bool BeginStroke(Vec2 pixel)
    {
        if (_stroke != null || !IsActive || Surface is not { } surface || PoseOf(surface) is not { } pose || Pick(surface, pose, pixel) is not { } hit)
        {
            return false;
        }
        var newMask = false;
        LandscapeMap? map;
        if (Brush is LandscapeBrush.Hole or LandscapeBrush.Fill)
        {
            map = MaskOf(surface);
            if (map == null && surface.HoleMask == "")
            {
                map = NewMask(surface);
                newMask = map != null;
            }
        }
        else
        {
            map = HeightOf(surface);
            if (map == null && surface.HeightMap == "")
            {
                shell.Console.Add(LogLevel.Warning, "landscape: the surface has no height_map to sculpt. Name a height texture in its Surface_Renderer.");
            }
        }
        if (map == null)
        {
            return false;
        }
        if (!map.IsLive)
        {
            SendWhole(map);
        }
        var dab = DabAt(hit, map, surface);
        var stroke = new LandscapeStroke(map.Grid, Brush, dab);
        _stroke = new Stroking(stroke, map, surface, pose, map.Revision, LandscapeMap.NextRevision(), hit, newMask);
        map.Touched(stroke.Apply(dab), _stroke.Revision);
        return true;
    }

    /// <summary>Paints the stroke on to a pixel: dabs a quarter of the radius apart from the last hit, or none off the terrain.</summary>
    public void DragStroke(Vec2 pixel)
    {
        if (_stroke is not { } s || Pick(s.Surface, s.Pose, pixel) is not { } hit)
        {
            return;
        }
        var map = s.Map;
        var from = DabAt(s.Last, map, s.Surface);
        var to = DabAt(hit, map, s.Surface);
        // A ramp is drawn whole at each step, so it needs only the last dab.
        var dabs = Brush == LandscapeBrush.Ramp ? 1 : Math.Max(1, (int)Math.Ceiling(Distance(from, to) / Spacing));
        var changed = TexelRect.Empty;
        for (var i = 1; i <= dabs; i++)
        {
            var t = (double)i / dabs;
            changed = changed.Union(s.Stroke.Apply(to with { X = from.X + (to.X - from.X) * t, Y = from.Y + (to.Y - from.Y) * t }));
        }
        _stroke = s with { Last = hit };
        map.Touched(changed, s.Revision);
        Hover(pixel);
    }

    /// <summary>Ends the stroke as one undo entry on the scene's stack, with the hole mask that it made.</summary>
    public void EndStroke()
    {
        if (_stroke is not { } s)
        {
            return;
        }
        var patches = s.Stroke.Patches();
        var ops = new List<Operation>();
        if (s.NewMask)
        {
            ops.Add(new SetField(s.Surface.Entity, LandscapeSurface.ComponentId, "hole_mask", SceneValue.AssetRef(s.Map.Guid)));
        }
        if (patches.Count > 0)
        {
            ops.Add(new LandscapeOperation(s.Map, patches, s.Before, s.Revision));
        }
        var label = Brush is LandscapeBrush.Hole or LandscapeBrush.Fill ? "Paint Holes" : $"Sculpt ({Brush})";
        if (ops.Count == 0 || !shell.Edit(label, [.. ops]))
        {
            CancelStroke();
            return;
        }
        _stroke = null;
        Changed?.Invoke();
    }

    /// <summary>Ends the stroke by putting back what it painted, as Escape or a lost capture does.</summary>
    public void CancelStroke()
    {
        if (_stroke is not { } s)
        {
            return;
        }
        _stroke = null;
        s.Map.Touched(s.Stroke.Restore(), s.Before);
        if (s.NewMask)
        {
            Close(s.Map);
        }
    }

    /// <summary>Shows the brush on the terrain under a pixel, or hides it off the terrain. The game hears of it only when it changes.</summary>
    public void Hover(Vec2 pixel)
    {
        if (!IsActive || Surface is not { } surface || PoseOf(surface) is not { } pose || Pick(surface, pose, pixel) is not { } hit)
        {
            HideOverlay();
            return;
        }
        var world = pose.Rotation.Rotate(Vec3.Scale(hit.Local, Vec3.From(pose.Scale)));
        var up = pose.Rotation.Rotate(Vec3.UnitY);
        var scale = Math.Max(Math.Abs(pose.Scale[0]), Math.Abs(pose.Scale[2]));
        SendOverlay(new Wire.LandscapeOverlay(true,
            [pose.Position[0] + (long)Math.Round(world.X * Pose.Unit), pose.Position[1] + (long)Math.Round(world.Y * Pose.Unit), pose.Position[2] + (long)Math.Round(world.Z * Pose.Unit)],
            [(float)up.X, (float)up.Y, (float)up.Z], (float)(Radius * scale), (float)Falloff));
    }

    void HideOverlay()
    {
        if (_overlay.Visible)
        {
            SendOverlay(_overlay with { Visible = false });
        }
    }

    void SendOverlay(Wire.LandscapeOverlay overlay)
    {
        if (overlay.Visible == _overlay.Visible && overlay.Radius == _overlay.Radius && overlay.Falloff == _overlay.Falloff
            && overlay.Center.SequenceEqual(_overlay.Center) && overlay.Up.SequenceEqual(_overlay.Up))
        {
            return;
        }
        _overlay = overlay;
        shell.Host.Send(overlay);
    }

    /// <summary>The terrain under a pixel of the frame, as the editor picks it itself, at once.</summary>
    public LandscapeHit? Pick(LandscapeSurface surface, Pose pose, Vec2 pixel)
    {
        var (width, height) = shell.FrameSize;
        if (width <= 0 || height <= 0)
        {
            return null;
        }
        var ray = shell.Camera.Ray(pixel, width, height);
        // Into the entity's space: relative to its position, turned back and unscaled.
        var origin = Vec3.Between(shell.Camera.Position, pose.Position);
        var inverse = pose.Rotation.Conjugate;
        var scale = Vec3.From(pose.Scale);
        static Vec3 Unscale(Vec3 v, Vec3 s) => new(Divide(v.X, s.X), Divide(v.Y, s.Y), Divide(v.Z, s.Z));
        var from = Unscale(inverse.Rotate(ray.Origin - origin), scale);
        var along = Unscale(inverse.Rotate(ray.Direction), scale);
        var grid = HeightOf(surface)?.Grid ?? new HeightGrid(1, 1, 0);
        return LandscapePick.Ray(surface, grid, MaskOf(surface)?.Grid, from, along);
    }

    static double Divide(double a, double b) => Math.Abs(b) < 1e-12 ? 0 : a / b;

    Pose? PoseOf(LandscapeSurface surface) =>
        shell.Scene?.Expanded.Flat.Find(surface.Entity) is { } entity ? SceneEdits.WorldPose(shell.Scene.Expanded.Flat, entity) : null;

    // A dab at a hit, in the texels of a map: the brush's radius in meters is a share of the surface's size.
    BrushDab DabAt(LandscapeHit hit, LandscapeMap map, LandscapeSurface surface) => new(
        hit.U * map.Grid.Width, hit.V * map.Grid.Height,
        Math.Max(Radius / surface.SizeX * map.Grid.Width, 0.5), Math.Max(Radius / surface.SizeZ * map.Grid.Height, 0.5),
        Strength, Falloff);

    // How many radii apart two dabs are.
    static double Distance(BrushDab a, BrushDab b)
    {
        double dx = (b.X - a.X) / a.RadiusX, dy = (b.Y - a.Y) / a.RadiusY;
        return Math.Sqrt(dx * dx + dy * dy);
    }

    /// <summary>The surface's height map, opened from its file the first time, or null when it has none or cannot be read.</summary>
    public LandscapeMap? HeightOf(LandscapeSurface surface) => Open(surface.HeightMap, LandscapeMapKind.Height);

    /// <summary>The surface's hole mask, opened from its file the first time, or null when it has none or cannot be read.</summary>
    public LandscapeMap? MaskOf(LandscapeSurface surface) => Open(surface.HoleMask, LandscapeMapKind.Mask);

    LandscapeMap? Open(string guid, LandscapeMapKind kind)
    {
        if (guid == "")
        {
            return null;
        }
        if (_maps.TryGetValue(guid, out var open))
        {
            return open;
        }
        if (shell.Assets.Find(guid) is not { } asset || shell.Assets.FullPath(asset) is not { } path)
        {
            return null;
        }
        if (LandscapeMap.Open(guid, path, kind) is not { } map)
        {
            shell.Console.Add(LogLevel.Error, $"landscape: cannot read {path} as a PNG of 8- or 16-bit texels without a palette or interlacing");
            return null;
        }
        Add(map);
        return map;
    }

    // A new hole mask for a surface that has none (see docs/editor/landscape.md#holes): one texel a finest cell, all solid,
    // beside the height map, or the scene, named for the entity. Its file and .meta are written when it saves.
    LandscapeMap? NewMask(LandscapeSurface surface)
    {
        var beside = HeightOf(surface)?.Path ?? shell.Scene?.Path;
        if (beside == null || shell.Scene?.Expanded.Flat.Find(surface.Entity) is not { } entity)
        {
            return null;
        }
        var name = string.Concat((entity.Name.Length > 0 ? entity.Name : $"{entity.Id:x16}").Select(c => char.IsLetterOrDigit(c) ? char.ToLowerInvariant(c) : '_'));
        var directory = Path.GetDirectoryName(beside)!;
        var path = Path.Combine(directory, $"{name}_holes.png");
        for (var n = 2; File.Exists(path) || _maps.Values.Any(m => string.Equals(m.Path, path, StringComparison.OrdinalIgnoreCase)); n++)
        {
            path = Path.Combine(directory, $"{name}_holes_{n}.png");
        }
        var (x, z) = surface.Cells;
        var map = new LandscapeMap(System.Guid.NewGuid().ToString("N"), path, LandscapeMapKind.Mask, new HeightGrid(x, z, 65535));
        Add(map);
        return map;
    }

    void Add(LandscapeMap map)
    {
        _maps[map.Guid] = map;
        map.Changed += OnMapChanged;
        Changed?.Invoke();
    }

    void Close(LandscapeMap map)
    {
        Release(map);
        map.Changed -= OnMapChanged;
        _maps.Remove(map.Guid);
        Changed?.Invoke();
    }

    // A stroke's step, an undo or a redo: the host gets the rectangle, or the whole map when it does not have it.
    void OnMapChanged(LandscapeMap map, TexelRect rect)
    {
        if (!map.IsLive)
        {
            SendWhole(map);
        }
        else if (!rect.IsEmpty)
        {
            shell.Host.Send(new Wire.LiveTextureRegion(Convert.FromHexString(map.Guid), [(uint)rect.X, (uint)rect.Y],
                [(uint)rect.Width, (uint)rect.Height], map.Grid.Read(rect)));
        }
        Changed?.Invoke();
    }

    void SendWhole(LandscapeMap map)
    {
        map.IsLive = true;
        shell.Host.Send(new Wire.LiveTexture(Convert.FromHexString(map.Guid),
            map.Kind == LandscapeMapKind.Height ? Wire.LiveTextureUsage.Height : Wire.LiveTextureUsage.Mask,
            [(uint)map.Grid.Width, (uint)map.Grid.Height], map.Grid.Texels));
    }

    void Release(LandscapeMap map)
    {
        if (map.IsLive)
        {
            map.IsLive = false;
            shell.Host.Send(new Wire.ReleaseLiveTexture(Convert.FromHexString(map.Guid)));
        }
    }

    /// <summary>
    /// Saves every dirty map that the scene names, through temporary files, with a new mask's <c>.meta</c>. A new mask
    /// that an undo took out of the scene is not written. A failure goes to the console.
    /// </summary>
    public bool SaveMaps()
    {
        var ok = true;
        var named = shell.Scene?.Expanded.Flat.Entities.Select(LandscapeSurface.Of).OfType<LandscapeSurface>()
            .SelectMany(s => new[] { s.HeightMap, s.HoleMask }).ToHashSet() ?? [];
        foreach (var map in _maps.Values.Where(m => m.IsDirty && named.Contains(m.Guid)).ToList())
        {
            try
            {
                var meta = map.Path + ".meta";
                if (map.SavedRevision == null && !File.Exists(meta))
                {
                    SceneDocument.WriteAtomically(meta, MaskMeta(map.Guid));
                }
                map.Save();
                shell.Console.Add(LogLevel.Info, $"landscape: saved {map.Path}");
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                shell.Console.Add(LogLevel.Error, $"landscape: cannot save {map.Path}: {e.Message}");
                ok = false;
            }
        }
        Changed?.Invoke();
        return ok;
    }

    /// <summary>A new hole mask's <c>.meta</c>: a mask, with box mips and clamped, as docs/rendering/surfaces.md#holes asks.</summary>
    public static string MaskMeta(string guid) =>
        "# cinnabar asset metadata. Keep this file next to its asset (see docs/content/identity-and-cooking.md#identity).\n" +
        $"guid = {guid}\nusage = mask\n\n[mip_map]\nkernel = box\n\n[sampler]\nwrap = clamp\n";

    /// <summary>Lets go of each saved map whose cooked blob is current, so the host draws the blob.</summary>
    internal void ReleaseCooked()
    {
        foreach (var map in _maps.Values)
        {
            if (map.IsLive && !map.IsDirty && shell.Assets.Find(map.Guid) is { Status: AssetStatus.Current })
            {
                Release(map);
            }
        }
    }

    /// <summary>Sends every live map again, and the brush, as after a resync or a soft restart, which lose the host's copies.</summary>
    internal void SendLiveMaps()
    {
        foreach (var map in _maps.Values.Where(m => m.IsLive))
        {
            SendWhole(map);
        }
        if (_overlay.Visible)
        {
            shell.Host.Send(_overlay);
        }
    }

    /// <summary>The scene's maps close with it, unsaved strokes and all.</summary>
    internal void CloseMaps()
    {
        CancelStroke();
        HideOverlay();
        foreach (var map in _maps.Values.ToList())
        {
            Close(map);
        }
    }
}
