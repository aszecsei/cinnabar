using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Mesh;

/// <summary>
/// One mesh file that the editor edits (see docs/editor/mesh-editing.md#undo-and-saving): its path, its GUID, the
/// current <see cref="MeshData"/> and the snapshot that the file has. The scene's undo stack holds its edits, as
/// <see cref="MeshOperation"/>s, so the document keeps no history of its own. It is dirty when its data is not the
/// saved snapshot: an undo back to the saved snapshot makes it clean again, since snapshots are immutable and shared.
/// </summary>
public sealed class MeshDocument(string path, string guid, MeshData data, bool saved = true)
    : LiveSnapshotAsset<MeshData>(guid, path, data, saved ? new SavedSnapshot<MeshData>.At(data) : new SavedSnapshot<MeshData>.NoFile())
{
    public MeshData Data { get => Current; internal set => Current = value; }

    public string Title => System.IO.Path.GetFileName(Path);

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

    protected override byte[] Encode(MeshData snapshot) => Utf8Text.Encode(MeshFile.Write(snapshot));
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

    /// <summary>
    /// Sets a derived document's data, as a cut wall's (see docs/editor/mesh-editing.md#cut-meshes), with no undo
    /// entry: its inputs are on the stack, and an undo derives it again.
    /// </summary>
    public void Derive(string guid, MeshData data) => Set(guid, data);

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
public sealed record MeshOperation(string Guid, MeshData Before, MeshData After, MeshSet Meshes) : SnapshotOperation<MeshData>(Before, After)
{
    protected override void Restore(MeshData snapshot) => Meshes.Set(Guid, snapshot);

    public override bool IsReplacedBy(Operation later) => later is MeshOperation m && m.Guid == Guid;
}
