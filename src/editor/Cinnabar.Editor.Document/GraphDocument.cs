namespace Cinnabar.Editor.Document;

/// <summary>What the shell's commands and the window ask of any graph document: its file, its history and its state.</summary>
public interface IGraphDocument
{
    /// <summary>The file's full path.</summary>
    string Path { get; }

    /// <summary>The asset's GUID.</summary>
    string Guid { get; }

    string Title { get; }

    bool IsDirty { get; }

    bool CanUndo { get; }

    bool CanRedo { get; }

    /// <summary>The graph changed: an edit, a step of a drag, undo or redo. Also the dirty state.</summary>
    event Action? Changed;

    void Undo();

    void Redo();

    /// <summary>Writes the graph to its file.</summary>
    void Save();

    /// <summary>The file moved, as when the content browser moves or renames it. Nothing is written.</summary>
    void Move(string path);
}

/// <summary>
/// A graph in a text file and its edits. Every edit changes the graph and keeps its text before and after as an undo
/// entry: graphs are small, and their text is what the cook daemon reads. A drag groups its steps with
/// <see cref="Begin"/> and <see cref="Commit"/> into one entry.
/// </summary>
public abstract class GraphDocument<TGraph> : IGraphDocument
{
    // Each entry's label and the text after it; the first state is the file's.
    readonly List<(string Label, string Text)> _states;
    string? _transaction;
    string _transactionStart = "";

    /// <param name="path">The file's full path.</param>
    /// <param name="guid">The asset's GUID.</param>
    /// <param name="graph">The graph.</param>
    /// <param name="text">The text that the file opened with, or null for what the writer gives.</param>
    protected GraphDocument(string path, string guid, TGraph graph, string? text = null)
    {
        Path = path;
        Guid = guid;
        Graph = graph;
        _states = [("Open", text ?? WriteGraph())];
    }

    public string Path { get; private set; }

    public string Guid { get; }

    public TGraph Graph { get; private set; }

    public string Title => System.IO.Path.GetFileName(Path);

    /// <summary>The entries, oldest first, after the state that the file opened with. The first <see cref="Position"/> are applied.</summary>
    public IReadOnlyList<string> History => [.. _states.Skip(1).Select(s => s.Label)];

    public int Position { get; private set; }

    public int SavedPosition { get; private set; }

    public bool IsDirty => Position != SavedPosition;

    public bool CanUndo => _transaction == null && Position > 0;

    public bool CanRedo => _transaction == null && Position < _states.Count - 1;

    public bool InTransaction => _transaction != null;

    /// <summary>The graph's text, as the file would have it now.</summary>
    public string Text => _transaction == null ? _states[Position].Text : WriteGraph();

    public event Action? Changed;

    /// <summary>The graph's text now.</summary>
    protected abstract string WriteGraph();

    /// <summary>The graph of a text that the document wrote, so it reads.</summary>
    protected abstract TGraph ReadGraph(string text);

    /// <summary>Changes the graph as one undo entry. An edit that changes nothing leaves no entry.</summary>
    public void Edit(string label, Action<TGraph> edit)
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
    public void Step(Action<TGraph> edit)
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
        var text = WriteGraph();
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
        Graph = ReadGraph(text);
        WriteGraph();
    }

    public void Save()
    {
        SceneDocument.WriteAtomically(Path, Text);
        SavedPosition = Position;
        Changed?.Invoke();
    }

    public void Move(string path)
    {
        Path = System.IO.Path.GetFullPath(path);
        Changed?.Invoke();
    }
}
