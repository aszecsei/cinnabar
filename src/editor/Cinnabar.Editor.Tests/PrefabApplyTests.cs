using Cinnabar.Editor.Document;
using Wire = Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Tests;

/// <summary>Editing prefabs from the scene, Apply, Revert and Make Variant, and a prefab as the open document.</summary>
public sealed class PrefabApplyTests : IDisposable
{
    readonly string _directory = Path.Combine(Path.GetTempPath(), $"cinnabar-prefab-apply-tests-{Guid.NewGuid():N}");

    const string Door = "22222222222222222222222222222222";
    const string Lamp = "11111111111111111111111111111111";
    const ulong Front = 0x5000000000000001;
    const ulong Back = 0x5000000000000002;
    const ulong Outside = 0x6000000000000001;
    const ulong FrameId = 0x2000000000000002;
    const ulong HandleId = 0x2000000000000003;
    const ulong HingeId = 0x2000000000000004;

    // Two doors, and an entity outside them.
    const string Level = "scene 2\n\n" +
        "entity 5000000000000001\nname = \"Front Door\"\nprefab = $22222222222222222222222222222222\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n\n" +
        "entity 5000000000000002\nname = \"Back Door\"\nprefab = $22222222222222222222222222222222\ncomponent 1 Transform\n\tposition = [16777216, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n\n" +
        "entity 6000000000000001\nname = \"Trigger\"\n";

    public void Dispose()
    {
        if (Directory.Exists(_directory))
        {
            Directory.Delete(_directory, recursive: true);
        }
    }

    static string Fixture(string name)
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
        {
            if (File.Exists(Path.Combine(dir.FullName, "justfile")))
            {
                return File.ReadAllText(Path.Combine(dir.FullName, "lib", "engine", "asset", "format", "testdata", "prefabs", name));
            }
        }
        throw new InvalidOperationException("the tests do not run inside the repository");
    }

    static Scene Parse(string text)
    {
        var (scene, problems) = SceneFile.Parse(text.ReplaceLineEndings("\n"));
        Assert.True(scene != null, string.Join("\n", problems));
        return scene;
    }

    // The fixture's door and lamp as files in the test's directory, and a document that opens them from there.
    Func<string, PrefabDocument?> Files()
    {
        Directory.CreateDirectory(_directory);
        var files = new Dictionary<string, string> { [Door] = "door.prefab", [Lamp] = "lamp.prefab" };
        foreach (var (guid, name) in files)
        {
            File.WriteAllText(Path.Combine(_directory, name), Fixture(name));
        }
        return g => files.TryGetValue(g, out var name) ? PrefabDocument.Open(Path.Combine(_directory, name), g).Document : null;
    }

    (SceneDocument Document, List<Wire.Operation> Sent) Open(string text = Level)
    {
        var document = new SceneDocument(Path.Combine(_directory, "level.scene"), Parse(text), Files());
        var sent = new List<Wire.Operation>();
        document.Applied += ops => sent.AddRange(ops.SelectMany(o => o.ToWires()));
        return (document, sent);
    }

    static ulong In(ulong instance, ulong id) => ScenePath.Id(instance, id);

    static double Intensity(SceneDocument d, ulong id) =>
        d.Expanded.Flat.Find(id)!.Components.Single(c => c.Id == 35).Fields.Single(f => f.Name == "intensity").Value.Numbers[0].Float;

    static SceneValue Number(double v) => SceneValue.Of(SceneNumber.Of(v));

    [Fact]
    public void ApplyingAFieldGivesEveryInstanceTheValue()
    {
        var (document, sent) = Open();
        document.Apply("Override", new SetField(In(Front, FrameId), 35, "intensity", Number(0.25)));
        sent.Clear();

        document.Apply("Apply Door", PrefabEdits.Apply(document, In(Front, FrameId), 35, null, "intensity"));

        Assert.Equal(0.25, Intensity(document, In(Back, FrameId)));
        Assert.Equal(0.25, Intensity(document, In(Front, FrameId)));
        Assert.Null(document.Scene.Find(In(Front, FrameId)));
        var door = document.Prefabs.Find(Door)!;
        Assert.True(door.IsDirty);
        Assert.Contains("intensity = 0.25", SceneFile.Write(door.Scene));
        // The host hears of the other instance's change, and nothing of this one's, whose value stays.
        var set = Assert.Single(sent);
        Assert.Equal(In(Back, FrameId), set.Entity);

        document.Undo();
        Assert.Equal(1.0, Intensity(document, In(Back, FrameId)));
        Assert.Equal(0.25, Intensity(document, In(Front, FrameId)));
        Assert.False(door.IsDirty);
        document.Redo();

        document.Save();
        Assert.Contains("intensity = 0.25", File.ReadAllText(Path.Combine(_directory, "door.prefab")));
        Assert.False(door.IsDirty);
    }

    [Fact]
    public void ApplyAllCarriesEveryOverrideAndKeepsReferencesOutside()
    {
        var (document, _) = Open();
        var handle = In(Front, HandleId);
        document.Apply("Edits",
            new Rename(Front, "Main Door"),
            new SetBehaviourField(Front, "9d2e41c0b7a35f6e81c4d2a90b3e7f15", "trigger", SceneValue.EntityRef(Outside)),
            new SetBehaviourField(Front, "9d2e41c0b7a35f6e81c4d2a90b3e7f15", "open_angle", Number(45)),
            new SetActive(handle, false),
            new RemoveComponent(In(Front, FrameId), 35),
            new CreateEntity(new SceneEntity(0x7000000000000001) { Name = "Sticker", Parent = In(Front, FrameId) }));
        document.Apply("Delete Hinge", PrefabEdits.DestroyTree(document, In(Front, HingeId)));
        var before = SceneEdits.Descendants(document.Expanded.Flat, Front).Select(e => e.Name).Order().ToList();

        document.Apply("Apply All Door", PrefabEdits.ApplyAll(document, Front));

        var door = SceneFile.Write(document.Prefabs.Find(Door)!.Scene);
        Assert.Contains("name = \"Main Door\"", door);
        Assert.Contains("open_angle = 45.0", door);
        Assert.Contains("entity 7000000000000001\nname = \"Sticker\"\nparent = @2000000000000002\n", door);
        Assert.DoesNotContain("Hinge", door);
        Assert.DoesNotContain("trigger = @6000000000000001", door);
        // The other door follows the prefab, but for its own name, which it overrides.
        Assert.Equal("Back Door", document.Expanded.Flat.Find(Back)!.Name);
        Assert.Equal(Number(45), document.Expanded.Flat.Find(Back)!.Behaviours[0].Fields.Single(f => f.Name == "open_angle").Value);
        Assert.False(document.Expanded.Flat.Find(In(Back, HandleId))!.Active);
        Assert.NotNull(document.Expanded.Flat.Find(In(Back, 0x7000000000000001)));
        // This one keeps what it showed, with the reference to the trigger still its own override.
        var after = SceneEdits.Descendants(document.Expanded.Flat, Front).Select(e => e.Name).Order().ToList();
        Assert.Equal(before, after);
        var block = document.Scene.Find(Front)!;
        Assert.Equal(SceneValue.EntityRef(Outside), Assert.Single(block.Behaviours).Fields.Single().Value);
        Assert.Equal(2, document.Scene.Entities.Count(e => e.Path == null || e.Path[0] == Front) - 1);
        Assert.Null(document.Scene.Find(0x7000000000000001));
        Assert.Equal(Outside, document.Expanded.Flat.Find(Front)!.Behaviours[0].Fields.Single(f => f.Name == "trigger").Value.Entity);

        document.Undo();
        Assert.NotNull(document.Scene.Find(0x7000000000000001));
        Assert.Equal(Number(90), document.Expanded.Flat.Find(Back)!.Behaviours[0].Fields.Single(f => f.Name == "open_angle").Value);
    }

    [Fact]
    public void RevertAllDropsTheOverridesAndTheAddedEntities()
    {
        var (document, _) = Open();
        document.Apply("Edits",
            new Rename(In(Front, HandleId), "Brass"),
            new CreateEntity(new SceneEntity(0x7000000000000001) { Name = "Sticker", Parent = In(Front, FrameId) }),
            new CreateEntity(new SceneEntity(0x7000000000000002) { Name = "Glue", Parent = 0x7000000000000001 }));

        document.Apply("Revert All Door", PrefabEdits.RevertAll(document, Front));

        Assert.Equal("Handle", document.Expanded.Flat.Find(In(Front, HandleId))!.Name);
        Assert.Null(document.Scene.Find(0x7000000000000001));
        Assert.Null(document.Scene.Find(0x7000000000000002));
        Assert.Equal("Door", document.Expanded.Flat.Find(Front)!.Name);
        document.Undo();
        Assert.Equal("Brass", document.Expanded.Flat.Find(In(Front, HandleId))!.Name);
        Assert.NotNull(document.Scene.Find(0x7000000000000002));
    }

    [Fact]
    public void MakeVariantMovesTheOverridesIntoANewPrefab()
    {
        var (document, _) = Open();
        document.Apply("Edits",
            new SetField(In(Front, FrameId), 35, "intensity", Number(0.25)),
            new SetBehaviourField(Front, "9d2e41c0b7a35f6e81c4d2a90b3e7f15", "trigger", SceneValue.EntityRef(Outside)),
            new AddComponent(Outside, new SceneComponent(1001, "Spin", [new SceneField("target", SceneValue.EntityRef(In(Front, HandleId)))])));
        var names = document.Expanded.Flat.Entities.Select(e => e.Name).Order().ToList();

        var (ops, variant) = PrefabEdits.MakeVariant(document, Front, Path.Combine(_directory, "dim_door.prefab"));
        document.Apply("Make Variant Door", ops);

        Assert.Equal(variant.Guid, document.Scene.Find(Front)!.Prefab);
        var (root, roots) = PrefabExpansion.RootOf(variant.Scene);
        Assert.Equal(1, roots);
        Assert.Equal(Door, root!.Prefab);
        // The instance shows what it did, its entities now a level down, through the variant's root.
        Assert.Equal(names, document.Expanded.Flat.Entities.Select(e => e.Name).Order().ToList());
        Assert.Equal(0.25, Intensity(document, ScenePath.Id([Front, root.Id, FrameId])));
        Assert.Equal(1.0, Intensity(document, In(Back, FrameId)));
        // The reference out of the instance stays the scene's, and the scene's reference in follows the new path.
        Assert.Equal(Outside, document.Expanded.Flat.Find(Front)!.Behaviours[0].Fields.Single(f => f.Name == "trigger").Value.Entity);
        Assert.Equal(ScenePath.Id([Front, root.Id, HandleId]), document.Expanded.Flat.Find(Outside)!.Components[0].Fields[0].Value.Entity);
        Assert.DoesNotContain(document.Expanded.Problems, p => p.IsError);

        document.Undo();
        Assert.Equal(Door, document.Scene.Find(Front)!.Prefab);
        Assert.DoesNotContain(document.Prefabs.Documents, d => d.Guid == variant.Guid);
    }

    [Fact]
    public void APrefabDocumentKeepsOneRootAndCannotContainItself()
    {
        var files = Files();
        var (document, _) = SceneDocument.Open(Path.Combine(_directory, "door.prefab"), files, Door);
        Assert.NotNull(document);
        Assert.True(document.IsPrefab);
        Assert.Equal(6, document.Expanded.Flat.Entities.Count);

        Assert.Throws<InvalidOperationException>(() => document.Apply("Create", new CreateEntity(new SceneEntity(0x7000000000000001) { Name = "Second" })));
        Assert.Null(document.Scene.Find(0x7000000000000001));
        Assert.Throws<InvalidOperationException>(() => document.Apply("Root", PrefabEdits.DestroyTree(document, 0x2000000000000001)));
        Assert.NotNull(document.Scene.Find(0x2000000000000001));

        // An instance of itself, or of a prefab that contains it, is refused.
        var pose = new SceneComponent(SceneEdits.LocalTransformId, "Local_Transform", []);
        Assert.Throws<InvalidOperationException>(() => document.Apply("Self", PrefabEdits.CreateInstance(document, Door, 0x2000000000000001, pose)));
        Assert.True(PrefabEdits.Contains(document, Door, Lamp));
        Assert.False(PrefabEdits.Contains(document, Lamp, Door));
        Assert.Equal(6, document.Expanded.Flat.Entities.Count);
        Assert.False(document.CanUndo);

        // A child of the root is fine.
        document.Apply("Create", new CreateEntity(new SceneEntity(0x7000000000000001) { Name = "Bell", Parent = 0x2000000000000001 }));
        document.Save();
        Assert.Contains("name = \"Bell\"", File.ReadAllText(Path.Combine(_directory, "door.prefab")));
    }

    [Fact]
    public void AChangedFileOfACleanPrefabIsReadAgain()
    {
        var (document, _) = Open();
        Assert.Equal(1.0, Intensity(document, In(Front, FrameId)));
        var path = Path.Combine(_directory, "door.prefab");
        File.WriteAllText(path, File.ReadAllText(path).Replace("intensity = 1.0", "intensity = 0.75"));

        var before = document.Expanded.Flat.Entities.ToList();
        var kept = new List<PrefabDocument>();
        var reloaded = document.Prefabs.ReloadChanged(kept);

        Assert.Equal(Door, Assert.Single(reloaded).Guid);
        Assert.Empty(kept);
        Assert.Equal(0.75, Intensity(document, In(Front, FrameId)));
        var diff = PrefabExpansion.Diff(before, document.Expanded.Flat.Entities);
        Assert.Equal(2, diff.Count(o => o.Kind == Wire.OperationKind.SetField));

        // A dirty prefab keeps the editor's version.
        document.Apply("Override", new SetField(In(Front, HandleId), 2, "offset", SceneEdits.Floats(1, 0, 0)));
        document.Apply("Apply", PrefabEdits.Apply(document, In(Front, HandleId), 2, null, "offset"));
        File.WriteAllText(path, File.ReadAllText(path).Replace("intensity = 0.75", "intensity = 0.5"));
        Assert.Empty(document.Prefabs.ReloadChanged(kept));
        Assert.Equal(Door, Assert.Single(kept).Guid);
        Assert.Equal(0.75, Intensity(document, In(Front, FrameId)));
    }
}
