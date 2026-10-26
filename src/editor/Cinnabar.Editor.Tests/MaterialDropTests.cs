using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Tests;

/// <summary>Dropping a material in the viewport, in the shell without a host: the slot that a pick finds, and its preview.</summary>
public sealed class MaterialDropTests : IDisposable
{
    readonly string _directory = Path.Combine(Path.GetTempPath(), $"cinnabar-material-drop-tests-{Guid.NewGuid():N}");

    const string Old = "b0de249d5bae464988ec7b909fbcac41";
    const string New = "0123456789abcdef0123456789abcdef";

    // A mesh with a material in its first slot, and an entity with no Mesh_Renderer.
    const string Text = "scene 1\n\n" +
        "entity 0000000000000001\nname = \"Mesh\"\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n" +
        "component 33 Mesh_Renderer\n\tmesh = $89fc38c8aa19f0cf0cc161d2ab5e015b\n\tmaterials.0 = $" + Old + "\n\n" +
        "entity 0000000000000002\nname = \"Empty\"\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n";

    static ulong Handle(uint index) => 1UL << 32 | index;

    EditorShell NewShell()
    {
        Directory.CreateDirectory(_directory);
        var path = Path.Combine(_directory, "mesh.scene");
        File.WriteAllText(path, Text);
        var shell = new EditorShell(new EditorOptions("host.exe", "game.dll", path) { AutosaveDirectory = Path.Combine(_directory, "autosave") },
            new EditorSettings(Path.Combine(_directory, "settings")));
        shell.OnGameMessage(new EntitySnapshot(
        [
            new EntityInfo(Handle(0), "Mesh", 1, 0, true, [1, 33]),
            new EntityInfo(Handle(1), "Empty", 2, 0, true, [1]),
            new EntityInfo(Handle(2), "", 0, 0, true, [1, 33]),
        ]));
        return shell;
    }

    static PickResult Pick(int submesh, params (uint Index, ulong SceneId)[] hits) =>
        new(1, [.. hits.Select(h => new PickHit(Handle(h.Index), h.SceneId))], 1, submesh);

    static string? Material(EditorShell shell, int slot) =>
        shell.Scene!.Scene.Find(1)!.Components.Single(c => c.Id == SceneEdits.MeshRendererId).Fields.Find(f => f.Name == $"materials.{slot}")?.Value.Asset;

    [Fact]
    public void APickFindsTheSlotOfTheSubmeshUnderIt()
    {
        using var shell = NewShell();

        Assert.Equal(new MaterialTarget(1, 2), shell.MaterialTargetOf(Pick(2, (0, 1))));
        // Spawned entities, entities without a Mesh_Renderer, nothing drawn and submeshes past the slots take none.
        Assert.Null(shell.MaterialTargetOf(Pick(0, (2, 0))));
        Assert.Null(shell.MaterialTargetOf(Pick(0, (1, 2))));
        Assert.Null(shell.MaterialTargetOf(Pick(-1)));
        Assert.Null(shell.MaterialTargetOf(Pick(EditorShell.MaterialSlots, (0, 1))));

        shell.SetLocked([1], true);
        Assert.Null(shell.MaterialTargetOf(Pick(0, (0, 1))));
        shell.SetLocked([1], false);
        shell.SetHidden([1], true);
        Assert.Null(shell.MaterialTargetOf(Pick(0, (0, 1))));
    }

    [Fact]
    public void APreviewFollowsTheDragAndADropIsOneUndoEntry()
    {
        using var shell = NewShell();

        shell.PreviewMaterial(new MaterialTarget(1, 0), New);
        Assert.Equal(New, Material(shell, 0));
        // Moving to another submesh puts the first one back.
        shell.PreviewMaterial(new MaterialTarget(1, 1), New);
        Assert.Equal(Old, Material(shell, 0));
        Assert.Equal(New, Material(shell, 1));
        // Leaving puts it back too, and leaves nothing to undo.
        shell.CancelMaterial();
        Assert.Null(Material(shell, 1));
        Assert.False(shell.Scene!.CanUndo);

        shell.PreviewMaterial(new MaterialTarget(1, 0), New);
        Assert.True(shell.DropMaterial(Pick(0, (0, 1)), New));
        Assert.Equal(New, Material(shell, 0));
        Assert.False(shell.Scene.InTransaction);
        shell.Scene.Undo();
        Assert.Equal(Old, Material(shell, 0));
        Assert.False(shell.Scene.CanUndo);
    }

    [Fact]
    public void ADropOnNothingThatTakesItChangesNothing()
    {
        using var shell = NewShell();

        shell.PreviewMaterial(new MaterialTarget(1, 0), New);
        Assert.False(shell.DropMaterial(Pick(0, (1, 2)), New));
        Assert.Equal(Old, Material(shell, 0));
        Assert.False(shell.Scene!.InTransaction);
        Assert.False(shell.Scene.CanUndo);
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory))
        {
            Directory.Delete(_directory, true);
        }
    }
}
