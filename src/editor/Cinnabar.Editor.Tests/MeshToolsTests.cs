using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Tests;

/// <summary>The mesh tools on a box: Delete of each element kind, moves, the selection's conversions, and the grid.</summary>
public class MeshToolsTests
{
    static MeshData Box() => Primitives.Block(Vec3.Zero, new Vec3(1, 1, 1));

    [Fact]
    public void ABlockIsClosedAndFrontsOut()
    {
        var box = Primitives.Block(new Vec3(1, 0, 2), new Vec3(3, 1, 0), material: "00112233445566778899aabbccddeeff");
        Assert.Equal(8, box.Vertices.Length);
        Assert.Equal(6, box.Faces.Length);
        Assert.Equal(12, box.Edges.Length);
        Assert.Equal(12, box.SharpEdges.Length);
        Assert.Equal("00112233445566778899aabbccddeeff", box.Materials[0]);
        Assert.Empty(box.Validate());
        // Every edge has two faces, and every face's normal points away from the middle.
        Assert.All(box.Edges, e => Assert.Equal(2, box.FacesOfEdge(e).Count));
        var middle = new Vec3(2, 0.5, 1);
        for (var i = 0; i < box.Faces.Length; i++)
        {
            var center = box.Faces[i].Corners.Aggregate(Vec3.Zero, (sum, c) => sum + box.Vertices[c]) / 4;
            Assert.True(Vec3.Dot(box.FaceNormal(i), center - middle) > 0.4);
            Assert.Equal(Mapping.WorldAligned(box.FaceNormal(i)), box.Faces[i].Mapping);
        }
        // The corners are sorted, whichever way round they were given.
        Assert.Equal(new Vec3(1, 0, 0), box.Vertices[0]);
    }

    [Fact]
    public void DeleteRemovesByKind()
    {
        var box = Box();
        // A vertex takes its three faces with it, and the other vertices stay.
        var vertex = MeshTools.Delete(box, MeshElement.Vertices, [6]);
        Assert.Equal(7, vertex.Vertices.Length);
        Assert.Equal(3, vertex.Faces.Length);
        Assert.Empty(vertex.Validate());
        Assert.Equal(9, vertex.SharpEdges.Length);
        // An edge takes its two faces, and no vertex.
        var edge = MeshTools.Delete(box, MeshElement.Edges, [box.EdgeIndex(4, 5)]);
        Assert.Equal(8, edge.Vertices.Length);
        Assert.Equal(4, edge.Faces.Length);
        // The top face goes, and its vertices stay because the sides use them; the top and the sides then leave four
        // vertices unused when they go too.
        var face = MeshTools.Delete(box, MeshElement.Faces, [1]);
        Assert.Equal(8, face.Vertices.Length);
        Assert.Equal(5, face.Faces.Length);
        var sides = MeshTools.Delete(box, MeshElement.Faces, [1, 2, 3, 4, 5]);
        Assert.Equal(4, sides.Vertices.Length);
        Assert.Single(sides.Faces);
        Assert.Equal([0, 1, 2, 3], sides.Faces[0].Corners);
        Assert.Equal(4, sides.SharpEdges.Length);
        Assert.Empty(sides.Validate());
    }

    [Fact]
    public void MovesChangeOnlyTheChosenVertices()
    {
        var box = Box();
        var moved = MeshTools.MoveVertices(box, [4, 5, 6, 7], v => v + new Vec3(0, 1, 0));
        Assert.Equal(2, moved.Vertices[4].Y);
        Assert.Equal(0, moved.Vertices[0].Y);
        Assert.Equal(box.Faces, moved.Faces);
        Assert.Equal(new Vec3(0.5, 2, 0.5), MeshTools.Centroid(moved, [4, 5, 6, 7]));
    }

    [Fact]
    public void SelectionsConvertThroughTheirVertices()
    {
        var box = Box();
        MeshData? Find(string guid) => guid == "a" ? box : null;
        var top = new MeshSelection(MeshElement.Faces, [new MeshItem("a", 1)]);
        var vertices = top.As(MeshElement.Vertices, Find);
        Assert.Equal([4, 5, 6, 7], vertices.Of("a").Order());
        var edges = top.As(MeshElement.Edges, Find);
        Assert.Equal(4, edges.Count);
        Assert.All(edges.Of("a"), e => Assert.True(box.Edges[e].A >= 4));
        // Back to faces: the four vertices make only the top.
        Assert.Equal([1], vertices.As(MeshElement.Faces, Find).Of("a"));
        // The eight vertices make every face and edge.
        var all = new MeshSelection(MeshElement.Vertices, [.. MeshSelection.All("a", box, MeshElement.Vertices)]);
        Assert.Equal(6, all.As(MeshElement.Faces, Find).Count);
        Assert.Equal(12, all.As(MeshElement.Edges, Find).Count);
        // Toggling and pruning.
        var toggled = top.Toggle([new MeshItem("a", 1), new MeshItem("a", 2)]);
        Assert.Equal([2], toggled.Of("a"));
        var pruned = new MeshSelection(MeshElement.Faces, [new MeshItem("a", 5), new MeshItem("a", 9), new MeshItem("b", 0)]).Pruned(Find);
        Assert.Equal([new MeshItem("a", 5)], pruned.Items);
    }

    [Fact]
    public void TheGridSnapsAndSteps()
    {
        Assert.Equal(new Vec3(0.25, -0.5, 1), MeshGrid.Snap(new Vec3(0.3, -0.4, 1.1), 0.25));
        Assert.Equal(0.125, MeshGrid.Finer(0.25));
        Assert.Equal(MeshGrid.MinSize, MeshGrid.Finer(MeshGrid.MinSize));
        Assert.Equal(MeshGrid.MaxSize, MeshGrid.Coarser(MeshGrid.MaxSize));
        Assert.Equal("1/64 m", MeshGrid.Format(MeshGrid.MinSize));
        Assert.Equal("0.25 m", MeshGrid.Format(0.25));
        Assert.Equal("16 m", MeshGrid.Format(16));
        Assert.Equal(1, MeshGrid.NearestAxis(new Vec3(0.2, -0.9, 0.3)));
        // A ray down onto the floor plane 2 m below.
        Assert.Equal(new Vec3(0, -2, 2), MeshGrid.HitPlane(new Vec3(0, -2, 0), Vec3.UnitY, new Vec3(0, -1, 1).Normalized())!.Value);
        Assert.Null(MeshGrid.HitPlane(new Vec3(0, -2, 0), Vec3.UnitY, Vec3.UnitZ));
    }
}
