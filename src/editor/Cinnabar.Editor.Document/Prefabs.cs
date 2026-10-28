namespace Cinnabar.Editor.Document;

/// <summary>
/// One prefab that the open scene uses (see docs/editor/prefabs.md#the-editors-documents): its file, its GUID, its
/// scene as the file has it, with one root, and the text that the file has. The scene's undo stack holds its edits,
/// as a mesh document's are, so it keeps no history of its own.
/// </summary>
public sealed class PrefabDocument(string path, string guid, Scene scene, string? savedText)
{
    /// <summary>The file's full path.</summary>
    public string Path { get; private set; } = System.IO.Path.GetFullPath(path);

    /// <summary>The asset's GUID, as 32 lowercase hex digits.</summary>
    public string Guid { get; } = guid;

    public Scene Scene { get; internal set; } = scene;

    /// <summary>The text that the file has, or null for a prefab that has no file yet, as one that Make Prefab made.</summary>
    public string? SavedText { get; private set; } = savedText;

    /// <summary>
    /// The file's scene when the file no longer has the text that the document was read from or saved with, as after
    /// an edit in another editor or a pull, and null when it has, or it cannot be read or parsed.
    /// </summary>
    public Scene? Changed()
    {
        try
        {
            var text = File.ReadAllText(Path);
            if (SceneFile.Parse(text).Scene is not { } scene || SceneFile.Write(scene) == SavedText)
            {
                return null;
            }
            return scene;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>The scene that <see cref="Changed"/> read is the file's: the document takes it, clean.</summary>
    internal void Reloaded(Scene scene)
    {
        Scene = scene;
        SavedText = SceneFile.Write(scene);
    }

    public string Title => System.IO.Path.GetFileName(Path);

    public bool IsDirty => SavedText != SceneFile.Write(Scene);

    /// <summary>Reads and parses a prefab file. The document is null when the file cannot be read or has an error.</summary>
    public static (PrefabDocument? Document, IReadOnlyList<SceneProblem> Problems) Open(string path, string guid)
    {
        string text;
        try
        {
            text = File.ReadAllText(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return (null, [new SceneProblem(0, e.Message, true)]);
        }
        var (scene, problems) = SceneFile.Parse(text);
        return (scene == null ? null : new PrefabDocument(path, guid, scene, SceneFile.Write(scene)), problems);
    }

    /// <summary>
    /// Writes the prefab to its file, through a temporary file, and a new prefab's <c>.meta</c> file with its GUID, so
    /// the scene's reference to it resolves at the cook daemon's next pass.
    /// </summary>
    public void Save()
    {
        var text = SceneFile.Write(Scene);
        var meta = Path + ".meta";
        if (!File.Exists(meta))
        {
            SceneDocument.WriteAtomically(meta, $"guid = {Guid}\n");
        }
        SceneDocument.WriteAtomically(Path, text);
        SavedText = text;
    }

    /// <summary>The prefab's file moved, as when the content browser moves or renames it. Nothing is written.</summary>
    public void Move(string path) => Path = System.IO.Path.GetFullPath(path);
}

/// <summary>
/// The prefabs of the open scene, by GUID: each one that it instantiates at any depth, opened from its file when an
/// expansion first asks for it, and each one that an edit made. The set closes with the scene.
/// </summary>
public sealed class PrefabSet(Func<string, PrefabDocument?> open)
{
    readonly Dictionary<string, PrefabDocument> _documents = [];

    public IReadOnlyCollection<PrefabDocument> Documents => _documents.Values;

    public bool AnyDirty => _documents.Values.Any(d => d.IsDirty);

    /// <summary>A prefab joined or left the set, or its scene changed, so the expansion is out of date.</summary>
    public event Action? Changed;

    /// <summary>The prefab with a GUID, opened from its file if the set does not have it yet, or null for none.</summary>
    public PrefabDocument? Find(string guid)
    {
        if (_documents.TryGetValue(guid, out var document))
        {
            return document;
        }
        // A prefab that cannot be opened is asked for again at the next expansion, since the index may not have it yet.
        if (open(guid) is not { } opened)
        {
            return null;
        }
        _documents[guid] = opened;
        return opened;
    }

    /// <summary>The scene of a prefab, for an expansion.</summary>
    public Scene? SceneOf(string guid) => Find(guid)?.Scene;

    public void Add(PrefabDocument document)
    {
        _documents[document.Guid] = document;
        Changed?.Invoke();
    }

    public bool Remove(string guid)
    {
        if (!_documents.Remove(guid))
        {
            return false;
        }
        Changed?.Invoke();
        return true;
    }

    /// <summary>
    /// Reads again the prefabs that are clean and whose files changed, and returns them. A dirty prefab whose file changed
    /// keeps the editor's version, and comes back in <paramref name="kept"/>.
    /// </summary>
    public IReadOnlyList<PrefabDocument> ReloadChanged(List<PrefabDocument> kept)
    {
        var reloaded = new List<PrefabDocument>();
        foreach (var document in _documents.Values.Where(d => d.SavedText != null))
        {
            if (document.Changed() is not { } scene)
            {
                continue;
            }
            if (document.IsDirty)
            {
                kept.Add(document);
                continue;
            }
            document.Reloaded(scene);
            reloaded.Add(document);
        }
        if (reloaded.Count > 0)
        {
            Changed?.Invoke();
        }
        return reloaded;
    }

    /// <summary>Gives a prefab's document another scene, as an edit of the prefab, its undo, or a reload does.</summary>
    public void SetScene(string guid, Scene scene)
    {
        var document = Find(guid) ?? throw new InvalidOperationException($"no prefab {guid} is open");
        document.Scene = scene;
        Changed?.Invoke();
    }

    /// <summary>Forgets the prefabs that are not dirty, so the next expansion reads their files again.</summary>
    public void Reload()
    {
        foreach (var guid in _documents.Where(d => !d.Value.IsDirty).Select(d => d.Key).ToList())
        {
            _documents.Remove(guid);
        }
        Changed?.Invoke();
    }
}

/// <summary>
/// An edit of a prefab in the scene's set, as Apply makes, on the scene's undo stack: it gives the prefab's document
/// a snapshot of its scene, and its inverse the one before. The scenes are never changed after, so the snapshots stay
/// as they are. Its wire form is the difference that it makes to the scene's expansion: every instance follows the
/// prefab. Steps on one prefab replace each other.
/// </summary>
public sealed record PrefabOperation(SceneDocument Document, string Guid, Scene Before, Scene After) : Operation(0)
{
    IReadOnlyList<Link.Protocol.Operation> _wires = [];

    public override Operation Apply(Scene scene)
    {
        var before = Document.Expanded.Flat.Entities.ToList();
        Document.Prefabs.SetScene(Guid, After);
        _wires = PrefabExpansion.Diff(before, Document.Expanded.Flat.Entities);
        return new PrefabOperation(Document, Guid, After, Before);
    }

    public override Link.Protocol.Operation? ToWire() => null;

    public override IReadOnlyList<Link.Protocol.Operation> ToWires() => _wires;

    public override bool IsReplacedBy(Operation later) => later is PrefabOperation p && p.Guid == Guid;
}

/// <summary>
/// Adds a prefab document to the scene's set, as Make Prefab does, or with null, takes one out: its inverse does the
/// other. It has nothing for the host's world.
/// </summary>
public sealed record PrefabSetOperation(PrefabSet Prefabs, string Guid, PrefabDocument? Added) : Operation(0)
{
    public override Operation Apply(Scene scene)
    {
        var old = Prefabs.Documents.FirstOrDefault(d => d.Guid == Guid);
        if (Added != null)
        {
            Prefabs.Add(Added);
        }
        else
        {
            Prefabs.Remove(Guid);
        }
        return this with { Added = old };
    }

    public override Link.Protocol.Operation? ToWire() => null;
}
