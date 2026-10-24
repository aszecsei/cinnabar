using Cinnabar.Editor.Document;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using ApplyOperations = Cinnabar.Editor.Link.Protocol.ApplyOperations;
using EditProblems = Cinnabar.Editor.Link.Protocol.EditProblems;
using PickResult = Cinnabar.Editor.Link.Protocol.PickResult;

namespace Cinnabar.Editor.Shell;

/// <summary>The open scene and its edits: opening, saving, autosave, the host's refusals, and selection by scene ID.</summary>
public sealed partial class EditorShell
{
    readonly Dictionary<ulong, List<string>> _problems = [];
    // The scene IDs of the selected entities, so the selection stays across a resync, which gives every entity a new
    // handle.
    List<ulong> _selectedSceneIds = [];
    // Entities that an edit created, to select when the host reports them.
    List<ulong> _selectWhenSeen = [];

    /// <summary>The open scene, which the host's world mirrors. Null until one is opened.</summary>
    public SceneDocument? Scene { get; private set; }

    public Autosave Autosave { get; }

    /// <summary>An autosave that is newer than the open scene's file, which the window offers to restore.</summary>
    public string? PendingRestore { get; private set; }

    /// <summary>A scene was opened, or the open one changed its history, its file or its dirty state.</summary>
    public event Action? SceneChanged;

    /// <summary>The user asked to pick a scene file. The window shows the picker, and calls <see cref="OpenScene"/>.</summary>
    public event Action? OpenSceneRequested;

    /// <summary>The user asked to save under a new path. The window shows the picker, and calls <see cref="SaveScene"/>.</summary>
    public event Action? SaveAsRequested;

    /// <summary><see cref="PendingRestore"/> is set. The window asks, and calls <see cref="RestoreAutosave"/> or <see cref="DiscardAutosave"/>.</summary>
    public event Action? RestoreOffered;

    /// <summary>The host refused edits, or a resync replaced the problems.</summary>
    public event Action? ProblemsChanged;

    public void RequestOpenScene() => OpenSceneRequested?.Invoke();

    public void RequestSaveAs() => SaveAsRequested?.Invoke();

    /// <summary>What the host could not apply of an entity, by scene ID: the latest load's problems and the edits' since.</summary>
    public IReadOnlyList<string> ProblemsOf(ulong sceneId) => _problems.GetValueOrDefault(sceneId) ?? [];

    /// <summary>
    /// Opens a scene file, and replaces the host's world with it. A file with an error is not opened: the problems go
    /// to the console with their lines, and the scene that was open stays. An autosave that is newer than the file is
    /// offered with <see cref="RestoreOffered"/>.
    /// </summary>
    public bool OpenScene(string path)
    {
        var (document, problems) = SceneDocument.Open(path);
        Report(path, problems);
        if (document == null)
        {
            Console.Add(LogLevel.Error, $"scene: cannot open {path}");
            return false;
        }
        Attach(document);
        Console.Add(LogLevel.Info, $"scene: opened {document.Path}, {document.Scene.Entities.Count} entities");
        PendingRestore = Autosave.Newer(document.Path);
        if (PendingRestore != null)
        {
            RestoreOffered?.Invoke();
        }
        return true;
    }

    /// <summary>Replaces the open scene with its newer autosave. The scene is then dirty, as its file lacks the changes.</summary>
    public bool RestoreAutosave()
    {
        if (PendingRestore is not { } autosave || Scene == null)
        {
            return false;
        }
        PendingRestore = null;
        var (scene, problems) = SceneFile.Parse(File.ReadAllText(autosave));
        Report(autosave, problems);
        if (scene == null)
        {
            Console.Add(LogLevel.Error, $"scene: cannot restore {autosave}");
            return false;
        }
        Attach(SceneDocument.Restored(Scene.Path, scene));
        Console.Add(LogLevel.Info, $"scene: restored the unsaved changes of {Scene.Path} from {autosave}");
        return true;
    }

    public void DiscardAutosave()
    {
        if (PendingRestore != null && Scene != null)
        {
            Autosave.Delete(Scene.Path);
        }
        PendingRestore = null;
    }

    /// <summary>Saves the open scene, to its file or to a new path. A failure goes to the console.</summary>
    public bool SaveScene(string? path = null)
    {
        if (Scene == null)
        {
            return false;
        }
        var old = Scene.Path;
        try
        {
            Scene.Save(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Console.Add(LogLevel.Error, $"scene: cannot save {path ?? old}: {e.Message}");
            return false;
        }
        Autosave.Delete(old);
        Autosave.Delete(Scene.Path);
        // Save As keeps what the user hid and locked for the new file.
        if (Scene.Path != old)
        {
            SaveSceneView();
        }
        Console.Add(LogLevel.Info, $"scene: saved {Scene.Path}");
        return true;
    }

    /// <summary>Forgets the open scene's unsaved changes and their autosave, as when the user closes without saving.</summary>
    public void DiscardChanges()
    {
        if (Scene != null)
        {
            Autosave.Delete(Scene.Path);
        }
    }

    /// <summary>Writes the autosave if it is due. The window calls it every few seconds, and so does every new undo entry.</summary>
    public void Tick(DateTime now)
    {
        if (Scene == null)
        {
            return;
        }
        try
        {
            Autosave.WriteIfDue(Scene, now);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Console.Add(LogLevel.Warning, $"scene: cannot autosave to {Autosave.Directory}: {e.Message}");
        }
    }

    /// <summary>Applies operations to the open scene as one undo entry. One that does not fit goes to the console.</summary>
    public bool Edit(string label, params Operation[] operations)
    {
        if (Scene == null || operations.Length == 0)
        {
            return false;
        }
        if (!IsEditing)
        {
            Console.Add(LogLevel.Warning, $"edit: cannot {label.ToLowerInvariant()} while the game plays. Stop it to edit the scene.");
            return false;
        }
        try
        {
            Scene.Apply(label, operations);
            return true;
        }
        catch (InvalidOperationException e)
        {
            Console.Add(LogLevel.Error, $"edit: cannot {label.ToLowerInvariant()}: {e.Message}");
            return false;
        }
    }

    /// <summary>The steps of a drag: <see cref="SceneDocument.Begin"/>, then a preview per step, then commit or cancel.</summary>
    public void BeginEdit(string label)
    {
        if (Scene is { InTransaction: false } && IsEditing)
        {
            Scene.Begin(label);
        }
    }

    public void PreviewEdit(Operation op) => PreviewEdit([op]);

    public void PreviewEdit(IReadOnlyList<Operation> ops)
    {
        if (Scene is not { InTransaction: true })
        {
            return;
        }
        try
        {
            Scene.Preview(ops);
        }
        catch (InvalidOperationException e)
        {
            Console.Add(LogLevel.Error, $"edit: {e.Message}");
        }
    }

    public void CommitEdit() => Scene?.Commit();

    public void CancelEdit() => Scene?.Cancel();

    /// <summary>The primary selected entity as the document has it, or null for none, or for one that the game spawned.</summary>
    /// In play mode the host's world is not the document's, so there is none.
    public SceneEntity? SelectedSceneEntity =>
        IsEditing && World.Find(Selection.Entity) is { SceneId: not 0 } node ? Scene?.Scene.Find(node.SceneId) : null;

    /// <summary>The selected entities that the document has, in the order they were selected.</summary>
    public IReadOnlyList<SceneEntity> SelectedSceneEntities =>
        Scene == null || !IsEditing ? [] : [.. Selection.Entities.Select(h => World.Find(h)?.SceneId ?? 0).Select(id => Scene.Scene.Find(id)).OfType<SceneEntity>()];

    /// <summary>Selects an entity by scene ID, now, or when the host reports it.</summary>
    public void SelectScene(ulong sceneId) => SelectScenes([sceneId]);

    /// <summary>Selects entities by scene ID, now, or when the host reports them.</summary>
    public void SelectScenes(IReadOnlyList<ulong> sceneIds)
    {
        if (sceneIds.All(id => World.FindScene(id) != null))
        {
            Selection.Set(sceneIds.Select(id => World.FindScene(id)!.Handle));
            _selectWhenSeen = [];
        }
        else
        {
            _selectWhenSeen = [.. sceneIds];
        }
    }

    public void CreateEntity()
    {
        if (Scene == null)
        {
            return;
        }
        var at = SelectedSceneEntity is { } selected ? SceneEdits.WorldPose(Scene.Scene, selected)?.Position : null;
        var create = SceneEdits.NewEntity(Scene.Scene, at ?? [0, 0, 0]);
        if (Edit("Create Entity", create))
        {
            SelectScene(create.Created.Id);
        }
    }

    /// <summary>Copies the selected entities with their descendants, and selects the copies.</summary>
    public void DuplicateSelected()
    {
        var roots = TopmostSelected();
        if (Scene == null || roots.Count == 0)
        {
            return;
        }
        var ops = new List<Operation>();
        var copies = new List<ulong>();
        foreach (var entity in roots)
        {
            var (duplicate, copy) = SceneEdits.Duplicate(Scene.Scene, entity.Id);
            ops.AddRange(duplicate);
            copies.Add(copy);
        }
        if (Edit(roots.Count == 1 ? $"Duplicate {Label(roots[0])}" : $"Duplicate {roots.Count} Entities", [.. ops]))
        {
            SelectScenes(copies);
        }
    }

    /// <summary>Deletes the selected entities with their descendants.</summary>
    public void DeleteSelected()
    {
        var roots = TopmostSelected();
        if (Scene == null || roots.Count == 0)
        {
            return;
        }
        Edit(roots.Count == 1 ? $"Delete {Label(roots[0])}" : $"Delete {roots.Count} Entities",
            [.. roots.SelectMany(e => SceneEdits.DestroyTree(Scene.Scene, e.Id))]);
    }

    // The selected entities without those under another selected entity, which an edit of that one includes.
    List<SceneEntity> TopmostSelected()
    {
        var selected = SelectedSceneEntities;
        var ids = selected.Select(e => e.Id).ToHashSet();
        return [.. selected.Where(e =>
        {
            var parent = e.Parent;
            for (var depth = 0; parent != 0 && depth < 64; depth++)
            {
                if (ids.Contains(parent))
                {
                    return false;
                }
                parent = Scene!.Scene.Find(parent)?.Parent ?? 0;
            }
            return true;
        })];
    }

    /// <summary>Moves an entity under another, or to the root with 0, keeping where it is in the world.</summary>
    public bool Reparent(ulong sceneId, ulong parent)
    {
        if (Scene?.Scene.Find(sceneId) is not { } entity || entity.Parent == parent || sceneId == parent)
        {
            return false;
        }
        try
        {
            return Edit(parent == 0 ? $"Unparent {Label(entity)}" : $"Parent {Label(entity)}", SceneEdits.Reparent(Scene.Scene, sceneId, parent));
        }
        catch (InvalidOperationException e)
        {
            Console.Add(LogLevel.Error, $"edit: {e.Message}");
            return false;
        }
    }

    static string Label(SceneEntity e) => e.Name.Length > 0 ? e.Name : $"{e.Id:x16}";

    void Attach(SceneDocument document)
    {
        if (Scene != null)
        {
            Scene.Applied -= SendOperations;
            Scene.Changed -= OnDocumentChanged;
        }
        Scene = document;
        document.Applied += SendOperations;
        document.Changed += OnDocumentChanged;
        _problems.Clear();
        ProblemsChanged?.Invoke();
        Commands.InvalidateAll();
        SceneChanged?.Invoke();
        LoadSceneView();
        SendScene();
        FrameScene();
    }

    void SendOperations(IReadOnlyList<Operation> operations)
    {
        Host.Send(new ApplyOperations([.. operations.Select(o => o.ToWire())]));
        // The gizmo sits on the primary entity, which an edit can move.
        SendGizmo();
    }

    void OnDocumentChanged()
    {
        Commands.InvalidateAll();
        SceneChanged?.Invoke();
        SendGizmo();
        // Undo back to the file's state leaves nothing to restore, so its autosave goes.
        if (Scene is { IsDirty: false })
        {
            Autosave.Delete(Scene.Path);
            return;
        }
        Tick(DateTime.UtcNow);
    }

    // The host replaces its world with the document. Its next entity snapshot shows the result.
    void SendScene()
    {
        if (Scene != null && Host.Linked)
        {
            Host.Send(SceneSnapshot.ToMessage(Scene.Scene));
        }
    }

    internal void OnGameMessage(Link.ILinkMessage message)
    {
        if (message is PickResult picked)
        {
            OnPickResult(picked);
            return;
        }
        if (message is not EditProblems problems)
        {
            World.Apply(message);
            return;
        }
        if (problems.Snapshot)
        {
            _problems.Clear();
        }
        foreach (var p in problems.Problems)
        {
            if (!_problems.TryGetValue(p.Entity, out var list))
            {
                _problems[p.Entity] = list = [];
            }
            if (!list.Contains(p.Message))
            {
                list.Add(p.Message);
            }
            if (!problems.Snapshot)
            {
                Console.Add(LogLevel.Warning, $"edit: the game did not apply an edit of {p.Entity:x16}: {p.Message}");
            }
        }
        ProblemsChanged?.Invoke();
    }

    void OnEntitiesChanged()
    {
        if (_selectWhenSeen.Count > 0 && _selectWhenSeen.All(id => World.FindScene(id) != null))
        {
            var created = _selectWhenSeen;
            _selectWhenSeen = [];
            Selection.Set(created.Select(id => World.FindScene(id)!.Handle));
            return;
        }
        if (Selection.Entities.All(e => World.Find(e) != null))
        {
            return;
        }
        // A resync gives the selected entities new handles. Those that are gone leave the selection.
        var sceneIds = _selectedSceneIds;
        var kept = Selection.Entities.Where(e => World.Find(e) is { SceneId: 0 }).ToList();
        Selection.Set([.. kept, .. sceneIds.Select(id => World.FindScene(id)?.Handle ?? 0).Where(h => h != 0)]);
    }

    void Report(string path, IReadOnlyList<SceneProblem> problems)
    {
        foreach (var p in problems)
        {
            var location = p.Line > 0 ? $"{path}:{p.Line}" : path;
            Console.Add(p.IsError ? LogLevel.Error : LogLevel.Warning, $"scene: {location}: {p.Message}");
        }
    }
}
