using System.Collections.Immutable;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Mesh;

/// <summary>Which edge of the texture's repeat Justify puts on the face's bounding rectangle's.</summary>
public enum Justification
{
    Left,
    Right,
    Top,
    Bottom,
    Center,
}

/// <summary>A hotspot rectangle of a material's tool texture, in texels, as its <c>hotspot</c> line gives it.</summary>
public readonly record struct Hotspot(int X0, int Y0, int X1, int Y1)
{
    public int Width => X1 - X0;
    public int Height => Y1 - Y0;
}

/// <summary>
/// The texture tools (see docs/editor/mesh-editing.md#texture-tools): each takes a face's <see cref="Mapping"/> and
/// gives a new one, exactly and reversibly, since a face stores its mapping and not its UVs. The tools are pure, so
/// each is a unit test without a host; the shell runs one on every selected face as one undo entry.
/// </summary>
public static class MeshTexture
{
    /// <summary>A Shift's step, in texture repeats.</summary>
    public const double ShiftStep = 0.125;
    /// <summary>A Rotate's step, in degrees.</summary>
    public const double RotateStep = 15;
    /// <summary>What Scale Up multiplies the scale by, so the texture is larger on the face.</summary>
    public const double ScaleStep = 1.25;
    /// <summary>The project's texel density when its settings give none, in texels per meter.</summary>
    public const double DefaultDensity = 256;

    /// <summary>The scale in meters per repeat that puts a texture at a density: its size over the density, or the default without a texture.</summary>
    public static double ScaleFor(double textureSize, double density) =>
        textureSize > 0 && density > 0 ? textureSize / density : Mapping.DefaultScale;

    /// <summary>A face's density in texels per meter along u and v, from its scale and its texture's size, or null without a texture.</summary>
    public static (double U, double V)? Density(Mapping m, double width, double height) =>
        width > 0 && height > 0 && m.ScaleU != 0 && m.ScaleV != 0 ? (width / Math.Abs(m.ScaleU), height / Math.Abs(m.ScaleV)) : null;

    public static Mapping Shift(Mapping m, double du, double dv) => m with { ShiftU = m.ShiftU + du, ShiftV = m.ShiftV + dv };

    /// <summary>Adds to the rotation about the mapping's origin, kept in (-180, 180].</summary>
    public static Mapping Rotate(Mapping m, double degrees) => m with { Rotation = Wrap(m.Rotation + degrees) };

    public static Mapping Scale(Mapping m, double factorU, double factorV) =>
        factorU == 0 || factorV == 0 ? m : m with { ScaleU = m.ScaleU * factorU, ScaleV = m.ScaleV * factorV };

    /// <summary>Sets the scale in meters per repeat, either axis or both; a zero is refused and keeps the old value.</summary>
    public static Mapping SetScale(Mapping m, double? scaleU, double? scaleV) => m with
    {
        ScaleU = scaleU is { } u && u != 0 ? u : m.ScaleU,
        ScaleV = scaleV is { } v && v != 0 ? v : m.ScaleV,
    };

    /// <summary>Reset Scale: the scale from the texture's size and the project's density, keeping the sign of each axis.</summary>
    public static Mapping ResetScale(Mapping m, double width, double height, double density) => m with
    {
        ScaleU = Math.CopySign(ScaleFor(width, density), m.ScaleU == 0 ? 1 : m.ScaleU),
        ScaleV = Math.CopySign(ScaleFor(height, density), m.ScaleV == 0 ? 1 : m.ScaleV),
    };

    /// <summary>Align World: the axes from the face's normal's nearest world axis, with the scale kept and the shift and rotation cleared.</summary>
    public static Mapping AlignWorld(MeshData mesh, int face, Mapping m) =>
        Mapping.WorldAligned(mesh.FaceNormal(face)) with { ScaleU = m.ScaleU, ScaleV = m.ScaleV };

    /// <summary>Align Face: u along the face's longest edge and v down the face, with the scale kept.</summary>
    public static Mapping AlignFace(MeshData mesh, int face, Mapping m)
    {
        var corners = mesh.Faces[face].Corners;
        var best = Vec3.Zero;
        for (var i = 0; i < corners.Length; i++)
        {
            var d = mesh.Vertices[corners[(i + 1) % corners.Length]] - mesh.Vertices[corners[i]];
            if (d.Length > best.Length)
            {
                best = d;
            }
        }
        return Along(mesh.FaceNormal(face), best, m) ?? m;
    }

    /// <summary>Align to Edge: u along an edge of the face, with the scale kept. An edge across the face's plane changes nothing.</summary>
    public static Mapping AlignToEdge(MeshData mesh, int face, MeshEdge edge, Mapping m) =>
        Along(mesh.FaceNormal(face), mesh.Vertices[edge.B] - mesh.Vertices[edge.A], m) ?? m;

    // The axes with u along a direction in a face's plane and v across it, so a texture on a wall reads upright.
    static Mapping? Along(Vec3 normal, Vec3 direction, Mapping m)
    {
        var u = (direction - normal * Vec3.Dot(direction, normal)).Normalized();
        if (u == Vec3.Zero || normal == Vec3.Zero)
        {
            return null;
        }
        return new Mapping(u, Vec3.Cross(u, normal).Normalized(), m.ScaleU, m.ScaleV, 0, 0, 0);
    }

    /// <summary>
    /// Align to Face: the mapping of one face carried onto another, turned with the face about the line where their
    /// planes meet and shifted so the texture is continuous across a shared edge, so a texture flows around a corner
    /// without a seam. Faces in one plane, or facing opposite ways, take the mapping as it is.
    /// </summary>
    public static Mapping AlignToFace(MeshData mesh, int from, int to)
    {
        var m = mesh.Faces[from].Mapping;
        var (na, nb) = (mesh.FaceNormal(from), mesh.FaceNormal(to));
        var axis = Vec3.Cross(na, nb);
        if (axis.Length < 1e-9)
        {
            return m;
        }
        var rotation = Rotations.AxisAngle(axis.Normalized(), Math.Atan2(axis.Length, Vec3.Dot(na, nb)));
        var u = rotation.Rotate(m.UAxis);
        var v = rotation.Rotate(m.VAxis);
        // The texture agrees at a shared vertex, else at the target's first corner, and so along the whole edge.
        var shared = mesh.Faces[to].Corners.FirstOrDefault(c => mesh.Faces[from].Corners.Contains(c), -1);
        var e0 = mesh.Vertices[shared >= 0 ? shared : mesh.Faces[to].Corners[0]];
        var (u0, v0) = m.Uv(e0);
        var (u1, v1) = m.Uv(rotation.Conjugate.Rotate(e0));
        return m with { UAxis = u, VAxis = v, ShiftU = m.ShiftU + u0 - u1, ShiftV = m.ShiftV + v0 - v1 };
    }

    /// <summary>
    /// Fit: scales and shifts so that the texture's repeat, or <paramref name="tiles"/> of them, covers the face's
    /// bounding rectangle in the mapping's axes, along u, along v, or both. The rotation folds into the axes, so the
    /// texture keeps its direction.
    /// </summary>
    public static Mapping Fit(MeshData mesh, int face, Mapping m, bool u, bool v, double tiles = 1)
    {
        var (ua, va) = FoldedAxes(m);
        var (minA, maxA, minB, maxB) = Extent(mesh, face, ua, va);
        var result = m with { UAxis = ua, VAxis = va, Rotation = 0 };
        if (tiles <= 0)
        {
            return m;
        }
        if (u && maxA - minA > 1e-9)
        {
            var scale = (maxA - minA) / tiles;
            result = result with { ScaleU = scale, ShiftU = -minA / scale };
        }
        if (v && maxB - minB > 1e-9)
        {
            var scale = (maxB - minB) / tiles;
            result = result with { ScaleV = scale, ShiftV = -minB / scale };
        }
        return result;
    }

    /// <summary>Justify: shifts so that the texture's edge, or its center, is on the face's bounding rectangle's, in UV.</summary>
    public static Mapping Justify(MeshData mesh, int face, Mapping m, Justification how)
    {
        var (minU, maxU, minV, maxV) = UvBounds(mesh, face, m);
        return how switch
        {
            Justification.Left => m with { ShiftU = m.ShiftU - minU },
            Justification.Right => m with { ShiftU = m.ShiftU + 1 - maxU },
            Justification.Top => m with { ShiftV = m.ShiftV - minV },
            Justification.Bottom => m with { ShiftV = m.ShiftV + 1 - maxV },
            _ => m with { ShiftU = m.ShiftU + 0.5 - (minU + maxU) / 2, ShiftV = m.ShiftV + 0.5 - (minV + maxV) / 2 },
        };
    }

    /// <summary>Flips the texture across the face's bounding rectangle's middle, along u, along v, or both, so the face shows the same part mirrored.</summary>
    public static Mapping Flip(MeshData mesh, int face, Mapping m, bool u, bool v)
    {
        var (minU, maxU, minV, maxV) = UvBounds(mesh, face, m);
        var result = m;
        if (u)
        {
            result = result with { UAxis = -result.UAxis, ShiftU = minU + maxU - result.ShiftU };
        }
        if (v)
        {
            result = result with { VAxis = -result.VAxis, ShiftV = minV + maxV - result.ShiftV };
        }
        // Negating one axis mirrors the rotation's sense; negating both keeps it.
        return u != v ? result with { Rotation = -result.Rotation } : result;
    }

    /// <summary>
    /// The hotspots in the order that fits a face best: by how near each rectangle's aspect ratio and its size at the
    /// project's density are to the face's bounding rectangle in the mapping's axes.
    /// </summary>
    public static IReadOnlyList<int> RankHotspots(MeshData mesh, int face, Mapping m, IReadOnlyList<Hotspot> hotspots, double density)
    {
        var (ua, va) = FoldedAxes(m);
        var (minA, maxA, minB, maxB) = Extent(mesh, face, ua, va);
        var (width, height) = (Math.Max(maxA - minA, 1e-6), Math.Max(maxB - minB, 1e-6));
        density = density > 0 ? density : DefaultDensity;
        double Score(Hotspot h)
        {
            if (h.Width <= 0 || h.Height <= 0)
            {
                return double.MaxValue;
            }
            var (w, hgt) = (h.Width / density, h.Height / density);
            return Math.Abs(Math.Log(width / height) - Math.Log(w / hgt)) + Math.Abs(Math.Log(width * height) - Math.Log(w * hgt)) / 2;
        }
        return [.. Enumerable.Range(0, hotspots.Count).OrderBy(i => Score(hotspots[i])).ThenBy(i => i)];
    }

    /// <summary>
    /// Maps a face onto a hotspot rectangle of a texture, as Fit does onto the rectangle's share of the texture, in one
    /// of the rectangle's symmetries: bit 0 of <paramref name="symmetry"/> flips u, bit 1 flips v and bit 2 turns the
    /// texture a quarter, which only a square rectangle keeps tileable.
    /// </summary>
    public static Mapping MapToHotspot(MeshData mesh, int face, Mapping m, Hotspot hotspot, double width, double height, int symmetry = 0)
    {
        if (hotspot.Width <= 0 || hotspot.Height <= 0 || width <= 0 || height <= 0)
        {
            return m;
        }
        var (ua, va) = FoldedAxes(m);
        if ((symmetry & 4) != 0)
        {
            (ua, va) = (va, ua);
        }
        if ((symmetry & 1) != 0)
        {
            ua = -ua;
        }
        if ((symmetry & 2) != 0)
        {
            va = -va;
        }
        var (minA, maxA, minB, maxB) = Extent(mesh, face, ua, va);
        if (maxA - minA < 1e-9 || maxB - minB < 1e-9)
        {
            return m;
        }
        var (repeatsU, repeatsV) = (hotspot.Width / width, hotspot.Height / height);
        var (scaleU, scaleV) = ((maxA - minA) / repeatsU, (maxB - minB) / repeatsV);
        return new Mapping(ua, va, scaleU, scaleV, hotspot.X0 / width - minA / scaleU, hotspot.Y0 / height - minB / scaleV, 0);
    }

    /// <summary>The hotspot that a face sits on: the rectangle under the middle of its UVs, or null off every one.</summary>
    public static int? CurrentHotspot(MeshData mesh, int face, Mapping m, IReadOnlyList<Hotspot> hotspots, double width, double height)
    {
        if (hotspots.Count == 0 || width <= 0 || height <= 0)
        {
            return null;
        }
        var (minU, maxU, minV, maxV) = UvBounds(mesh, face, m);
        var (cu, cv) = ((minU + maxU) / 2 * width, (minV + maxV) / 2 * height);
        for (var i = 0; i < hotspots.Count; i++)
        {
            var h = hotspots[i];
            if (cu >= h.X0 && cu <= h.X1 && cv >= h.Y0 && cv <= h.Y1)
            {
                return i;
            }
        }
        return null;
    }

    /// <summary>Whether a face's UVs leave a hotspot's rectangle, which the Face panel shows in red.</summary>
    public static bool LeavesHotspot(MeshData mesh, int face, Mapping m, Hotspot hotspot, double width, double height)
    {
        const double tolerance = 1e-3;
        var (minU, maxU, minV, maxV) = UvBounds(mesh, face, m);
        return minU * width < hotspot.X0 - tolerance || maxU * width > hotspot.X1 + tolerance
            || minV * height < hotspot.Y0 - tolerance || maxV * height > hotspot.Y1 + tolerance;
    }

    /// <summary>The mapping after the texture moves with a translation in the mesh's space, as a Move drag of the texture gizmo.</summary>
    public static Mapping Moved(Mapping m, Vec3 translation)
    {
        var (du, dv) = m.Turn(Vec3.Dot(translation, m.UAxis) / m.ScaleU, Vec3.Dot(translation, m.VAxis) / m.ScaleV);
        return m with { ShiftU = m.ShiftU - du, ShiftV = m.ShiftV - dv };
    }

    /// <summary>The mapping after the texture turns about a pivot in the mesh's space: the axes turn with it and the shift keeps the pivot's UV.</summary>
    public static Mapping Turned(Mapping m, Quat rotation, Vec3 pivot)
    {
        var d = pivot - rotation.Conjugate.Rotate(pivot);
        var (du, dv) = m.Turn(Vec3.Dot(d, m.UAxis) / m.ScaleU, Vec3.Dot(d, m.VAxis) / m.ScaleV);
        return m with { UAxis = rotation.Rotate(m.UAxis), VAxis = rotation.Rotate(m.VAxis), ShiftU = m.ShiftU + du, ShiftV = m.ShiftV + dv };
    }

    /// <summary>The mapping after the texture scales about a pivot in the mesh's space, by a factor along each axis.</summary>
    public static Mapping Scaled(Mapping m, double factorU, double factorV, Vec3 pivot)
    {
        if (factorU == 0 || factorV == 0)
        {
            return m;
        }
        var (du, dv) = m.Turn(Vec3.Dot(pivot, m.UAxis) * (1 - 1 / factorU) / m.ScaleU, Vec3.Dot(pivot, m.VAxis) * (1 - 1 / factorV) / m.ScaleV);
        return m with { ScaleU = m.ScaleU * factorU, ScaleV = m.ScaleV * factorV, ShiftU = m.ShiftU + du, ShiftV = m.ShiftV + dv };
    }

    /// <summary>
    /// Sets the material of some faces: the slot that names it, else a slot that no other face uses, which a mesh has
    /// eight of. Null with the reason when every slot is in use.
    /// </summary>
    public static (MeshData? Mesh, string? Reason) SetMaterial(MeshData mesh, IEnumerable<int> faces, string guid)
    {
        var chosen = faces.ToHashSet();
        var slot = mesh.Materials.IndexOf(guid);
        if (slot < 0)
        {
            var used = mesh.Faces.Where((f, i) => !chosen.Contains(i)).Select(f => f.Slot).ToHashSet();
            slot = Enumerable.Range(0, MeshData.MaxSlots).FirstOrDefault(s => !used.Contains(s), -1);
            if (slot < 0)
            {
                return (null, $"a mesh has {MeshData.MaxSlots} materials, and every slot is in use");
            }
        }
        var materials = mesh.Materials.SetItem(slot, guid);
        var changed = mesh.Faces.Select((f, i) => chosen.Contains(i) && f.Slot != slot ? f with { Slot = slot } : f);
        return (mesh.With(materials: materials, faces: changed), null);
    }

    /// <summary>The axes with the rotation folded into them, which is exact when the scales agree and keeps the texture's direction otherwise.</summary>
    public static (Vec3 U, Vec3 V) FoldedAxes(Mapping m)
    {
        if (m.Rotation == 0)
        {
            return (m.UAxis, m.VAxis);
        }
        var (sin, cos) = Math.SinCos(m.Rotation * Math.PI / 180);
        return ((m.UAxis * cos - m.VAxis * sin).Normalized(), (m.UAxis * sin + m.VAxis * cos).Normalized());
    }

    /// <summary>A face's bounding rectangle along two axes, in meters.</summary>
    public static (double MinA, double MaxA, double MinB, double MaxB) Extent(MeshData mesh, int face, Vec3 u, Vec3 v)
    {
        double minA = double.MaxValue, maxA = double.MinValue, minB = double.MaxValue, maxB = double.MinValue;
        foreach (var c in mesh.Faces[face].Corners)
        {
            var p = mesh.Vertices[c];
            var (a, b) = (Vec3.Dot(p, u), Vec3.Dot(p, v));
            (minA, maxA, minB, maxB) = (Math.Min(minA, a), Math.Max(maxA, a), Math.Min(minB, b), Math.Max(maxB, b));
        }
        return (minA, maxA, minB, maxB);
    }

    /// <summary>A face's bounding rectangle in UV under a mapping.</summary>
    public static (double MinU, double MaxU, double MinV, double MaxV) UvBounds(MeshData mesh, int face, Mapping m)
    {
        double minU = double.MaxValue, maxU = double.MinValue, minV = double.MaxValue, maxV = double.MinValue;
        foreach (var c in mesh.Faces[face].Corners)
        {
            var (u, v) = m.Uv(mesh.Vertices[c]);
            (minU, maxU, minV, maxV) = (Math.Min(minU, u), Math.Max(maxU, u), Math.Min(minV, v), Math.Max(maxV, v));
        }
        return (minU, maxU, minV, maxV);
    }

    static double Wrap(double degrees)
    {
        var wrapped = degrees % 360;
        return wrapped > 180 ? wrapped - 360 : wrapped <= -180 ? wrapped + 360 : wrapped;
    }
}
