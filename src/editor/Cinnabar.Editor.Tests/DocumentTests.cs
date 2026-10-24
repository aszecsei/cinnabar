using Cinnabar.Editor.Document;
using Wire = Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Tests;

public sealed class DocumentTests : IDisposable
{
    readonly string _directory = Path.Combine(Path.GetTempPath(), $"cinnabar-document-tests-{Guid.NewGuid():N}");

    const string Text = """
        scene 1

        entity 0000000000000001
        name = "Door"
        component 1 Transform
        	position = [16777216, 0, 0]
        	rotation = [0, 0, 0, 1]
        	scale = [1, 1, 1]
        component 1001 Spin
        	speed = 1

        entity 0000000000000002
        name = "Hinge"
        parent = @0000000000000001
        component 2 Local_Transform
        	offset = [0, 1, 0]
        	rotation = [0, 0, 0, 1]
        	scale = [1, 1, 1]
        behaviour 7142e05b3941bc44849ed0379727e60b
        	rate = 2
        	target = @0000000000000001

        """;

    (SceneDocument Document, List<Wire.Operation> Sent) Open()
    {
        var (scene, problems) = SceneFile.Parse(Text.ReplaceLineEndings("\n"));
        Assert.True(scene != null, string.Join("\n", problems));
        var document = new SceneDocument(Path.Combine(_directory, "door.scene"), scene);
        var sent = new List<Wire.Operation>();
        document.Applied += ops => sent.AddRange(ops.Select(o => o.ToWire()));
        return (document, sent);
    }

    static SceneValue Speed(SceneDocument d) => d.Scene.Find(1)!.Components.Single(c => c.Id == 1001).Fields.Single(f => f.Name == "speed").Value;

    [Fact]
    public void AnEditGoesToTheHostAndUndoes()
    {
        var (document, sent) = Open();

        document.Apply("Rename", new Rename(1, "Front Door"));

        Assert.Equal("Front Door", document.Scene.Find(1)!.Name);
        Assert.True(document.IsDirty);
        Assert.Equal(Wire.OperationKind.Rename, Assert.Single(sent).Kind);
        Assert.Equal("Front Door", sent[0].Name);

        document.Undo();
        Assert.Equal("Door", document.Scene.Find(1)!.Name);
        Assert.False(document.IsDirty);
        Assert.Equal("Door", sent[^1].Name);

        document.Redo();
        Assert.Equal("Front Door", document.Scene.Find(1)!.Name);
    }

    [Fact]
    public void ADragIsOneEntryWithTheLastValueAndTheFirstInverse()
    {
        var (document, sent) = Open();

        document.Begin("Drag Speed");
        for (var v = 2; v <= 5; v++)
        {
            document.Preview(new SetField(1, 1001, "speed", SceneValue.Of(SceneNumber.Of((long)v))));
        }
        document.Commit();

        Assert.Equal(4, sent.Count);
        var entry = Assert.Single(document.History);
        Assert.Equal("Drag Speed", entry.Label);
        Assert.Single(entry.Operations);
        Assert.Equal(SceneValue.Of(SceneNumber.Of(5L)), Speed(document));
        document.Undo();
        Assert.Equal(SceneValue.Of(SceneNumber.Of(1L)), Speed(document));
    }

    [Fact]
    public void ACancelledDragPutsTheValueBack()
    {
        var (document, sent) = Open();

        document.Begin("Drag Speed");
        document.Preview(new SetField(1, 1001, "speed", SceneValue.Of(SceneNumber.Of(9L))));
        document.Cancel();

        Assert.Empty(document.History);
        Assert.Equal(SceneValue.Of(SceneNumber.Of(1L)), Speed(document));
        Assert.Equal(2, sent.Count);
        Assert.False(document.IsDirty);
    }

    [Fact]
    public void ResettingAFieldRemovesItAndUndoBringsItBack()
    {
        var (document, sent) = Open();

        document.Apply("Reset Speed", new SetField(1, 1001, "speed", null));

        Assert.Empty(document.Scene.Find(1)!.Components.Single(c => c.Id == 1001).Fields);
        Assert.Equal(Wire.OperationKind.ResetField, sent[0].Kind);
        document.Undo();
        Assert.Equal(SceneValue.Of(SceneNumber.Of(1L)), Speed(document));
        Assert.Equal(Wire.OperationKind.SetField, sent[^1].Kind);
    }

    [Fact]
    public void MovingThroughTheHistoryUndoesAndRedoes()
    {
        var (document, _) = Open();
        document.Apply("One", new Rename(1, "One"));
        document.Apply("Two", new Rename(1, "Two"));
        document.Apply("Three", new Rename(1, "Three"));

        document.MoveTo(1);
        Assert.Equal("One", document.Scene.Find(1)!.Name);
        Assert.Equal(1, document.Position);

        document.MoveTo(3);
        Assert.Equal("Three", document.Scene.Find(1)!.Name);

        // A new edit after an undo drops the entries after it.
        document.MoveTo(1);
        document.Apply("Other", new Rename(1, "Other"));
        Assert.Equal(["One", "Other"], document.History.Select(t => t.Label));
    }

    [Fact]
    public void SavingWritesTheFileAndMarksThePosition()
    {
        var (document, _) = Open();
        document.Apply("Rename", new Rename(1, "Saved"));

        document.Save();

        Assert.False(document.IsDirty);
        Assert.Contains("name = \"Saved\"", File.ReadAllText(document.Path));
        document.Undo();
        Assert.True(document.IsDirty);
        // The saved entry is dropped by a new edit, so no position matches the file any more.
        document.Apply("Other", new Rename(1, "Other"));
        document.Undo();
        Assert.True(document.IsDirty);
    }

    [Fact]
    public void AnOperationThatDoesNotFitChangesNothing()
    {
        var (document, sent) = Open();

        Assert.Throws<InvalidOperationException>(() => document.Apply("Two", new Rename(1, "Changed"), new Rename(99, "Nobody")));

        Assert.Equal("Door", document.Scene.Find(1)!.Name);
        Assert.Empty(document.History);
        Assert.False(document.InTransaction);
        // The host got the first rename and then its inverse.
        Assert.Equal(["Changed", "Door"], sent.Select(o => o.Name));
        Assert.Throws<InvalidOperationException>(() => document.Apply("Cycle", new SetParent(1, 2)));
    }

    [Fact]
    public void DestroyingATreeUndoesWithEveryEntity()
    {
        var (document, sent) = Open();

        document.Apply("Delete", SceneEdits.DestroyTree(document.Scene, 1));

        Assert.Empty(document.Scene.Entities);
        Assert.Equal([2UL, 1UL], sent.Select(o => o.Entity));
        document.Undo();
        Assert.Equal(2, document.Scene.Entities.Count);
        // The parent comes back first, so the child can name it.
        Assert.Equal([1UL, 2UL], sent.Skip(2).Select(o => o.Entity));
        Assert.Equal(1UL, document.Scene.Find(2)!.Parent);
    }

    [Fact]
    public void ADuplicateRefersToItsOwnCopies()
    {
        var (document, _) = Open();

        var (ops, copy) = SceneEdits.Duplicate(document.Scene, 1);
        document.Apply("Duplicate", ops);

        Assert.Equal(4, document.Scene.Entities.Count);
        var child = document.Scene.Entities.Single(e => e.Parent == copy);
        Assert.NotEqual(2UL, child.Id);
        Assert.Equal(SceneValue.EntityRef(copy), child.Behaviours[0].Fields.Single(f => f.Name == "target").Value);
        Assert.Equal("Door", document.Scene.Find(copy)!.Name);
    }

    [Fact]
    public void ReparentingKeepsTheWorldPose()
    {
        var (document, _) = Open();
        var door = document.Scene.Find(1)!;
        // Turn the door a quarter about y and double its size.
        document.Apply("Turn", new AddComponent(1, new SceneComponent(1, "Transform", SceneEdits.TransformFields(
            new Pose([16777216, 0, 0], new Quat(0, Math.Sqrt(0.5), 0, Math.Sqrt(0.5)), [2, 2, 2])))));
        var before = SceneEdits.WorldPose(document.Scene, document.Scene.Find(2)!)!;

        document.Apply("Unparent", SceneEdits.Reparent(document.Scene, 2, 0));
        var root = document.Scene.Find(2)!;
        Assert.Equal(0UL, root.Parent);
        Assert.DoesNotContain(root.Components, c => c.Id == SceneEdits.LocalTransformId);
        AssertSame(before, SceneEdits.WorldPose(document.Scene, root)!);

        document.Apply("Reparent", SceneEdits.Reparent(document.Scene, 2, 1));
        Assert.Equal(1UL, root.Parent);
        AssertSame(before, SceneEdits.WorldPose(document.Scene, root)!);
        _ = door;
    }

    static void AssertSame(Pose expected, Pose actual)
    {
        for (var i = 0; i < 3; i++)
        {
            // A few units of 2^-24 m: the offset is an f32 in meters.
            Assert.InRange(actual.Position[i] - expected.Position[i], -4, 4);
            Assert.Equal(expected.Scale[i], actual.Scale[i], 5);
        }
        var dot = expected.Rotation.X * actual.Rotation.X + expected.Rotation.Y * actual.Rotation.Y
            + expected.Rotation.Z * actual.Rotation.Z + expected.Rotation.W * actual.Rotation.W;
        Assert.Equal(1, Math.Abs(dot), 5);
    }

    [Fact]
    public void AnAutosaveIsWrittenWhenDueAndFoundWhenNewer()
    {
        var (document, _) = Open();
        document.Save();
        var autosave = new Autosave(Path.Combine(_directory, "autosave"));
        var now = DateTime.UtcNow;

        Assert.False(autosave.WriteIfDue(document, now));
        document.Apply("Rename", new Rename(1, "Unsaved"));
        Assert.True(autosave.WriteIfDue(document, now));
        Assert.False(autosave.WriteIfDue(document, now + TimeSpan.FromSeconds(1)));
        Assert.True(autosave.WriteIfDue(document, now + Autosave.Interval));

        File.SetLastWriteTimeUtc(document.Path, DateTime.UtcNow - TimeSpan.FromMinutes(1));
        var found = autosave.Newer(document.Path);
        Assert.NotNull(found);
        Assert.Contains("name = \"Unsaved\"", File.ReadAllText(found));
        Assert.NotEqual(autosave.PathOf(Path.Combine(_directory, "other", "door.scene")), found);

        autosave.Delete(document.Path);
        Assert.Null(autosave.Newer(document.Path));
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory))
        {
            Directory.Delete(_directory, recursive: true);
        }
    }
}
