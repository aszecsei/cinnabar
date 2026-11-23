using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// An open world in its editor (see docs/editor/world-view.md#the-world-editor): a table of its scenes, each with its
/// bounds and distances, with the problems of the last check of its text on their rows. The view turns input into calls
/// here, so tests can drive the editor without a window. Scenes are named by GUID, since an undo replaces the file's
/// scene objects.
/// </summary>
public sealed class WorldEditor : IGraphEditor
{
    // The box of a new scene, in meters, and its load distance.
    const double NewSceneSize = 40;
    const double NewLoadDistance = 25;

    readonly EditorShell _shell;

    internal WorldEditor(EditorShell shell, WorldDocument document)
    {
        _shell = shell;
        Document = document;
        Checks = new CookChecks<GraphProblem>(shell, document.Guid, () => Document.Text, () => Document.Path,
            l => new GraphProblem(null, l.Text, l.Error, l.Line));
        Checks.Changed += () => ProblemsChanged?.Invoke();
        Document.Changed += OnDocumentChanged;
    }

    public WorldDocument Document { get; }

    IGraphDocument IGraphEditor.Document => Document;

    public string Noun => "world";

    public string Guid => Document.Guid;

    WorldFile File => Document.Graph;

    /// <summary>The scenes in the file's order.</summary>
    public IReadOnlyList<WorldScene> Scenes => [.. File.Scenes];

    /// <summary>The problems of the last check, each with its scene's line, or 0 for one of no line.</summary>
    public IReadOnlyList<GraphProblem> Problems => Checks.Problems;

    /// <summary>The checks of the unsaved text.</summary>
    public CookChecks<GraphProblem> Checks { get; }

    /// <summary>The world or its document's state changed.</summary>
    public event Action? Changed;

    public event Action? ProblemsChanged;

    void OnDocumentChanged()
    {
        Changed?.Invoke();
        _shell.Commands.InvalidateAll();
        _shell.OnWorldChanged();
        if (!Document.InTransaction)
        {
            Checks.Schedule();
        }
    }

    /// <summary>The problems on a scene's lines.</summary>
    public IEnumerable<GraphProblem> ProblemsOf(WorldScene scene)
    {
        var first = File.LineOf(scene);
        var last = first + scene.LineTexts.Count() - 1;
        return Problems.Where(p => p.Line >= first && p.Line <= last);
    }

    /// <summary>The scene that has a line, from 1, or null for a line of no scene.</summary>
    public WorldScene? SceneAt(int line) => File.SceneAt(line);

    /// <summary>The scene of the world with a GUID, or null.</summary>
    public WorldScene? Find(string guid) => File.Find(guid);

    /// <summary>
    /// What the game has of a scene, in Play, when it streams this world: "Loading" or "Ready" for a scene that the
    /// game has in, and "" for another scene, in Edit, or when the game streams another world.
    /// </summary>
    public string PlayState(WorldScene scene) => _shell.StreamedState(Guid, scene.Guid);

    /// <summary>
    /// Adds a scene that the world does not name: not persistent, a 40 m box around the active scene view's pivot, and
    /// a load distance of 25 m. Returns false for one that it names.
    /// </summary>
    public bool AddScene(string guid)
    {
        if (File.Find(guid) != null)
        {
            return false;
        }
        var (min, max) = NewBounds();
        Document.Edit("Add Scene", f => f.AddScene(guid, min, max, NewLoadDistance));
        return true;
    }

    // The box around the pivot, whose center is a whole number of meters.
    (double[] Min, double[] Max) NewBounds()
    {
        var center = _shell.ViewPivot().Select(raw => Math.Round(raw / 16777216.0)).ToArray();
        return ([.. center.Select(c => c - NewSceneSize / 2)], [.. center.Select(c => c + NewSceneSize / 2)]);
    }

    public void SetBounds(string guid, double[] min, double[] max) =>
        Document.Edit("Set Bounds", f =>
        {
            if (f.Find(guid) is { } scene)
            {
                f.SetBounds(scene, min, max);
            }
        });

    /// <summary>Sets the distances in meters. A null unload distance removes its line, so the cooker uses its own.</summary>
    public void SetDistances(string guid, double load, double? unload) =>
        Document.Edit("Set Distances", f =>
        {
            if (f.Find(guid) is { } scene)
            {
                f.SetDistances(scene, load, unload);
            }
        });

    /// <summary>
    /// Makes a scene persistent or not. A scene that stops being persistent and has no bounds or load distance, as a
    /// scene that was persistent from the start has none, gets those of a new scene.
    /// </summary>
    public void SetPersistent(string guid, bool persistent)
    {
        var (min, max) = NewBounds();
        Document.Edit(persistent ? "Make Persistent" : "Make Not Persistent", f =>
        {
            if (f.Find(guid) is not { } scene)
            {
                return;
            }
            f.SetPersistent(scene, persistent);
            if (persistent)
            {
                return;
            }
            if (scene.Min == null || scene.Max == null)
            {
                f.SetBounds(scene, scene.Min ?? min, scene.Max ?? max);
            }
            if (scene.LoadDistance == null)
            {
                f.SetDistances(scene, NewLoadDistance, scene.UnloadDistance);
            }
        });
    }

    public void RemoveScene(string guid) =>
        Document.Edit("Remove Scene", f =>
        {
            if (f.Find(guid) is { } scene)
            {
                f.Remove(scene);
            }
        });

    /// <summary>Sends the unsaved text to the cook daemon now, and shows the answer's problems.</summary>
    public Task CookNow() => Checks.CookNow();

    public void Dispose()
    {
        Checks.Dispose();
        Document.Changed -= OnDocumentChanged;
    }
}
