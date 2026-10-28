using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// The texture tools (see docs/editor/mesh-editing.md#texture-tools): each one's effect on the UVs that the bake
/// derives, Fit and Justify against a rectangle, the flips, the hotspot choice among rectangles of known aspect, the
/// texture gizmo's transforms, and the material slots.
/// </summary>
public sealed class MeshMappingTests
{
    // A 2 m by 1 m wall fronting +z, from x = 1 to 3 and y = 2 to 3, with the world mapping: u along +x, v along -y.
    static MeshData Wall() => new([], [new Vec3(1, 2, 0), new Vec3(3, 2, 0), new Vec3(3, 3, 0), new Vec3(1, 3, 0)],
        [new MeshFace(0, [0, 1, 2, 3], Mapping.WorldAligned(Vec3.UnitZ))], []);

    static readonly MeshData Box = Primitives.Block(new Vec3(0, 0, 0), new Vec3(2, 2, 2));

    static void AssertUv((double U, double V) uv, double u, double v)
    {
        Assert.Equal(u, uv.U, 6);
        Assert.Equal(v, uv.V, 6);
    }

    [Fact]
    public void ShiftRotateAndScaleAreExact()
    {
        var m = Wall().Faces[0].Mapping;
        AssertUv(MeshTexture.Shift(m, 0.125, -0.25).Uv(new Vec3(1, 2, 0)), 1.125, -2.25);
        var turned = MeshTexture.Rotate(m, 90);
        AssertUv(turned.Uv(new Vec3(1, 0, 0)), 0, 1);
        Assert.Equal(180, MeshTexture.Rotate(m, 180).Rotation);
        Assert.Equal(-170, MeshTexture.Rotate(MeshTexture.Rotate(m, 180), 10).Rotation);
        var larger = MeshTexture.Scale(m, 2, 4);
        AssertUv(larger.Uv(new Vec3(2, 4, 0)), 1, -1);
        Assert.Equal(m, MeshTexture.Scale(m, 0, 1));
        var set = MeshTexture.SetScale(m, 0.5, null);
        Assert.Equal((0.5, 1.0), (set.ScaleU, set.ScaleV));
        var reset = MeshTexture.ResetScale(m with { ScaleU = -1 }, 1024, 512, 256);
        Assert.Equal((-4.0, 2.0), (reset.ScaleU, reset.ScaleV));
        Assert.Equal((256.0, 256.0), MeshTexture.Density(reset, 1024, 512));
        Assert.Null(MeshTexture.Density(reset, 0, 0));
        Assert.Equal(Mapping.DefaultScale, MeshTexture.ScaleFor(0, 256));
    }

    [Fact]
    public void FitCoversTheFaceAndJustifyPutsAnEdgeOnIt()
    {
        var wall = Wall();
        var m = MeshTexture.Scale(wall.Faces[0].Mapping, 3, 3);
        var fit = MeshTexture.Fit(wall, 0, m, u: true, v: true);
        var (minU, maxU, minV, maxV) = MeshTexture.UvBounds(wall, 0, fit);
        Assert.Equal((0, 1, 0, 1), (Math.Round(minU, 6), Math.Round(maxU, 6), Math.Round(minV, 6), Math.Round(maxV, 6)));
        Assert.Equal((2.0, 1.0), (fit.ScaleU, fit.ScaleV));
        var tiled = MeshTexture.Fit(wall, 0, m, u: true, v: false, tiles: 4);
        Assert.Equal(0.5, tiled.ScaleU);
        Assert.Equal(3, tiled.ScaleV);
        (_, maxU, _, _) = MeshTexture.UvBounds(wall, 0, tiled);
        Assert.Equal(4, maxU, 6);

        var right = MeshTexture.Justify(wall, 0, m, Justification.Right);
        Assert.Equal(1, MeshTexture.UvBounds(wall, 0, right).MaxU, 6);
        var bottom = MeshTexture.Justify(wall, 0, m, Justification.Bottom);
        Assert.Equal(1, MeshTexture.UvBounds(wall, 0, bottom).MaxV, 6);
        var center = MeshTexture.Justify(wall, 0, m, Justification.Center);
        var bounds = MeshTexture.UvBounds(wall, 0, center);
        Assert.Equal(1, bounds.MinU + bounds.MaxU, 6);
        Assert.Equal(1, bounds.MinV + bounds.MaxV, 6);
        // A rotated mapping fits with its direction kept: the rotation folds into the axes.
        var turnedFit = MeshTexture.Fit(wall, 0, MeshTexture.Rotate(m, 90), u: true, v: true);
        Assert.Equal(0, turnedFit.Rotation);
        Assert.Equal(0, Vec3.Dot(turnedFit.UAxis, Vec3.UnitX), 6);
    }

    [Fact]
    public void FlipsMirrorWithinTheFace()
    {
        var wall = Wall();
        var m = MeshTexture.Rotate(wall.Faces[0].Mapping, 30);
        var before = MeshTexture.UvBounds(wall, 0, m);
        var flipped = MeshTexture.Flip(wall, 0, m, u: true, v: false);
        var after = MeshTexture.UvBounds(wall, 0, flipped);
        Assert.Equal(before.MinU, after.MinU, 6);
        Assert.Equal(before.MaxU, after.MaxU, 6);
        Assert.Equal(before.MinV, after.MinV, 6);
        // A corner's u mirrors about the middle and its v stays.
        var (u0, v0) = m.Uv(wall.Vertices[0]);
        var (u1, v1) = flipped.Uv(wall.Vertices[0]);
        Assert.Equal(before.MinU + before.MaxU - u0, u1, 6);
        Assert.Equal(v0, v1, 6);
        var both = MeshTexture.Flip(wall, 0, m, u: true, v: true);
        Assert.Equal(m.Rotation, both.Rotation);
        Assert.Equal(-m.Rotation, flipped.Rotation);
    }

    [Fact]
    public void AlignmentsSetTheAxes()
    {
        var wall = Wall();
        Assert.Equal(Vec3.UnitZ, wall.FaceNormal(0));
        var m = MeshTexture.Shift(MeshTexture.Rotate(wall.Faces[0].Mapping, 20), 1, 1);
        var world = MeshTexture.AlignWorld(wall, 0, m);
        Assert.Equal(Mapping.WorldAligned(Vec3.UnitZ), world);
        var face = MeshTexture.AlignFace(wall, 0, m);
        Assert.Equal(1, Math.Abs(Vec3.Dot(face.UAxis, Vec3.UnitX)), 6);
        Assert.Equal(0, face.Rotation);
        var edge = MeshTexture.AlignToEdge(wall, 0, new MeshEdge(0, 3), m);
        Assert.Equal(new Vec3(0, 1, 0), edge.UAxis);
        Assert.Equal(new Vec3(1, 0, 0), edge.VAxis);
        // An edge across the plane changes nothing.
        var across = new MeshData([], [.. wall.Vertices, new Vec3(1, 2, 5)], wall.Faces, []);
        Assert.Equal(m, MeshTexture.AlignToEdge(across, 0, new MeshEdge(0, 4), m));
    }

    [Fact]
    public void AlignToFaceContinuesTheTextureAroundACorner()
    {
        // The box's front face (+z) and its right face (+x) share the edge at x = 2, z = 2.
        var front = Enumerable.Range(0, 6).First(f => Box.FaceNormal(f) == Vec3.UnitZ);
        var right = Enumerable.Range(0, 6).First(f => Box.FaceNormal(f) == Vec3.UnitX);
        var source = MeshTexture.Shift(MeshTexture.Rotate(Box.Faces[front].Mapping, 15), 0.3, 0.7);
        var box = Box.With(faces: Box.Faces.Select((f, i) => i == front ? f with { Mapping = source } : f));
        var carried = MeshTexture.AlignToFace(box, front, right);
        Assert.Equal(0, Vec3.Dot(carried.UAxis, Vec3.UnitX), 6);
        foreach (var c in box.Faces[right].Corners.Where(c => box.Faces[front].Corners.Contains(c)))
        {
            AssertUv(carried.Uv(box.Vertices[c]), source.Uv(box.Vertices[c]).U, source.Uv(box.Vertices[c]).V);
        }
        // Faces in one plane take the mapping as it is.
        var back = Enumerable.Range(0, 6).First(f => Box.FaceNormal(f) == -Vec3.UnitZ);
        Assert.Equal(source, MeshTexture.AlignToFace(box, front, back));
    }

    [Fact]
    public void HotspotsRankByAspectAndSizeAndMapExactly()
    {
        var wall = Wall();
        var m = wall.Faces[0].Mapping;
        Hotspot[] hotspots = [new(0, 0, 256, 256), new(256, 0, 768, 256), new(0, 256, 128, 768), new(768, 0, 1024, 128)];
        // At 256 texels per meter the 2 by 1 wall is 512 by 256 texels: the second rectangle.
        Assert.Equal(1, MeshTexture.RankHotspots(wall, 0, m, hotspots, 256)[0]);
        // Twice as dense, the wall is 1024 by 512: the second rectangle is still the nearest in aspect, then the fourth.
        Assert.Equal([1, 3, 0, 2], MeshTexture.RankHotspots(wall, 0, m, hotspots, 512));
        var mapped = MeshTexture.MapToHotspot(wall, 0, m, hotspots[1], 1024, 1024);
        var (minU, maxU, minV, maxV) = MeshTexture.UvBounds(wall, 0, mapped);
        Assert.Equal((0.25, 0.75, 0, 0.25), (Math.Round(minU, 6), Math.Round(maxU, 6), Math.Round(minV, 6), Math.Round(maxV, 6)));
        Assert.Equal(1, MeshTexture.CurrentHotspot(wall, 0, mapped, hotspots, 1024, 1024));
        Assert.False(MeshTexture.LeavesHotspot(wall, 0, mapped, hotspots[1], 1024, 1024));
        Assert.True(MeshTexture.LeavesHotspot(wall, 0, MeshTexture.Shift(mapped, 0.1, 0), hotspots[1], 1024, 1024));
        Assert.Null(MeshTexture.CurrentHotspot(wall, 0, MeshTexture.Shift(mapped, 0, 0.5), hotspots, 1024, 1024));
        // A symmetry covers the same rectangle the other way round.
        var flipped = MeshTexture.MapToHotspot(wall, 0, m, hotspots[1], 1024, 1024, symmetry: 1);
        Assert.Equal((minU, maxU), (Math.Round(MeshTexture.UvBounds(wall, 0, flipped).MinU, 6), Math.Round(MeshTexture.UvBounds(wall, 0, flipped).MaxU, 6)));
        Assert.Equal(mapped.Uv(wall.Vertices[0]).U, flipped.Uv(wall.Vertices[1]).U, 6);
        var turned = MeshTexture.MapToHotspot(wall, 0, m, hotspots[0], 1024, 1024, symmetry: 4);
        Assert.Equal(0, Vec3.Dot(turned.UAxis, Vec3.UnitX), 6);
        Assert.Equal((0, 0.25), (Math.Round(MeshTexture.UvBounds(wall, 0, turned).MinU, 6), Math.Round(MeshTexture.UvBounds(wall, 0, turned).MaxU, 6)));
    }

    [Fact]
    public void TheTextureGizmoKeepsTheTextureUnderTheDrag()
    {
        var wall = Wall();
        var m = MeshTexture.Shift(MeshTexture.Rotate(wall.Faces[0].Mapping, 25), 0.2, 0.4) with { ScaleU = 1.5, ScaleV = 0.75 };
        var pivot = new Vec3(2, 2.5, 0);
        var p = new Vec3(1.25, 2.75, 0);
        // A move: the point that was at p shows what p showed, moved with the texture.
        var move = new Vec3(0.3, -0.1, 0);
        var moved = MeshTexture.Moved(m, move);
        AssertUv(moved.Uv(p + move), m.Uv(p).U, m.Uv(p).V);
        // A turn about the pivot: the texture turns with the face's points.
        var rotation = Rotations.AxisAngle(Vec3.UnitZ, 0.4);
        var turned = MeshTexture.Turned(m, rotation, pivot);
        var turnedPoint = pivot + rotation.Rotate(p - pivot);
        AssertUv(turned.Uv(turnedPoint), m.Uv(p).U, m.Uv(p).V);
        // A scale about the pivot, by a different factor along each axis.
        var scaled = MeshTexture.Scaled(m, 2, 0.5, pivot);
        var d = p - pivot;
        var scaledPoint = pivot + m.UAxis * Vec3.Dot(d, m.UAxis) * 2 + m.VAxis * Vec3.Dot(d, m.VAxis) * 0.5;
        AssertUv(scaled.Uv(scaledPoint), m.Uv(p).U, m.Uv(p).V);
        Assert.Equal((3.0, 0.375), (scaled.ScaleU, scaled.ScaleV));
    }

    [Fact]
    public void SetMaterialTakesASlotAndRefusesANinth()
    {
        var box = Primitives.Block(Vec3.Zero, new Vec3(1, 1, 1), material: "aa");
        var (mesh, reason) = MeshTexture.SetMaterial(box, [0, 1], "bb");
        Assert.Null(reason);
        Assert.Equal(["aa", "bb"], mesh!.Materials.Take(2));
        Assert.Equal([1, 1, 0, 0, 0, 0], mesh.Faces.Select(f => f.Slot));
        // The same material again takes its slot.
        (mesh, _) = MeshTexture.SetMaterial(mesh!, [2], "bb");
        Assert.Equal(1, mesh!.Faces[2].Slot);
        Assert.Equal("", mesh.Materials[2]);
        var full = mesh;
        for (var i = 2; i < MeshData.MaxSlots; i++)
        {
            (full, reason) = MeshTexture.SetMaterial(full!, [3], $"{i:x2}");
            Assert.NotNull(full);
            Assert.Null(reason);
        }
        // Every slot is named, and the faces use only some: a slot that no other face uses is taken over.
        (mesh, reason) = MeshTexture.SetMaterial(full, [3], "ff");
        Assert.Null(reason);
        // With every slot in use by another face, a ninth material is refused.
        var everyUsed = full!.With(faces: full.Faces.Select((f, i) => f with { Slot = i + 2 }).Concat([full.Faces[0] with { Slot = 0 }, full.Faces[0] with { Slot = 1 }, full.Faces[0] with { Slot = 2 }]));
        (_, reason) = MeshTexture.SetMaterial(everyUsed, [0], "ff");
        Assert.NotNull(reason);
    }
}
