using Cinnabar.Editor.Document;
using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using AssetKind = Cinnabar.Editor.Link.Cook.AssetKind;
using AssetStatus = Cinnabar.Editor.Link.Cook.AssetStatus;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The mesh files that the editor edits (see docs/editor/mesh-editing.md#live-meshes): opening one beside the scene,
/// sending it to the host as a live mesh, which draws it from memory in place of its cooked blob, saving it with the
/// scene, and letting go of it once the daemon has cooked the saved file.
/// </summary>
public sealed partial class EditorShell
{
    /// <summary>The open mesh documents of the scene, by GUID.</summary>
    public MeshSet Meshes { get; } = new();

    /// <summary>A mesh document opened, closed, changed or changed its dirty state.</summary>
    public event Action? MeshesChanged;

    void WireMeshes()
    {
        Meshes.Changed += OnMeshChanged;
        // A mesh the editor made draws live from the start; one whose creation is undone is let go of.
        Meshes.Added += document =>
        {
            if (!document.IsLive)
            {
                SendLiveMesh(document);
            }
            MeshesChanged?.Invoke();
        };
        Meshes.Removed += document =>
        {
            ReleaseLiveMesh(document);
            _editedMeshes.Remove(document.Guid);
            if (InMeshMode)
            {
                SetMeshSelection(MeshSelection.Pruned(FindMeshData));
            }
            MeshesChanged?.Invoke();
        };
        // A saved mesh is let go of once its cooked blob is current, so the host draws the blob with its levels of
        // detail. A mesh that is dirty, or whose cook failed, stays live.
        Cook.Cooked += _ => ReleaseCookedMeshes();
    }

    /// <summary>
    /// Opens a mesh asset's file as a document, or finds the open one, and sends it to the host as a live mesh. A glTF
    /// mesh cannot be edited, and a file with an error is not opened: the console says so.
    /// </summary>
    public MeshDocument? OpenMesh(string guid)
    {
        if (Meshes.Find(guid) is { } open)
        {
            return open;
        }
        if (Assets.Find(guid) is not { Kind: AssetKind.Mesh } asset)
        {
            Console.Add(LogLevel.Error, $"mesh: no mesh asset has the GUID {guid}");
            return null;
        }
        if (Content.AssetIndex.IsSubasset(asset))
        {
            Console.Add(LogLevel.Error, $"mesh: {asset.Subasset} is a mesh of {asset.Path}, a model, which cannot be edited. Build level geometry as a .mesh file.");
            return null;
        }
        if (Assets.FullPath(asset) is not { } path)
        {
            return null;
        }
        var (document, problems) = MeshDocument.Open(path, guid);
        Report("mesh", path, problems.Select(p => (p.Line, p.Message, p.IsError)));
        if (document == null)
        {
            Console.Add(LogLevel.Error, $"mesh: cannot open {path}");
            return null;
        }
        Meshes.Add(document);
        return document;
    }

    /// <summary>Closes a mesh document, and lets the host draw its cooked blob. Unsaved changes are lost.</summary>
    public void CloseMesh(string guid)
    {
        if (Meshes.Find(guid) is not { } document)
        {
            return;
        }
        ReleaseLiveMesh(document);
        Meshes.Remove(guid);
        MeshesChanged?.Invoke();
    }

    /// <summary>Applies a tool's result to an open mesh as one undo entry on the scene's stack, labelled for the history.</summary>
    public bool EditMesh(string label, string guid, MeshData after)
    {
        if (Meshes.Find(guid) is not { } document)
        {
            Console.Add(LogLevel.Error, $"edit: cannot {label.ToLowerInvariant()}: the mesh {guid} is not open");
            return false;
        }
        var problems = after.Validate();
        if (problems.Count > 0)
        {
            Console.Add(LogLevel.Error, $"edit: cannot {label.ToLowerInvariant()}: {string.Join("; ", problems)}");
            return false;
        }
        return Edit(label, new MeshOperation(guid, document.Data, after, Meshes));
    }

    /// <summary>Saves every dirty mesh document, through temporary files. A failure goes to the console.</summary>
    public bool SaveMeshes()
    {
        var ok = true;
        foreach (var document in Meshes.Documents.Where(d => d.IsDirty).ToList())
        {
            try
            {
                // A new mesh's .meta file, with its GUID, is the editor's to write, so the scene's reference resolves
                // at the daemon's next pass. The daemon owns it from then on.
                var meta = document.Path + ".meta";
                if (document.Saved == null && !File.Exists(meta))
                {
                    SceneDocument.WriteAtomically(meta, "# cinnabar asset metadata. Keep this file next to its asset (see docs/content/identity-and-cooking.md#identity).\n" + $"guid = {document.Guid}\n");
                }
                document.Save();
                Console.Add(LogLevel.Info, $"mesh: saved {document.Path}");
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                Console.Add(LogLevel.Error, $"mesh: cannot save {document.Path}: {e.Message}");
                ok = false;
            }
        }
        MeshesChanged?.Invoke();
        return ok;
    }

    /// <summary>Sends every live mesh again, as after a resync or a soft restart, which lose the host's copies.</summary>
    void SendLiveMeshes()
    {
        foreach (var document in Meshes.Documents.Where(d => d.IsLive))
        {
            Host.Send(LiveMeshes.Mesh(document.Guid, document.Data));
        }
    }

    void SendLiveMesh(MeshDocument document)
    {
        document.IsLive = true;
        Host.Send(LiveMeshes.Mesh(document.Guid, document.Data));
    }

    void ReleaseLiveMesh(MeshDocument document)
    {
        if (!document.IsLive)
        {
            return;
        }
        document.IsLive = false;
        Host.Send(LiveMeshes.Release(document.Guid));
    }

    // An edit, an undo or a redo changed a mesh: the host gets the positions for a change that moved vertices only,
    // and the whole mesh otherwise. A change of the topology can leave the sub-selection with indices the mesh no
    // longer has.
    void OnMeshChanged(MeshDocument document, MeshData before)
    {
        if (document.IsLive && LiveMeshes.IsVerticesOnly(before, document.Data))
        {
            Host.Send(LiveMeshes.Vertices(document.Guid, document.Data));
        }
        else
        {
            SendLiveMesh(document);
            if (InMeshMode && _meshDrag == null)
            {
                MeshSelection = MeshSelection.Pruned(FindMeshData);
            }
        }
        if (InMeshMode)
        {
            ResendMeshOverlay();
        }
        MeshesChanged?.Invoke();
    }

    void ReleaseCookedMeshes()
    {
        foreach (var document in Meshes.Documents)
        {
            if (document.IsLive && !document.IsDirty && Assets.Find(document.Guid) is { Status: AssetStatus.Current })
            {
                ReleaseLiveMesh(document);
            }
        }
    }

    // The scene's mesh documents close with it.
    void CloseMeshes()
    {
        LeaveMeshMode();
        foreach (var document in Meshes.Documents.ToList())
        {
            ReleaseLiveMesh(document);
        }
        Meshes.Clear();
        MeshesChanged?.Invoke();
    }
}
