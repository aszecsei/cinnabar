using Cinnabar.Editor.Document;
using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Tests;

/// <summary>Picking in mesh mode: a ray against a box, the nearest vertex and edge on screen, and box selection.</summary>
public class MeshPickTests
{
    const double Width = 1600;
    const double Height = 900;

    // A 1 m box 5 m ahead of a camera at the origin, centered on the view's axis.
    static (MeshData Mesh, MeshPlacement Placement, EditorCamera Camera) Scene()
    {
        var mesh = Primitives.Block(new Vec3(-0.5, -0.5, -0.5), new Vec3(0.5, 0.5, 0.5));
        var camera = new EditorCamera();
        camera.Place([0, 0, 0], 0, 0);
        var pose = new Pose([0, 0, (long)(5 * Pose.Unit)], Quat.Identity, [1, 1, 1]);
        return (mesh, MeshPlacement.Of(pose, camera.Position), camera);
    }

    static Vec2 Center => new(Width / 2, Height / 2);

    [Fact]
    public void ARayPicksTheNearFace()
    {
        var (mesh, placement, camera) = Scene();
        var hit = MeshPick.Face(mesh, placement, camera.Ray(Center, Width, Height));
        Assert.NotNull(hit);
        // The front face, at z = -0.5 of the box, is 4.5 m away, and its normal faces the camera.
        Assert.Equal(2, hit.Value.Face);
        Assert.Equal(4.5, hit.Value.Distance, 6);
        Assert.Equal(-1, Vec3.Dot(placement.NormalToView(mesh.FaceNormal(hit.Value.Face)), Vec3.UnitZ), 6);

        // Through the box, the back face is the nearest back face: with back faces, the front still wins.
        var through = MeshPick.Face(mesh, placement, camera.Ray(Center, Width, Height), through: true);
        Assert.Equal(2, through!.Value.Face);
        // A ray past the box hits nothing.
        Assert.Null(MeshPick.Face(mesh, placement, camera.Ray(new Vec2(10, 10), Width, Height)));
    }

    [Fact]
    public void TheVertexWithinEightPixelsWinsOverTheFace()
    {
        var (mesh, placement, camera) = Scene();
        // The front face's top right corner on screen.
        var corner = camera.Project(placement.ToView(mesh.Vertices[5]), Width, Height)!.Value;
        var near = corner + new Vec2(3, -3);
        var hit = MeshPick.Face(mesh, placement, camera.Ray(near, Width, Height));
        Assert.Equal(5, MeshPick.Vertex(mesh, placement, camera, near, Width, Height, hit?.Distance));
        // Twelve pixels away is too far.
        Assert.Null(MeshPick.Vertex(mesh, placement, camera, corner + new Vec2(12, 0), Width, Height, hit?.Distance));
        // The back face's corner behind it projects near the same place only from the side; from the front it is far.
        var back = camera.Project(placement.ToView(mesh.Vertices[6]), Width, Height)!.Value;
        var frontHit = MeshPick.Face(mesh, placement, camera.Ray(back, Width, Height));
        Assert.NotNull(frontHit);
        // Vertex 6 is on the back face: deeper than the front face hit under it, so it is not picked.
        Assert.NotEqual(6, MeshPick.Vertex(mesh, placement, camera, back, Width, Height, frontHit!.Value.Distance));
    }

    [Fact]
    public void EdgesArePickedByScreenDistance()
    {
        var (mesh, placement, camera) = Scene();
        // The middle of the front face's top edge, 4 to 5.
        var (a, b) = (camera.Project(placement.ToView(mesh.Vertices[4]), Width, Height)!.Value, camera.Project(placement.ToView(mesh.Vertices[5]), Width, Height)!.Value);
        var middle = (a + b) * 0.5 + new Vec2(0, 2);
        var hit = MeshPick.Face(mesh, placement, camera.Ray(middle, Width, Height));
        var edge = MeshPick.Edge(mesh, placement, camera, middle, Width, Height, hit?.Distance);
        Assert.NotNull(edge);
        Assert.Equal(new MeshEdge(4, 5), mesh.Edges[edge.Value]);
        Assert.Null(MeshPick.Edge(mesh, placement, camera, Center, Width, Height, hit?.Distance));
    }

    [Fact]
    public void BoxSelectionTakesWhatIsInsideAndSelectThroughTakesTheBack()
    {
        var (mesh, placement, camera) = Scene();
        var min = new Vec2(0, 0);
        var max = new Vec2(Width, Height);
        // From the front, only the front face and its four vertices and edges face the camera.
        Assert.Equal([2], MeshPick.InBox(mesh, placement, camera, MeshElement.Faces, min, max, Width, Height, through: false));
        Assert.Equal([0, 1, 4, 5], MeshPick.InBox(mesh, placement, camera, MeshElement.Vertices, min, max, Width, Height, through: false).Order());
        Assert.Equal(4, MeshPick.InBox(mesh, placement, camera, MeshElement.Edges, min, max, Width, Height, through: false).Count());
        // Select Through takes everything.
        Assert.Equal(6, MeshPick.InBox(mesh, placement, camera, MeshElement.Faces, min, max, Width, Height, through: true).Count());
        Assert.Equal(8, MeshPick.InBox(mesh, placement, camera, MeshElement.Vertices, min, max, Width, Height, through: true).Count());
        Assert.Equal(12, MeshPick.InBox(mesh, placement, camera, MeshElement.Edges, min, max, Width, Height, through: true).Count());
        // A box over the left half takes the left vertices only, and no whole face.
        var left = MeshPick.InBox(mesh, placement, camera, MeshElement.Vertices, min, new Vec2(Width / 2, Height), Width, Height, through: true).ToList();
        Assert.Equal([0, 3, 4, 7], left.Order());
        Assert.Empty(MeshPick.InBox(mesh, placement, camera, MeshElement.Faces, min, new Vec2(Width / 2 + 1, Height), Width, Height, through: false));
    }

    [Fact]
    public void PlacementsRoundTrip()
    {
        var pose = new Pose([(long)(2 * Pose.Unit), (long)Pose.Unit, 0], Rotations.AxisAngle(Vec3.UnitY, Math.PI / 2), [2, 1, 1]);
        var placement = MeshPlacement.Of(pose, [0, 0, 0]);
        var local = new Vec3(0.5, 0.25, -1);
        var view = placement.ToView(local);
        var back = placement.ToLocal(view);
        Assert.Equal(local.X, back.X, 9);
        Assert.Equal(local.Y, back.Y, 9);
        Assert.Equal(local.Z, back.Z, 9);
        // A normal turns with the rotation and stays unit under the scale.
        var n = placement.NormalToView(Vec3.UnitX);
        Assert.Equal(1, n.Length, 9);
        Assert.Equal(-1, n.Z, 6);
    }
}
