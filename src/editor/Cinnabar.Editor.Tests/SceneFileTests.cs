using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Tests;

public class SceneFileTests
{
    const string Door = """
        # A door and its trigger.
        scene 1

        entity 1b04c7e95a2f3d88
        active = false
        component 5 Disabled

        entity 5f3a9c01e2b47d10
        name = "Door \"A\""
        parent = @1b04c7e95a2f3d88
        colour = [1, 0, 0]
        component 1 Transform
        	position = [2516582400000000000, 0, -754974720]
        	rotation = [0, 0.7071068, 0, 0.7071068]
        	scale = [1.5, 1.0, 1]
        component 1002 Tuned
        	big = 18446744073709551615
        	mode = Swing
        	target = @0
        behaviour 9d2e41c0b7a35f6e81c4d2a90b3e7f15
        	open_angle = 90.5
        	trigger = @7a11e0c3d94b2f56

        """;

    static Scene Parse(string text)
    {
        var (scene, problems) = SceneFile.Parse(text.ReplaceLineEndings("\n"));
        Assert.True(scene != null, string.Join("\n", problems));
        return scene;
    }

    [Fact]
    public void AFileParses()
    {
        var scene = Parse(Door);

        Assert.Equal(["# A door and its trigger."], scene.HeaderComments);
        var door = scene.Find(0x5f3a9c01e2b47d10)!;
        Assert.Equal("Door \"A\"", door.Name);
        Assert.Equal(0x1b04c7e95a2f3d88UL, door.Parent);
        Assert.True(door.Active);
        Assert.False(scene.Find(0x1b04c7e95a2f3d88)!.Active);
        Assert.Equal([("colour", "[1, 0, 0]")], door.UnknownKeys);
        var position = door.Components[0].Fields[0].Value;
        Assert.Equal(SceneValueKind.Number, position.Kind);
        // Raw positions are beyond a double's exact range, so the integers are kept as written.
        Assert.Equal((Int128)2516582400000000000, position.Numbers[0].Integer);
        Assert.False(door.Components[0].Fields[1].Value.Numbers[1].IsInteger);
        Assert.Equal(ulong.MaxValue, (ulong)door.Components[1].Fields[0].Value.Numbers[0].Integer!.Value);
        Assert.Equal(SceneValue.Name("Swing"), door.Components[1].Fields[1].Value);
        Assert.Equal("9d2e41c0b7a35f6e81c4d2a90b3e7f15", door.Behaviours[0].Script);
        Assert.Equal(SceneValue.EntityRef(0x7a11e0c3d94b2f56), door.Behaviours[0].Fields[1].Value);
    }

    [Fact]
    public void WritingGivesTheFileBack()
    {
        var text = Door.ReplaceLineEndings("\n");
        Assert.Equal(text, SceneFile.Write(Parse(text)));
    }

    [Fact]
    public void TheSampleSceneRoundTrips()
    {
        var path = Path.Combine(RepositoryRoot(), "samples", "mygame", "content", "scenes", "main.scene");
        var text = File.ReadAllText(path).ReplaceLineEndings("\n");
        Assert.Equal(text, SceneFile.Write(Parse(text)));
    }

    [Fact]
    public void WritingSortsEntitiesAndComponents()
    {
        var scene = new Scene();
        var b = new SceneEntity(2) { Name = "b" };
        b.Components.Add(new SceneComponent(9, "Late", []));
        b.Components.Add(new SceneComponent(1, "Transform", [new SceneField("scale", SceneValue.Of(SceneNumber.Of(2.0), SceneNumber.Of(1L), SceneNumber.Of(0.5)))]));
        scene.Entities.Add(b);
        scene.Entities.Add(new SceneEntity(1));

        Assert.Equal("""
            scene 1

            entity 0000000000000001

            entity 0000000000000002
            name = "b"
            component 1 Transform
            	scale = [2.0, 1, 0.5]
            component 9 Late

            """.ReplaceLineEndings("\n"), SceneFile.Write(scene));
    }

    [Theory]
    [InlineData("entity 0000000000000001\n", 1, "starts with `scene 1`")]
    [InlineData("scene 1\nentity 12\n", 2, "16 hex digits")]
    [InlineData("scene 1\ncomponent 1 Transform\n", 2, "needs an entity")]
    [InlineData("scene 1\nentity 0000000000000001\n\tx = 1\n", 3, "no component or behaviour is open")]
    [InlineData("scene 1\nentity 0000000000000001\ncomponent 1 T\n\tx = [1, 2\n", 4, "ends with ]")]
    [InlineData("scene 1\nentity 0000000000000001\ncomponent 1 T\n\tx = 1\n\tx = 2\n", 5, "set twice")]
    [InlineData("scene 1\nentity 0000000000000001\ncomponent 1 T\n\tx = \"a\\q\"\n", 4, "not an escape")]
    [InlineData("scene 1\nentity 0000000000000001\ncomponent 1 T\ncomponent 1 T\n", 4, "twice")]
    [InlineData("scene 1\nentity 0000000000000001\ncomponent 1 T\n\tx = 1.2.3\n", 4, "not a number")]
    [InlineData("scene 1\nentity 0000000000000001\nentity 0000000000000001\n", 0, "two entities")]
    public void ErrorsNameTheirLine(string text, int line, string fragment)
    {
        var (scene, problems) = SceneFile.Parse(text);

        Assert.Null(scene);
        Assert.Contains(problems, p => p.IsError && p.Line == line && p.Message.Contains(fragment));
    }

    [Fact]
    public void TheSnapshotTagsValuesAsTheGameReadsThem()
    {
        var message = SceneSnapshot.ToMessage(Parse(Door));

        var door = message.Entities.Single(e => e.Id == 0x5f3a9c01e2b47d10);
        Assert.Equal(0x1b04c7e95a2f3d88UL, door.Parent);
        var position = door.Components[0].Fields[0].Value;
        Assert.Equal(Link.Protocol.SceneValueKind.Number, position.Kind);
        Assert.Equal(3, position.Count);
        Assert.Equal(0b111, position.Integer);
        Assert.Equal([2516582400000000000, 0, -754974720, 0], position.Ints);
        // A u64 beyond a long's range goes with its bits.
        Assert.Equal(-1L, door.Components[1].Fields[0].Value.Ints[0]);
        var rotation = door.Components[0].Fields[1].Value;
        Assert.Equal(0b0101, rotation.Integer);
        Assert.Equal(0.7071068, rotation.Floats[3]);
        Assert.Equal(Convert.FromHexString("9d2e41c0b7a35f6e81c4d2a90b3e7f15"), door.Behaviours[0].Script);
        Assert.False(message.Entities.Single(e => e.Id == 0x1b04c7e95a2f3d88).Active);
        Assert.Equal(1L, SceneSnapshot.Value(SceneValue.Of(true)).Ints[0]);
    }

    static string RepositoryRoot()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
        {
            if (File.Exists(Path.Combine(dir.FullName, "justfile")))
            {
                return dir.FullName;
            }
        }
        throw new InvalidOperationException("the tests do not run inside the repository");
    }
}
