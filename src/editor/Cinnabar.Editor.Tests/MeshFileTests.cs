using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Tests;

public class MeshFileTests
{
    /// <summary>A 1 m box on the origin's corner, as the cooker's mesh template writes it, with a material and a comment.</summary>
    const string Box = """
        # A box.
        mesh 1
        material 0 $00112233445566778899aabbccddeeff
        v 0 0 0
        v 1 0 0
        v 1 0 1
        v 0 0 1
        v 0 1 0
        v 1 1 0
        v 1 1 1
        v 0 1 1
        f 0 0 1 2 3
        map 1 0 0 0 0 -1 1 1 0 0 0
        f 0 4 7 6 5
        map 1 0 0 0 0 -1 1 1 0 0 0
        f 0 0 4 5 1
        map 1 0 0 0 -1 0 1 1 0 0 0
        f 0 2 6 7 3
        map 1 0 0 0 -1 0 1 1 0 0 0
        f 0 3 7 4 0
        map 0 0 1 0 -1 0 1 1 0 0 0
        f 0 1 5 6 2
        map 0 0 1 0 -1 0 1 1 0 0 0
        e 4 5 sharp
        e 5 6 sharp
        e 6 7 sharp
        e 7 4 sharp

        """;

    static MeshData Parse(string text)
    {
        var (mesh, problems) = MeshFile.Parse(text.ReplaceLineEndings("\n"));
        Assert.True(mesh != null, string.Join("\n", problems));
        return mesh;
    }

    [Fact]
    public void AFileParses()
    {
        var mesh = Parse(Box);
        Assert.Equal(["# A box."], mesh.HeaderComments);
        Assert.Equal("00112233445566778899aabbccddeeff", mesh.Materials[0]);
        Assert.Equal("", mesh.Materials[1]);
        Assert.Equal(MeshData.MaxSlots, mesh.Materials.Length);
        Assert.Equal(8, mesh.Vertices.Length);
        Assert.Equal(new Vec3(1, 1, 1), mesh.Vertices[6]);
        Assert.Equal(6, mesh.Faces.Length);
        var top = mesh.Faces[1];
        Assert.Equal(0, top.Slot);
        Assert.Equal([4, 7, 6, 5], top.Corners);
        Assert.Equal(new Mapping(Vec3.UnitX, new Vec3(0, 0, -1), 1, 1, 0, 0, 0), top.Mapping);
        Assert.Equal(4, mesh.SharpEdges.Length);
        Assert.True(mesh.IsSharp(4, 7));
        Assert.False(mesh.IsSharp(0, 4));
        Assert.Empty(mesh.Validate());
    }

    [Fact]
    public void WritingGivesTheFileBack()
    {
        var text = Box.ReplaceLineEndings("\n");
        Assert.Equal(text, MeshFile.Write(Parse(text)));
    }

    [Fact]
    public void TheSampleRoomRoundTrips()
    {
        var path = Path.Combine(EditorOptions.RepositoryRoot(), "samples", "mygame", "content", "meshes", "room.mesh");
        var text = File.ReadAllText(path).ReplaceLineEndings("\n");
        var mesh = Parse(text);
        Assert.Equal(text, MeshFile.Write(mesh));
        Assert.Empty(mesh.Validate());
        // The room's faces front inward: the floor's normal points up.
        Assert.Equal(new Vec3(0, 1, 0), mesh.FaceNormal(0));
    }

    [Fact]
    public void NumbersWriteAsTheCookerDoes()
    {
        // The shortest decimal that reads back as the same f32, without an exponent, as format.mesh_text_write.
        Assert.Equal("1", MeshFile.FormatNumber(1));
        Assert.Equal("0.5", MeshFile.FormatNumber(0.5));
        Assert.Equal("-0.25", MeshFile.FormatNumber(-0.25));
        Assert.Equal("0.1", MeshFile.FormatNumber(0.1));
        Assert.Equal("0.33333334", MeshFile.FormatNumber(1.0 / 3));
        Assert.Equal("-0.00000025", MeshFile.FormatNumber(-2.5e-7));
        Assert.Equal("123456.78", MeshFile.FormatNumber(123456.78));
        Assert.Equal("100000000", MeshFile.FormatNumber(1e8));
        Assert.Equal("0", MeshFile.FormatNumber(0));
        var mesh = new MeshData([], [new Vec3(0.1, 1.0 / 3, -2.5e-7), new Vec3(123456.78, 0, 0), Vec3.Zero],
            [new MeshFace(0, [0, 1, 2], new Mapping(Vec3.UnitX, Vec3.UnitY, 0.25, 0.5, 0.125, -0.375, 15))], []);
        var text = MeshFile.Write(mesh);
        Assert.Contains("v 0.1 0.33333334 -0.00000025\n", text);
        Assert.Contains("map 1 0 0 0 1 0 0.25 0.5 0.125 -0.375 15\n", text);
        var again = Parse(text);
        Assert.Equal((float)0.1, (float)again.Vertices[0].X);
        Assert.Equal(mesh.Faces[0].Mapping, again.Faces[0].Mapping);
    }

    [Fact]
    public void ProblemsNameTheirLines()
    {
        var text = "mesh 1\nv 0 0 0\nv 1 0 0\nv 1 1 0\nf 0 0 1\nf 9 0 1 2\nf 0 0 1 7\nmap 1 0 0 0 1 0 1 1 0 0\nv 0 1 x\nhinge 0 1\nf 0 0 1 2\n";
        var (mesh, problems) = MeshFile.Parse(text);
        Assert.Null(mesh);
        // Two indices, a slot of 9, a vertex that is not there, a map of 10 numbers, a vertex that is not a number.
        foreach (var line in new[] { 5, 6, 7, 8, 9 })
        {
            Assert.Contains(problems, p => p.Line == line && p.IsError);
        }
        Assert.Contains(problems, p => p.Line == 10 && !p.IsError);

        Assert.Equal([new MeshFileProblem(1, "a mesh file starts with `mesh 1`", true)], MeshFile.Parse("scene 1\n").Problems);
        Assert.Single(MeshFile.Parse("").Problems);
        Assert.Equal(2, MeshFile.Parse("mesh 1\nmap 1 0 0 0 1 0 1 1 0 0 0\n").Problems.Single().Line);
    }

    [Fact]
    public void AFaceWithoutAMapGetsAWorldAlignedOne()
    {
        // A face in the xy plane, fronting -z: a front wall's mapping.
        var mesh = Parse("mesh 1\nv 0 0 0\nv 0 1 0\nv 1 1 0\nv 1 0 0\nf 0 0 1 2 3\n");
        Assert.Equal(new Vec3(0, 0, -1), mesh.FaceNormal(0));
        Assert.Equal(Mapping.WorldAligned(new Vec3(0, 0, -1)), mesh.Faces[0].Mapping);
        Assert.Equal(new Mapping(Vec3.UnitX, new Vec3(0, -1, 0), 1, 1, 0, 0, 0), mesh.Faces[0].Mapping);

        Assert.Equal((Vec3.UnitX, new Vec3(0, 0, -1)), (Mapping.WorldAligned(new Vec3(0.1, 0.9, 0.2)).UAxis, Mapping.WorldAligned(new Vec3(0.1, 0.9, 0.2)).VAxis));
        Assert.Equal((Vec3.UnitZ, new Vec3(0, -1, 0)), (Mapping.WorldAligned(new Vec3(-1, 0, 0)).UAxis, Mapping.WorldAligned(new Vec3(-1, 0, 0)).VAxis));
        Assert.Equal(2, Mapping.WorldAligned(Vec3.UnitY, 2).ScaleU);
    }

    [Fact]
    public void UvsFollowTheMapping()
    {
        // u = x / 2 + 0.25, v = -z / 4 - 0.5, as the bake computes them.
        var m = new Mapping(Vec3.UnitX, new Vec3(0, 0, -1), 2, 4, 0.25, -0.5, 0);
        Assert.Equal((0.75, -0.25), m.Uv(new Vec3(1, 7, -1)));
        // The rotation turns the texture about the mapping's origin: at 90°, u becomes v.
        var (u, v) = (m with { Rotation = 90 }).Uv(new Vec3(1, 0, -1));
        Assert.Equal(0, u, 6);
        Assert.Equal(0, v, 6);
    }

    [Fact]
    public void ValidationFindsBentFacesAndBadEdges()
    {
        var box = Parse(Box);
        // A corner moved 3 mm out along each axis bends the three faces at it by 1.5 mm each: the plane is the average, so half.
        var bent = box.With(vertices: box.Vertices.SetItem(6, new Vec3(1.003, 1.003, 1.003)));
        var problems = bent.Validate();
        Assert.Equal(3, problems.Count);
        Assert.All(problems, p => Assert.Contains("not planar", p.Message));
        // A move of 1 mm bends them by half a millimeter, which is within the tolerance.
        Assert.Empty(box.With(vertices: box.Vertices.SetItem(6, new Vec3(1.001, 1.001, 1.001))).Validate());

        var faces = box.Faces.Add(new MeshFace(0, [0, 1, 5, 4], Mapping.WorldAligned(Vec3.UnitZ)))
            .Add(new MeshFace(9, [0, 1, 1], Mapping.WorldAligned(Vec3.UnitZ)))
            .Add(new MeshFace(0, [0, 1, 99], Mapping.WorldAligned(Vec3.UnitZ)))
            .Add(new MeshFace(0, [0, 1, 2], Mapping.WorldAligned(Vec3.UnitZ) with { ScaleU = 0 }));
        problems = box.With(faces: faces, sharpEdges: box.SharpEdges.Add(new MeshEdge(0, 40))).Validate();
        Assert.Contains(problems, p => p.Face == 7 && p.Message.Contains("slot 9"));
        Assert.Contains(problems, p => p.Face == 7 && p.Message.Contains("fewer than three"));
        Assert.Contains(problems, p => p.Face == 8 && p.Message.Contains("does not have"));
        Assert.Contains(problems, p => p.Face == 9 && p.Message.Contains("scale is 0"));
        // The copy of the front wall and the zero-scale triangle both use the edge 0 1, with the bottom and the front.
        Assert.Contains(problems, p => p.Face == -1 && p.Message == "the edge 0 1 has 4 faces");
        Assert.Contains(problems, p => p.Face == -1 && p.Message.Contains("sharp edge 0 40"));
    }
}
