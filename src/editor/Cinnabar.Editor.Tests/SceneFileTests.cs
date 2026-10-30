using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Tests;

public class SceneFileTests
{
    const string Door = """
        # A door and its trigger.
        scene 2

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
        var path = Path.Combine(EditorOptions.RepositoryRoot(), "samples", "mygame", "content", "scenes", "main.scene");
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
            scene 2

            entity 0000000000000001

            entity 0000000000000002
            name = "b"
            component 1 Transform
            	scale = [2.0, 1, 0.5]
            component 9 Late

            """.ReplaceLineEndings("\n"), SceneFile.Write(scene));
    }

    [Theory]
    [InlineData("entity 0000000000000001\n", 1, "starts with `scene 2`")]
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

    [Fact]
    public void AssetReferencesRoundTripAndCrossTheWire()
    {
        const string guid = "9db8150cc7215ffc2708d20d77cf60bf";
        var text = $"scene 2\n\nentity 0000000000000001\ncomponent 7 Renderer\n\tmesh = ${guid}\n\tnone = $0\n";
        var scene = Parse(text);
        var fields = scene.Entities[0].Components[0].Fields;
        Assert.Equal(SceneValue.AssetRef(guid), fields[0].Value);
        Assert.Equal(SceneValue.AssetRef(""), fields[1].Value);
        Assert.Equal(text, SceneFile.Write(scene));

        var wire = SceneSnapshot.Value(fields[0].Value);
        Assert.Equal(Convert.FromHexString(guid), wire.Asset);
        Assert.Equal(fields[0].Value, SceneSnapshot.FromWire(wire));
        Assert.Equal(new byte[16], SceneSnapshot.Value(fields[1].Value).Asset);
        Assert.Equal(fields[1].Value, SceneSnapshot.FromWire(SceneSnapshot.Value(fields[1].Value)));

        var (_, problems) = SceneFile.Parse("scene 1\nentity 0000000000000001\ncomponent 7 R\n\tmesh = $12\n");
        Assert.Contains(problems, p => p.IsError && p.Message.Contains("32 hex digits after $"));
    }

    [Fact]
    public void PathIdsMatchTheCookers()
    {
        // asset_format's path_ids_are_pinned pins the same values.
        Assert.Equal(0x7717980363c8e066UL, ScenePath.Id(1, 2));
        Assert.Equal(0x68bd608f979f4aa6UL, ScenePath.Id(0x5f3a9c01e2b47d10, 0xa90b3e7f15c4d2e8));
        Assert.Equal(0x3fd7ace1e2ddd054UL, ScenePath.Id([0x5000000000000001, 0x2000000000000005, 0x1000000000000002]));
        Assert.Equal(42UL, ScenePath.Id([42]));
    }

    [Fact]
    public void InstancesAndOverridesRoundTrip()
    {
        const string text = """
            scene 2

            entity 5f3a9c01e2b47d10
            name = "Front Door"
            prefab = $9db8150cc7215ffc2708d20d77cf60bf
            remove component 10
            component 1 Transform
            	position = [16777216, 0, -754974720]

            entity 5f3a9c01e2b47d10#a90b3e7f15c4d2e8
            name = ""
            active = true
            remove behaviour $9d2e41c0b7a35f6e81c4d2a90b3e7f15
            component 35 Point_Light
            	intensity = 0.25

            entity 5f3a9c01e2b47d10#c41d2f0e9b7a3651
            parent = @5f3a9c01e2b47d10
            removed = true

            entity 8c2e7b19d4f0a3c5
            name = "Sticker"
            parent = @5f3a9c01e2b47d10#a90b3e7f15c4d2e8
            component 2 Local_Transform
            	target = @5f3a9c01e2b47d10#c41d2f0e9b7a3651

            """;
        var scene = Parse(text);

        var instance = scene.Find(0x5f3a9c01e2b47d10)!;
        Assert.Equal("9db8150cc7215ffc2708d20d77cf60bf", instance.Prefab);
        Assert.Null(instance.Path);
        Assert.Equal([10UL], instance.RemovedComponents);
        var light = scene.Find(ScenePath.Id(0x5f3a9c01e2b47d10, 0xa90b3e7f15c4d2e8))!;
        Assert.Equal([0x5f3a9c01e2b47d10UL, 0xa90b3e7f15c4d2e8], light.Path);
        // An override writes what it changes, so an empty name and active = true stay.
        Assert.Equal(SceneKeys.Name | SceneKeys.Active, light.Keys);
        Assert.Equal(["9d2e41c0b7a35f6e81c4d2a90b3e7f15"], light.RemovedBehaviours);
        Assert.True(scene.Entities[2].Removed);
        var sticker = scene.Find(0x8c2e7b19d4f0a3c5)!;
        Assert.Equal(light.Id, sticker.Parent);
        Assert.Equal(ScenePath.Id(0x5f3a9c01e2b47d10, 0xc41d2f0e9b7a3651), sticker.Components[0].Fields[0].Value.Entity);

        Assert.Equal(text.ReplaceLineEndings("\n"), SceneFile.Write(scene));
        // A copy keeps the path and the overrides.
        var copy = new Scene();
        copy.Entities.AddRange(scene.Entities.Select(e => e.Clone()));
        Assert.Equal(text.ReplaceLineEndings("\n"), SceneFile.Write(copy));
    }

    [Fact]
    public void OverrideBlocksFollowTheirInstance()
    {
        var scene = new Scene();
        scene.Entities.Add(new SceneEntity([0x20, 0x01]) { Name = "x", Keys = SceneKeys.Name });
        scene.Entities.Add(new SceneEntity(0x30));
        scene.Entities.Add(new SceneEntity(0x20) { Prefab = "9db8150cc7215ffc2708d20d77cf60bf" });
        scene.Entities.Add(new SceneEntity(0x10));

        var ids = SceneFile.Write(scene).Split('\n').Where(l => l.StartsWith("entity ", StringComparison.Ordinal)).ToList();
        Assert.Equal(["entity 0000000000000010", "entity 0000000000000020", "entity 0000000000000020#0000000000000001", "entity 0000000000000030"], ids);
    }

    // The fixture that the cooker's expansion is tested with reads as the cooker reads it, and the files that the
    // editor writes, in its order, write back as they are.
    [Theory]
    [InlineData("level.scene", true)]
    [InlineData("door.prefab", true)]
    [InlineData("door_variant.prefab", true)]
    [InlineData("lamp.prefab", true)]
    [InlineData("expected.scene", false)]
    public void ThePrefabFixtureParses(string name, bool roundTrips)
    {
        var path = Path.Combine(EditorOptions.RepositoryRoot(), "lib", "engine", "asset", "format", "testdata", "prefabs", name);
        var text = File.ReadAllText(path).ReplaceLineEndings("\n");
        var scene = Parse(text);
        if (roundTrips)
        {
            Assert.Equal(text, SceneFile.Write(scene));
        }
    }

    [Theory]
    [InlineData("scene 2\nentity 0000000000000001\nremove component 3\n", "only an instance or an override block")]
    [InlineData("scene 2\nentity 0000000000000001\nremoved = true\n", "only an override block")]
    [InlineData("scene 2\nentity 0000000000000001#0000000000000002\nprefab = $9db8150cc7215ffc2708d20d77cf60bf\n", "cannot change which prefab")]
    [InlineData("scene 2\nentity 0000000000000001#00000002\n", "joined by #")]
    [InlineData("scene 2\nentity 0000000000000001\nprefab = $0\n", "prefab takes")]
    [InlineData("scene 2\nentity 0000000000000001\nprefab = $9db8150cc7215ffc2708d20d77cf60bf\nremove widget 3\n", "remove takes")]
    [InlineData("scene 2\nentity 0000000000000001\ncomponent 1 T\n\tx = @0000000000000001#\n", "joined by #")]
    [InlineData("scene 3\n", "starts with `scene 2`")]
    public void Version2ErrorsAreTheCookers(string text, string fragment)
    {
        var (scene, problems) = SceneFile.Parse(text);

        Assert.Null(scene);
        Assert.Contains(problems, p => p.IsError && p.Message.Contains(fragment));
    }
}
