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

    /// <summary>A drag's entry is open, so <see cref="Save"/> is refused.</summary>
    bool InTransaction { get; }

    /// <summary>The graph changed: an edit, a step of a drag, undo or redo. Also the dirty state, and a drag's entry opening or ending.</summary>
    event Action? Changed;

    void Undo();

    void Redo();

    /// <summary>Writes the graph to its file. Refused while an entry is open.</summary>
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
    // The merge key of the current entry while edits with that key still merge into it, as a held key's nudges do.
    string? _merge;

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

    /// <summary>
    /// Changes the graph as one undo entry, which later edits with the same merge key change too, until
    /// <see cref="EndMerge"/> or any other entry, undo, redo or save, so the entry is never the saved one. A held key's repeats are one entry this way, without an
    /// entry left open, so Save and Undo still run between them. An edit that brings the graph back to the entry's
    /// start drops the entry.
    /// </summary>
    public void EditMerged(string label, string mergeKey, Action<TGraph> edit)
    {
        if (_transaction != null)
        {
            Edit(label, edit);
            return;
        }
        if (_merge != mergeKey || Position == 0 || Position != _states.Count - 1)
        {
            edit(Graph);
            if (Push(label))
            {
                _merge = mergeKey;
            }
            return;
        }
        edit(Graph);
        var text = WriteGraph();
        if (text == _states[Position].Text)
        {
            return;
        }
        if (text == _states[Position - 1].Text)
        {
            _states.RemoveAt(Position);
            Position--;
            _merge = null;
        }
        else
        {
            _states[Position] = (_states[Position].Label, text);
        }
        Changed?.Invoke();
    }

    /// <summary>Ends the merge of <see cref="EditMerged"/>: the next edit is an entry of its own.</summary>
    public void EndMerge() => _merge = null;

    /// <summary>Starts an entry that a drag's steps change, until <see cref="Commit"/> or <see cref="Cancel"/>.</summary>
    public void Begin(string label)
    {
        if (_transaction != null)
        {
            throw new InvalidOperationException($"\"{_transaction}\" is still open");
        }
        _merge = null;
        _transaction = label;
        _transactionStart = _states[Position].Text;
        Changed?.Invoke();
    }

    /// <summary>Changes the graph as a step of the open entry.</summary>
    public void Step(Action<TGraph> edit)
    {
        if (_transaction == null)
        {
            throw new InvalidOperationException("no entry is open");
        }
        edit(Graph);
        Changed?.Invoke();
    }

    /// <summary>
    /// Changes the graph as a step of the open entry, from the graph as it was when the entry began: a drag's step that
    /// sets where its blocks are from where they started, so steps do not add up and the blocks keep their first names.
    /// </summary>
    public void StepFromStart(Action<TGraph> edit)
    {
        if (_transaction == null)
        {
            throw new InvalidOperationException("no entry is open");
        }
        Graph = ReadGraph(_transactionStart);
        edit(Graph);
        Changed?.Invoke();
    }

    public void Commit()
    {
        var label = _transaction ?? throw new InvalidOperationException("no entry is open");
        _transaction = null;
        // A drag that changed nothing leaves no entry, but its end is still news: Save can run again.
        if (!Push(label))
        {
            Changed?.Invoke();
        }
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

    // Adds an entry for the graph as it is now, unless it is the current entry's. Returns whether it added one.
    bool Push(string label)
    {
        _merge = null;
        var text = WriteGraph();
        if (text == _states[Position].Text)
        {
            return false;
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
        return true;
    }

    public void Undo()
    {
        _merge = null;
        if (CanUndo)
        {
            Position--;
            Load(_states[Position].Text);
            Changed?.Invoke();
        }
    }

    public void Redo()
    {
        _merge = null;
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

    /// <summary>Writes the graph to its file. Refused while an entry is open, whose steps can still be put back.</summary>
    public virtual void Save()
    {
        if (_transaction != null)
        {
            throw new InvalidOperationException($"\"{_transaction}\" is still open");
        }
        SceneDocument.WriteAtomically(Path, Text);
        SavedPosition = Position;
        _merge = null;
        Changed?.Invoke();
    }

    public void Move(string path)
    {
        Path = System.IO.Path.GetFullPath(path);
        Changed?.Invoke();
    }
}
