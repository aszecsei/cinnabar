namespace Cinnabar.Editor.Document;

/// <summary>One undo entry: the operations of an interaction, and their inverses in the order that undoes them.</summary>
public sealed record Transaction(string Label, IReadOnlyList<Operation> Operations, IReadOnlyList<Operation> Inverses);

/// <summary>
/// An open scene and its edits (see docs/editor/document-and-scenes.md#document-model): every change is an operation, applied to the
/// scene, kept on the undo stack and passed to <see cref="Applied"/>, which sends it to the host. The editor never
/// waits for the host. An interaction such as a drag groups its operations with <see cref="Begin"/>,
/// <see cref="Preview"/> and <see cref="Commit"/> into one entry.
/// </summary>
public sealed class SceneDocument
{
    /// <summary>
    /// A document of a scene. <paramref name="openPrefab"/> opens a prefab's document by GUID, for the prefabs that
    /// the scene instantiates, or gives null for one that it cannot find.
    /// </summary>
    public SceneDocument(string path, Scene scene, Func<string, PrefabDocument?>? openPrefab = null)
    {
        Path = path;
        Scene = scene;
        Prefabs = new PrefabSet(openPrefab ?? (_ => null));
        Prefabs.Changed += Invalidate;
    }

    Expansion? _expanded;

    readonly List<Transaction> _history = [];
    // The open transaction: its label, its operations and their inverses in the order applied.
    string? _label;
    readonly List<Operation> _pending = [];
    readonly List<Operation> _pendingInverses = [];

    /// <summary>The file's full path.</summary>
    public string Path { get; private set; }

    /// <summary>The scene as its file has it, with instance blocks and override blocks.</summary>
    public Scene Scene { get; }

    /// <summary>The prefabs that the scene instantiates and those that its edits made, which it saves with it.</summary>
    public PrefabSet Prefabs { get; }

    /// <summary>
    /// The scene with its instances expanded into plain entities, as the host loads it, and where each instance's
    /// entity comes from (see docs/editor/prefabs.md#the-editors-documents). The panels, the gizmo and picking read
    /// it, and an operation names its entities.
    /// </summary>
    public Expansion Expanded => _expanded ??= PrefabExpansion.Expand(Scene, Prefabs.SceneOf);

    /// <summary>The expansion is out of date, as after an edit or a change of a prefab, and is made again when next read.</summary>
    public void Invalidate() => _expanded = null;

    public string Title => System.IO.Path.GetFileName(Path);

    /// <summary>The undo stack, oldest first. The first <see cref="Position"/> entries are applied.</summary>
    public IReadOnlyList<Transaction> History => _history;

    public int Position { get; private set; }

    /// <summary>The <see cref="Position"/> that the file has, or -1 when no position has it, as after a restore.</summary>
    public int SavedPosition { get; private set; }

    public bool IsDirty => Position != SavedPosition;

    public bool CanUndo => _label == null && Position > 0;

    public bool CanRedo => _label == null && Position < _history.Count;

    public bool InTransaction => _label != null;

    /// <summary>Operations that changed the scene, in order: edits, undo and redo. The host gets them.</summary>
    public event Action<IReadOnlyList<Operation>>? Applied;

    /// <summary>The history, the position or the dirty state changed.</summary>
    public event Action? Changed;

    /// <summary>Reads and parses a scene file. The document is null when the file cannot be read or has an error.</summary>
    public static (SceneDocument? Document, IReadOnlyList<SceneProblem> Problems) Open(string path, Func<string, PrefabDocument?>? openPrefab = null)
    {
        var full = System.IO.Path.GetFullPath(path);
        string text;
        try
        {
            text = File.ReadAllText(full);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return (null, [new SceneProblem(0, e.Message, true)]);
        }
        var (scene, problems) = SceneFile.Parse(text);
        return (scene == null ? null : new SceneDocument(full, scene, openPrefab), problems);
    }

    /// <summary>A document with the scene of an autosave for the file at path, with changes that the file lacks.</summary>
    public static SceneDocument Restored(string path, Scene scene, Func<string, PrefabDocument?>? openPrefab = null) =>
        new(System.IO.Path.GetFullPath(path), scene, openPrefab) { SavedPosition = -1 };

    /// <summary>Applies operations as one undo entry.</summary>
    public void Apply(string label, params Operation[] operations)
    {
        Begin(label);
        try
        {
            Preview(operations);
        }
        catch
        {
            Cancel();
            throw;
        }
        Commit();
    }

    /// <summary>Starts an undo entry. Only one is open at a time.</summary>
    public void Begin(string label)
    {
        if (_label != null)
        {
            throw new InvalidOperationException($"\"{_label}\" is still open");
        }
        _label = label;
        _pending.Clear();
        _pendingInverses.Clear();
    }

    /// <summary>
    /// Applies an operation of the open entry at once, and sends it. An operation that replaces an earlier one, such
    /// as the next step of a drag, takes its place, so the entry keeps the last value and the first inverse. An
    /// operation on an instance's entity becomes the edit of its block that <see cref="PrefabEdits.Route"/> gives.
    /// </summary>
    public void Preview(Operation op) => Preview([op]);

    /// <summary>Applies operations of the open entry in order, as <see cref="Preview(Operation)"/>, and sends them together.</summary>
    public void Preview(IReadOnlyList<Operation> ops)
    {
        if (_label == null)
        {
            throw new InvalidOperationException("no undo entry is open");
        }
        var applied = new List<Operation>();
        try
        {
            foreach (var given in ops)
            {
                var op = PrefabEdits.Route(this, given);
                var inverse = op.Apply(Scene);
                Invalidate();
                applied.Add(op);
                if (Replaced(op) is var at and >= 0)
                {
                    _pending[at] = op;
                }
                else
                {
                    _pending.Add(op);
                    _pendingInverses.Add(inverse);
                }
            }
        }
        finally
        {
            // What applied is in the document, so the host gets it even when a later operation does not fit.
            if (applied.Count > 0)
            {
                Applied?.Invoke(applied);
            }
        }
    }

    // The pending operation that a new one replaces. A drag step of several fields, or of several entities, sets each
    // field in turn, so the search goes back over field sets, which do not depend on each other, and stops at anything
    // else.
    int Replaced(Operation op)
    {
        for (var k = _pending.Count - 1; k >= 0; k--)
        {
            if (_pending[k].IsReplacedBy(op))
            {
                return k;
            }
            if (_pending[k] is not (SetField or SetBehaviourField or BlockOperation { Key: not "" }))
            {
                return -1;
            }
        }
        return -1;
    }

    /// <summary>Ends the open entry. An entry without operations leaves no entry.</summary>
    public void Commit()
    {
        var label = _label ?? throw new InvalidOperationException("no undo entry is open");
        _label = null;
        if (_pending.Count == 0)
        {
            return;
        }
        // A new edit drops the entries that were undone, and with them a saved position among them.
        _history.RemoveRange(Position, _history.Count - Position);
        if (SavedPosition > Position)
        {
            SavedPosition = -1;
        }
        _history.Add(new Transaction(label, [.. _pending], [.. Enumerable.Reverse(_pendingInverses)]));
        Position = _history.Count;
        Changed?.Invoke();
    }

    /// <summary>Ends the open entry by undoing what it applied, as when a drag is cancelled.</summary>
    public void Cancel()
    {
        if (_label == null)
        {
            return;
        }
        _label = null;
        var inverses = Enumerable.Reverse(_pendingInverses).ToList();
        foreach (var op in inverses)
        {
            op.Apply(Scene);
            Invalidate();
        }
        if (inverses.Count > 0)
        {
            Applied?.Invoke(inverses);
        }
    }

    public void Undo()
    {
        if (CanUndo)
        {
            Position--;
            Run(_history[Position].Inverses);
        }
    }

    public void Redo()
    {
        if (CanRedo)
        {
            Run(_history[Position].Operations);
            Position++;
        }
    }

    /// <summary>Undoes or redoes until the first <paramref name="position"/> entries are applied.</summary>
    public void MoveTo(int position)
    {
        position = Math.Clamp(position, 0, _history.Count);
        while (Position > position && CanUndo)
        {
            Position--;
            Run(_history[Position].Inverses, notify: false);
        }
        while (Position < position && CanRedo)
        {
            Run(_history[Position].Operations, notify: false);
            Position++;
        }
        Changed?.Invoke();
    }

    void Run(IReadOnlyList<Operation> operations, bool notify = true)
    {
        foreach (var op in operations)
        {
            op.Apply(Scene);
            Invalidate();
        }
        Applied?.Invoke(operations);
        if (notify)
        {
            Changed?.Invoke();
        }
    }

    /// <summary>
    /// Writes the scene to its file, or to another path, which the document then has, and every prefab that is dirty,
    /// so a prefab that an edit made has its file when the scene that names it does.
    /// </summary>
    public void Save(string? path = null)
    {
        var target = path == null ? Path : System.IO.Path.GetFullPath(path);
        foreach (var prefab in Prefabs.Documents.Where(d => d.IsDirty))
        {
            prefab.Save();
        }
        WriteAtomically(target, SceneFile.Write(Scene));
        Path = target;
        SavedPosition = Position;
        Changed?.Invoke();
    }

    /// <summary>The scene's file moved, as when the content browser moves or renames it. Nothing is written.</summary>
    public void Move(string path)
    {
        Path = System.IO.Path.GetFullPath(path);
        Changed?.Invoke();
    }

    /// <summary>Writes text to a temporary file and moves it over the target, so a crash never leaves half a file.</summary>
    public static void WriteAtomically(string path, string text)
    {
        System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, text);
        File.Move(temporary, path, overwrite: true);
    }
}
