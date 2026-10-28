using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using EntityInfo = Cinnabar.Editor.Link.Protocol.EntityInfo;
using EntitySnapshot = Cinnabar.Editor.Link.Protocol.EntitySnapshot;
using Welcome = Cinnabar.Editor.Link.Cook.Welcome;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Tests;

/// <summary>Instances in the shell, without a host: the prefabs that the index names, a drop, an override's drag, Reset and Make Prefab.</summary>
public sealed class PrefabShellTests : IDisposable
{
    readonly string _directory = Path.Combine(Path.GetTempPath(), $"cinnabar-prefab-shell-tests-{Guid.NewGuid():N}");

    const string Door = "22222222222222222222222222222222";
    const string Lamp = "11111111111111111111111111111111";
    const ulong Front = 0x5000000000000001;
    const ulong Crate = 0x0000000000000009;

    const string Text = "scene 2\n\n" +
        "entity 0000000000000009\nname = \"Crate\"\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n\n" +
        "entity 5000000000000001\nname = \"Front Door\"\nprefab = $22222222222222222222222222222222\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n";

    static ulong Handle(uint index) => 1UL << 32 | index;

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

    EditorShell NewShell()
    {
        Directory.CreateDirectory(_directory);
        File.WriteAllText(Path.Combine(_directory, "door.prefab"), Fixture("door.prefab"));
        File.WriteAllText(Path.Combine(_directory, "lamp.prefab"), Fixture("lamp.prefab"));
        var path = Path.Combine(_directory, "level.scene");
        File.WriteAllText(path, Text);
        var shell = new EditorShell(new EditorOptions("host.exe", "game.dll", path) { AutosaveDirectory = Path.Combine(_directory, "autosave") },
            new EditorSettings(Path.Combine(_directory, "settings")));
        shell.OnGameMessage(new EntitySnapshot([new EntityInfo(Handle(0), "Crate", Crate, 0, true, [1]), new EntityInfo(Handle(1), "Front Door", Front, 0, true, [1])]));
        return shell;
    }

    static void Index(EditorShell shell, string directory)
    {
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", directory)], [new Importer(AssetKind.Prefab, ".prefab", [])], []));
        shell.Assets.Apply(new AssetSnapshot(
        [
            new Asset(Door, AssetKind.Prefab, "game", "door.prefab", AssetStatus.Current, 0, 0, "", [], [Lamp], "", "", 0, [0, 0], "", []),
            new Asset(Lamp, AssetKind.Prefab, "game", "lamp.prefab", AssetStatus.Current, 0, 0, "", [], [], "", "", 0, [0, 0], "", []),
        ], []));
    }

    static ulong InDoor(ulong id) => ScenePath.Id(Front, id);

    [Fact]
    public void AnInstanceExpandsOnceTheIndexNamesItsPrefab()
    {
        using var shell = NewShell();
        // Before the index arrives, the instance is its root alone.
        Assert.Equal(2, shell.Scene!.Expanded.Flat.Entities.Count);

        Index(shell, _directory);

        Assert.Equal(7, shell.Scene.Expanded.Flat.Entities.Count);
        Assert.Equal("Front Door", shell.Scene.Expanded.Flat.Find(Front)!.Name);
        Assert.True(shell.InstanceOf(Front)!.IsInstanceRoot);
        Assert.Equal(Lamp, shell.InstanceOf(InDoor(0x2000000000000005))!.Prefab);
        Assert.Equal("door", shell.PrefabName(Door));
    }

    [Fact]
    public void ADropShowsTheInstanceUnderTheDragAndIsOneEntry()
    {
        using var shell = NewShell();
        Index(shell, _directory);
        var before = shell.Scene!.Scene.Entities.Count;

        shell.PreviewPrefab(Door, [16777216, 0, 0]);
        shell.PreviewPrefab(Door, [33554432, 0, 0]);
        Assert.True(shell.CommitPrefab());

        Assert.Equal(before + 1, shell.Scene.Scene.Entities.Count);
        var created = shell.Scene.Scene.Entities.Single(e => e.Prefab == Door && e.Id != Front);
        Assert.Equal(33554432L, (long)SceneEdits.WorldPose(shell.Scene.Expanded.Flat, shell.Scene.Expanded.Flat.Find(created.Id)!)!.Position[0]);
        Assert.Equal("Create Instance door", Assert.Single(shell.Scene.History).Label);

        // A drag that leaves takes its instance back.
        shell.PreviewPrefab(Door, [0, 0, 0]);
        shell.CancelPrefab();
        Assert.Equal(before + 1, shell.Scene.Scene.Entities.Count);
        Assert.Single(shell.Scene.History);

        // A drop on the outliner makes a child at the identity pose.
        Assert.True(shell.CreateInstance(Lamp, Crate));
        var lamp = shell.Scene.Scene.Entities.Single(e => e.Prefab == Lamp);
        Assert.Equal(Crate, lamp.Parent);
        Assert.Equal(SceneEdits.LocalTransformId, Assert.Single(lamp.Components).Id);
    }

    [Fact]
    public void ADragOfAChildIsAnOverrideAndResetRevertsIt()
    {
        using var shell = NewShell();
        Index(shell, _directory);
        var frame = InDoor(0x2000000000000002);

        shell.BeginEdit("Move Frame");
        foreach (var x in new[] { 0.1, 0.2, 0.3 })
        {
            shell.PreviewEdit(new SetField(frame, SceneEdits.LocalTransformId, "offset", SceneEdits.Floats(x, 0, 0)));
        }
        shell.CommitEdit();

        Assert.Single(shell.Scene!.History);
        Assert.True(shell.IsOverridden(frame));
        Assert.Equal(SceneEdits.Floats(0.3, 0, 0), shell.OverridesOf(frame)!.Components.Single().Fields.Single().Value);
        Assert.Equal(SceneValue.Of(SceneNumber.Of(0L), SceneNumber.Of(0L), SceneNumber.Of(0L)),
            shell.PrefabBase(frame)!.Components.Single(c => c.Id == SceneEdits.LocalTransformId).Fields.Single(f => f.Name == "offset").Value);

        Assert.True(shell.Edit("Reset Offset", new SetField(frame, SceneEdits.LocalTransformId, "offset", null)));
        Assert.False(shell.IsOverridden(frame));
        Assert.Null(shell.OverridesOf(frame));

        // An entity added under one of the instance's is the scene's, and marked as added.
        shell.Edit("Add", new CreateEntity(new SceneEntity(0x6000000000000001) { Name = "Sticker", Parent = frame }));
        Assert.True(shell.IsAddedToInstance(0x6000000000000001));
        Assert.False(shell.IsAddedToInstance(Crate));
    }

    [Fact]
    public void MakePrefabWritesTheFileAtTheSave()
    {
        using var shell = NewShell();
        Index(shell, _directory);
        shell.SelectScene(Crate);

        Assert.True(shell.MakePrefab("crate"));
        var path = Path.Combine(_directory, "crate.prefab");
        Assert.False(File.Exists(path));
        var instance = shell.Scene!.Scene.Find(Crate)!;
        Assert.NotEqual("", instance.Prefab);
        // The instance's root is the same entity, so it stays selected and keeps its place.
        Assert.Equal("Crate", shell.Scene.Expanded.Flat.Find(Crate)!.Name);

        Assert.True(shell.SaveScene());
        Assert.True(File.Exists(path));
        Assert.Contains($"prefab = ${instance.Prefab}\n", File.ReadAllText(Path.Combine(_directory, "level.scene")));
        Assert.Contains($"guid = {instance.Prefab}", File.ReadAllText(path + ".meta"));

        // A name that a file has is refused.
        shell.SelectScene(Crate);
        Assert.False(shell.MakePrefab("door"));
    }

    [Fact]
    public void UnpackMakesTheInstanceTheScenes()
    {
        using var shell = NewShell();
        Index(shell, _directory);
        shell.SelectScene(Front);

        Assert.True(shell.UnpackSelected(completely: true));

        Assert.All(shell.Scene!.Scene.Entities, e => Assert.Equal("", e.Prefab));
        Assert.Equal(7, shell.Scene.Scene.Entities.Count);
        Assert.Null(shell.InstanceOf(Front));
    }

    [Fact]
    public void APrefabOpensAsTheDocumentWithOneRoot()
    {
        using var shell = NewShell();
        Index(shell, _directory);

        Assert.True(shell.OpenScene(Path.Combine(_directory, "door.prefab")));

        Assert.True(shell.Scene!.IsPrefab);
        Assert.Equal(Door, shell.Scene.PrefabGuid);
        Assert.Equal(6, shell.Scene.Expanded.Flat.Entities.Count);
        // New Entity goes under the root, and an instance dropped in the viewport too.
        shell.CreateEntity();
        var created = shell.Scene.Scene.Entities.Single(e => e.Name == "Entity");
        Assert.Equal(0x2000000000000001UL, created.Parent);
        shell.PreviewPrefab(Lamp, [16777216, 0, 0]);
        Assert.True(shell.CommitPrefab());
        Assert.Equal(0x2000000000000001UL, shell.Scene.Scene.Entities.Last(e => e.Prefab == Lamp).Parent);
        // The prefab itself cannot go inside it.
        shell.PreviewPrefab(Door, [0, 0, 0]);
        Assert.False(shell.CommitPrefab());
        Assert.Equal(2, shell.Scene.History.Count);

        Assert.True(shell.SaveScene());
        Assert.Contains("name = \"Entity\"\nparent = @2000000000000001\n", File.ReadAllText(Path.Combine(_directory, "door.prefab")));
    }

    [Fact]
    public void ApplyFromTheShellAndAReloadOfAChangedPrefab()
    {
        using var shell = NewShell();
        Index(shell, _directory);
        var frame = InDoor(0x2000000000000002);
        shell.Edit("Override", new SetField(frame, 35, "intensity", SceneValue.Of(SceneNumber.Of(0.25))));

        Assert.True(shell.ApplyField(frame, 35, null, "intensity"));
        Assert.Null(shell.OverridesOf(frame));
        Assert.True(shell.PrefabOfInstance(Front)!.IsDirty);
        Assert.Equal("Apply Intensity to door", shell.Scene!.History[^1].Label);
        shell.Scene.Undo();
        shell.Scene.Undo();

        // A clean prefab whose file changes shows the change when the index next reports.
        var path = Path.Combine(_directory, "door.prefab");
        File.WriteAllText(path, File.ReadAllText(path).Replace("name = \"Frame\"", "name = \"Jamb\""));
        Index(shell, _directory);
        Assert.Equal("Jamb", shell.Scene.Expanded.Flat.Find(frame)!.Name);
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory))
        {
            Directory.Delete(_directory, true);
        }
    }
}
