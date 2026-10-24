namespace Cinnabar.Editor.Document;

/// <summary>One undo entry: the operations of an interaction, and their inverses in the order that undoes them.</summary>
public sealed record Transaction(string Label, IReadOnlyList<Operation> Operations, IReadOnlyList<Operation> Inverses);

/// <summary>
/// An open scene and its edits (see docs/editor.md#document-model): every change is an operation, applied to the
/// scene, kept on the undo stack and passed to <see cref="Applied"/>, which sends it to the host. The editor never
/// waits for the host. An interaction such as a drag groups its operations with <see cref="Begin"/>,
/// <see cref="Preview"/> and <see cref="Commit"/> into one entry.
/// </summary>
public sealed class SceneDocument(string path, Scene scene)
{
    readonly List<Transaction> _history = [];
    // The open transaction: its label, its operations and their inverses in the order applied.
    string? _label;
    readonly List<Operation> _pending = [];
    readonly List<Operation> _pendingInverses = [];

    /// <summary>The file's full path.</summary>
    public string Path { get; private set; } = path;

    public Scene Scene { get; } = scene;

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
    public static (SceneDocument? Document, IReadOnlyList<SceneProblem> Problems) Open(string path)
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
        return (scene == null ? null : new SceneDocument(full, scene), problems);
    }

    /// <summary>A document with the scene of an autosave for the file at path, with changes that the file lacks.</summary>
    public static SceneDocument Restored(string path, Scene scene) => new(System.IO.Path.GetFullPath(path), scene) { SavedPosition = -1 };

    /// <summary>Applies operations as one undo entry.</summary>
    public void Apply(string label, params Operation[] operations)
    {
        Begin(label);
        try
        {
            foreach (var op in operations)
            {
                Preview(op);
            }
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
    /// Applies an operation of the open entry at once, and sends it. An operation that replaces the one before it,
    /// such as the next step of a drag, takes its place, so the entry keeps the last value and the first inverse.
    /// </summary>
    public void Preview(Operation op)
    {
        if (_label == null)
        {
            throw new InvalidOperationException("no undo entry is open");
        }
        var inverse = op.Apply(Scene);
        if (_pending.Count > 0 && _pending[^1].IsReplacedBy(op))
        {
            _pending[^1] = op;
        }
        else
        {
            _pending.Add(op);
            _pendingInverses.Add(inverse);
        }
        Applied?.Invoke([op]);
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
        }
        Applied?.Invoke(operations);
        if (notify)
        {
            Changed?.Invoke();
        }
    }

    /// <summary>Writes the scene to its file, or to another path, which the document then has.</summary>
    public void Save(string? path = null)
    {
        var target = path == null ? Path : System.IO.Path.GetFullPath(path);
        WriteAtomically(target, SceneFile.Write(Scene));
        Path = target;
        SavedPosition = Position;
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
