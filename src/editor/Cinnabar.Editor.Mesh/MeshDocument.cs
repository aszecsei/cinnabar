using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Mesh;

/// <summary>
/// One mesh file that the editor edits (see docs/editor/mesh-editing.md#undo-and-saving): its path, its GUID, the
/// current <see cref="MeshData"/> and the snapshot that the file has. The scene's undo stack holds its edits, as
/// <see cref="MeshOperation"/>s, so the document keeps no history of its own. It is dirty when its data is not the
/// saved snapshot: an undo back to the saved snapshot makes it clean again, since snapshots are immutable and shared.
/// </summary>
public sealed class MeshDocument
{
    public MeshDocument(string path, string guid, MeshData data, bool saved = true)
    {
        Path = System.IO.Path.GetFullPath(path);
        Guid = guid;
        Data = data;
        Saved = saved ? data : null;
    }

    /// <summary>The file's full path.</summary>
    public string Path { get; private set; }

    /// <summary>The asset's GUID, as 32 lowercase hex digits.</summary>
    public string Guid { get; }

    public MeshData Data { get; internal set; }

    /// <summary>The snapshot that the file has, or null for a mesh whose file has none of the data, such as a new mesh.</summary>
    public MeshData? Saved { get; private set; }

    public string Title => System.IO.Path.GetFileName(Path);

    public bool IsDirty => !ReferenceEquals(Data, Saved);

    /// <summary>
    /// The host draws the mesh from the editor's data: it was sent as a live mesh and not let go of. A mesh that is
    /// saved and cooked is let go of, and drawn from its blob, until the next edit.
    /// </summary>
    public bool IsLive { get; set; }

    /// <summary>Reads and parses a mesh file. The document is null when the file cannot be read or has an error.</summary>
    public static (MeshDocument? Document, IReadOnlyList<MeshFileProblem> Problems) Open(string path, string guid)
    {
        string text;
        try
        {
            text = File.ReadAllText(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return (null, [new MeshFileProblem(0, e.Message, true)]);
        }
        var (mesh, problems) = MeshFile.Parse(text);
        return (mesh == null ? null : new MeshDocument(path, guid, mesh), problems);
    }

    /// <summary>Writes the mesh to its file, through a temporary file, and the data becomes the saved snapshot.</summary>
    public void Save()
    {
        SceneDocument.WriteAtomically(Path, MeshFile.Write(Data));
        Saved = Data;
    }

    /// <summary>The mesh's file moved, as when the content browser moves or renames it. Nothing is written.</summary>
    public void Move(string path) => Path = System.IO.Path.GetFullPath(path);
}

/// <summary>
/// The open mesh documents of the scene, by GUID (see docs/editor/mesh-editing.md#undo-and-saving). One opens when
/// its mesh is edited, and the set closes with the scene. Edits reach it only through <see cref="MeshOperation"/>s
/// on the scene's undo stack.
/// </summary>
public sealed class MeshSet
{
    readonly Dictionary<string, MeshDocument> _documents = [];

    public IReadOnlyCollection<MeshDocument> Documents => _documents.Values;

    public int Count => _documents.Count;

    public bool AnyDirty => _documents.Values.Any(d => d.IsDirty);

    /// <summary>A document's data changed: by an edit, an undo or a redo, with the data before it.</summary>
    public event Action<MeshDocument, MeshData>? Changed;

    /// <summary>A document joined the set, as a new mesh does, or an undone removal.</summary>
    public event Action<MeshDocument>? Added;

    /// <summary>A document left the set, as an undone creation does.</summary>
    public event Action<MeshDocument>? Removed;

    public MeshDocument? Find(string guid) => _documents.GetValueOrDefault(guid);

    public void Add(MeshDocument document)
    {
        _documents[document.Guid] = document;
        Added?.Invoke(document);
    }

    public bool Remove(string guid)
    {
        if (!_documents.Remove(guid, out var document))
        {
            return false;
        }
        Removed?.Invoke(document);
        return true;
    }

    public void Clear() => _documents.Clear();

    internal void Set(string guid, MeshData data)
    {
        var document = _documents.GetValueOrDefault(guid) ?? throw new InvalidOperationException($"no mesh {guid} is open");
        var before = document.Data;
        document.Data = data;
        Changed?.Invoke(document, before);
    }
}

/// <summary>
/// An edit of a mesh document, on the scene's undo stack beside the scene's operations: it sets the document's data
/// to a snapshot, and its inverse sets it back. A drag's step replaces the step before it of the same mesh, so an
/// entry keeps the first snapshot before and the last after. It has nothing for the host's world: the shell sends
/// the mesh itself as a live mesh instead.
/// </summary>
public sealed record MeshOperation(string Guid, MeshData Before, MeshData After, MeshSet Meshes) : Operation(0)
{
    public override Operation Apply(Scene scene)
    {
        Meshes.Set(Guid, After);
        return this with { Before = After, After = Before };
    }

    public override Link.Protocol.Operation? ToWire() => null;

    public override bool IsReplacedBy(Operation later) => later is MeshOperation m && m.Guid == Guid;
}
