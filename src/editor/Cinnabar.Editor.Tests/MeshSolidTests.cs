using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Tests;

/// <summary>Solid meshes: IsSolid, the open edges, Bridge and Cap, and Clean's report of open edges.</summary>
public class MeshSolidTests
{
    static MeshData Make(PrimitiveKind kind) => Primitives.Make(kind, Vec3.Zero, new Vec3(2, 2, 2), 1, PrimitiveParameters.Default);

    static int Face(MeshData mesh, Vec3 normal, Func<Vec3, bool>? at = null) =>
        Enumerable.Range(0, mesh.Faces.Length).Single(f => Vec3.Dot(mesh.FaceNormal(f), normal) > 0.999 && (at == null || mesh.Faces[f].Corners.All(c => at(mesh.Vertices[c]))));

    [Theory]
    [InlineData(PrimitiveKind.Block)]
    [InlineData(PrimitiveKind.Wedge)]
    [InlineData(PrimitiveKind.Cylinder)]
    [InlineData(PrimitiveKind.Cone)]
    [InlineData(PrimitiveKind.Sphere)]
    [InlineData(PrimitiveKind.Stairs)]
    [InlineData(PrimitiveKind.Torus)]
    public void EachClosedPrimitiveIsSolid(PrimitiveKind kind)
    {
        var mesh = Make(kind);
        Assert.Empty(mesh.OpenEdges);
        Assert.True(mesh.IsSolid, $"{kind} is not solid");
        Assert.True(mesh.SignedVolume > 0);
    }

    [Fact]
    public void APlaneAndAnArchAreOpenAndAnInvertedBlockIsNotSolid()
    {
        Assert.False(Make(PrimitiveKind.Plane).IsSolid);
        Assert.Equal(4, Make(PrimitiveKind.Plane).OpenEdges.Length);
        var arch = Make(PrimitiveKind.Arch);
        Assert.False(arch.IsSolid);
        Assert.Equal(8, arch.OpenEdges.Length);
        // A block's volume is its size; inside out, it is negative and the block is closed but not solid.
        var box = MeshFixtures.Box();
        Assert.Equal(1, box.SignedVolume, 9);
        var (inverted, _, _) = MeshTools.Invert(box, Enumerable.Range(0, box.Faces.Length));
        Assert.Empty(inverted.OpenEdges);
        Assert.Equal(-1, inverted.SignedVolume, 9);
        Assert.False(inverted.IsSolid);
        // An edge of three faces is closed but not solid.
        var fin = box.With(faces: box.Faces.Add(new MeshFace(0, [0, 1, 5], Mapping.WorldAligned(Vec3.UnitZ))));
        Assert.False(fin.IsSolid);
    }

    [Fact]
    public void ADoorwayDrawnAndExtrudedThroughABlockIsBridgedSolid()
    {
        // A doorway drawn on the block's front, pulled in to the back, with the back face and the recess's end deleted.
        var block = Primitives.Block(Vec3.Zero, new Vec3(2, 2, 1));
        var front = Face(block, -Vec3.UnitZ);
        var (drawn, reason) = MeshCut.Draw(block, front, [new(0.5, 0.25, 0), new(1.5, 0.25, 0), new(1.5, 1.5, 0), new(0.5, 1.5, 0)]);
        Assert.Null(reason);
        var door = Assert.Single(drawn.Selected);
        var (recessed, _, selected) = MeshTools.Extrude(drawn.Mesh, [door], -1);
        Assert.Empty(recessed.Validate());
        var end = Assert.Single(selected);
        var back = Enumerable.Range(0, recessed.Faces.Length).Single(f => f != end && Vec3.Dot(recessed.FaceNormal(f), Vec3.UnitZ) > 0.999);
        var open = MeshTools.Delete(recessed, MeshElement.Faces, [end, back]);
        Assert.Equal(8, open.OpenEdges.Length);
        Assert.False(open.IsSolid);

        var (bridged, bridgeReason) = MeshTools.Bridge(open, open.OpenEdges);
        Assert.Null(bridgeReason);
        var mesh = bridged.Mesh;
        Assert.Empty(mesh.Validate());
        Assert.True(mesh.IsSolid);
        Assert.Equal(4, bridged.Selected.Count);
        Assert.Equal(MeshElement.Faces, bridged.Kind);
        // The new back faces front along +z, and none of their mappings lies edge-on to them.
        foreach (var f in bridged.Selected)
        {
            Assert.True(Vec3.Dot(mesh.FaceNormal(f), Vec3.UnitZ) > 0.999);
            var m = mesh.Faces[f].Mapping;
            Assert.True(Math.Abs(Vec3.Dot(Vec3.Cross(m.UAxis, m.VAxis).Normalized(), mesh.FaceNormal(f))) > 0.9);
        }
        // The block less the doorway's 1 by 1.25 by 1 m.
        Assert.Equal(4 - 1.25, mesh.SignedVolume, 6);
    }

    [Fact]
    public void BridgeRefusesOneLoopAndLoopsOfDifferentLengths()
    {
        var box = MeshFixtures.Box();
        var open = MeshTools.Delete(box, MeshElement.Faces, [Face(box, Vec3.UnitY)]);
        Assert.Contains("two loops", MeshTools.Bridge(open, open.OpenEdges).Reason);
        // A block without its top and without one triangle of its bottom: loops of four and of three edges.
        var bottom = Face(box, -Vec3.UnitY);
        var corners = box.Faces[bottom].Corners;
        var split = box.With(faces: box.Faces.SetItem(bottom, box.Faces[bottom] with { Corners = [corners[0], corners[1], corners[2]] })
            .Add(box.Faces[bottom] with { Corners = [corners[0], corners[2], corners[3]] }));
        var twoLoops = MeshTools.Delete(split, MeshElement.Faces, [Face(split, Vec3.UnitY), split.Faces.Length - 1]);
        Assert.Contains("same number", MeshTools.Bridge(twoLoops, twoLoops.OpenEdges).Reason);
        // A closed edge is not open.
        Assert.Contains("not open", MeshTools.Bridge(box, [0]).Reason);
    }

    [Fact]
    public void AnArchsEndsCapSolid()
    {
        var arch = Make(PrimitiveKind.Arch);
        var mesh = arch;
        // Each end is a loop of four open edges: cap the loop of the lowest open edge's end, then the other.
        for (var i = 0; i < 2; i++)
        {
            var first = mesh.OpenEdges[0];
            var linked = LoopOf(mesh, first);
            var (capped, reason) = MeshTools.Cap(mesh, linked);
            Assert.Null(reason);
            Assert.Equal(MeshElement.Faces, capped.Kind);
            Assert.Single(capped.Selected);
            Assert.Empty(capped.Mesh.Validate());
            mesh = capped.Mesh;
        }
        Assert.Empty(mesh.OpenEdges);
        Assert.True(mesh.IsSolid);
    }

    [Fact]
    public void CapRefusesALoopThatIsNotPlanar()
    {
        var arch = Make(PrimitiveKind.Arch);
        var loop = LoopOf(arch, arch.OpenEdges[0]);
        var bent = MeshTools.MoveVertices(arch, [arch.Edges[loop[0]].A], v => v + new Vec3(0, 0, 0.005) + new Vec3(0.005, 0, 0));
        var (result, reason) = MeshTools.Cap(bent, loop);
        Assert.NotNull(reason);
        Assert.Contains("not planar", reason);
        Assert.Same(bent, result.Mesh);
        // Two loops at once are refused too.
        Assert.Contains("one loop", MeshTools.Cap(arch, arch.OpenEdges).Reason);
    }

    [Fact]
    public void ACapOfAConcaveLoopIsTheBakesTriangles()
    {
        // An L-shaped plane pulled up into a prism with walls, open underneath: the bottom's loop is concave.
        Vec3[] l = [new(0, 0, 0), new(2, 0, 0), new(2, 0, 1), new(1, 0, 1), new(1, 0, 2), new(0, 0, 2)];
        var plane = MeshCut.Plane(l, Vec3.UnitY)!;
        var (open, _, _) = MeshTools.Extrude(plane, [0], 1);
        Assert.Equal(6, open.OpenEdges.Length);
        var (capped, reason) = MeshTools.Cap(open, open.OpenEdges);
        Assert.Null(reason);
        Assert.Equal(4, capped.Selected.Count);
        Assert.All(capped.Selected, f => Assert.Equal(3, capped.Mesh.Faces[f].Corners.Length));
        Assert.All(capped.Selected, f => Assert.True(Vec3.Dot(capped.Mesh.FaceNormal(f), -Vec3.UnitY) > 0.999));
        Assert.Empty(capped.Mesh.Validate());
        Assert.True(capped.Mesh.IsSolid);
        Assert.Equal(3, capped.Mesh.SignedVolume, 6);
    }

    [Fact]
    public void CleanReportsOpenEdgesInOneLine()
    {
        var box = MeshFixtures.Box();
        var open = MeshTools.Delete(box, MeshElement.Faces, [Face(box, Vec3.UnitY)]);
        var (_, problems) = MeshTools.Clean(open);
        Assert.Equal(["4 edges are open"], problems);
        Assert.Empty(MeshTools.Clean(box).Problems);
    }

    // The open edges joined to one through the open edges at its ends.
    static List<int> LoopOf(MeshData mesh, int edge)
    {
        var open = mesh.OpenEdges.ToHashSet();
        var loop = new List<int> { edge };
        var queue = new Queue<int>([edge]);
        while (queue.Count > 0)
        {
            var e = mesh.Edges[queue.Dequeue()];
            foreach (var other in open.Where(o => !loop.Contains(o) && (mesh.Edges[o].A == e.A || mesh.Edges[o].A == e.B || mesh.Edges[o].B == e.A || mesh.Edges[o].B == e.B)).ToList())
            {
                loop.Add(other);
                queue.Enqueue(other);
            }
        }
        return loop;
    }
}
