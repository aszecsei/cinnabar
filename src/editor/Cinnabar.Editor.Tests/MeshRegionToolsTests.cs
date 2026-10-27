using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Tests;

/// <summary>The region and topology tools on a box: counts, planarity, winding and the mappings of new faces.</summary>
public class MeshRegionToolsTests
{
    static MeshData Box() => Primitives.Block(Vec3.Zero, new Vec3(1, 1, 1));

    // Every face fronts away from the box's middle.
    static void AssertFrontsOut(MeshData mesh, Vec3 middle)
    {
        for (var i = 0; i < mesh.Faces.Length; i++)
        {
            var center = mesh.Faces[i].Corners.Aggregate(Vec3.Zero, (s, c) => s + mesh.Vertices[c]) / mesh.Faces[i].Corners.Length;
            Assert.True(Vec3.Dot(mesh.FaceNormal(i), center - middle) > 0, $"face {i} fronts in");
        }
    }

    [Fact]
    public void ExtrudePullsAFaceOutWithWalls()
    {
        var box = Box();
        var (mesh, kind, selected) = MeshTools.Extrude(box, [1], 0.5);
        Assert.Equal(MeshElement.Faces, kind);
        Assert.Equal([1], selected);
        // The top's four vertices are copied up, the top moves, and four walls join the copies to the old vertices.
        Assert.Equal(12, mesh.Vertices.Length);
        Assert.Equal(10, mesh.Faces.Length);
        Assert.All(mesh.Faces[1].Corners, c => Assert.Equal(1.5, mesh.Vertices[c].Y));
        Assert.Empty(mesh.Validate());
        AssertFrontsOut(mesh, new Vec3(0.5, 0.5, 0.5));
        // A wall takes the top's slot and a world-aligned mapping for its own normal, and its edges are sharp.
        var wall = mesh.Faces[6];
        Assert.Equal(Mapping.WorldAligned(mesh.FaceNormal(6)), wall.Mapping);
        // The walls' far edges and their four uprights join the box's twelve.
        Assert.Equal(20, mesh.SharpEdges.Length);

        // Two faces that share an edge extrude as one: no wall between them.
        var (two, _, _) = MeshTools.Extrude(box, [1, 2], 0.25);
        Assert.Equal(6 + 6, two.Faces.Length);
        Assert.Empty(two.Validate());

        // An open mesh grows walls on its open edges too: a plane becomes a solid.
        var plane = Primitives.Make(PrimitiveKind.Plane, Vec3.Zero, new Vec3(2, 0, 2), 1, PrimitiveParameters.Default);
        var (solid, _, _) = MeshTools.Extrude(plane, [0], 1);
        Assert.Equal(5, solid.Faces.Length);
        Assert.Equal(8, solid.Vertices.Length);
        Assert.All(solid.Edges, e => Assert.True(solid.FacesOfEdge(e).Count <= 2));
    }

    [Fact]
    public void OpenEdgesExtrudeIntoQuads()
    {
        // Two edges of a floor plane become walls, and an edge of the box, which has two faces, is left alone.
        var plane = Primitives.Make(PrimitiveKind.Plane, Vec3.Zero, new Vec3(2, 0, 2), 1, PrimitiveParameters.Default);
        var (mesh, kind, selected) = MeshTools.ExtrudeEdges(plane, [0, 1], 1);
        Assert.Equal(MeshElement.Edges, kind);
        Assert.Equal(2, selected.Count);
        Assert.Equal(8, mesh.Vertices.Length);
        Assert.Equal(3, mesh.Faces.Length);
        Assert.All(selected, e => Assert.True(mesh.Vertices[mesh.Edges[e].A].Y > 0.99 && mesh.Vertices[mesh.Edges[e].B].Y > 0.99));
        Assert.Empty(mesh.Validate());
        var box = Box();
        Assert.Empty(MeshTools.ExtrudeEdges(box, [box.EdgeIndex(4, 5)], 0.5).Selected);
    }

    [Fact]
    public void PushPullAndOffsetMoveFaces()
    {
        var box = Box();
        var (pushed, _, _) = MeshTools.PushPull(box, [1], 0.5);
        Assert.Equal(8, pushed.Vertices.Length);
        Assert.All(pushed.Faces[1].Corners, c => Assert.Equal(1.5, pushed.Vertices[c].Y));
        Assert.Empty(pushed.Validate());

        // Offsetting two faces at a corner keeps the corner sharp: the shared vertices move along the bisector.
        var (offset, _, _) = MeshTools.Offset(box, [1, 5], 0.5);
        Assert.Equal(new Vec3(1.5, 1.5, 0), offset.Vertices[5]);
        Assert.Equal(new Vec3(0, 1.5, 0), offset.Vertices[4]);
        Assert.Equal(new Vec3(1.5, 0, 0), offset.Vertices[1]);
        Assert.Empty(offset.Validate());
        // Offsetting the whole box grows it by the distance on every side, so corners meet three planes.
        var (grown, _, _) = MeshTools.Offset(box, [0, 1, 2, 3, 4, 5], 0.5);
        Assert.Equal(new Vec3(-0.5, -0.5, -0.5), grown.Vertices[0]);
        Assert.Equal(new Vec3(1.5, 1.5, 1.5), grown.Vertices[6]);
    }

    [Fact]
    public void InsetShrinksAFaceInsideARing()
    {
        var box = Box();
        var (mesh, _, selected) = MeshTools.Inset(box, [1], 0.25);
        Assert.Equal([1], selected);
        Assert.Equal(12, mesh.Vertices.Length);
        Assert.Equal(10, mesh.Faces.Length);
        // The inset face's corners are a quarter in from the box's.
        var inner = mesh.Faces[1].Corners.Select(c => mesh.Vertices[c]).ToList();
        Assert.Contains(new Vec3(0.25, 1, 0.25), inner);
        Assert.Contains(new Vec3(0.75, 1, 0.75), inner);
        Assert.Empty(mesh.Validate());
        AssertFrontsOut(mesh, new Vec3(0.5, 0.5, 0.5));
        // The ring faces keep the top's mapping, and are in its plane.
        for (var f = 6; f < 10; f++)
        {
            Assert.Equal(box.Faces[1].Mapping, mesh.Faces[f].Mapping);
            Assert.Equal(1, Vec3.Dot(mesh.FaceNormal(f), Vec3.UnitY), 9);
        }
        // Outset: a negative distance.
        var (outset, _, _) = MeshTools.Inset(box, [1], -0.25);
        Assert.Contains(new Vec3(-0.25, 1, -0.25), outset.Faces[1].Corners.Select(c => outset.Vertices[c]));
    }

    [Fact]
    public void DuplicateCopiesFacesInPlace()
    {
        var box = Box();
        var (mesh, kind, selected) = MeshTools.Duplicate(box, [1, 2]);
        Assert.Equal(MeshElement.Faces, kind);
        Assert.Equal([6, 7], selected);
        Assert.Equal(8, mesh.Faces.Length);
        // The two faces share an edge, so their copies share its two copies: six new vertices.
        Assert.Equal(14, mesh.Vertices.Length);
        Assert.Equal(box.Faces[1].Mapping, mesh.Faces[6].Mapping);
        Assert.Equal(mesh.Vertices[mesh.Faces[6].Corners[0]], box.Vertices[box.Faces[1].Corners[0]]);
    }

    [Fact]
    public void InvertFlipsFacesAndTheirTextures()
    {
        var box = Box();
        var (mesh, _, _) = MeshTools.Invert(box, [1]);
        Assert.Equal(-1, Vec3.Dot(mesh.FaceNormal(1), Vec3.UnitY), 9);
        Assert.Equal(-box.Faces[1].Mapping.VAxis, mesh.Faces[1].Mapping.VAxis);
        Assert.Equal(box.Faces[1].Mapping.UAxis, mesh.Faces[1].Mapping.UAxis);
    }

    [Fact]
    public void CollapseMergesVerticesEdgesAndFaces()
    {
        var box = Box();
        // The top's four vertices become one at its middle: a pyramid of four triangles and the bottom.
        var (pyramid, kind, selected) = MeshTools.Collapse(box, MeshElement.Faces, [1]);
        Assert.Equal(MeshElement.Vertices, kind);
        Assert.Equal(5, pyramid.Vertices.Length);
        Assert.Equal(5, pyramid.Faces.Length);
        Assert.Equal(new Vec3(0.5, 1, 0.5), pyramid.Vertices[Assert.Single(selected)]);
        Assert.Empty(pyramid.Validate());
        // An edge collapses to its middle, and the two faces beside it become triangles.
        var (edge, _, _) = MeshTools.Collapse(box, MeshElement.Edges, [box.EdgeIndex(4, 5)]);
        Assert.Equal(7, edge.Vertices.Length);
        Assert.Equal(6, edge.Faces.Length);
        Assert.Equal(2, edge.Faces.Count(f => f.Corners.Length == 3));
        Assert.Contains(new Vec3(0.5, 1, 0), edge.Vertices);
        // Two vertices that share no edge still collapse into one at their centroid.
        var (vertices, _, _) = MeshTools.Collapse(box, MeshElement.Vertices, [4, 6]);
        Assert.Equal(7, vertices.Vertices.Length);
        Assert.Contains(new Vec3(0.5, 1, 0.5), vertices.Vertices);
    }

    [Fact]
    public void MergeFacesDissolvesCoplanarNeighbors()
    {
        // The top split in two by a cut, then merged back into one quad.
        var box = Box();
        var (cut, reason) = MeshCut.Cut(box, [new CutPoint.OnEdge(4, 7, 0.5), new CutPoint.OnEdge(5, 6, 0.5)]);
        Assert.Null(reason);
        Assert.Equal(7, cut.Mesh.Faces.Length);
        var halves = Enumerable.Range(0, cut.Mesh.Faces.Length).Where(f => Vec3.Dot(cut.Mesh.FaceNormal(f), Vec3.UnitY) > 0.99).ToList();
        Assert.Equal(2, halves.Count);
        var (merged, _, selected) = MeshTools.MergeFaces(cut.Mesh, halves);
        Assert.Equal(6, merged.Faces.Length);
        var top = merged.Faces[Assert.Single(selected)];
        // The cut's vertices stay on the sides, so the merged top has six corners.
        Assert.Equal(6, top.Corners.Length);
        Assert.Empty(merged.Validate());
        // Faces that are not coplanar stay apart.
        var (apart, _, _) = MeshTools.MergeFaces(box, [1, 2]);
        Assert.Equal(6, apart.Faces.Length);
    }

    [Fact]
    public void CleanWeldsAndDissolves()
    {
        var box = Box();
        // A doubled vertex a hair off, a collinear vertex on the top's edge, and a degenerate face.
        var vertices = box.Vertices.Add(new Vec3(1, 1, 1.00001)).Add(new Vec3(0.5, 1, 1));
        var faces = box.Faces.SetItem(3, box.Faces[3] with { Corners = [2, 8, 7, 3] }).SetItem(1, box.Faces[1] with { Corners = [4, 7, 9, 6, 5] })
            .Add(new MeshFace(0, [0, 1, 1], Mapping.WorldAligned(Vec3.UnitY)));
        var dirty = box.With(vertices: vertices, faces: faces);
        var (clean, problems) = MeshTools.Clean(dirty);
        Assert.Equal(8, clean.Vertices.Length);
        Assert.Equal(6, clean.Faces.Length);
        Assert.Equal(4, clean.Faces[1].Corners.Length);
        Assert.Empty(problems);
        Assert.Empty(clean.Validate());
        // An edge with three faces is reported.
        var (_, reported) = MeshTools.Clean(box.With(faces: box.Faces.Add(new MeshFace(0, [0, 1, 5], Mapping.WorldAligned(Vec3.UnitZ)))));
        Assert.Contains(reported, p => p.Contains("edge 0 1 has 3 faces"));
    }

    [Fact]
    public void RecalculateNormalsMarksSharpEdgesByAngle()
    {
        var box = Box();
        var smooth = box.With(sharpEdges: []);
        Assert.Equal(12, MeshTools.RecalculateNormals(smooth, 30).SharpEdges.Length);
        Assert.Empty(MeshTools.RecalculateNormals(smooth, 91).SharpEdges);
        // Only the top's edges, with the others kept as they were.
        var partial = MeshTools.RecalculateNormals(box.With(sharpEdges: [new MeshEdge(0, 1)]), 30, [1]);
        Assert.Equal(5, partial.SharpEdges.Length);
    }

    [Fact]
    public void SplitTakesFacesIntoTheirOwnMesh()
    {
        var box = Box();
        var (extracted, remaining) = MeshTools.Split(box, [1]);
        Assert.Single(extracted.Faces);
        Assert.Equal(4, extracted.Vertices.Length);
        Assert.Equal(4, extracted.SharpEdges.Length);
        Assert.Equal(5, remaining.Faces.Length);
        Assert.Equal(8, remaining.Vertices.Length);
        Assert.Equal(box.Materials, extracted.Materials);
    }
}
