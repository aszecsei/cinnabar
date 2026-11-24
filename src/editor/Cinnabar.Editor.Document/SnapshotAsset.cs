namespace Cinnabar.Editor.Document;

/// <summary>What an asset's file has: no file yet, as for an asset that an edit made, or one snapshot.</summary>
public abstract record SavedSnapshot<T>
{
    SavedSnapshot() { }

    /// <summary>The asset has no file yet. Its first save writes a new <c>.meta</c> file beside it.</summary>
    public sealed record NoFile : SavedSnapshot<T>;

    /// <summary>The file has this snapshot.</summary>
    public sealed record At(T Value) : SavedSnapshot<T>;
}

/// <summary>An asset on the scene's undo stack as snapshots, as the shell saves it: whatever its snapshot is.</summary>
public interface ISnapshotAsset
{
    string Guid { get; }

    string Path { get; }

    bool IsDirty { get; }

    void Save();
}

/// <summary>
/// An asset whose edits are snapshots on the scene's undo stack (see docs/editor/document-and-scenes.md#document-model):
/// a prefab, a mesh, a foliage set or a landscape map. It has a GUID, a file, the current snapshot and what the file
/// has, and it is dirty while the current snapshot is not the saved one, so an undo back to the saved snapshot makes it
/// clean again. Each kind says how a snapshot is written and what a new file's <c>.meta</c> has.
/// </summary>
public abstract class SnapshotAsset<TSnapshot>(string guid, string path, TSnapshot current, SavedSnapshot<TSnapshot> saved) : ISnapshotAsset
{
    /// <summary>The asset's GUID, as 32 lowercase hex digits.</summary>
    public string Guid { get; } = guid;

    /// <summary>The file's full path.</summary>
    public string Path { get; private set; } = System.IO.Path.GetFullPath(path);

    public TSnapshot Current { get; protected set; } = current;

    public SavedSnapshot<TSnapshot> Saved { get; private set; } = saved;

    public bool IsDirty => Saved is not SavedSnapshot<TSnapshot>.At(var s) || !IsSame(Current, s);

    /// <summary>The snapshot as the file's bytes.</summary>
    protected abstract byte[] Encode(TSnapshot snapshot);

    /// <summary>The <c>.meta</c> file that the asset's first save writes, so the scene's reference resolves at the daemon's next pass.</summary>
    protected virtual MetaFile.Builder NewMeta() => MetaFile.New(Guid);

    /// <summary>Whether two snapshots are the same: the same object, or for a value, an equal one.</summary>
    protected virtual bool IsSame(TSnapshot current, TSnapshot saved) => EqualityComparer<TSnapshot>.Default.Equals(current, saved);

    /// <summary>
    /// Writes the current snapshot to the file, through a temporary file, and before it, for an asset with no file yet, a
    /// new <c>.meta</c> file unless one is there. The daemon owns the <c>.meta</c> file from then on. The file has the
    /// snapshot only once both are written.
    /// </summary>
    public void Save()
    {
        var snapshot = Current;
        var meta = Path + MetaFile.Extension;
        if (Saved is SavedSnapshot<TSnapshot>.NoFile && !File.Exists(meta))
        {
            AtomicFile.Write(meta, NewMeta().Text());
        }
        AtomicFile.Write(Path, Encode(snapshot));
        Saved = new SavedSnapshot<TSnapshot>.At(snapshot);
    }

    /// <summary>The file has a snapshot that the asset did not write, as one read again after a change on disk: the asset takes it, clean.</summary>
    protected internal void Reloaded(TSnapshot snapshot)
    {
        Current = snapshot;
        Saved = new SavedSnapshot<TSnapshot>.At(snapshot);
    }

    /// <summary>The asset's file moved, as when the content browser moves or renames it. Nothing is written.</summary>
    public void Move(string path) => Path = System.IO.Path.GetFullPath(path);
}

/// <summary>A snapshot asset that the host can draw from the editor's copy: a mesh, a foliage set or a landscape map.</summary>
public interface ILiveAsset : ISnapshotAsset
{
    bool IsLive { get; }
}

/// <summary>
/// A snapshot asset that the host draws from the editor's copy while it is live: sent whole, and not released. The
/// session that sends it marks it, and releases it once it is saved and its cooked blob is current, so the host draws
/// the blob until the next edit.
/// </summary>
public abstract class LiveSnapshotAsset<TSnapshot>(string guid, string path, TSnapshot current, SavedSnapshot<TSnapshot> saved)
    : SnapshotAsset<TSnapshot>(guid, path, current, saved), ILiveAsset
{
    public bool IsLive { get; private set; }

    /// <summary>The host was sent the whole asset, and draws it from the editor's copy.</summary>
    public void Sent() => IsLive = true;

    /// <summary>Whether the asset was live and is now released, so the host is told once.</summary>
    public bool Release()
    {
        if (!IsLive)
        {
            return false;
        }
        IsLive = false;
        return true;
    }
}

/// <summary>
/// An edit of a snapshot asset on the scene's undo stack: it gives the asset the snapshot after, and its inverse the one
/// before. Snapshots are never changed after they are made, so the operation keeps them as they are. It has nothing
/// for the host's world: the shell sends the asset itself.
/// </summary>
public abstract record SnapshotOperation<TSnapshot>(TSnapshot Before, TSnapshot After) : Operation(0)
{
    /// <summary>Gives the asset a snapshot.</summary>
    protected abstract void Restore(TSnapshot snapshot);

    public override Operation Apply(Scene scene)
    {
        Restore(After);
        return this with { Before = After, After = Before };
    }

    public override Link.Protocol.Operation? ToWire() => null;
}
