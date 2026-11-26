using Cinnabar.Editor.Content;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Model;
using AssetKind = Cinnabar.Editor.Link.Cook.AssetKind;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// What the cut set knows of a cut target (see docs/editor/mesh-editing.md#cut-meshes). A target that it has no state
/// for is Uncut. Each state that names a result has its GUID, which the target's <c>Mesh_Renderer</c> names.
/// </summary>
public abstract record CutState(string Result)
{
    /// <summary>The first cut named a new result, which is not derived yet. Its document holds the source until it is.</summary>
    public sealed record Made(string Result) : CutState(Result);

    /// <summary>The result is derived from the inputs of the hash.</summary>
    public sealed record Cut(string Result, string Hash) : CutState(Result);

    /// <summary>The inputs of the hash cannot be cut, for the reason. The result keeps the last good cut.</summary>
    public sealed record Refused(string Result, string Hash, string Reason) : CutState(Result);
}

/// <summary>
/// Derives each cut wall's mesh from its source and its cutters, for every open scene (see
/// docs/editor/mesh-editing.md#cut-meshes). The scene's fields that a cut sets join the edit that caused it, through
/// <see cref="SceneDocument.Derive"/>, so undo replays them, and the results are derived again from the scene after
/// every change. The results are documents of the mesh set, which draws them live and saves them with the scene.
/// </summary>
public sealed class CutSet
{
    enum Check
    {
        // The scene opened, and its results have not been compared with the inputs yet.
        Unchecked,
        Checked,
    }

    enum Flush
    {
        Idle,
        // A drag's step changed the scene, and a derive of its newest state is posted.
        Posted,
    }

    sealed class SceneCuts(Action<IReadOnlyList<Operation>> applied)
    {
        public readonly Action<IReadOnlyList<Operation>> Applied = applied;
        public readonly Dictionary<ulong, CutState> Targets = [];
        public Check Check = Check.Unchecked;
        public Flush Flush = Flush.Idle;
    }

    readonly EditorShell _shell;
    readonly Dictionary<SceneDocument, SceneCuts> _scenes = [];
    // The meshes read from files, with the time that each file was written.
    readonly Dictionary<string, (DateTime Written, MeshData? Mesh)> _files = [];

    internal CutSet(EditorShell shell, Action<Action> post)
    {
        _shell = shell;
        Post = post;
    }

    /// <summary>Posts a derive to the next frame, so that a drag derives once a frame, from its newest step. A test replaces it.</summary>
    internal Action<Action> Post { get; set; }

    /// <summary>A target's refusal came or went, which <see cref="ProblemsOf"/> shows.</summary>
    public event Action? ProblemsChanged;

    /// <summary>What the cut set knows of a target of an open scene, by its ID in the expanded scene, or null for Uncut.</summary>
    public CutState? StateOf(SceneDocument document, ulong id) =>
        _scenes.TryGetValue(document, out var cuts) ? cuts.Targets.GetValueOrDefault(id) : null;

    /// <summary>Why a target of an open scene cannot be cut, for Properties, or nothing.</summary>
    public IReadOnlyList<string> ProblemsOf(SceneDocument document, ulong id) =>
        StateOf(document, id) is CutState.Refused r ? [$"the cut is refused: {r.Reason}"] : [];

    /// <summary>
    /// Starts deriving the cuts of an open scene. Call it before the shell's own handlers subscribe, so that a result
    /// reaches the host before the field that names it.
    /// </summary>
    internal void Track(SceneDocument document)
    {
        if (document.IsPrefab || _scenes.ContainsKey(document))
        {
            return;
        }
        var cuts = new SceneCuts(_ => Applied(document));
        _scenes[document] = cuts;
        document.Derive = () => FieldOperations(document, cuts);
        document.Applied += cuts.Applied;
    }

    /// <summary>Stops deriving a scene's cuts, as it closes, and closes its results.</summary>
    internal void Untrack(SceneDocument document)
    {
        if (!_scenes.Remove(document, out var cuts))
        {
            return;
        }
        document.Derive = null;
        document.Applied -= cuts.Applied;
        foreach (var state in cuts.Targets.Values)
        {
            _shell.Mesh.CloseMesh(state.Result);
        }
        if (cuts.Targets.Values.Any(s => s is CutState.Refused))
        {
            ProblemsChanged?.Invoke();
        }
    }

    /// <summary>Derives a scene's results from its newest state now, as after a commit, an undo or before a save.</summary>
    internal void Derive(SceneDocument document)
    {
        if (!_scenes.TryGetValue(document, out var cuts))
        {
            return;
        }
        cuts.Flush = Flush.Idle;
        if (Plan(document) is not { } plan)
        {
            return;
        }
        var seen = new HashSet<ulong>();
        foreach (var inputs in plan)
        {
            seen.Add(inputs.Target.Id);
            Update(document, cuts, inputs);
        }
        foreach (var id in cuts.Targets.Keys.Where(id => !seen.Contains(id)).ToList())
        {
            Drop(cuts, id);
        }
    }

    /// <summary>
    /// Compares every open scene's cuts with their inputs, once its inputs are in the index: at its open, and when
    /// files change. A result that its inputs no longer give changes the scene, in an entry of its own, "Update Cuts",
    /// with a line in the console. A result that they give, and whose file is there, is kept as it is.
    /// </summary>
    internal void Reconcile()
    {
        foreach (var (document, cuts) in _scenes.ToList())
        {
            if (document.InTransaction || !_shell.IsEditing || _shell.OpenEdit != null || Plan(document) is not { } plan)
            {
                continue;
            }
            if (cuts.Check == Check.Unchecked)
            {
                // At the open, a result whose file the inputs gave is kept, without a cut.
                foreach (var inputs in plan)
                {
                    var e = inputs.Target;
                    var hash = inputs.Hash();
                    if (inputs.Cutters.Count > 0 && MeshCutters.SourceOf(e) != null && MeshCutters.RendererMesh(e) is { } result
                        && hash == MeshCutters.HashOf(e) && OnDisk(result) != null)
                    {
                        Change(cuts, e, new CutState.Cut(result, hash));
                    }
                }
                cuts.Check = Check.Checked;
            }
            var stale = plan.Select(inputs => (inputs.Target, Ops: FieldOperations(document, cuts, inputs))).Where(s => s.Ops.Count > 0).ToList();
            foreach (var (target, _) in stale)
            {
                _shell.Console.Add(LogLevel.Warning, $"cut: {Label(target)}: the cut is out of date, so the scene changes to cut it again");
            }
            if (stale.Count == 0 || !_shell.Edit(document, "Update Cuts", [.. stale.SelectMany(s => s.Ops)]))
            {
                Derive(document);
            }
        }
    }

    // A step of an edit, an undo, a redo or a cancel changed the scene. A drag's steps derive once a frame.
    void Applied(SceneDocument document)
    {
        if (!_scenes.TryGetValue(document, out var cuts))
        {
            return;
        }
        if (!document.InTransaction)
        {
            Derive(document);
            return;
        }
        if (cuts.Flush == Flush.Idle)
        {
            cuts.Flush = Flush.Posted;
            Post(() =>
            {
                if (_scenes.TryGetValue(document, out var now) && now == cuts && cuts.Flush == Flush.Posted)
                {
                    Derive(document);
                }
            });
        }
    }

    // The fields that the scene's edit derives, which join its entry: see SceneDocument.Derive.
    List<Operation> FieldOperations(SceneDocument document, SceneCuts cuts) =>
        Plan(document) is { } plan ? [.. plan.SelectMany(inputs => FieldOperations(document, cuts, inputs))] : [];

    // The fields of a target that differ from what its inputs give: its source, the mesh that its renderer names, the
    // hash and its cap slots' materials. A first cut makes a new result, and a target that nothing cuts goes back to its
    // source.
    List<Operation> FieldOperations(SceneDocument document, SceneCuts cuts, CutInputs inputs)
    {
        var e = inputs.Target;
        var ops = new List<Operation>();
        if (e.Components.Find(c => c.Id == SceneEdits.MeshRendererId) is not { } renderer)
        {
            return ops;
        }
        var source = MeshCutters.SourceOf(e);
        var mesh = MeshCutters.RendererMesh(e);
        if (inputs.Cutters.Count == 0)
        {
            if (source != null)
            {
                ops.Add(new SetField(e.Id, SceneEdits.MeshRendererId, "mesh", SceneValue.AssetRef(source)));
                ops.Add(new SetField(e.Id, SceneEdits.CutTargetId, "source", null));
            }
            if (MeshCutters.HashOf(e) != "")
            {
                ops.Add(new SetField(e.Id, SceneEdits.CutTargetId, "inputs_hash", null));
            }
            return ops;
        }
        if (MeshCuts.CapSlots(inputs).Slots is not { } slots)
        {
            // A refusal keeps the last good cut, and Derive says why.
            return ops;
        }
        if (source == null || mesh == null || mesh == source)
        {
            var result = Convert.ToHexStringLower(Guid.NewGuid().ToByteArray());
            Make(document, cuts, inputs, result);
            ops.Add(new SetField(e.Id, SceneEdits.CutTargetId, "source", SceneValue.AssetRef(inputs.Source)));
            ops.Add(new SetField(e.Id, SceneEdits.MeshRendererId, "mesh", SceneValue.AssetRef(result)));
        }
        var hash = inputs.Hash();
        if (MeshCutters.HashOf(e) != hash)
        {
            ops.Add(new SetField(e.Id, SceneEdits.CutTargetId, "inputs_hash", SceneValue.String(hash)));
        }
        for (var i = 0; i < slots.Count; i++)
        {
            var material = MeshCuts.CapMaterial(inputs.Cutters[i]);
            var field = $"materials.{slots[i]}";
            var drawn = renderer.Fields.Find(f => f.Name == field)?.Value is { Kind: SceneValueKind.Asset } v ? v.Asset : "";
            if (material != "" && drawn != material && !ops.Any(o => o is SetField { Field: var f } && f == field))
            {
                ops.Add(new SetField(e.Id, SceneEdits.MeshRendererId, field, SceneValue.AssetRef(material)));
            }
        }
        return ops;
    }

    // A first cut's result: a document of the source's mesh, which the host draws from the start, until the derive.
    void Make(SceneDocument document, SceneCuts cuts, CutInputs inputs, string result)
    {
        if (cuts.Targets.GetValueOrDefault(inputs.Target.Id) is { } old)
        {
            _shell.Mesh.CloseMesh(old.Result);
        }
        _shell.Mesh.Meshes.Add(new MeshDocument(ResultPath(document, inputs.Target, result), result, inputs.SourceMesh, saved: false));
        Change(cuts, inputs.Target, new CutState.Made(result));
    }

    // Derives a target's result, unless the cut set has it from the same inputs.
    void Update(SceneDocument document, SceneCuts cuts, CutInputs inputs)
    {
        var e = inputs.Target;
        if (inputs.Cutters.Count == 0 || MeshCutters.SourceOf(e) == null || MeshCutters.RendererMesh(e) is not { } result)
        {
            Drop(cuts, e.Id);
            return;
        }
        var hash = inputs.Hash();
        var state = cuts.Targets.GetValueOrDefault(e.Id);
        if (state is CutState.Cut c && c.Result == result && c.Hash == hash
            || state is CutState.Refused r && r.Result == result && r.Hash == hash)
        {
            return;
        }
        if (state != null && state.Result != result)
        {
            _shell.Mesh.CloseMesh(state.Result);
        }
        switch (MeshCuts.Derive(inputs))
        {
            case CutResult.Cut cut:
                Put(document, e, result, cut.Mesh);
                Change(cuts, e, new CutState.Cut(result, hash));
                break;
            case CutResult.Refused refused:
                Change(cuts, e, new CutState.Refused(result, hash, refused.Reason));
                break;
        }
    }

    // Sets a result's document to a mesh: the open one, or the file's when it holds that mesh, else a new one.
    void Put(SceneDocument document, SceneEntity target, string result, MeshData mesh)
    {
        var meshes = _shell.Mesh.Meshes;
        if (meshes.Find(result) is { } open)
        {
            if (!ReferenceEquals(open.Data, mesh))
            {
                meshes.Derive(result, mesh);
            }
            return;
        }
        var path = ResultPath(document, target, result);
        if (File.Exists(path) && MeshDocument.Open(path, result) is ({ } saved, _) && MeshFile.Write(saved.Data) == MeshFile.Write(mesh))
        {
            meshes.Add(saved);
            return;
        }
        meshes.Add(new MeshDocument(path, result, mesh, saved: false));
    }

    // The target no longer has a result: its document closes.
    void Drop(SceneCuts cuts, ulong id)
    {
        if (cuts.Targets.GetValueOrDefault(id) is not { } state)
        {
            return;
        }
        _shell.Mesh.CloseMesh(state.Result);
        var refused = state is CutState.Refused;
        cuts.Targets.Remove(id);
        if (refused)
        {
            ProblemsChanged?.Invoke();
        }
    }

    // The one writer of a target's state. A new refusal goes to the console and to Properties.
    void Change(SceneCuts cuts, SceneEntity target, CutState next)
    {
        var before = cuts.Targets.GetValueOrDefault(target.Id);
        cuts.Targets[target.Id] = next;
        if (next is CutState.Refused r && (before is not CutState.Refused b || b.Reason != r.Reason))
        {
            _shell.Console.Add(LogLevel.Warning, $"cut: cannot cut {Label(target)}: {r.Reason}");
        }
        if (before is CutState.Refused || next is CutState.Refused)
        {
            ProblemsChanged?.Invoke();
        }
    }

    // The scene's cut targets with their inputs, or null while an input is not in the index or the mesh set yet: a
    // prefab, a target's mesh or a cutter's mesh. Without them, a cut could not tell a cutter that is gone from one that
    // has not arrived, so nothing is derived until they are.
    IReadOnlyList<CutInputs>? Plan(SceneDocument document)
    {
        var expansion = document.Expanded;
        if (expansion.Problems.Any(p => p.Message.Contains("is missing or does not parse")))
        {
            return null;
        }
        foreach (var entity in expansion.Flat.Entities)
        {
            if (MeshCutters.TargetLayer(entity) != null && MeshCutters.EditableMesh(entity) is { } mesh && !Known(mesh))
            {
                return null;
            }
            if (entity.Components.Find(c => c.Id == SceneEdits.MeshCutterId) is { } cutter
                && CutterFields.Of(cutter) is { Shape: CutterShape.Mesh, Mesh.Length: > 0 } fields && !Known(fields.Mesh))
            {
                return null;
            }
        }
        return MeshCuts.Plan(expansion, MeshOf);
    }

    bool Known(string guid) => _shell.Mesh.Meshes.Find(guid) != null || _shell.Assets.Find(guid) != null;

    // A mesh file's mesh: its open document's, else its file's, read again when the file is written. Null for a model's
    // mesh, or one that does not parse.
    MeshData? MeshOf(string guid)
    {
        if (_shell.Mesh.Meshes.Find(guid) is { } open)
        {
            return open.Data;
        }
        if (OnDisk(guid) is not { } path)
        {
            return null;
        }
        var written = File.GetLastWriteTimeUtc(path);
        if (_files.TryGetValue(path, out var file) && file.Written == written)
        {
            return file.Mesh;
        }
        string text;
        try
        {
            text = File.ReadAllText(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
        var mesh = MeshFile.Parse(text).Mesh;
        _files[path] = (written, mesh);
        return mesh;
    }

    // The file of a mesh asset that the editor can read, or null.
    string? OnDisk(string guid) =>
        _shell.Assets.Find(guid) is { Kind: AssetKind.Mesh } asset && !AssetIndex.IsSubasset(asset)
            && _shell.Assets.FullPath(asset) is { } path && File.Exists(path) ? path : null;

    // A result's file: the index's, once it has one, else beside the scene, by the target's name and ID, so a redo
    // after an undo makes the same file.
    string ResultPath(SceneDocument document, SceneEntity target, string result)
    {
        if (_shell.Assets.Find(result) is { } asset && _shell.Assets.FullPath(asset) is { } indexed)
        {
            return indexed;
        }
        var directory = Path.Combine(Path.GetDirectoryName(document.Path)!, $"{Path.GetFileNameWithoutExtension(document.Path)}_meshes");
        var name = string.Concat(target.Name.Select(c => Path.GetInvalidFileNameChars().Contains(c) || c == ' ' ? '_' : c));
        return Path.Combine(directory, $"{(name.Length > 0 ? name + "_" : "")}{target.Id:x16}.cut{MeshFile.Extension}");
    }

    static string Label(SceneEntity e) => e.Name.Length > 0 ? e.Name : $"{e.Id:x16}";
}
