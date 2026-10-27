using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Tests;

/// <summary>Cut, Draw, Bevel and the primitives.</summary>
public class MeshCutAndPrimitiveTests
{
    static MeshData Box() => Primitives.Block(Vec3.Zero, new Vec3(1, 1, 1));

    [Fact]
    public void CutSplitsEveryFaceTheLineCrosses()
    {
        var box = Box();
        // Around the box at half height: a point on each vertical edge slices it into two boxes' worth of faces.
        var (result, reason) = MeshCut.Cut(box,
        [
            new CutPoint.OnEdge(0, 4, 0.5), new CutPoint.OnEdge(1, 5, 0.5), new CutPoint.OnEdge(2, 6, 0.5), new CutPoint.OnEdge(3, 7, 0.5), new CutPoint.OnEdge(0, 4, 0.5),
        ]);
        Assert.Null(reason);
        var mesh = result.Mesh;
        Assert.Equal(12, mesh.Vertices.Length);
        Assert.Equal(10, mesh.Faces.Length);
        Assert.Equal(MeshElement.Vertices, result.Kind);
        Assert.Equal(4, result.Selected.Count);
        Assert.Empty(mesh.Validate());
        Assert.All(mesh.Edges, e => Assert.Equal(2, mesh.FacesOfEdge(e).Count));
        // The sharp vertical edges split into sharp halves.
        Assert.True(mesh.IsSharp(0, result.Selected[0]) && mesh.IsSharp(result.Selected[0], 4));

        // A cut through a point inside the face bends: the top gets a chord through its middle.
        var (bent, bentReason) = MeshCut.Cut(box, [new CutPoint.OnVertex(4), new CutPoint.OnFace(1, new Vec3(0.5, 1, 0.5)), new CutPoint.OnVertex(6)]);
        Assert.Null(bentReason);
        Assert.Equal(7, bent.Mesh.Faces.Length);
        Assert.Equal(9, bent.Mesh.Vertices.Length);
        Assert.Empty(bent.Mesh.Validate());

        // Two points inside the top extend to its edges, as Hammer's clipping line does: the top splits across.
        var (across, acrossReason) = MeshCut.Cut(box, [new CutPoint.OnFace(1, new Vec3(0.25, 1, 0.5)), new CutPoint.OnFace(1, new Vec3(0.75, 1, 0.5))]);
        Assert.Null(acrossReason);
        Assert.Equal(7, across.Mesh.Faces.Length);
        Assert.Equal(12, across.Mesh.Vertices.Length);
        Assert.Contains(across.Mesh.Vertices, v => v == new Vec3(0, 1, 0.5));
        Assert.Contains(across.Mesh.Vertices, v => v == new Vec3(1, 1, 0.5));
        Assert.Empty(across.Mesh.Validate());
        // An edge point and a point inside extend past the inside one.
        var (half, halfReason) = MeshCut.Cut(box, [new CutPoint.OnEdge(4, 7, 0.5), new CutPoint.OnFace(1, new Vec3(0.5, 1, 0.5))]);
        Assert.Null(halfReason);
        Assert.Equal(7, half.Mesh.Faces.Length);

        // A cut along an existing edge, or of one point, is refused.
        Assert.NotNull(MeshCut.Cut(box, [new CutPoint.OnVertex(4), new CutPoint.OnVertex(5)]).Reason);
        Assert.NotNull(MeshCut.Cut(box, [new CutPoint.OnVertex(4)]).Reason);
    }

    [Fact]
    public void DrawCutsAPolygonIntoAFaceAndMakesPlanesOnNothing()
    {
        var box = Box();
        Vec3[] door = [new(0.25, 1, 0.25), new(0.75, 1, 0.25), new(0.75, 1, 0.75), new(0.25, 1, 0.75)];
        var (result, reason) = MeshCut.Draw(box, 1, door);
        Assert.Null(reason);
        var mesh = result.Mesh;
        Assert.Equal(8, mesh.Faces.Length);
        Assert.Equal(12, mesh.Vertices.Length);
        var inner = mesh.Faces[Assert.Single(result.Selected)];
        Assert.Equal(4, inner.Corners.Length);
        // The new face fronts as the top does, whichever way the polygon went, and keeps its mapping.
        Assert.Equal(1, Vec3.Dot(mesh.FaceNormal(result.Selected[0]), Vec3.UnitY), 9);
        Assert.Equal(box.Faces[1].Mapping, inner.Mapping);
        Assert.Empty(mesh.Validate());
        // The ring's two faces are in the top's plane and front up.
        foreach (var f in new[] { 1, 6 })
        {
            Assert.Equal(1, Vec3.Dot(mesh.FaceNormal(f), Vec3.UnitY), 6);
        }
        // Every edge of the result has one or two faces, the ring's inner edges two.
        Assert.All(mesh.Edges, e => Assert.InRange(mesh.FacesOfEdge(e).Count, 1, 2));
        // The reverse polygon gives the same face.
        var (reversed, _) = MeshCut.Draw(box, 1, [.. door.Reverse()]);
        Assert.Equal(1, Vec3.Dot(reversed.Mesh.FaceNormal(reversed.Selected[0]), Vec3.UnitY), 9);

        // A bowtie, a polygon off the face and one of two points are refused.
        Assert.NotNull(MeshCut.Draw(box, 1, [new(0.25, 1, 0.25), new(0.75, 1, 0.75), new(0.75, 1, 0.25), new(0.25, 1, 0.75)]).Reason);
        Assert.NotNull(MeshCut.Draw(box, 1, [new(0.25, 1, 0.25), new(2, 1, 0.25), new(0.75, 1, 0.75)]).Reason);
        Assert.NotNull(MeshCut.Draw(box, 1, [new(0.25, 1, 0.25), new(0.75, 1, 0.75)]).Reason);

        // On nothing, a plane that fronts the way asked.
        var plane = MeshCut.Plane([new(0, 0, 0), new(2, 0, 0), new(2, 0, 2), new(0, 0, 2)], Vec3.UnitY);
        Assert.NotNull(plane);
        Assert.Equal(1, Vec3.Dot(plane.FaceNormal(0), Vec3.UnitY), 9);
        Assert.Equal(Mapping.WorldAligned(Vec3.UnitY), plane.Faces[0].Mapping);
        Assert.Null(MeshCut.Plane([new(0, 0, 0), new(2, 0, 0), new(1, 0, 0)], Vec3.UnitY));
    }

    [Fact]
    public void BevelReplacesVerticesAndEdges()
    {
        var box = Box();
        // A corner becomes a triangle, and its three faces gain a corner each.
        var (vertex, kind, selected) = MeshBevel.Vertices(box, [6], 0.25);
        Assert.Equal(MeshElement.Faces, kind);
        Assert.Equal(7, vertex.Faces.Length);
        Assert.Equal(10, vertex.Vertices.Length);
        var cap = vertex.Faces[Assert.Single(selected)];
        Assert.Equal(3, cap.Corners.Length);
        Assert.True(Vec3.Dot(vertex.FaceNormal(selected[0]), new Vec3(1, 1, 1)) > 0.9);
        Assert.Equal(3, vertex.Faces.Count(f => f.Corners.Length == 5));
        Assert.Empty(vertex.Validate());
        Assert.All(vertex.Edges, e => Assert.Equal(2, vertex.FacesOfEdge(e).Count));

        // An edge becomes a chamfer with one segment, and a rounded strip with more; the ends close with a fan.
        var (chamfer, _, strip) = MeshBevel.Edges(box, [box.EdgeIndex(5, 6)], 0.25, 1);
        Assert.Single(strip);
        Assert.Equal(4, chamfer.Faces[strip[0]].Corners.Length);
        Assert.True(Vec3.Dot(chamfer.FaceNormal(strip[0]), new Vec3(1, 1, 0).Normalized()) > 0.99);
        Assert.Equal(6 + 1 + 2, chamfer.Faces.Length);
        Assert.Empty(chamfer.Validate());
        var (round, _, rounded) = MeshBevel.Edges(box, [box.EdgeIndex(5, 6)], 0.25, 4);
        Assert.Equal(4, rounded.Count);
        Assert.Equal(6 + 4 + 8, round.Faces.Length);
        Assert.Empty(round.Validate());
        // An open edge is left alone.
        var plane = Primitives.Make(PrimitiveKind.Plane, Vec3.Zero, new Vec3(1, 0, 1), 1, PrimitiveParameters.Default);
        Assert.Empty(MeshBevel.Edges(plane, [0], 0.1).Selected);
    }

    [Theory]
    [InlineData(PrimitiveKind.Block, 6)]
    [InlineData(PrimitiveKind.Wedge, 5)]
    [InlineData(PrimitiveKind.Cylinder, 16 + 2)]
    [InlineData(PrimitiveKind.Cone, 16 + 1)]
    [InlineData(PrimitiveKind.Sphere, 16 * 8)]
    [InlineData(PrimitiveKind.Arch, 16 * 4)]
    [InlineData(PrimitiveKind.Stairs, 8 * 2 + 4)]
    [InlineData(PrimitiveKind.Torus, 16 * 8)]
    [InlineData(PrimitiveKind.Plane, 1)]
    public void PrimitivesHaveTheirFacesAndFrontOut(PrimitiveKind kind, int faces)
    {
        var parameters = PrimitiveParameters.Default with { Sides = kind == PrimitiveKind.Torus ? 8 : 16 };
        var min = new Vec3(1, 2, 3);
        var mesh = Primitives.Make(kind, min, min + new Vec3(2, 1, 2), 1, parameters, material: "00112233445566778899aabbccddeeff");
        Assert.Equal(faces, mesh.Faces.Length);
        Assert.Equal("00112233445566778899aabbccddeeff", mesh.Materials[0]);
        Assert.Empty(mesh.Validate());
        // Every face has a mapping that reads: its axes are not along its normal.
        for (var i = 0; i < mesh.Faces.Length; i++)
        {
            var normal = mesh.FaceNormal(i);
            Assert.True(Math.Abs(Vec3.Dot(mesh.Faces[i].Mapping.UAxis.Normalized(), normal)) < 0.5, $"face {i}'s u runs along its normal");
        }
        // Closed primitives have two faces on every edge, and every face fronts away from the middle.
        var middle = min + new Vec3(1, 0.5, 1);
        if (Primitives.IsClosed(kind))
        {
            Assert.All(mesh.Edges, e => Assert.Equal(2, mesh.FacesOfEdge(e).Count));
        }
        // A stair's risers, a torus's inside and an arch's inside front toward the middle, as they should, and a plane
        // only ever faces up.
        if (kind == PrimitiveKind.Plane)
        {
            Assert.Equal(1, Vec3.Dot(mesh.FaceNormal(0), Vec3.UnitY), 9);
        }
        else if (kind is not (PrimitiveKind.Stairs or PrimitiveKind.Torus or PrimitiveKind.Arch))
        {
            for (var i = 0; i < mesh.Faces.Length; i++)
            {
                var center = mesh.Faces[i].Corners.Aggregate(Vec3.Zero, (s, c) => s + mesh.Vertices[c]) / mesh.Faces[i].Corners.Length;
                Assert.True(Vec3.Dot(mesh.FaceNormal(i), center - middle) > -1e-6, $"face {i} of the {kind} fronts in");
            }
        }
        // Everything is inside the box.
        Assert.All(mesh.Vertices, v => Assert.True(v.X >= min.X - 1e-9 && v.X <= min.X + 2 + 1e-9 && v.Y >= min.Y - 1e-9 && v.Y <= min.Y + 1 + 1e-9));
    }

    [Fact]
    public void ACylindersSidesAreContinuousInU()
    {
        var mesh = Primitives.Make(PrimitiveKind.Cylinder, Vec3.Zero, new Vec3(2, 1, 2), 1, PrimitiveParameters.Default with { Sides = 8 });
        // Each side's u at its first corner is its u at the side before's last corner.
        for (var i = 0; i < 8; i++)
        {
            var side = mesh.Faces[2 + i];
            var next = mesh.Faces[2 + (i + 1) % 8];
            var (endU, _) = side.Mapping.Uv(mesh.Vertices[side.Corners[3]]);
            var (startU, _) = next.Mapping.Uv(mesh.Vertices[next.Corners[0]]);
            if (i < 7)
            {
                Assert.Equal(endU, startU, 6);
            }
        }
        // A primitive standing along z faces that way.
        var standing = Primitives.Make(PrimitiveKind.Cylinder, Vec3.Zero, new Vec3(2, 2, 1), 2, PrimitiveParameters.Default);
        Assert.Equal(1, Math.Abs(Vec3.Dot(standing.FaceNormal(0), Vec3.UnitZ)), 9);
        Assert.Empty(standing.Validate());
    }
}
