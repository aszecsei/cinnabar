using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Tests;

/// <summary>A unique directory under the system temp directory, deleted with the test that owns it.</summary>
sealed class TempDirectory(string name) : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"cinnabar-{name}-tests-{Guid.NewGuid():N}");

    public string Combine(params string[] parts) => System.IO.Path.Combine([Path, .. parts]);

    public void Dispose()
    {
        if (Directory.Exists(Path))
        {
            Directory.Delete(Path, recursive: true);
        }
    }
}

/// <summary>Editor shells over a scene file in a test's temp directory.</summary>
static class TestShell
{
    /// <summary>
    /// Opens a shell on <paramref name="sceneFileName"/> in <paramref name="dir"/> (no scene if null), first writing
    /// <paramref name="sceneText"/> to it unless that is null. Autosaves and settings go in the directory's autosave and settings folders.
    /// </summary>
    public static EditorShell Open(TempDirectory dir, string? sceneFileName, string? sceneText, string? projectPath = null)
    {
        Directory.CreateDirectory(dir.Path);
        var scenePath = sceneFileName == null ? null : dir.Combine(sceneFileName);
        if (scenePath != null && sceneText != null)
        {
            File.WriteAllText(scenePath, sceneText);
        }
        var options = new EditorOptions("host.exe", "game.dll", scenePath) { AutosaveDirectory = dir.Combine("autosave") };
        return new EditorShell(projectPath == null ? options : options with { ProjectPath = projectPath }, new EditorSettings(dir.Combine("settings")));
    }
}

/// <summary>Meshes the mesh tests share.</summary>
static class MeshFixtures
{
    public const string MeshGuid = "3b7f2c9e4d1a4f6b8c0d2e4f6a8b0c1d";

    public static MeshData Mesh(EditorShell shell) => shell.Mesh.Meshes.Find(MeshGuid)!.Data;

    /// <summary>The unit cube from the origin.</summary>
    public static MeshData Box() => Primitives.Block(Vec3.Zero, new Vec3(1, 1, 1));

    /// <summary>Writes room.mesh, a block a unit wide about the origin, into the directory.</summary>
    public static void WriteRoom(TempDirectory dir, string material = "")
    {
        Directory.CreateDirectory(dir.Path);
        File.WriteAllText(dir.Combine("room.mesh"), MeshFile.Write(Primitives.Block(new Vec3(-0.5, -0.5, -0.5), new Vec3(0.5, 0.5, 0.5), material: material)));
    }
}
