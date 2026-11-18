using Cinnabar.Editor.Document;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using ApplyOperations = Cinnabar.Editor.Link.Protocol.ApplyOperations;
using EditProblems = Cinnabar.Editor.Link.Protocol.EditProblems;
using PickResult = Cinnabar.Editor.Link.Protocol.PickResult;
using Wire = Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The open scenes and their edits: opening, adding, closing and saving, autosave, the host's refusals, and selection
/// by scene ID. Several scenes can be open, each a document with its own undo stack and dirty state; the active one is
/// the one that edits, undo and save act on (see docs/editor/document-and-scenes.md#several-scenes).
/// </summary>
public sealed partial class EditorShell
{
    readonly Dictionary<(uint Scene, ulong Id), List<string>> _problems = [];
    // The selected entities by scene and scene ID, so the selection stays across a resync, which gives every entity a new
    // handle.
    List<(uint Scene, ulong Id)> _selectedSceneIds = [];
    // Entities that an edit created, to select when the host reports them.
    List<(uint Scene, ulong Id)> _selectWhenSeen = [];
    // The open scenes, in the order they were opened. The first is the world's scene, whose GUID the host keeps.
    readonly List<SceneDocument> _scenes = [];
    // What each open scene's events call, so closing it lets them go.
    readonly Dictionary<SceneDocument, (Action<IReadOnlyList<Operation>> Applied, Action Changed)> _sceneHandlers = [];
    // The last number that an open scene got. Numbers are not used again in a session, so an operation for a closed
    // scene never edits another.
    uint _lastSceneNumber;
    // The autosave that the window offers to restore, and the open scene that it is for, or null.
    (SceneDocument Scene, string Autosave)? _restore;

    /// <summary>
    /// The active scene: the open scene that edits, undo, redo and save act on, and that the selection's primary entity
    /// is in. Null until one is opened.
    /// </summary>
    public SceneDocument? Scene { get; private set; }

    /// <summary>Every open scene, in the order they were opened. The host's world holds them all.</summary>
    public IReadOnlyList<SceneDocument> Scenes => _scenes;

    /// <summary>The active scene's number, or 0 without one.</summary>
    public uint ActiveNumber => Scene?.Number ?? 0;

    /// <summary>The open scene with the number, or null.</summary>
    public SceneDocument? SceneByNumber(uint number) => number == 0 ? null : _scenes.Find(s => s.Number == number);

    /// <summary>The open scene of the file, or null.</summary>
    public SceneDocument? SceneOfPath(string path) =>
        _scenes.Find(s => string.Equals(Path.GetFullPath(s.Path), Path.GetFullPath(path), StringComparison.OrdinalIgnoreCase));

    /// <summary>Whether a scene, the active one or another, has changes that its file lacks.</summary>
    public bool AnySceneDirty => _scenes.Any(s => s.IsDirty);

    /// <summary>The open scene that made the entity, or null for one that the game spawned.</summary>
    public SceneDocument? SceneOf(EntityNode node) => node.SceneId == 0 ? null : SceneByNumber(node.Scene);

    /// <summary>Whether the entity is one of the active scene's.</summary>
    public bool InActiveScene(EntityNode node) => node.SceneId != 0 && Scene != null && node.Scene == Scene.Number;

    /// <summary>The entity that the active scene made with the scene ID, or null.</summary>
    public EntityNode? FindInScene(ulong sceneId) => Scene == null ? null : World.FindScene(Scene.Number, sceneId);

    /// <summary>The scene ID of an entity of the active scene, by handle, or 0 for another scene's or one that the game spawned.</summary>
    public ulong ActiveSceneIdOf(ulong handle) => World.Find(handle) is { } node && InActiveScene(node) ? node.SceneId : 0;

    /// <summary>The GUID of the open scene's file, as its .meta file or the index has it, or null when it has none yet.</summary>
    public string? GuidOf(SceneDocument scene) => AssetGuidOf(scene.Path);

    /// <summary>The open scene whose file has the GUID, or null.</summary>
    public SceneDocument? SceneOfGuid(string guid) => guid == "" ? null : _scenes.Find(s => GuidOf(s) == guid);

    /// <summary>
    /// The reference that a field makes to an entity, by handle, or 0 for none: its scene ID for an entity of the active
    /// scene, and for an entity of another open scene, that scene's GUID and its ID or its path in an instance. Null with
    /// the reason when the entity cannot be named: one that the game spawned, and one of a scene that has no GUID yet.
    /// </summary>
    public SceneValue? ReferenceTo(ulong handle, out string reason)
    {
        reason = "";
        if (handle == 0)
        {
            return SceneValue.EntityRef(0);
        }
        if (World.Find(handle) is not { } node || SceneOf(node) is not { } scene)
        {
            reason = $"{EntityNode.Format(handle)} is not in the scene, so a field cannot refer to it";
            return null;
        }
        if (scene == Scene)
        {
            return SceneValue.EntityRef(node.SceneId);
        }
        if (GuidOf(scene) is not { } guid)
        {
            reason = $"{Path.GetFileName(scene.Path)} has no GUID yet, so a field cannot refer to its entities: save the scene, and let the cook index it";
            return null;
        }
        return scene.Expanded.InstanceOf(node.SceneId) is { Path.Count: > 1 } info ? SceneValue.EntityRef(guid, info.Path) : SceneValue.EntityRef(guid, node.SceneId);
    }

    /// <summary>
    /// What a field that the host reports as an entity holds, as a scene stores it: none for an entity that cannot be
    /// named (see <see cref="ReferenceTo"/>).
    /// </summary>
    public SceneValue ReferenceOf(ulong handle) => ReferenceTo(handle, out _) ?? SceneValue.EntityRef(0);

    public Autosave Autosave { get; }

    /// <summary>An autosave that is newer than the scene file opened last, which the window offers to restore.</summary>
    public string? PendingRestore => _restore?.Autosave;

    /// <summary>The open scene that <see cref="PendingRestore"/> is for, or null.</summary>
    public SceneDocument? PendingRestoreScene => _restore?.Scene;

    /// <summary>A scene was opened, added or closed, the active one changed, or an open one changed its history, its file or its dirty state.</summary>
    public event Action? SceneChanged;

    /// <summary>The user asked to pick a scene file. The window shows the picker, and calls <see cref="OpenScene"/>.</summary>
    public event Action? OpenSceneRequested;

    /// <summary>The user asked to pick a scene file to open beside the others. The window shows the picker, and calls <see cref="AddScene"/>.</summary>
    public event Action? AddSceneRequested;

    /// <summary>The user asked to close the active scene. The window asks about its changes, and calls <see cref="CloseScene"/>.</summary>
    public event Action<SceneDocument>? CloseSceneRequested;

    /// <summary>The user asked to save under a new path. The window shows the picker, and calls <see cref="SaveScene(string?)"/>.</summary>
    public event Action? SaveAsRequested;

    /// <summary><see cref="PendingRestore"/> is set. The window asks, and calls <see cref="RestoreAutosave"/> or <see cref="DiscardAutosave"/>.</summary>
    public event Action? RestoreOffered;

    /// <summary>The host refused edits, or a resync replaced the problems.</summary>
    public event Action? ProblemsChanged;

    public void RequestOpenScene() => OpenSceneRequested?.Invoke();

    public void RequestAddScene() => AddSceneRequested?.Invoke();

    public void RequestCloseScene() => RequestCloseScene(Scene);

    /// <summary>Asks to close an open scene, as <see cref="RequestCloseScene()"/> does for the active one.</summary>
    public void RequestCloseScene(SceneDocument? document)
    {
        if (document != null && _scenes.Count > 1)
        {
            CloseSceneRequested?.Invoke(document);
        }
    }

    public void RequestSaveAs() => SaveAsRequested?.Invoke();

    /// <summary>What the host could not apply of an entity of the active scene, by scene ID: the latest load's problems and the edits' since.</summary>
    public IReadOnlyList<string> ProblemsOf(ulong sceneId) => _problems.GetValueOrDefault((ActiveNumber, sceneId)) ?? [];

    /// <summary>What the host could not apply of an entity of any open scene.</summary>
    public IReadOnlyList<string> ProblemsOf(EntityNode node) => _problems.GetValueOrDefault((node.Scene, node.SceneId)) ?? [];

    /// <summary>
    /// Opens a scene file in place of every open scene, and replaces the host's world with it. A file with an error is
    /// not opened: the problems go to the console with their lines, and the scenes that were open stay. An autosave that
    /// is newer than the file is offered with <see cref="RestoreOffered"/>.
    /// </summary>
    public bool OpenScene(string path)
    {
        var (document, problems) = SceneDocument.Open(path, OpenPrefab, PrefabGuidOf(path), ParseOptionsFor(path));
        Report(path, problems);
        if (document == null)
        {
            Console.Add(LogLevel.Error, $"scene: cannot open {path}");
            return false;
        }
        Attach(document);
        Console.Add(LogLevel.Info, $"scene: opened {document.Path}, {document.Scene.Entities.Count} entities");
        OfferRestore(document);
        return true;
    }

    /// <summary>
    /// Opens a scene file beside the open ones and makes it the active scene, so the host's world holds them all (see
    /// docs/editor/document-and-scenes.md#several-scenes). A scene that is already open becomes the active one. Without
    /// an open scene it opens as <see cref="OpenScene"/> does. A prefab opens alone, as the document: it is refused
    /// beside a scene, and nothing opens beside it.
    /// </summary>
    public bool AddScene(string path)
    {
        if (Scene == null)
        {
            return OpenScene(path);
        }
        if (SceneOfPath(path) is { } open)
        {
            ActivateScene(open);
            return true;
        }
        if (Scene.IsPrefab || PrefabGuidOf(path) != "")
        {
            Console.Add(LogLevel.Warning, $"scene: cannot open {path} beside {Scene.Title}: a prefab opens alone, as the document. Open it with Open Scene.");
            return false;
        }
        var (document, problems) = SceneDocument.Open(path, OpenPrefab, options: ParseOptionsFor(path));
        Report(path, problems);
        if (document == null)
        {
            Console.Add(LogLevel.Error, $"scene: cannot open {path}");
            return false;
        }
        // The active scene's drag or drop ends, as the active scene changes.
        OpenEdit?.Cancel();
        Subscribe(document);
        _scenes.Add(document);
        Scene = document;
        ReportExpansion();
        Commands.InvalidateAll();
        SceneChanged?.Invoke();
        Visibility.Load();
        SendAddedScene(document);
        Console.Add(LogLevel.Info, $"scene: opened {document.Path} beside {_scenes.Count - 1} other scenes, {document.Scene.Entities.Count} entities");
        OfferRestore(document);
        return true;
    }

    /// <summary>
    /// Closes an open scene, without asking about its changes: the window asks first. The last open scene does not close,
    /// as the host's world would have nothing of the editor's. The host's world drops its entities, and only them.
    /// </summary>
    public bool CloseScene(SceneDocument document)
    {
        if (!_scenes.Contains(document) || _scenes.Count == 1)
        {
            return false;
        }
        if (OpenEdit is { } open && open.Document == document)
        {
            open.Cancel();
        }
        Unsubscribe(document);
        _scenes.Remove(document);
        foreach (var key in _problems.Keys.Where(k => k.Scene == document.Number).ToList())
        {
            _problems.Remove(key);
        }
        if (_restore?.Scene == document)
        {
            _restore = null;
        }
        if (Scene == document)
        {
            Scene = _scenes[^1];
        }
        ProblemsChanged?.Invoke();
        Commands.InvalidateAll();
        SceneChanged?.Invoke();
        Visibility.Load();
        SendRemovedScene(document);
        Console.Add(LogLevel.Info, $"scene: closed {document.Path}");
        return true;
    }

    /// <summary>
    /// Makes an open scene the active one, which edits, undo, redo and save act on. Selecting an entity of another scene
    /// does it too. The active scene's open entry ends for its owner, as when a scene opens.
    /// </summary>
    public void ActivateScene(SceneDocument document)
    {
        if (Scene == document || !_scenes.Contains(document))
        {
            return;
        }
        InterruptEdit();
        Scene = document;
        // The selection's entities of other scenes stay selected, but the primary one is the active scene's or none.
        if (World.Find(Selection.Entity) is { } primary && !InActiveScene(primary))
        {
            Selection.Set([]);
        }
        Commands.InvalidateAll();
        SceneChanged?.Invoke();
        Landscape.Sync();
        SendGizmo();
    }

    /// <summary>Replaces the scene that the autosave is for with its newer autosave. The scene is then dirty, as its file lacks the changes.</summary>
    public bool RestoreAutosave()
    {
        if (_restore is not ({ } old, { } autosave) || !_scenes.Contains(old))
        {
            return false;
        }
        _restore = null;
        var (scene, problems) = SceneFile.Parse(File.ReadAllText(autosave), ParseOptionsFor(old.Path));
        Report(autosave, problems);
        if (scene == null)
        {
            Console.Add(LogLevel.Error, $"scene: cannot restore {autosave}");
            return false;
        }
        var restored = SceneDocument.Restored(old.Path, scene, OpenPrefab, old.PrefabGuid);
        if (_scenes.Count == 1)
        {
            Attach(restored);
        }
        else
        {
            Replace(old, restored);
        }
        Console.Add(LogLevel.Info, $"scene: restored the unsaved changes of {old.Path} from {autosave}");
        return true;
    }

    public void DiscardAutosave()
    {
        if (_restore is ({ } scene, _))
        {
            Autosave.Delete(scene.Path);
        }
        _restore = null;
    }

    void OfferRestore(SceneDocument document)
    {
        _restore = Autosave.Newer(document.Path) is { } autosave ? (document, autosave) : null;
        if (_restore != null)
        {
            RestoreOffered?.Invoke();
        }
    }

    /// <summary>
    /// Saves the active scene, to its file or to a new path, and then every dirty mesh document and landscape map. A
    /// failure goes to the console. Refused while an entry is open, whose preview the file must not get as saved.
    /// </summary>
    public bool SaveScene(string? path = null) => Scene != null && SaveScene(Scene, path);

    /// <summary>Saves an open scene as <see cref="SaveScene(string?)"/> saves the active one. The other scenes are not touched.</summary>
    public bool SaveScene(SceneDocument document, string? path = null)
    {
        if (!_scenes.Contains(document))
        {
            return false;
        }
        if (OpenEdit is { } open)
        {
            Console.Add(LogLevel.Warning, $"scene: cannot save while {open.Owner} has \"{open.Label}\" open. Finish or cancel it first.");
            return false;
        }
        var old = document.Path;
        try
        {
            document.Save(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Console.Add(LogLevel.Error, $"scene: cannot save {path ?? old}: {e.Message}");
            return false;
        }
        var meshesSaved = Mesh.SaveMeshes();
        var mapsSaved = Landscape.SaveMaps();
        Autosave.Delete(old);
        Autosave.Delete(document.Path);
        // Save As keeps what the user hid and locked for the new file.
        if (document.Path != old)
        {
            Visibility.Save();
        }
        Console.Add(LogLevel.Info, $"scene: saved {document.Path}");
        return meshesSaved && mapsSaved;
    }

    /// <summary>Saves every open scene that is dirty, as the close prompt's Save does. False when one could not be saved.</summary>
    public bool SaveAllScenes()
    {
        var saved = true;
        foreach (var document in _scenes.Where(s => s.IsDirty).ToList())
        {
            saved &= SaveScene(document);
        }
        if (!_scenes.Any(s => s.IsDirty) && (Mesh.Meshes.AnyDirty || Landscape.AnyDirty) && Scene != null)
        {
            saved &= SaveScene(Scene);
        }
        return saved;
    }

    /// <summary>Forgets every open scene's unsaved changes and their autosaves, as when the user closes without saving.</summary>
    public void DiscardChanges()
    {
        foreach (var document in _scenes)
        {
            Autosave.Delete(document.Path);
        }
    }

    /// <summary>Forgets one open scene's unsaved changes and its autosave, as when the user closes it without saving.</summary>
    public void DiscardChanges(SceneDocument document) => Autosave.Delete(document.Path);

    /// <summary>Writes the autosaves that are due. The window calls it every few seconds, and so does every new undo entry.</summary>
    public void Tick(DateTime now)
    {
        Thumbnails.Pump(now);
        foreach (var document in _scenes)
        {
            try
            {
                Autosave.WriteIfDue(document, now);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                Console.Add(LogLevel.Warning, $"scene: cannot autosave to {Autosave.Directory}: {e.Message}");
                return;
            }
        }
    }

    /// <summary>Applies operations to the active scene as one undo entry. One that does not fit goes to the console.</summary>
    public bool Edit(string label, params Operation[] operations) => Scene != null && Edit(Scene, label, operations);

    // Applies operations to an open scene as one undo entry, as Edit does for the active one.
    bool Edit(SceneDocument document, string label, Operation[] operations)
    {
        if (operations.Length == 0 || CannotEdit(label))
        {
            return false;
        }
        try
        {
            document.Apply(label, operations);
            return true;
        }
        catch (InvalidOperationException e)
        {
            Console.Add(LogLevel.Error, $"edit: cannot {label.ToLowerInvariant()}: {e.Message}");
            return false;
        }
    }

    // Says in the console why an edit cannot apply now: the game plays, or another edit is open, which stays.
    bool CannotEdit(string label)
    {
        if (!IsEditing)
        {
            Console.Add(LogLevel.Warning, $"edit: cannot {label.ToLowerInvariant()} while the game plays. Stop it to edit the scene.");
            return true;
        }
        if (OpenEdit is { } open)
        {
            Console.Add(LogLevel.Warning, $"edit: cannot {label.ToLowerInvariant()} while {open.Owner} has \"{open.Label}\" open");
            return true;
        }
        return false;
    }

    /// <summary>
    /// Builds operations and applies them as <see cref="Edit(string, Operation[])"/> does. A build that does not fit goes
    /// to the console as "cannot" and a phrase, which is the label in lower case unless <paramref name="cannot"/> gives one.
    /// </summary>
    public bool TryEdit(string label, Func<Operation[]> build, string? cannot = null)
    {
        Operation[] operations;
        try
        {
            operations = build();
        }
        catch (InvalidOperationException e)
        {
            Console.Add(LogLevel.Error, $"edit: cannot {cannot ?? label.ToLowerInvariant()}: {e.Message}");
            return false;
        }
        return Edit(label, operations);
    }

    /// <summary>
    /// Undoes or redoes to a position of the active scene's history, as a click in the undo history does. Refused while
    /// the game plays or an entry is open, as Undo and Redo are, with the reason in the console.
    /// </summary>
    public bool MoveHistoryTo(int position)
    {
        if (Scene == null || position == Scene.Position)
        {
            return Scene != null;
        }
        if (CannotEdit("move through the history"))
        {
            return false;
        }
        Scene.MoveTo(position);
        return true;
    }

    /// <summary>The active scene's open undo entry and its owner, or null when none is open.</summary>
    public SceneEdit? OpenEdit { get; private set; }

    /// <summary>
    /// Opens an undo entry of the active scene that a drag previews its steps in, and gives its owner the token that
    /// previews, commits and cancels it. Null without a scene, while the game plays, or while another entry is open: the
    /// open one stays. <paramref name="commitIfInterrupted"/> keeps the entry when the shell ends it, as Play does;
    /// otherwise it is put back.
    /// </summary>
    public SceneEdit? TryBeginEdit(string label, string owner, bool commitIfInterrupted = false)
    {
        if (Scene == null || !IsEditing || OpenEdit != null)
        {
            return null;
        }
        Scene.Begin(label);
        OpenEdit = new SceneEdit(this, Scene, label, owner, commitIfInterrupted);
        // Save waits while an entry is open.
        Commands.InvalidateAll();
        return OpenEdit;
    }

    // The one place where the open entry ends: a stale token does nothing, and the owner learns after the document.
    internal void EndEdit(SceneEdit edit, bool commit)
    {
        if (OpenEdit != edit)
        {
            return;
        }
        OpenEdit = null;
        edit.End(commit);
        Commands.InvalidateAll();
        edit.RaiseEnded(commit);
    }

    /// <summary>Ends the open entry for its owner, as it asked when it opened it, and the owner learns that it ended.</summary>
    public void InterruptEdit()
    {
        if (OpenEdit is { } edit)
        {
            EndEdit(edit, edit.CommitIfInterrupted);
        }
    }

    /// <summary>The primary selected entity as the active scene has it, or null for none, or for one that the game spawned.</summary>
    /// In play mode the host's world is not the document's, so there is none.
    public SceneEntity? SelectedSceneEntity =>
        IsEditing && World.Find(Selection.Entity) is { } node && InActiveScene(node) ? Scene?.Expanded.Flat.Find(node.SceneId) : null;

    /// <summary>The selected entities that the active scene has, in the order they were selected.</summary>
    public IReadOnlyList<SceneEntity> SelectedSceneEntities =>
        Scene == null || !IsEditing ? [] : [.. Selection.Entities.Select(ActiveSceneIdOf).Where(id => id != 0).Select(id => Scene.Expanded.Flat.Find(id)).OfType<SceneEntity>()];

    /// <summary>Selects an entity of the active scene by scene ID, now, or when the host reports it.</summary>
    public void SelectScene(ulong sceneId) => SelectScenes([sceneId]);

    /// <summary>Selects entities of the active scene by scene ID, now, or when the host reports them.</summary>
    public void SelectScenes(IReadOnlyList<ulong> sceneIds) => SelectScenes(ActiveNumber, sceneIds);

    // Selects entities of a scene by scene ID, now, or when the host reports them.
    void SelectScenes(uint scene, IReadOnlyList<ulong> sceneIds)
    {
        if (sceneIds.All(id => World.FindScene(scene, id) != null))
        {
            Selection.Set(sceneIds.Select(id => World.FindScene(scene, id)!.Handle));
            _selectWhenSeen = [];
        }
        else
        {
            _selectWhenSeen = [.. sceneIds.Select(id => (scene, id))];
        }
    }

    /// <summary>Adds an entity with a Transform and nothing else, as <see cref="AddEntity"/> adds any kind.</summary>
    public void CreateEntity() => AddEntity(EntityCatalog.Find(EntityCatalog.EmptyId)!);

    /// <summary>
    /// Adds an entity of a kind of the catalog (see docs/editor/shell-and-panels.md#add) to the active scene, with the
    /// components that the kind starts with, as one undo entry, and selects it. It goes where the selected entity is, so
    /// that the two can be told apart by a drag of the gizmo; without a selection, where the active scene view looks, at
    /// its pivot, which is in view; and with no scene view shown, to the origin.
    /// </summary>
    public bool AddEntity(EntityTemplate template)
    {
        if (Scene == null)
        {
            return false;
        }
        var create = UnderPrefabRoot(EntityCatalog.Create(Scene.Expanded.Flat, template, NewEntityPosition()));
        if (!Edit(template.Id == EntityCatalog.EmptyId ? "Create Entity" : $"Add {template.Label}", create))
        {
            return false;
        }
        SelectScene(create.Created.Id);
        return true;
    }

    long[] NewEntityPosition()
    {
        if (SelectedSceneEntity is { } selected && SceneEdits.WorldPose(Scene!.Expanded.Flat, selected)?.Position is { } at)
        {
            return at;
        }
        return ActiveViewport is { IsShown: true, HasCamera: true } view ? view.Camera.Pivot : [0, 0, 0];
    }

    /// <summary>Copies the selected entities of the active scene with their descendants, and selects the copies.</summary>
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
            var (duplicate, copy) = PrefabEdits.Duplicate(Scene, entity.Id);
            ops.AddRange(duplicate);
            copies.Add(copy);
        }
        if (Edit(roots.Count == 1 ? $"Duplicate {Label(roots[0])}" : $"Duplicate {roots.Count} Entities", [.. ops]))
        {
            SelectScenes(copies);
        }
    }

    /// <summary>Deletes the selected entities of the active scene with their descendants, or in mesh mode the selected elements.</summary>
    public void DeleteSelected()
    {
        if (Mesh.InMeshMode)
        {
            Mesh.DeleteMeshSelection();
            return;
        }
        var roots = TopmostSelected();
        if (Scene == null || roots.Count == 0)
        {
            return;
        }
        Edit(roots.Count == 1 ? $"Delete {Label(roots[0])}" : $"Delete {roots.Count} Entities",
            [.. roots.SelectMany(e => PrefabEdits.DestroyTree(Scene, e.Id))]);
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
                parent = Scene!.Expanded.Flat.Find(parent)?.Parent ?? 0;
            }
            return true;
        })];
    }

    /// <summary>
    /// Whether an entity of the active scene can go under the target, which is null for the root. The target is of the
    /// same scene, and not the entity or one of its descendants. With another scene's target, or one that the game
    /// spawned, the reason is given, as a parent is in its entity's own scene (see docs/editor/document-and-scenes.md#several-scenes).
    /// </summary>
    public bool CanReparent(EntityNode dragged, EntityNode? target, out string reason)
    {
        reason = "";
        if (dragged.SceneId == 0 || !InActiveScene(dragged) || !IsEditing)
        {
            return false;
        }
        if (target == null)
        {
            return dragged.Parent != 0;
        }
        if (target.SceneId == 0 || target.Scene != dragged.Scene)
        {
            var where = SceneOf(target) is { } other ? Path.GetFileName(other.Path) : "no scene";
            reason = $"an entity's parent is in its own scene: {EntityNode.Format(dragged.Handle)} is in {Path.GetFileName(Scene!.Path)}, and {EntityNode.Format(target.Handle)} is in {where}";
            return false;
        }
        for (var p = target; p != null; p = p.Parent == 0 ? null : World.Find(p.Parent))
        {
            if (p.SceneId == dragged.SceneId)
            {
                return false;
            }
        }
        return true;
    }

    /// <summary>Moves an entity of the active scene under another of it, or to the root with 0, keeping where it is in the world.</summary>
    public bool Reparent(ulong sceneId, ulong parent)
    {
        if (Scene?.Expanded.Flat.Find(sceneId) is not { } entity || entity.Parent == parent || sceneId == parent)
        {
            return false;
        }
        try
        {
            return Edit(parent == 0 ? $"Unparent {Label(entity)}" : $"Parent {Label(entity)}", SceneEdits.Reparent(Scene.Expanded.Flat, sceneId, parent));
        }
        catch (InvalidOperationException e)
        {
            Console.Add(LogLevel.Error, $"edit: {e.Message}");
            return false;
        }
    }

    static string Label(SceneEntity e) => e.Name.Length > 0 ? e.Name : $"{e.Id:x16}";

    // Makes the document the only open scene, in place of every open one.
    void Attach(SceneDocument document)
    {
        // The old documents' drag or drop ends with them, and its owner learns.
        OpenEdit?.Cancel();
        if (_scenes.Count > 0)
        {
            foreach (var old in _scenes)
            {
                Unsubscribe(old);
            }
            _scenes.Clear();
            Mesh.CloseMeshes();
            Landscape.CloseMaps();
        }
        Subscribe(document);
        _scenes.Add(document);
        Scene = document;
        ClearNavProbe();
        _problems.Clear();
        ProblemsChanged?.Invoke();
        ReportExpansion();
        Commands.InvalidateAll();
        SceneChanged?.Invoke();
        Visibility.Load();
        SendScene();
        FrameScene();
    }

    // Puts a document in an open one's place, with its number, as a restored autosave takes its file's.
    void Replace(SceneDocument old, SceneDocument document)
    {
        if (OpenEdit is { } open && open.Document == old)
        {
            open.Cancel();
        }
        Unsubscribe(old);
        document.Number = old.Number;
        _scenes[_scenes.IndexOf(old)] = document;
        Subscribe(document, keepNumber: true);
        if (Scene == old)
        {
            Scene = document;
        }
        ReportExpansion();
        Commands.InvalidateAll();
        SceneChanged?.Invoke();
        SendScene();
    }

    void Subscribe(SceneDocument document, bool keepNumber = false)
    {
        if (!keepNumber)
        {
            document.Number = ++_lastSceneNumber;
        }
        var handlers = ((Action<IReadOnlyList<Operation>>)(ops => SendOperations(document, ops)), (Action)(() => OnDocumentChanged(document)));
        _sceneHandlers[document] = handlers;
        document.Applied += handlers.Item1;
        document.Changed += handlers.Item2;
    }

    void Unsubscribe(SceneDocument document)
    {
        if (_sceneHandlers.Remove(document, out var handlers))
        {
            document.Applied -= handlers.Applied;
            document.Changed -= handlers.Changed;
        }
    }

    void SendOperations(SceneDocument document, IReadOnlyList<Operation> operations)
    {
        // A mesh operation has nothing here: the mesh set's change sends the live mesh.
        // An edit of an instance has the difference that it made to the expansion.
        var wire = operations.SelectMany(o => o.ToWires()).Select(w => w with { Scene = document.Number }).ToArray();
        if (wire.Length > 0)
        {
            Host.Send(new ApplyOperations(wire));
        }
        // The gizmo sits on the primary entity, which an edit can move.
        SendGizmo();
    }

    void OnDocumentChanged(SceneDocument document)
    {
        Landscape.Sync();
        Commands.InvalidateAll();
        SceneChanged?.Invoke();
        SendGizmo();
        // Undo back to the file's state leaves nothing to restore, so its autosave goes.
        if (!document.IsDirty)
        {
            Autosave.Delete(document.Path);
            return;
        }
        Tick(DateTime.UtcNow);
    }

    // The host replaces its world with every open scene. Its next entity snapshot shows the result.
    void SendScene()
    {
        if (_scenes.Count > 0 && Host.Linked)
        {
            Host.Send(SceneSnapshot.ToMessage(_scenes.Select(s => SceneSnapshot.Loaded(s.Number, s.Expanded.Flat, AssetGuidOf(s.Path) ?? "")), ++_sceneTicket));
        }
    }

    // The host adds a scene that opened beside the others, and their entities keep their handles. Its next entity delta
    // shows the result.
    void SendAddedScene(SceneDocument document)
    {
        if (Host.Linked)
        {
            Host.Send(new Wire.AddScene(SceneSnapshot.Loaded(document.Number, document.Expanded.Flat, AssetGuidOf(document.Path) ?? ""), ++_sceneTicket));
        }
    }

    // The host despawns the entities of a scene that closed, and the others' stay as they are.
    void SendRemovedScene(SceneDocument document)
    {
        if (Host.Linked)
        {
            Host.Send(new Wire.RemoveScene(document.Number, ++_sceneTicket));
        }
    }

    internal void OnGameMessage(Link.ILinkMessage message)
    {
        switch (message)
        {
            case PickResult picked:
                OnPickResult(picked);
                return;
            case Link.Protocol.GameCommands commands:
                OnGameCommands(commands);
                return;
            case Link.Protocol.GameCommandResult result:
                OnGameCommandResult(result);
                return;
            case Link.Protocol.BehaviourOperations batch:
                OnBehaviourOperations(batch);
                return;
            case Link.Protocol.SkySun sun:
                OnSkySun(sun);
                return;
            case Link.Protocol.GameStats stats:
                Stats.Apply(stats);
                return;
            case Link.Protocol.HostStats host:
                Stats.Apply(host);
                return;
            case Link.Protocol.ProfileSummary summary:
                Stats.Apply(summary);
                Profiler.Apply(summary);
                return;
            case Link.Protocol.ProfileCapture capture:
                Profiler.Apply(capture);
                return;
            case Link.Protocol.CaptureResult { Kind: Link.Protocol.CaptureKind.Thumbnail } thumbnail:
                Thumbnails.Apply(thumbnail, DateTime.UtcNow);
                return;
            case Link.Protocol.ThumbnailFailed failed:
                Thumbnails.Apply(failed, DateTime.UtcNow);
                return;
            case Link.Protocol.CaptureResult result:
                Captures.Apply(result);
                return;
            case Link.Protocol.PreviewTarget target:
                _previewSlots.Route(target);
                return;
            case Link.Protocol.ViewportTarget target:
                OnViewportTarget(target);
                return;
            case Link.Protocol.AnimatorView { Entity: 0 } preview:
                OnPreviewView(preview);
                return;
            case Link.Protocol.UiPreviewLayout layout:
                OnUiLayout(layout);
                return;
            case Link.Protocol.StreamedScenes streamed:
                OnStreamedScenes(streamed);
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
            if (!_problems.TryGetValue((p.Scene, p.Entity), out var list))
            {
                _problems[(p.Scene, p.Entity)] = list = [];
            }
            if (!list.Contains(p.Message))
            {
                list.Add(p.Message);
            }
            if (!problems.Snapshot)
            {
                var where = _scenes.Count > 1 && SceneByNumber(p.Scene) is { } scene ? $" of {scene.Title}" : "";
                Console.Add(LogLevel.Warning, $"edit: the game did not apply an edit of {p.Entity:x16}{where}: {p.Message}");
            }
        }
        ProblemsChanged?.Invoke();
    }

    void OnEntitiesChanged()
    {
        if (_selectWhenSeen.Count > 0 && _selectWhenSeen.All(e => World.FindScene(e.Scene, e.Id) != null))
        {
            var created = _selectWhenSeen;
            _selectWhenSeen = [];
            Selection.Set(created.Select(e => World.FindScene(e.Scene, e.Id)!.Handle));
            return;
        }
        if (Selection.Entities.All(e => World.Find(e) != null))
        {
            return;
        }
        // A resync gives the selected entities new handles. Those that are gone leave the selection.
        var sceneIds = _selectedSceneIds;
        var kept = Selection.Entities.Where(e => World.Find(e) is { SceneId: 0 }).ToList();
        Selection.Set([.. kept, .. sceneIds.Select(e => World.FindScene(e.Scene, e.Id)?.Handle ?? 0).Where(h => h != 0)]);
    }

    // Follows the selection: an entity of another open scene that becomes the primary one makes its scene the active one.
    void FollowSelection()
    {
        if (World.Find(Selection.Entity) is { SceneId: not 0 } primary && primary.Scene != ActiveNumber && SceneOf(primary) is { } other)
        {
            ActivateScene(other);
        }
    }

    void Report(string path, IReadOnlyList<SceneProblem> problems) =>
        Report("scene", path, problems.Select(p => (p.Line, p.Message, p.IsError)));

    // A file's problems to the console, an error or a warning each, with the line where there is one.
    void Report(string area, string path, IEnumerable<(int Line, string Message, bool IsError)> problems)
    {
        foreach (var (line, message, isError) in problems)
        {
            var location = line > 0 ? $"{path}:{line}" : path;
            Console.Add(isError ? LogLevel.Error : LogLevel.Warning, $"{area}: {location}: {message}");
        }
    }
}
