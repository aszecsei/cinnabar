using Cinnabar.Editor.Document;
using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Tools;
using Wire = Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Tests;

public sealed class MeshDocumentTests : IDisposable
{
    readonly string _directory = Path.Combine(Path.GetTempPath(), $"cinnabar-mesh-tests-{Guid.NewGuid():N}");

    const string MeshGuid = "3b7f2c9e4d1a4f6b8c0d2e4f6a8b0c1d";

    const string Quad = """
        mesh 1
        v 0 0 0
        v 0 1 0
        v 1 1 0
        v 1 0 0
        f 0 0 1 2 3
        map 1 0 0 0 -1 0 1 1 0 0 0

        """;

    (SceneDocument Scene, MeshSet Meshes, MeshDocument Mesh, List<(MeshDocument, MeshData)> Changes) Open()
    {
        var (scene, _) = SceneFile.Parse("scene 1\n");
        var document = new SceneDocument(Path.Combine(_directory, "room.scene"), scene!);
        var meshes = new MeshSet();
        var changes = new List<(MeshDocument, MeshData)>();
        meshes.Changed += (d, before) => changes.Add((d, before));
        var (mesh, _) = MeshFile.Parse(Quad.ReplaceLineEndings("\n"));
        var meshDocument = new MeshDocument(Path.Combine(_directory, "room.mesh"), MeshGuid, mesh!);
        meshes.Add(meshDocument);
        return (document, meshes, meshDocument, changes);
    }

    static MeshData Moved(MeshData mesh, double dy) =>
        mesh.With(vertices: mesh.Vertices.Select(v => new Vec3(v.X, v.Y + dy, v.Z)));

    [Fact]
    public void ADragIsOneEntryWithTheFirstSnapshotBefore()
    {
        var (scene, meshes, mesh, changes) = Open();
        var start = mesh.Data;
        var sent = new List<Operation>();
        scene.Applied += ops => sent.AddRange(ops);

        scene.Begin("Move");
        scene.Preview(new MeshOperation(MeshGuid, mesh.Data, Moved(start, 1), meshes));
        scene.Preview(new MeshOperation(MeshGuid, mesh.Data, Moved(start, 2), meshes));
        scene.Commit();

        Assert.Single(scene.History);
        Assert.Equal("Move", scene.History[0].Label);
        Assert.Equal(2, mesh.Data.Vertices[0].Y);
        Assert.True(mesh.IsDirty);
        Assert.True(meshes.AnyDirty);
        // Each step reached the set, with the data before it, and nothing goes to the host as an operation.
        Assert.Equal(2, changes.Count);
        Assert.Same(start, changes[0].Item2);
        Assert.All(sent, op => Assert.Null(op.ToWire()));

        // Undo returns the very first snapshot, so the document is clean again.
        scene.Undo();
        Assert.Same(start, mesh.Data);
        Assert.False(mesh.IsDirty);
        Assert.False(scene.IsDirty);
        scene.Redo();
        Assert.Equal(2, mesh.Data.Vertices[0].Y);
    }

    [Fact]
    public void SceneAndMeshDirtyStatesAreIndependent()
    {
        var (scene, meshes, mesh, _) = Open();
        scene.Apply("Move", new MeshOperation(MeshGuid, mesh.Data, Moved(mesh.Data, 1), meshes));
        Assert.True(scene.IsDirty);
        Assert.True(mesh.IsDirty);

        // Saving the mesh makes it clean, and the scene stays dirty, since its history position is not the saved one.
        Directory.CreateDirectory(_directory);
        mesh.Save();
        Assert.False(mesh.IsDirty);
        Assert.True(scene.IsDirty);
        var (again, _) = MeshFile.Parse(File.ReadAllText(mesh.Path));
        Assert.Equal(1, again!.Vertices[0].Y);

        // An undo past the save makes the mesh dirty again, with the scene at its saved position.
        scene.Undo();
        Assert.True(mesh.IsDirty);
        Assert.False(scene.IsDirty);

        // A mixed entry: a scene operation and a mesh operation together.
        var create = SceneEdits.NewEntity(scene.Scene, [0, 0, 0]);
        scene.Apply("Block", create, new MeshOperation(MeshGuid, mesh.Data, Moved(mesh.Data, 3), meshes));
        Assert.NotNull(scene.Scene.Find(create.Created.Id));
        Assert.Equal(3, mesh.Data.Vertices[0].Y);
        scene.Undo();
        Assert.Null(scene.Scene.Find(create.Created.Id));
        Assert.Equal(0, mesh.Data.Vertices[0].Y);
    }

    [Fact]
    public void AnOperationOnAMeshThatIsNotOpenIsRefused()
    {
        var (scene, meshes, mesh, _) = Open();
        Assert.Throws<InvalidOperationException>(() => scene.Apply("Move", new MeshOperation("00112233445566778899aabbccddeeff", mesh.Data, mesh.Data, meshes)));
        Assert.Empty(scene.History);
    }

    [Fact]
    public void LiveMessagesCarryTheFile()
    {
        var (_, _, mesh, _) = Open();
        var data = mesh.Data.With(materials: ["", "00112233445566778899aabbccddeeff"], sharpEdges: [new MeshEdge(0, 1)]);
        var message = LiveMeshes.Mesh(MeshGuid, data);
        Assert.Equal(Convert.FromHexString(MeshGuid), message.Guid);
        var material = Assert.Single(message.Materials);
        Assert.Equal(1u, material.Slot);
        Assert.Equal(Convert.FromHexString("00112233445566778899aabbccddeeff"), material.Guid);
        Assert.Equal(12, message.Positions.Length);
        Assert.Equal(1, message.Positions[4]);
        var face = Assert.Single(message.Faces);
        Assert.Equal([0u, 1u, 2u, 3u], face.Corners);
        Assert.Equal([1, 0, 0], face.Mapping.UAxis);
        Assert.Equal([0, -1, 0], face.Mapping.VAxis);
        Assert.Equal([1, 1], face.Mapping.Scale);
        var edge = Assert.Single(message.Sharp);
        Assert.Equal((0u, 1u), (edge.A, edge.B));

        var vertices = LiveMeshes.Vertices(MeshGuid, Moved(data, 2));
        Assert.Equal(3, vertices.Positions[4]);
        Assert.Equal(Convert.FromHexString(MeshGuid), LiveMeshes.Release(MeshGuid).Guid);

        // A move keeps the faces, so it is a vertices-only change; a new face is not, nor is a new vertex.
        Assert.True(LiveMeshes.IsVerticesOnly(data, Moved(data, 2)));
        Assert.False(LiveMeshes.IsVerticesOnly(data, data.With(faces: data.Faces.Add(data.Faces[0]))));
        Assert.False(LiveMeshes.IsVerticesOnly(data, data.With(vertices: data.Vertices.Add(Vec3.Zero))));
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory))
        {
            Directory.Delete(_directory, recursive: true);
        }
    }
}
