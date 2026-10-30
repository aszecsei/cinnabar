using Cinnabar.Editor.Document;
using Wire = Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Tests;

public sealed class PrefabTests : IDisposable
{
    readonly TempDirectory _temp = new("prefab");

    const string Door = "22222222222222222222222222222222";
    const string Lamp = "11111111111111111111111111111111";
    const ulong Front = 0x5000000000000001;
    const ulong FrameId = 0x2000000000000002;
    const ulong HandleId = 0x2000000000000003;
    const ulong PorchId = 0x2000000000000005;
    const ulong BulbId = 0x1000000000000002;

    public void Dispose() => _temp.Dispose();

    static string FixtureDirectory() =>
        Path.Combine(EditorOptions.RepositoryRoot(), "lib", "engine", "asset", "format", "testdata", "prefabs");

    static Scene Parse(string text)
    {
        var (scene, problems) = SceneFile.Parse(text.ReplaceLineEndings("\n"));
        Assert.True(scene != null, string.Join("\n", problems));
        return scene;
    }

    // The fixture's prefabs, by the GUIDs in their .meta files.
    static Dictionary<string, Scene> FixturePrefabs() => Directory.GetFiles(FixtureDirectory(), "*.prefab").ToDictionary(
        p => File.ReadAllText(p + ".meta").Split('=')[1].Trim(),
        p => Parse(File.ReadAllText(p)));

    [Fact]
    public void TheFixtureExpandsAsTheCookerExpandsIt()
    {
        var prefabs = FixturePrefabs();
        var level = Parse(File.ReadAllText(Path.Combine(FixtureDirectory(), "level.scene")));
        var expected = Parse(File.ReadAllText(Path.Combine(FixtureDirectory(), "expected.scene")));

        var expansion = PrefabExpansion.Expand(level, g => prefabs.GetValueOrDefault(g));

        Assert.Equal(expected.Entities.Select(e => e.Id), expansion.Flat.Entities.Select(e => e.Id));
        foreach (var (want, got) in expected.Entities.Zip(expansion.Flat.Entities))
        {
            Assert.Equal((want.Name, want.Parent, want.Active), (got.Name, got.Parent, got.Active));
            Assert.Equal(want.Components.Select(c => c.Id), got.Components.Select(c => c.Id));
            foreach (var (wc, gc) in want.Components.Zip(got.Components))
            {
                Assert.Equal(wc.Fields, gc.Fields);
            }
            Assert.Equal(want.Behaviours.Select(b => b.Script), got.Behaviours.Select(b => b.Script));
            foreach (var (wb, gb) in want.Behaviours.Zip(got.Behaviours))
            {
                Assert.Equal(wb.Fields, gb.Fields);
            }
        }
        // The same warnings as the cooker's, and no errors.
        Assert.DoesNotContain(expansion.Problems, p => p.IsError);
        Assert.Equal(3, expansion.Problems.Count);
        Assert.Contains(expansion.Problems, p => p.Message.Contains("44444444444444444444444444444444 is missing"));
        Assert.Contains(expansion.Problems, p => p.Message.Contains("5000000000000001#2000000000000009"));
        Assert.Contains(expansion.Problems, p => p.Message.Contains("instance 5000000000000001: the field bell refers to 20000000000000ff"));

        // Where each entity comes from.
        var bulb = expansion.InstanceOf(ScenePath.Id([Front, PorchId, BulbId]))!;
        Assert.Equal([Front, PorchId, BulbId], bulb.Path);
        Assert.Equal(Lamp, expansion.InstanceOf(ScenePath.Id(Front, PorchId))!.Prefab);
        Assert.True(expansion.InstanceOf(Front)!.IsInstanceRoot);
        Assert.Null(expansion.InstanceOf(0x6000000000000002));
    }

    [Fact]
    public void ACycleIsAnErrorAndTheInstanceIsItsRoot()
    {
        var a = Parse("scene 2\nentity 0000000000000001\nentity 0000000000000002\nparent = @0000000000000001\nprefab = $bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n");
        var b = Parse("scene 2\nentity 0000000000000001\nentity 0000000000000002\nparent = @0000000000000001\nprefab = $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n");
        var prefabs = new Dictionary<string, Scene> { ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"] = a, ["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"] = b };

        var expansion = PrefabExpansion.Expand(a, g => prefabs.GetValueOrDefault(g), self: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");

        Assert.Contains(expansion.Problems, p => p.IsError && p.Message.Contains("contains itself: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa contains bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb contains aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
        // A, B's root, and the root alone of the A inside B.
        Assert.Equal(3, expansion.Flat.Entities.Count);
    }

    // A level with one door, the fixture's prefabs, and what it sends.
    (SceneDocument Document, List<Wire.Operation> Sent) Open(string text = "scene 2\n\nentity 5000000000000001\nname = \"Front Door\"\nprefab = $22222222222222222222222222222222\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n")
    {
        var prefabs = FixturePrefabs();
        var document = new SceneDocument(_temp.Combine("level.scene"), Parse(text),
            g => prefabs.TryGetValue(g, out var scene) ? new PrefabDocument(_temp.Combine(g + ".prefab"), g, scene, SceneFile.Write(scene)) : null);
        var sent = new List<Wire.Operation>();
        document.Applied += ops => sent.AddRange(ops.SelectMany(o => o.ToWires()));
        return (document, sent);
    }

    static ulong InDoor(ulong id) => ScenePath.Id(Front, id);

    static SceneValue Intensity(SceneDocument d, ulong id) =>
        d.Expanded.Flat.Find(id)!.Components.Single(c => c.Id == 35).Fields.Single(f => f.Name == "intensity").Value;

    [Fact]
    public void AnEditOfAPrefabsEntityIsAnOverrideAndResetRevertsIt()
    {
        var (document, sent) = Open();
        var frame = InDoor(FrameId);
        Assert.Equal(SceneValue.Of(SceneNumber.Of(1.0)), Intensity(document, frame));

        document.Apply("Override", new SetField(frame, 35, "intensity", SceneValue.Of(SceneNumber.Of(0.25))));

        var block = document.Scene.Find(frame)!;
        Assert.Equal([Front, FrameId], block.Path);
        Assert.Equal([new SceneField("intensity", SceneValue.Of(SceneNumber.Of(0.25)))], Assert.Single(block.Components).Fields);
        Assert.Equal(SceneValue.Of(SceneNumber.Of(0.25)), Intensity(document, frame));
        var set = Assert.Single(sent);
        Assert.Equal((Wire.OperationKind.SetField, frame, 35UL), (set.Kind, set.Entity, set.Component));
        Assert.Contains("entity 5000000000000001#2000000000000002\ncomponent 35 Point_Light\n\tintensity = 0.25\n", SceneFile.Write(document.Scene));

        // Reset takes the override away, and the host gets the prefab's value back.
        sent.Clear();
        document.Apply("Reset", new SetField(frame, 35, "intensity", null));
        Assert.Null(document.Scene.Find(frame));
        Assert.Equal(1.0, Assert.Single(sent).Fields[0].Value.Floats[0]);
        Assert.Equal(Wire.OperationKind.SetField, sent[0].Kind);

        document.Undo();
        Assert.Equal(SceneValue.Of(SceneNumber.Of(0.25)), Intensity(document, frame));
        document.Undo();
        Assert.Null(document.Scene.Find(frame));
        Assert.False(document.IsDirty);
    }

    [Fact]
    public void ADragOfAnOverrideIsOneEntry()
    {
        var (document, _) = Open();
        var frame = InDoor(FrameId);

        document.Begin("Drag");
        foreach (var v in new[] { 0.5, 0.4, 0.3 })
        {
            document.Preview(new SetField(frame, 35, "intensity", SceneValue.Of(SceneNumber.Of(v))));
        }
        document.Commit();

        var entry = Assert.Single(document.History);
        Assert.Single(entry.Operations);
        document.Undo();
        Assert.Null(document.Scene.Find(frame));
        document.Redo();
        Assert.Equal(SceneValue.Of(SceneNumber.Of(0.3)), Intensity(document, frame));
    }

    [Fact]
    public void EveryOperationOverridesAndUndoes()
    {
        var (document, sent) = Open();
        var handle = InDoor(HandleId);
        var before = SceneFile.Write(document.Scene);

        document.Apply("Edits",
            new Rename(handle, "Brass"),
            new SetActive(handle, false),
            new AddComponent(handle, new SceneComponent(40, "Audio_Source", [new SceneField("volume", SceneValue.Of(SceneNumber.Of(0.5)))])),
            new RemoveBehaviour(handle, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
            new RemoveComponent(Front, 10),
            new SetBehaviourField(Front, "9d2e41c0b7a35f6e81c4d2a90b3e7f15", "open_angle", SceneValue.Of(SceneNumber.Of(45.0))));

        var text = SceneFile.Write(document.Scene);
        Assert.Contains("entity 5000000000000001#2000000000000003\nname = \"Brass\"\nactive = false\nremove behaviour $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\ncomponent 40 Audio_Source\n\tvolume = 0.5\n", text);
        Assert.Contains("remove component 10\n", text);
        Assert.Contains("behaviour 9d2e41c0b7a35f6e81c4d2a90b3e7f15\n\topen_angle = 45.0\n", text);
        var flat = document.Expanded.Flat.Find(handle)!;
        Assert.Equal(("Brass", false), (flat.Name, flat.Active));
        Assert.Empty(flat.Behaviours);
        Assert.Contains(sent, o => o.Kind == Wire.OperationKind.RemoveComponent && o.Entity == Front && o.Component == 10);
        Assert.Contains(sent, o => o.Kind == Wire.OperationKind.AddComponent && o.Entity == handle);

        // Renaming back to the prefab's name leaves the name to the prefab.
        document.Apply("Back", new Rename(handle, "Handle"));
        Assert.DoesNotContain("name = \"Handle\"", SceneFile.Write(document.Scene));

        document.Undo();
        document.Undo();
        Assert.Equal(before, SceneFile.Write(document.Scene));
        Assert.Equal("Handle", document.Expanded.Flat.Find(handle)!.Name);
    }

    [Fact]
    public void RevertingARemovedComponentLeavesNoOverride()
    {
        var (document, sent) = Open();
        var frame = InDoor(FrameId);

        document.Apply("Remove", new RemoveComponent(frame, 35));
        Assert.Equal([35UL], document.Scene.Find(frame)!.RemovedComponents);
        Assert.DoesNotContain(document.Expanded.Flat.Find(frame)!.Components, c => c.Id == 35);

        // The properties panel's Revert adds the prefab's component back as the prefab gives it.
        var prefab = PrefabEdits.Base(document, frame)!.Components.Single(c => c.Id == 35);
        sent.Clear();
        document.Apply("Revert", new AddComponent(frame, prefab));
        Assert.Null(document.Scene.Find(frame));
        Assert.Equal(Wire.OperationKind.AddComponent, Assert.Single(sent).Kind);
        Assert.Equal(SceneValue.Of(SceneNumber.Of(1.0)), Intensity(document, frame));
    }

    [Fact]
    public void AReferenceToAnInstancesEntityIsWrittenAsItsPath()
    {
        var (document, _) = Open("scene 2\n\nentity 5000000000000001\nprefab = $22222222222222222222222222222222\n\nentity 6000000000000001\ncomponent 1001 Spin\n\ttarget = @0\n");

        document.Apply("Target", new SetField(0x6000000000000001, 1001, "target", SceneValue.EntityRef(InDoor(FrameId))));

        Assert.Contains("\ttarget = @5000000000000001#2000000000000002\n", SceneFile.Write(document.Scene));
        Assert.Equal(InDoor(FrameId), document.Scene.Find(0x6000000000000001)!.Components[0].Fields[0].Value.Entity);
    }

    [Fact]
    public void APrefabsEntityStaysInsideItsInstance()
    {
        var (document, _) = Open("scene 2\n\nentity 5000000000000001\nprefab = $22222222222222222222222222222222\n\nentity 6000000000000001\nname = \"Outside\"\n");

        Assert.Throws<InvalidOperationException>(() => document.Apply("Out", new SetParent(InDoor(HandleId), 0x6000000000000001)));
        Assert.Throws<InvalidOperationException>(() => document.Apply("In", new SetParent(0x6000000000000001, InDoor(FrameId))));

        // Inside the instance it overrides the parent, written as the path.
        document.Apply("Move", new SetParent(InDoor(HandleId), Front));
        Assert.Contains("entity 5000000000000001#2000000000000003\nparent = @5000000000000001\n", SceneFile.Write(document.Scene));
        Assert.Equal(Front, document.Expanded.Flat.Find(InDoor(HandleId))!.Parent);

        // A new entity can be added under one of the instance's, and its parent is the path.
        document.Apply("Add", new CreateEntity(new SceneEntity(0x6000000000000002) { Name = "Sticker", Parent = InDoor(FrameId) }));
        Assert.Contains("parent = @5000000000000001#2000000000000002\n", SceneFile.Write(document.Scene));
    }

    [Fact]
    public void DeletingAPrefabsEntityRemovesItAndDeletingTheRootRemovesTheInstance()
    {
        var (document, sent) = Open("scene 2\n\nentity 5000000000000001\nprefab = $22222222222222222222222222222222\n\nentity 5000000000000001#2000000000000002\nname = \"Lit\"\n\nentity 6000000000000002\nparent = @5000000000000001#2000000000000002\n");
        var frame = InDoor(FrameId);

        document.Apply("Delete", PrefabEdits.DestroyTree(document, frame));
        Assert.True(document.Scene.Find(frame)!.Removed);
        Assert.Null(document.Scene.Find(0x6000000000000002));
        Assert.Null(document.Expanded.Flat.Find(InDoor(HandleId)));
        Assert.Contains(sent, o => o.Kind == Wire.OperationKind.DestroyEntity && o.Entity == frame);
        document.Undo();
        Assert.False(document.Scene.Find(frame)!.Removed);
        Assert.NotNull(document.Scene.Find(0x6000000000000002));

        sent.Clear();
        var count = document.Expanded.Flat.Entities.Count;
        document.Apply("Delete Door", PrefabEdits.DestroyTree(document, Front));
        Assert.Empty(document.Scene.Entities);
        Assert.Equal(count, sent.Count(o => o.Kind == Wire.OperationKind.DestroyEntity));
        // The root goes last, after everything under it.
        Assert.Equal(Front, sent[^1].Entity);

        sent.Clear();
        document.Undo();
        Assert.Equal(3, document.Scene.Entities.Count);
        Assert.Equal(count, sent.Count(o => o.Kind == Wire.OperationKind.CreateEntity));
        Assert.Equal(Front, sent.First(o => o.Kind == Wire.OperationKind.CreateEntity).Entity);
    }

    [Fact]
    public void AnInstanceIsCreatedAndDuplicatedWithItsOverrides()
    {
        var (document, sent) = Open("scene 2\n");
        var pose = new SceneComponent(SceneEdits.TransformId, "Transform", SceneEdits.TransformFields(new Pose([16777216, 0, 0], Quat.Identity, [1, 1, 1])));

        var create = PrefabEdits.CreateInstance(document, Door, 0, pose, Front);
        document.Apply("Create Instance Door", create);

        Assert.Equal(Door, document.Scene.Find(Front)!.Prefab);
        Assert.Equal(6, document.Expanded.Flat.Entities.Count);
        Assert.All(sent, o => Assert.Equal(Wire.OperationKind.CreateEntity, o.Kind));
        Assert.Equal(Front, sent[0].Entity);

        document.Apply("Override", new SetField(InDoor(FrameId), 35, "intensity", SceneValue.Of(SceneNumber.Of(0.25))));
        var (ops, copy) = PrefabEdits.Duplicate(document, Front);
        document.Apply("Duplicate", ops);

        var copyBlock = document.Scene.Find(copy)!;
        Assert.Equal(Door, copyBlock.Prefab);
        Assert.Equal(SceneValue.Of(SceneNumber.Of(0.25)), Intensity(document, ScenePath.Id(copy, FrameId)));
        // The copy's references inside it name its own entities.
        var behaviour = document.Expanded.Flat.Find(copy)!.Behaviours[0];
        Assert.Equal(ScenePath.Id(copy, HandleId), behaviour.Fields.Single(f => f.Name == "handle").Value.Entity);
        Assert.Equal(12, document.Expanded.Flat.Entities.Count);
    }

    [Fact]
    public void UnpackingKeepsTheWorld()
    {
        var text = "scene 2\n\nentity 5000000000000001\nname = \"Front Door\"\nprefab = $22222222222222222222222222222222\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\n" +
            "entity 5000000000000001#2000000000000002\ncomponent 35 Point_Light\n\tintensity = 0.25\n\n" +
            "entity 5000000000000001#2000000000000005#1000000000000002\ncomponent 35 Point_Light\n\tintensity = 2.0\n\n" +
            "entity 6000000000000001\ncomponent 1001 Spin\n\ttarget = @5000000000000001#2000000000000002\n";
        var (document, sent) = Open(text);
        var before = document.Expanded.Flat.Entities.Select(e => SceneFile.FormatValue(SceneValue.String(SceneFile.Write(One(e))))).ToList();

        document.Apply("Unpack Completely", PrefabEdits.UnpackCompletely(document, Front));

        Assert.Empty(sent);
        Assert.All(document.Scene.Entities, e => Assert.True(e.Prefab == "" && e.Path == null));
        Assert.Equal(before, document.Expanded.Flat.Entities.Select(e => SceneFile.FormatValue(SceneValue.String(SceneFile.Write(One(e))))).ToList());
        Assert.Contains($"\ttarget = @{InDoor(FrameId):x16}\n", SceneFile.Write(document.Scene));
        document.Undo();
        Assert.Equal(Door, document.Scene.Find(Front)!.Prefab);

        // One level: the door's own entities become plain, and its lamp stays an instance, with the scene's override.
        document.Apply("Unpack", PrefabEdits.Unpack(document, Front));
        var lamp = document.Scene.Find(InDoor(PorchId))!;
        Assert.Equal(Lamp, lamp.Prefab);
        Assert.Equal(SceneValue.Of(SceneNumber.Of(0.25)), Intensity(document, InDoor(FrameId)));
        Assert.Equal(SceneValue.Of(SceneNumber.Of(2.0)), Intensity(document, ScenePath.Id(InDoor(PorchId), BulbId)));
        Assert.Equal("Front Door", document.Scene.Find(Front)!.Name);
        Assert.Equal(7, document.Expanded.Flat.Entities.Count);
        Assert.DoesNotContain(document.Expanded.Problems, p => p.IsError);
        // The text reads back as the same scene.
        var reread = Parse(SceneFile.Write(document.Scene));
        Assert.Equal(document.Scene.Entities.Count, reread.Entities.Count);
    }

    static Scene One(SceneEntity e)
    {
        var scene = new Scene();
        scene.Entities.Add(e);
        return scene;
    }

    [Fact]
    public void MakePrefabReplacesATreeWithAnInstanceAndSavesTheFile()
    {
        var text = "scene 2\n\nentity 0000000000000001\nname = \"Crate\"\ncomponent 1 Transform\n\tposition = [16777216, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n\n" +
            "entity 0000000000000002\nname = \"Lid\"\nparent = @0000000000000001\n\n" +
            "entity 0000000000000003\nname = \"Watcher\"\ncomponent 1001 Spin\n\ttarget = @0000000000000002\n";
        var (document, sent) = Open(text);
        var path = _temp.Combine("crate.prefab");

        var (ops, prefab) = PrefabEdits.MakePrefab(document, 1, path);
        document.Apply("Make Prefab Crate", ops);

        var instance = document.Scene.Find(1)!;
        Assert.Equal(prefab.Guid, instance.Prefab);
        Assert.Null(document.Scene.Find(2));
        var lid = ScenePath.Id(1, 2);
        Assert.Equal("Lid", document.Expanded.Flat.Find(lid)!.Name);
        Assert.Equal(1UL, document.Expanded.Flat.Find(lid)!.Parent);
        Assert.Contains("\ttarget = @0000000000000001#0000000000000002\n", SceneFile.Write(document.Scene));
        // The root keeps its pose in the scene, and the prefab's root is at the origin.
        Assert.Equal(16777216L, (long)document.Expanded.Flat.Find(1)!.Components[0].Fields[0].Value.Numbers[0].Integer!.Value);
        Assert.True(prefab.IsDirty);
        Assert.Contains(sent, o => o.Kind == Wire.OperationKind.DestroyEntity && o.Entity == 2);
        Assert.Contains(sent, o => o.Kind == Wire.OperationKind.CreateEntity && o.Entity == lid);

        document.Save();
        Assert.True(File.Exists(path));
        Assert.Equal($"guid = {prefab.Guid}\n", File.ReadAllText(path + ".meta"));
        var saved = Parse(File.ReadAllText(path));
        Assert.Equal(2, saved.Entities.Count);
        Assert.False(prefab.IsDirty);

        document.Undo();
        Assert.Equal("Crate", document.Scene.Find(1)!.Name);
        Assert.Equal("Lid", document.Scene.Find(2)!.Name);
        Assert.DoesNotContain(document.Prefabs.Documents, d => d.Guid == prefab.Guid);
    }
}
