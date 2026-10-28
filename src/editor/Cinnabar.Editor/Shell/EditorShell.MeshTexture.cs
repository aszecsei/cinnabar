using System.Globalization;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Tools;
using GizmoKind = Cinnabar.Editor.Link.Protocol.GizmoKind;

namespace Cinnabar.Editor.Shell;

/// <summary>How Align Texture sets a face's axes.</summary>
public enum TextureAlignment
{
    World,
    Face,
    ToEdge,
    ToFace,
}

/// <summary>Which hotspot the Hotspot tool maps a face onto.</summary>
public enum HotspotChoice
{
    Best,
    Next,
    Random,
}

/// <summary>A dev material, by name and GUID (see docs/editor/mesh-editing.md#dev-materials).</summary>
public sealed record DevMaterial(string Name, string Guid);

/// <summary>
/// The texture tools in the shell (see docs/editor/mesh-editing.md#texture-tools): each runs on the selected faces of
/// every edited mesh as one undo entry, and the Face panel's drags run them as a scrub. The project's texel density
/// and each material's tool texture, from the cook index, give new faces their scale and the Face panel its density.
/// Transform Texture turns the gizmo onto the selected faces' mappings instead of their vertices.
/// </summary>
public sealed partial class EditorShell
{
    /// <summary>The project setting of the texture tools' density, in texels per meter.</summary>
    public const string TexelDensityKey = "mesh.texel_density";

    /// <summary>The engine's dev grid texture, which the dev materials sample: 1024 texels square.</summary>
    public const string DevGridTexture = "9c4e2a7b1d3f4a5c8e6b0d2f4a6c8e01";
    const double DevGridSize = 1024;

    /// <summary>The dev materials, gray first, as the Texture group's dropdown and the Face panel's picker offer them.</summary>
    public static readonly IReadOnlyList<DevMaterial> DevMaterials =
    [
        new("Gray", DevGrayMaterial),
        new("Blue", "6b2d4f809c3e5a718b2d4f6a8c0d2e3f"),
        new("Orange", "7c3e5a91ad4f6b829c3e5a7b9d1e3f40"),
        new("Green", "8d4f6ba2be507c93ad4f6b8cae2f4051"),
        new("Red", "9e507cb3cf618da4be507c9dbf305162"),
        new("Yellow", "af618dc4d0729eb5cf618daec0416273"),
        new("Sky", "b0729ed5e183afc6d0729ebfd1527384"),
    ];

    public static readonly IReadOnlyList<string> DensityOptions = ["32", "64", "128", "256", "512", "1024", "2048"];

    TextureDrag? _textureDrag;
    Dictionary<string, MeshData>? _mappingStarts;
    string? _faceMaterialKey;
    double? _texelDensityOverride;

    /// <summary>The face last clicked in the Faces kind, which Align to Face copies from, or null.</summary>
    public MeshItem? ActiveFace { get; private set; }

    /// <summary>The gizmo drags the selected faces' mappings instead of their vertices.</summary>
    public bool TextureGizmo { get; private set; }

    /// <summary>The project's texel density: <c>mesh.texel_density</c>, or 256 texels per meter.</summary>
    public double TexelDensity => _texelDensityOverride
        ?? (double.TryParse(ProjectSettings.Get(ProjectPath, TexelDensityKey), NumberStyles.Float, CultureInfo.InvariantCulture, out var density) && density > 0
            ? density : MeshTexture.DefaultDensity);

    /// <summary>Sets the project's texel density, in its settings file, so the game and the next session see it too.</summary>
    public void SetTexelDensity(double density)
    {
        if (density <= 0)
        {
            return;
        }
        try
        {
            ProjectSettings.Set(ProjectPath, TexelDensityKey, density.ToString(CultureInfo.InvariantCulture));
            _texelDensityOverride = null;
        }
        catch (IOException e)
        {
            Console.Add(LogLevel.Warning, $"project: cannot write {ProjectPath}: {e.Message}; the density holds for this session");
            _texelDensityOverride = density;
        }
        OnMeshModeChanged();
    }

    /// <summary>
    /// A material's tool texture and its size in texels, from the cook index, or for a dev material the engine's grid
    /// before the index arrives. Null for a material that samples nothing, or that the index does not know.
    /// </summary>
    public (string Texture, double Width, double Height)? MaterialTexture(string material)
    {
        if (Assets.Find(material) is { } asset && asset.ToolTexture != "")
        {
            var texture = Assets.Find(asset.ToolTexture);
            return texture is { Size: [> 0, > 0] } ? (asset.ToolTexture, texture.Size[0], texture.Size[1])
                : asset.ToolTexture == DevGridTexture ? (DevGridTexture, DevGridSize, DevGridSize) : null;
        }
        return DevMaterials.Any(d => d.Guid == material) ? (DevGridTexture, DevGridSize, DevGridSize) : null;
    }

    /// <summary>A material's hotspot rectangles from the index, in its tool texture's texels.</summary>
    public IReadOnlyList<Hotspot> MaterialHotspots(string material) =>
        Assets.Find(material)?.Hotspots.Select(h => new Hotspot((int)h.X0, (int)h.Y0, (int)h.X1, (int)h.Y1)).ToList() ?? [];

    /// <summary>The scale in meters per repeat of a new face with a material: its texture's size at the project's density, or 1.</summary>
    public double NewFaceScale(string material) =>
        MaterialTexture(material) is var (_, width, _) ? MeshTexture.ScaleFor(width, TexelDensity) : Mapping.DefaultScale;

    // The scale of the walls that a tool pulls out of some faces: their first face's material's.
    double ScaleForFaces(MeshData mesh, IEnumerable<int> faces)
    {
        var first = faces.FirstOrDefault(f => f < mesh.Faces.Length, -1);
        return NewFaceScale(first >= 0 ? mesh.Materials[mesh.Faces[first].Slot] : DefaultMeshMaterial);
    }

    double ScaleForEdges(MeshData mesh, IEnumerable<int> edges) =>
        ScaleForFaces(mesh, edges.Where(e => e < mesh.Edges.Length).SelectMany(e => mesh.FacesOfEdge(mesh.Edges[e])));

    /// <summary>The selected faces, by mesh, in the Faces kind; none in another kind.</summary>
    public IReadOnlyList<(string Guid, int Face)> SelectedFaces =>
        InMeshMode && MeshElement == MeshElement.Faces
            ? [.. MeshSelection.Items.Where(i => FindMeshData(i.Guid) is { } m && i.Index < m.Faces.Length).OrderBy(i => i.Guid).ThenBy(i => i.Index).Select(i => (i.Guid, i.Index))]
            : [];

    /// <summary>Whether a texture tool can run: mesh mode with faces selected.</summary>
    public bool CanRunTextureTool => InMeshMode && IsEditing && MeshElement == MeshElement.Faces && !MeshSelection.IsEmpty;

    // The operations that change the selected faces' mappings from a snapshot of each mesh: none for a change that
    // changes nothing.
    List<Operation> MappingOperations(Func<string, MeshData?> starts, Func<MeshData, int, Mapping, Mapping> change)
    {
        var ops = new List<Operation>();
        foreach (var group in SelectedFaces.GroupBy(f => f.Guid))
        {
            if (starts(group.Key) is not { } start || FindMeshData(group.Key) is not { } current)
            {
                continue;
            }
            var chosen = group.Select(f => f.Face).Where(f => f < start.Faces.Length).ToHashSet();
            var faces = start.Faces.Select((f, i) => chosen.Contains(i) ? f with { Mapping = change(start, i, f.Mapping) } : f).ToList();
            if (faces.SequenceEqual(start.Faces))
            {
                continue;
            }
            ops.Add(new MeshOperation(group.Key, current, start.With(faces: faces), Meshes));
        }
        return ops;
    }

    /// <summary>Runs a texture tool on the selected faces of every edited mesh, as one undo entry.</summary>
    public bool EditMappings(string label, Func<MeshData, int, Mapping, Mapping> change)
    {
        CommitPendingDistance();
        if (!CanRunTextureTool || Scene is not { InTransaction: false })
        {
            return false;
        }
        var ops = MappingOperations(FindMeshData, change);
        if (ops.Count == 0)
        {
            Console.Add(LogLevel.Info, $"mesh: {label.ToLowerInvariant()} changed nothing");
            return false;
        }
        foreach (var op in ops.OfType<MeshOperation>())
        {
            if (op.After.Validate() is { Count: > 0 } problems)
            {
                Console.Add(LogLevel.Error, $"mesh: cannot {label.ToLowerInvariant()}: {string.Join("; ", problems)}");
                return false;
            }
        }
        if (!Edit(label, [.. ops]))
        {
            return false;
        }
        OnMeshModeChanged();
        return true;
    }

    /// <summary>Starts a drag of the Face panel's mapping fields: one undo entry until <see cref="EndMappingScrub"/>.</summary>
    public bool BeginMappingScrub(string label)
    {
        CommitPendingDistance();
        if (!CanRunTextureTool || Scene is not { InTransaction: false })
        {
            return false;
        }
        _mappingStarts = SelectedFaces.Select(f => f.Guid).Distinct().ToDictionary(g => g, g => FindMeshData(g)!);
        BeginEdit(label);
        return true;
    }

    /// <summary>A step of the drag: the change from where each mapping was at the start.</summary>
    public void PreviewMappings(Func<MeshData, int, Mapping, Mapping> change)
    {
        if (_mappingStarts is not { } starts || Scene is not { InTransaction: true })
        {
            return;
        }
        var ops = MappingOperations(starts.GetValueOrDefault, change);
        if (ops.Count > 0)
        {
            PreviewEdit(ops);
        }
    }

    public void EndMappingScrub()
    {
        if (_mappingStarts == null)
        {
            return;
        }
        _mappingStarts = null;
        CommitEdit();
        OnMeshModeChanged();
    }

    /// <summary>Shift: moves the texture by steps of an eighth of a repeat along the mapping's axes, as it shows on the face.</summary>
    public bool ShiftTexture(int u, int v, double multiplier = 1) =>
        EditMappings("Shift Texture", (_, _, m) => MeshTexture.Shift(m, u * MeshTexture.ShiftStep * multiplier, v * MeshTexture.ShiftStep * multiplier));

    /// <summary>Rotate: turns the texture by steps of 15 degrees about the mapping's origin.</summary>
    public bool RotateTexture(int direction, double multiplier = 1) =>
        EditMappings("Rotate Texture", (_, _, m) => MeshTexture.Rotate(m, direction * MeshTexture.RotateStep * multiplier));

    /// <summary>Scale: makes the texture larger on the face, or smaller, by steps of a quarter.</summary>
    public bool ScaleTexture(int direction, double multiplier = 1)
    {
        var factor = Math.Pow(MeshTexture.ScaleStep, direction * multiplier);
        return EditMappings("Scale Texture", (_, _, m) => MeshTexture.Scale(m, factor, factor));
    }

    /// <summary>Sets the scale in meters per repeat, either axis or both, as the Face panel's typed value does.</summary>
    public bool SetTextureScale(double? scaleU, double? scaleV) =>
        EditMappings("Set Texture Scale", (_, _, m) => MeshTexture.SetScale(m, scaleU, scaleV));

    public bool SetTextureShift(double? shiftU, double? shiftV) =>
        EditMappings("Set Texture Shift", (_, _, m) => m with { ShiftU = shiftU ?? m.ShiftU, ShiftV = shiftV ?? m.ShiftV });

    public bool SetTextureRotation(double degrees) =>
        EditMappings("Set Texture Rotation", (_, _, m) => MeshTexture.Rotate(m with { Rotation = 0 }, degrees));

    /// <summary>Reset Scale: the scale from each face's texture's size at the project's density.</summary>
    public bool ResetTextureScale() => EditMappings("Reset Texture Scale", (mesh, face, m) =>
        MaterialTexture(mesh.Materials[mesh.Faces[face].Slot]) is var (_, width, height)
            ? MeshTexture.ResetScale(m, width, height, TexelDensity)
            : MeshTexture.SetScale(m, Math.CopySign(Mapping.DefaultScale, m.ScaleU), Math.CopySign(Mapping.DefaultScale, m.ScaleV)));

    /// <summary>
    /// Align: the axes from the world, from the face's own plane, along the selected edges' for their faces, or the
    /// active face's mapping carried onto the other selected faces.
    /// </summary>
    public bool AlignTexture(TextureAlignment how)
    {
        switch (how)
        {
            case TextureAlignment.World:
                return EditMappings("Align Texture to World", (mesh, face, m) => MeshTexture.AlignWorld(mesh, face, m));
            case TextureAlignment.Face:
                return EditMappings("Align Texture to Face", (mesh, face, m) => MeshTexture.AlignFace(mesh, face, m));
            case TextureAlignment.ToEdge:
                return AlignTextureToEdges();
            default:
                if (ActiveFace is not { } active || !MeshSelection.Contains(active.Guid, active.Index) || FindMeshData(active.Guid) is not { } source || active.Index >= source.Faces.Length)
                {
                    Console.Add(LogLevel.Info, "mesh: click the face to copy the texture from, then Shift-click the faces to carry it onto");
                    return false;
                }
                var mapping = source.Faces[active.Index].Mapping;
                return EditMappings("Align Texture to Active Face", (mesh, face, m) =>
                    ReferenceEquals(mesh, source) || mesh.Faces.Length == source.Faces.Length && mesh.Faces[active.Index] == source.Faces[active.Index]
                        ? face == active.Index ? m : MeshTexture.AlignToFace(mesh, active.Index, face)
                        : mapping);
        }
    }

    // Align to Edge runs in the Edges kind: each selected edge's faces take u along it.
    bool AlignTextureToEdges()
    {
        CommitPendingDistance();
        if (!CanRunMeshTool(MeshElement.Edges) || Scene is not { InTransaction: false })
        {
            Console.Add(LogLevel.Info, "mesh: select edges to align their faces' textures along them");
            return false;
        }
        var ops = new List<Operation>();
        foreach (var guid in MeshSelection.Guids)
        {
            if (FindMeshData(guid) is not { } mesh)
            {
                continue;
            }
            var faces = mesh.Faces.ToArray();
            foreach (var e in MeshSelection.Of(guid).Where(e => e < mesh.Edges.Length))
            {
                var edge = mesh.Edges[e];
                foreach (var f in mesh.FacesOfEdge(edge))
                {
                    faces[f] = faces[f] with { Mapping = MeshTexture.AlignToEdge(mesh, f, edge, faces[f].Mapping) };
                }
            }
            if (!faces.SequenceEqual(mesh.Faces))
            {
                ops.Add(new MeshOperation(guid, mesh, mesh.With(faces: faces), Meshes));
            }
        }
        return ops.Count > 0 && Edit("Align Texture to Edge", [.. ops]);
    }

    /// <summary>Fit: the texture's repeat, or some, over each face's bounding rectangle along u, v or both.</summary>
    public bool FitTexture(bool u, bool v, double tiles = 1) =>
        EditMappings("Fit Texture", (mesh, face, m) => MeshTexture.Fit(mesh, face, m, u, v, tiles));

    public bool JustifyTexture(Justification how) =>
        EditMappings($"Justify Texture {how}", (mesh, face, m) => MeshTexture.Justify(mesh, face, m, how));

    public bool FlipTexture(bool u, bool v) =>
        EditMappings(u && v ? "Flip Texture" : u ? "Flip Texture U" : "Flip Texture V", (mesh, face, m) => MeshTexture.Flip(mesh, face, m, u, v));

    /// <summary>
    /// Hotspot: maps each face onto the rectangle of its material's hotspots that fits it best, the next best after
    /// the one it is on, or the best in one of its symmetries at random. A material without hotspots gets Fit.
    /// </summary>
    public bool ApplyHotspot(HotspotChoice choice, Random? random = null)
    {
        var fitted = new List<string>();
        var ok = EditMappings(choice switch { HotspotChoice.Next => "Next Hotspot", HotspotChoice.Random => "Random Hotspot", _ => "Hotspot" }, (mesh, face, m) =>
        {
            var material = mesh.Materials[mesh.Faces[face].Slot];
            var hotspots = MaterialHotspots(material);
            if (hotspots.Count == 0 || MaterialTexture(material) is not var (_, width, height))
            {
                fitted.Add(material);
                return MeshTexture.Fit(mesh, face, m, true, true);
            }
            var ranked = MeshTexture.RankHotspots(mesh, face, m, hotspots, TexelDensity);
            var index = ranked[0];
            var symmetry = 0;
            switch (choice)
            {
                case HotspotChoice.Next:
                    var current = MeshTexture.CurrentHotspot(mesh, face, m, hotspots, width, height);
                    var at = current is { } c ? ranked.ToList().IndexOf(c) : -1;
                    index = ranked[(at + 1) % ranked.Count];
                    break;
                case HotspotChoice.Random:
                    var square = hotspots[index].Width == hotspots[index].Height;
                    symmetry = (random ?? Random.Shared).Next(square ? 8 : 4);
                    break;
            }
            return MeshTexture.MapToHotspot(mesh, face, m, hotspots[index], width, height, symmetry);
        });
        foreach (var material in fitted.Distinct())
        {
            var name = Assets.Find(material) is { } a ? Content.AssetIndex.DisplayName(a) : material;
            Console.Add(LogLevel.Info, $"mesh: {name} has no hotspots, so its faces fit the texture instead");
        }
        return ok;
    }

    /// <summary>Sets the selected faces' material: the mesh's slot, and the entity's Mesh_Renderer slot that draws it, as one undo entry.</summary>
    public bool SetFaceMaterial(string guid)
    {
        CommitPendingDistance();
        if (!CanRunTextureTool || Scene is not { InTransaction: false } || !IsMaterialOrNone(guid))
        {
            return false;
        }
        var ops = new List<Operation>();
        foreach (var group in SelectedFaces.GroupBy(f => f.Guid))
        {
            if (MaterialOperations(group.Key, group.Select(f => f.Face), guid, out var reason) is { } groupOps)
            {
                ops.AddRange(groupOps);
            }
            else
            {
                Console.Add(LogLevel.Warning, $"mesh: cannot set the material: {reason}");
                return false;
            }
        }
        return ops.Count > 0 && Edit("Set Material", [.. ops]);
    }

    bool IsMaterialOrNone(string guid) => guid == "" || IsMaterial(guid) || DevMaterials.Any(d => d.Guid == guid);

    // The operations that give some faces of a mesh a material, or null with the reason.
    List<Operation>? MaterialOperations(string meshGuid, IEnumerable<int> faces, string material, out string? reason)
    {
        reason = null;
        if (FindMeshData(meshGuid) is not { } mesh || !_editedMeshes.TryGetValue(meshGuid, out var entity))
        {
            return [];
        }
        var (after, why) = MeshTexture.SetMaterial(mesh, faces, material);
        if (after == null)
        {
            reason = why;
            return null;
        }
        var ops = new List<Operation>();
        if (!ReferenceEquals(after, mesh) && !after.Faces.SequenceEqual(mesh.Faces) || !after.Materials.SequenceEqual(mesh.Materials))
        {
            ops.Add(new MeshOperation(meshGuid, mesh, after, Meshes));
        }
        var slot = after.Materials.IndexOf(material);
        if (slot >= 0 && Scene?.Expanded.Flat.Find(entity) is { } document)
        {
            var renderer = document.Components.Find(c => c.Id == SceneEdits.MeshRendererId);
            var field = $"materials.{slot}";
            if (renderer?.Fields.Find(f => f.Name == field)?.Value is not { Kind: SceneValueKind.Asset } current || current.Asset != material)
            {
                ops.Add(new SetField(entity, SceneEdits.MeshRendererId, field, SceneValue.AssetRef(material)));
            }
        }
        return ops;
    }

    // The faces a material dropped at a pixel would set: the selected faces when it is over one of them, else the
    // face under it, with its mesh.
    (string Guid, List<int> Faces)? DropTarget(Vec2 pixel)
    {
        if (!InMeshMode || !IsEditing)
        {
            return null;
        }
        var (width, height) = FrameSize;
        var ray = Camera.Ray(pixel, width, height);
        (string Guid, int Face)? best = null;
        var bestDistance = double.MaxValue;
        foreach (var guid in _editedMeshes.Keys)
        {
            if (FindMeshData(guid) is { } mesh && PlacementOf(guid) is { } placement && MeshPick.Face(mesh, placement, ray) is { } hit && hit.Distance < bestDistance)
            {
                (best, bestDistance) = ((guid, hit.Face), hit.Distance);
            }
        }
        if (best is not var (meshGuid, face))
        {
            return null;
        }
        if (MeshElement == MeshElement.Faces && MeshSelection.Contains(meshGuid, face))
        {
            return (meshGuid, MeshSelection.Of(meshGuid).ToList());
        }
        return (meshGuid, [face]);
    }

    /// <summary>
    /// Shows a material on the faces under a drag, by face rather than by submesh, in an undo entry that stays open:
    /// moving to other faces puts the last ones back, and null puts them back without showing another.
    /// </summary>
    public void PreviewFaceMaterial(Vec2? pixel, string guid)
    {
        var target = pixel is { } p ? DropTarget(p) : null;
        var key = target is var (meshGuid, faces) ? $"{meshGuid}:{string.Join(",", faces.Order())}:{guid}" : null;
        if (key == _faceMaterialKey)
        {
            return;
        }
        CancelMaterial();
        if (target == null || Scene is not { InTransaction: false } || !IsMaterialOrNone(guid))
        {
            return;
        }
        var ops = MaterialOperations(target.Value.Guid, target.Value.Faces, guid, out _);
        if (ops is not { Count: > 0 })
        {
            return;
        }
        BeginEdit("Set Material");
        _faceMaterialKey = key;
        PreviewEdit(ops);
    }

    /// <summary>Drops a material on the faces under a pixel, keeping the preview as one undo entry.</summary>
    public bool DropFaceMaterial(Vec2 pixel, string guid)
    {
        PreviewFaceMaterial(pixel, guid);
        if (CommitMaterial())
        {
            return true;
        }
        Console.Add(LogLevel.Info, "mesh: a material drops onto a face of an edited mesh");
        return false;
    }

    /// <summary>Transform Texture: the gizmo shifts, turns or scales the selected faces' textures instead of moving their vertices.</summary>
    public void ToggleTextureGizmo()
    {
        TextureGizmo = !TextureGizmo;
        CancelGizmo();
        OnMeshModeChanged();
    }

    // The gizmo's axes with the texture gizmo on: the active face's mapping axes, u, v and across, in view space.
    Quat? TextureGizmoAxes()
    {
        if (!TextureGizmo || MeshElement != MeshElement.Faces)
        {
            return null;
        }
        var face = ActiveFace is { } active && MeshSelection.Contains(active.Guid, active.Index) ? active : MeshSelection.Items.OrderBy(i => i.Guid).ThenBy(i => i.Index).FirstOrDefault();
        if (FindMeshData(face.Guid) is not { } mesh || face.Index >= mesh.Faces.Length || PlacementOf(face.Guid) is not { } placement)
        {
            return null;
        }
        var (u, v) = MeshTexture.FoldedAxes(mesh.Faces[face.Index].Mapping);
        var x = placement.NormalToView(u);
        var y = placement.NormalToView(v);
        y = (y - x * Vec3.Dot(x, y)).Normalized();
        if (x == Vec3.Zero || y == Vec3.Zero)
        {
            return null;
        }
        return Rotations.FromAxes(x, y, Vec3.Cross(x, y));
    }

    /// <summary>
    /// A gizmo drag of the selected faces' mappings: each step moves, turns or scales the texture about the pivot, in
    /// the mesh's space, so the texture follows the gizmo as the vertices would.
    /// </summary>
    sealed class TextureDrag
    {
        readonly EditorShell _shell;
        readonly Vec3 _pivot;
        readonly List<(string Guid, MeshData Start, HashSet<int> Faces, MeshPlacement Placement)> _meshes = [];

        public TextureDrag(EditorShell shell, long[] pivot)
        {
            (_shell, _pivot) = (shell, shell.Camera.RelativeTo(pivot));
            foreach (var group in shell.SelectedFaces.GroupBy(f => f.Guid))
            {
                if (shell.FindMeshData(group.Key) is { } mesh && shell.PlacementOf(group.Key) is { } placement)
                {
                    _meshes.Add((group.Key, mesh, [.. group.Select(f => f.Face)], placement));
                }
            }
        }

        public bool IsEmpty => _meshes.Count == 0;

        public List<Operation> Apply(GizmoChange change, bool snap)
        {
            var ops = new List<Operation>();
            var (angle, axis) = AxisAngle(change.Rotation);
            foreach (var (guid, start, chosen, placement) in _meshes)
            {
                var pivot = placement.ToLocal(_pivot);
                var translation = placement.ToLocal(_pivot + change.Translation) - pivot;
                var rotation = angle == 0 ? Quat.Identity : Rotations.AxisAngle((placement.ToLocal(_pivot + axis) - pivot).Normalized(), angle);
                var faces = start.Faces.Select((f, i) =>
                {
                    if (!chosen.Contains(i))
                    {
                        return f;
                    }
                    var m = f.Mapping;
                    if (change.Translation != Vec3.Zero)
                    {
                        m = MeshTexture.Moved(m, translation);
                        if (snap)
                        {
                            m = m with { ShiftU = Math.Round(m.ShiftU / MeshTexture.ShiftStep) * MeshTexture.ShiftStep, ShiftV = Math.Round(m.ShiftV / MeshTexture.ShiftStep) * MeshTexture.ShiftStep };
                        }
                    }
                    if (rotation != Quat.Identity)
                    {
                        m = MeshTexture.Turned(m, rotation, pivot);
                    }
                    if (change.Scale != new Vec3(1, 1, 1))
                    {
                        m = MeshTexture.Scaled(m, change.Scale.X, change.Scale.Y, pivot);
                    }
                    return f with { Mapping = m };
                });
                ops.Add(new MeshOperation(guid, _shell.FindMeshData(guid) ?? start, start.With(faces: faces), _shell.Meshes));
            }
            return ops;
        }

        static (double Angle, Vec3 Axis) AxisAngle(Quat q)
        {
            var axis = new Vec3(q.X, q.Y, q.Z);
            var sin = axis.Length;
            return sin < 1e-12 ? (0, Vec3.UnitY) : (2 * Math.Atan2(sin, q.W), axis / sin);
        }
    }
}
