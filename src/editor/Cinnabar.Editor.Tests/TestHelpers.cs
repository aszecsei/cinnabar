using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;

[assembly: AssemblyFixture(typeof(Cinnabar.Editor.Tests.ControlsThread))]

namespace Cinnabar.Editor.Tests;

/// <summary>Made once, before the tests: the controls' thread takes what Avalonia's controls share (see <see cref="Ui"/>).</summary>
public sealed class ControlsThread
{
    public ControlsThread() => Ui.Run(() => new Avalonia.Controls.ListBox().Items.Add("claimed"));
}

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

/// <summary>
/// The one thread that the tests build Avalonia controls on. A control belongs to the thread that made it, and what the
/// controls share, such as the manager of the collections that a list or a menu listens to, belongs to the thread that
/// used it first. The runner has many threads, so a test that builds controls where it stands passes or fails by which
/// test came first. <see cref="Run"/> does the work on the one thread and waits for it. <see cref="ControlsThread"/>
/// claims what the controls share for the thread before any test runs, so a test that builds a list or a menu
/// elsewhere fails every time, not some times.
/// </summary>
static class Ui
{
    static readonly System.Collections.Concurrent.BlockingCollection<Action> Work = [];
    static readonly Thread Thread = Start();

    static Thread Start()
    {
        var thread = new Thread(() =>
        {
            foreach (var work in Work.GetConsumingEnumerable())
            {
                work();
            }
        })
        { IsBackground = true, Name = "test controls" };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return thread;
    }

    /// <summary>Runs a test's body on the controls' thread, and throws what it throws.</summary>
    public static void Run(Action body)
    {
        if (Thread.CurrentThread == Thread)
        {
            body();
            return;
        }
        System.Runtime.ExceptionServices.ExceptionDispatchInfo? error = null;
        using var done = new ManualResetEventSlim();
        Work.Add(() =>
        {
            try
            {
                body();
            }
            catch (Exception e)
            {
                error = System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(e);
            }
            finally
            {
                done.Set();
            }
        });
        done.Wait();
        error?.Throw();
    }
}

/// <summary>Index entries, naming only what a test cares about, so that a new field of an asset changes one place.</summary>
static class TestAssets
{
    public static Link.Cook.Asset Make(
        string guid,
        Link.Cook.AssetKind kind,
        string path,
        string root = "game",
        Link.Cook.AssetStatus status = Link.Cook.AssetStatus.Current,
        uint errors = 0,
        uint warnings = 0,
        string behaviour = "",
        string category = "",
        bool editMode = false,
        Link.Cook.Setting[]? settings = null,
        string[]? dependencies = null,
        string parent = "",
        string subasset = "",
        uint permutations = 0,
        uint[]? size = null,
        string toolTexture = "",
        Link.Cook.Hotspot[]? hotspots = null,
        string generated = "",
        string thumbnail = "",
        bool thumbnailReady = false,
        string action = "",
        Link.Cook.ActionParam[]? @params = null) =>
        new(guid, kind, root, path, status, errors, warnings, behaviour, category, editMode, action, @params ?? [], settings ?? [], dependencies ?? [], parent, subasset, permutations, size ?? [0, 0], toolTexture, hotspots ?? [], generated, thumbnail, thumbnailReady);
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
