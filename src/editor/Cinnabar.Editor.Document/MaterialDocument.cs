namespace Cinnabar.Editor.Document;

/// <summary>
/// An open material or material function and its edits (see docs/editor.md#material-editor). Every edit changes the
/// graph and keeps its text before and after as an undo entry: graphs are small, and their text is what the cook daemon
/// cooks for the preview. A drag groups its steps with <see cref="Begin"/> and <see cref="Commit"/> into one entry.
/// </summary>
public sealed class MaterialDocument
{
    // Each entry's label and the text after it; the first state is the file's.
    readonly List<(string Label, string Text)> _states;
    string? _transaction;
    string _transactionStart = "";
    Dictionary<int, int> _nodeLines = [];

    MaterialDocument(string path, string guid, MaterialGraph graph)
    {
        Path = path;
        Guid = guid;
        Graph = graph;
        _states = [("Open", Write())];
    }

    /// <summary>The file's full path.</summary>
    public string Path { get; private set; }

    /// <summary>The asset's GUID, which the preview cooks under.</summary>
    public string Guid { get; }

    public MaterialGraph Graph { get; private set; }

    public string Title => System.IO.Path.GetFileName(Path);

    public MaterialFileKind Kind => Graph.Kind;

    /// <summary>The entries, oldest first, after the state that the file opened with. The first <see cref="Position"/> are applied.</summary>
    public IReadOnlyList<string> History => [.. _states.Skip(1).Select(s => s.Label)];

    public int Position { get; private set; }

    public int SavedPosition { get; private set; }

    public bool IsDirty => Position != SavedPosition;

    public bool CanUndo => _transaction == null && Position > 0;

    public bool CanRedo => _transaction == null && Position < _states.Count - 1;

    public bool InTransaction => _transaction != null;

    /// <summary>The graph's text, as the file would have it now.</summary>
    public string Text => _transaction == null ? _states[Position].Text : Write();

    /// <summary>The graph changed: an edit, a step of a drag, undo or redo. Also the dirty state.</summary>
    public event Action? Changed;

    /// <summary>Reads and parses a material file. The document is null when the file cannot be read, does not parse, or is HLSL.</summary>
    public static (MaterialDocument? Document, IReadOnlyList<MaterialProblem> Problems) Open(string path, string guid)
    {
        var full = System.IO.Path.GetFullPath(path);
        string text;
        try
        {
            text = File.ReadAllText(full);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return (null, [new MaterialProblem(0, e.Message)]);
        }
        var (graph, problems) = MaterialFile.Parse(text, MaterialFile.KindOf(full));
        if (graph is { Hlsl: not null })
        {
            return (null, [new MaterialProblem(0, "its evaluate is HLSL after a --- line, which the script editor edits")]);
        }
        return (graph == null ? null : new MaterialDocument(full, guid, graph), problems);
    }

    /// <summary>A document of a graph, as a test or a new material makes it, at a path that it has not written.</summary>
    public static MaterialDocument Of(string path, string guid, MaterialGraph graph) => new(System.IO.Path.GetFullPath(path), guid, graph);

    /// <summary>The node whose lines of <see cref="Text"/> hold a line, or null for a line of the settings.</summary>
    public int? NodeAt(int line)
    {
        int? found = null;
        var start = 0;
        foreach (var (id, first) in _nodeLines)
        {
            if (first <= line && first >= start)
            {
                (found, start) = (id, first);
            }
        }
        return found;
    }

    /// <summary>Changes the graph as one undo entry. An edit that changes nothing leaves no entry.</summary>
    public void Edit(string label, Action<MaterialGraph> edit)
    {
        if (_transaction != null)
        {
            edit(Graph);
            Changed?.Invoke();
            return;
        }
        edit(Graph);
        Push(label);
    }

    /// <summary>Starts an entry that a drag's steps change, until <see cref="Commit"/> or <see cref="Cancel"/>.</summary>
    public void Begin(string label)
    {
        if (_transaction != null)
        {
            throw new InvalidOperationException($"\"{_transaction}\" is still open");
        }
        _transaction = label;
        _transactionStart = _states[Position].Text;
    }

    /// <summary>Changes the graph as a step of the open entry.</summary>
    public void Step(Action<MaterialGraph> edit)
    {
        edit(Graph);
        Changed?.Invoke();
    }

    public void Commit()
    {
        var label = _transaction ?? throw new InvalidOperationException("no entry is open");
        _transaction = null;
        Push(label);
    }

    /// <summary>Ends the open entry, and puts the graph back as it was before it.</summary>
    public void Cancel()
    {
        if (_transaction == null)
        {
            return;
        }
        _transaction = null;
        Load(_transactionStart);
        Changed?.Invoke();
    }

    void Push(string label)
    {
        var text = Write();
        if (text == _states[Position].Text)
        {
            return;
        }
        // A new edit drops the entries that were undone, and with them a saved position among them.
        _states.RemoveRange(Position + 1, _states.Count - Position - 1);
        if (SavedPosition > Position)
        {
            SavedPosition = -1;
        }
        _states.Add((label, text));
        Position = _states.Count - 1;
        Changed?.Invoke();
    }

    public void Undo()
    {
        if (CanUndo)
        {
            Position--;
            Load(_states[Position].Text);
            Changed?.Invoke();
        }
    }

    public void Redo()
    {
        if (CanRedo)
        {
            Position++;
            Load(_states[Position].Text);
            Changed?.Invoke();
        }
    }

    void Load(string text)
    {
        // The document wrote the text, so it parses.
        Graph = MaterialFile.Parse(text, Graph.Kind).Graph!;
        Write();
    }

    string Write()
    {
        var lines = new Dictionary<int, int>();
        var text = MaterialFile.Write(Graph, lines);
        _nodeLines = lines;
        return text;
    }

    /// <summary>Writes the graph to its file.</summary>
    public void Save()
    {
        SceneDocument.WriteAtomically(Path, Text);
        SavedPosition = Position;
        Changed?.Invoke();
    }

    /// <summary>The file moved, as when the content browser moves or renames it. Nothing is written.</summary>
    public void Move(string path)
    {
        Path = System.IO.Path.GetFullPath(path);
        Changed?.Invoke();
    }
}
