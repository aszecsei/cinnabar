using Cinnabar.Editor.Content;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Mesh;
using Cinnabar.Editor.Model;
using AssetKind = Cinnabar.Editor.Link.Cook.AssetKind;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// What the cut set knows of a cut target (see docs/editor/mesh-editing.md#cut-meshes). A target that it has no state
/// for is Uncut. A state that names a result has its GUID, which the target's <c>Mesh_Renderer</c> names. A state with
/// a collision result, which only the cutters that cut collision cut, has its GUID too, which the target's
/// <c>Collider</c> names.
/// </summary>
public abstract record CutState(string? Result, string? Collision)
{
    /// <summary>A cut named a new result or collision result, which is not derived yet. Its document holds the source until it is.</summary>
    public sealed record Made(string Result, string? Collision) : CutState(Result, Collision);

    /// <summary>The result is derived from the inputs of the hash, and maps back onto its source by the map.</summary>
    public sealed record Cut(string Result, uint Hash, string? Collision, CutMap Map) : CutState(Result, Collision);

    /// <summary>
    /// The inputs of the hash cannot be cut, for the reason. The result keeps the last good cut, or the source when there
    /// was none. A first cut that is refused before it names a result, for a ninth material, has none.
    /// </summary>
    public sealed record Refused(string? Result, uint Hash, string Reason, string? Collision) : CutState(Result, Collision);
}

/// <summary>
/// Derives each cut wall's mesh from its source and its cutters, for every open scene (see
/// docs/editor/mesh-editing.md#cut-meshes). The scene's fields that a cut sets join the edit that caused it, through
/// <see cref="SceneDocument.Derive"/>, so undo replays them, and the results are derived again from the scene after
/// every change. The results are documents of the mesh set, which draws them live and saves them with the scene.
/// </summary>
public sealed class CutSet
{

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
        public Flush Flush = Flush.Idle;
        // The collision results that this scene's cuts named, which a collider names again after an undo and a redo.
        public readonly HashSet<string> Collisions = [];
        // What each entity's cut or cutter warns of, derived with the cuts: a collider that ignores them, or one that
        // plugs a cutter's opening.
        public Dictionary<ulong, IReadOnlyList<string>> Warnings = [];
    }

    const string CollisionSuffix = ".collision.cut" + MeshFile.Extension;

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

    /// <summary>A target's refusal or an entity's warning came or went, which <see cref="ProblemsOf"/> shows.</summary>
    public event Action? ProblemsChanged;

    /// <summary>What the cut set knows of a target of an open scene, by its ID in the expanded scene, or null for Uncut.</summary>
    public CutState? StateOf(SceneDocument document, ulong id) =>
        _scenes.TryGetValue(document, out var cuts) ? cuts.Targets.GetValueOrDefault(id) : null;

    /// <summary>Why a target of an open scene cannot be cut, and what its cut or its cutter warns of, for Properties, or nothing.</summary>
    public IReadOnlyList<string> ProblemsOf(SceneDocument document, ulong id)
    {
        var problems = new List<string>();
        if (StateOf(document, id) is CutState.Refused r)
        {
            problems.Add($"the cut is refused: {r.Reason}");
        }
        if (_scenes.TryGetValue(document, out var cuts) && cuts.Warnings.TryGetValue(id, out var warnings))
        {
            problems.AddRange(warnings);
        }
        return problems;
    }

    /// <summary>
    /// The result that a cut target draws and the map of it onto its source, for mesh mode, while the map's indices are
    /// the source's: the target is cut, and its source has the faces it had, as while a drag moves its vertices before
    /// the next derive, or the same mesh read again, as when mesh mode opens it. Null otherwise, as for a refused cut or an edit of the topology that is not derived yet, when
    /// mesh mode draws the source.
    /// </summary>
    public (string Result, CutMap Map)? MapOf(SceneDocument document, ulong id) =>
        StateOf(document, id) is CutState.Cut cut && document.Expanded.Flat.Find(id) is { } target
            && MeshCutters.SourceOf(target) is { } source && MeshOf(source) is { } now
            && (ReferenceEquals(now, cut.Map.Source) || now.Faces == cut.Map.Source.Faces || CutInputs.Text(now) == CutInputs.Text(cut.Map.Source))
            ? (cut.Result!, cut.Map) : null;

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
            Close(state.Result);
            Close(state.Collision);
        }
        if (cuts.Targets.Values.Any(s => s is CutState.Refused) || cuts.Warnings.Count > 0)
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
        Warn(document, cuts, plan);
    }

    /// <summary>
    /// Compares every open scene's cuts with their inputs, once its inputs are in the index: at its open, and when
    /// files change. Fields that the inputs no longer give change the scene, in an entry of its own, "Update Cuts", with
    /// a line in the console. Then each result is derived, and one that its file already holds is left to the file.
    /// </summary>
    internal void Reconcile()
    {
        foreach (var (document, cuts) in _scenes.ToList())
        {
            if (document.InTransaction || !_shell.IsEditing || _shell.OpenEdit != null || Plan(document) is not { } plan)
            {
                continue;
            }
            var stale = TargetOperations(document, cuts, plan).Where(s => s.Ops.Count > 0).ToList();
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

    // What the scene's cuts and cutters warn of: a target's collider that keeps its primitive since no cutter of it cuts
    // collision, and a cutter's own static collider in its opening, which physics and the navmesh bake keep solid.
    void Warn(SceneDocument document, SceneCuts cuts, IReadOnlyList<CutInputs> plan)
    {
        var warnings = new Dictionary<ulong, IReadOnlyList<string>>();
        void Add(ulong id, string warning) => warnings[id] = [.. warnings.GetValueOrDefault(id) ?? [], warning];
        foreach (var inputs in plan)
        {
            if (inputs.Cutters.Count > 0 && MeshCuts.CollisionOf(inputs) == CollisionCut.Source
                && inputs.Target.Components.Find(c => c.Id == SceneEdits.ColliderId) is { } collider
                && MeshCutters.ColliderShape(collider) is var shape && shape != "Mesh")
            {
                Add(inputs.Target.Id, $"the {shape.Replace('_', ' ').ToLowerInvariant()} ignores the cut, since no cutter of it has cuts_collision set");
            }
        }
        var expansion = document.Expanded;
        foreach (var cutter in expansion.Flat.Entities.Where(e => e.Components.Any(c => c.Id == SceneEdits.MeshCutterId)))
        {
            foreach (var plug in MeshCutters.Plugs(expansion, cutter, MeshOf))
            {
                Add(cutter.Id, $"the static collider of {Label(plug)} plugs the opening for physics and the navmesh: give it a Kinematic Rigid_Body");
            }
        }
        var same = warnings.Count == cuts.Warnings.Count
            && warnings.All(w => cuts.Warnings.TryGetValue(w.Key, out var was) && was.SequenceEqual(w.Value));
        cuts.Warnings = warnings;
        if (!same)
        {
            ProblemsChanged?.Invoke();
        }
    }

    // The fields that the scene's edit derives, which join its entry: see SceneDocument.Derive.
    List<Operation> FieldOperations(SceneDocument document, SceneCuts cuts) =>
        Plan(document) is { } plan ? [.. TargetOperations(document, cuts, plan).SelectMany(t => t.Ops)] : [];

    // Each target's field operations, in the scene's order. A result belongs to one target: a target whose result
    // another one owns, as a duplicated wall's does, cuts as for the first time, with a result of its own. So does a
    // collision result.
    List<(SceneEntity Target, List<Operation> Ops)> TargetOperations(SceneDocument document, SceneCuts cuts, IReadOnlyList<CutInputs> plan)
    {
        var claimed = new HashSet<string>();
        var result = new List<(SceneEntity, List<Operation>)>();
        foreach (var inputs in plan)
        {
            var id = inputs.Target.Id;
            var own = ResultOf(inputs.Target) is { } r && !OwnedElsewhere(document, id, r) && claimed.Add(r);
            var collision = CollisionOf(cuts, inputs.Target) is { } c && !OwnedElsewhere(document, id, c) && claimed.Add(c) ? c : null;
            result.Add((inputs.Target, FieldOperations(document, cuts, inputs, own, collision)));
        }
        return result;
    }

    // Whether a target of another scene, or another target of this one, has the result or collision result.
    bool OwnedElsewhere(SceneDocument document, ulong id, string result) =>
        _scenes.Any(s => s.Value.Targets.Any(t => (t.Value.Result == result || t.Value.Collision == result) && (s.Key != document || t.Key != id)));

    /// <summary>
    /// The result that a cut target's fields name: what its <c>Mesh_Renderer</c> names while its <c>Cut_Target</c> has a
    /// source that differs from it. Null for a target that its fields do not say is cut.
    /// </summary>
    static string? ResultOf(SceneEntity target) =>
        MeshCutters.SourceOf(target) is { } source && MeshCutters.RendererMesh(target) is { } mesh && mesh != source ? mesh : null;

    // The collision result that a target's Collider names: a mesh that a cut of this scene named, or whose file is a
    // collision result's, and not the source or the render result. Null for a collider that names anything else, such
    // as a collision mesh of the designer's own, which a cut never writes into.
    string? CollisionOf(SceneCuts cuts, SceneEntity target)
    {
        if (target.Components.Find(c => c.Id == SceneEdits.ColliderId) is not { } collider
            || MeshCutters.ColliderMesh(collider) is not { } guid
            || guid == MeshCutters.SourceOf(target) || guid == ResultOf(target))
        {
            return null;
        }
        return cuts.Collisions.Contains(guid)
            || _shell.Assets.Find(guid) is { } asset && _shell.Assets.FullPath(asset) is { } path
                && path.EndsWith(CollisionSuffix, StringComparison.OrdinalIgnoreCase)
            ? guid : null;
    }

    // The fields of a target that differ from what its inputs give: its source, the mesh that its renderer names, the
    // hash, its cap slots' materials and its collider. A first cut makes a new result, and a target that nothing cuts
    // goes back to its source. A collider follows the cutters that cut collision: the source with none, the render
    // result with all of them, else a collision result of its own, which is new the first time. A cut that the
    // collider follows makes it a Mesh.
    List<Operation> FieldOperations(SceneDocument document, SceneCuts cuts, CutInputs inputs, bool owned, string? collision)
    {
        var e = inputs.Target;
        var ops = new List<Operation>();
        if (e.Components.Find(c => c.Id == SceneEdits.MeshRendererId) is not { } renderer)
        {
            return ops;
        }
        var source = MeshCutters.SourceOf(e);
        var collider = e.Components.Find(c => c.Id == SceneEdits.ColliderId);
        var named = collider != null ? MeshCutters.ColliderMesh(collider) : null;
        // Whether the collider follows a result now, so it goes back to the source with no cutter that cuts collision.
        var follows = named != null && (named == ResultOf(e) || named == collision);
        if (inputs.Cutters.Count == 0)
        {
            if (source != null)
            {
                ops.Add(new SetField(e.Id, SceneEdits.MeshRendererId, "mesh", SceneValue.AssetRef(source)));
                ops.Add(new SetField(e.Id, SceneEdits.CutTargetId, "source", null));
                if (follows)
                {
                    ops.Add(new SetField(e.Id, SceneEdits.ColliderId, "mesh", SceneValue.AssetRef(source)));
                }
            }
            if (MeshCutters.HashOf(e) != 0)
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
        var result = ResultOf(e);
        if (!owned || result == null)
        {
            result = NewGuid();
            Make(document, cuts, inputs, result, newResult: true, null);
            ops.Add(new SetField(e.Id, SceneEdits.CutTargetId, "source", SceneValue.AssetRef(inputs.Source)));
            ops.Add(new SetField(e.Id, SceneEdits.MeshRendererId, "mesh", SceneValue.AssetRef(result)));
        }
        var hash = inputs.Hash();
        if (MeshCutters.HashOf(e) != hash)
        {
            ops.Add(new SetField(e.Id, SceneEdits.CutTargetId, "inputs_hash", MeshCutters.HashValue(hash)));
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
        if (collider == null)
        {
            return ops;
        }
        string? wanted;
        switch (MeshCuts.CollisionOf(inputs))
        {
            case CollisionCut.Render:
                wanted = result;
                break;
            case CollisionCut.Own:
                if (collision == null)
                {
                    collision = NewGuid();
                    Make(document, cuts, inputs, result, newResult: false, collision);
                }
                wanted = collision;
                break;
            default:
                // A primitive keeps its shape, with a warning.
                wanted = follows ? inputs.Source : null;
                break;
        }
        if (wanted != null)
        {
            if (MeshCutters.ColliderShape(collider) != "Mesh")
            {
                ops.Add(new SetField(e.Id, SceneEdits.ColliderId, "shape", SceneValue.Name("Mesh")));
            }
            if (named != wanted)
            {
                ops.Add(new SetField(e.Id, SceneEdits.ColliderId, "mesh", SceneValue.AssetRef(wanted)));
            }
        }
        return ops;
    }

    static string NewGuid() => Convert.ToHexStringLower(Guid.NewGuid().ToByteArray());

    // A new result, or a new collision result beside the target's result: a document of the source's mesh, which the
    // host draws from the start, until the derive. Its document is added before the field that names it is sent.
    void Make(SceneDocument document, SceneCuts cuts, CutInputs inputs, string result, bool newResult, string? collision)
    {
        var old = cuts.Targets.GetValueOrDefault(inputs.Target.Id);
        if (newResult)
        {
            if (old?.Result is { } was && !OwnedElsewhere(document, inputs.Target.Id, was))
            {
                Close(was);
            }
            _shell.Mesh.Meshes.Add(new MeshDocument(ResultPath(document, inputs.Target, result, ""), result, inputs.SourceMesh, saved: false));
        }
        if (collision != null)
        {
            if (old?.Collision is { } was && !OwnedElsewhere(document, inputs.Target.Id, was))
            {
                Close(was);
            }
            cuts.Collisions.Add(collision);
            _shell.Mesh.Meshes.Add(new MeshDocument(ResultPath(document, inputs.Target, collision, CollisionSuffix), collision, inputs.SourceMesh, saved: false));
        }
        Change(cuts, inputs.Target, new CutState.Made(result, collision ?? old?.Collision));
    }

    // Derives a target's result and its collision result, unless the cut set has them from the same inputs.
    void Update(SceneDocument document, SceneCuts cuts, CutInputs inputs)
    {
        var e = inputs.Target;
        var hash = inputs.Hash();
        var state = cuts.Targets.GetValueOrDefault(e.Id);
        if (inputs.Cutters.Count == 0 || ResultOf(e) is not { } result || OwnedElsewhere(document, e.Id, result))
        {
            // A first cut that its cap slots refuse names no result, and says why.
            if (inputs.Cutters.Count > 0 && ResultOf(e) == null && MeshCuts.CapSlots(inputs).Reason is { } why)
            {
                Close(state?.Result);
                Close(state?.Collision);
                Change(cuts, e, new CutState.Refused(null, hash, why, null));
                return;
            }
            Drop(cuts, e.Id);
            return;
        }
        var collision = MeshCuts.CollisionOf(inputs) == CollisionCut.Own
            && CollisionOf(cuts, e) is { } c && !OwnedElsewhere(document, e.Id, c) ? c : null;
        if (state is CutState.Cut done && done.Result == result && done.Hash == hash && done.Collision == collision
            || state is CutState.Refused r && r.Result == result && r.Hash == hash && r.Collision == collision)
        {
            return;
        }
        if (state?.Result is { } oldResult && oldResult != result)
        {
            Close(oldResult);
        }
        if (state?.Collision is { } oldCollision && oldCollision != collision)
        {
            Close(oldCollision);
        }
        var derived = MeshCuts.Derive(inputs);
        var collided = collision != null ? MeshCuts.Derive(inputs, c => c.Fields.CutsCollision) : null;
        if (derived is CutResult.Cut cut && (collided is null || collided is CutResult.Cut))
        {
            Put(document, e, result, cut.Mesh, "");
            if (collision != null && collided is CutResult.Cut own)
            {
                cuts.Collisions.Add(collision);
                Put(document, e, collision, own.Mesh, CollisionSuffix);
            }
            Change(cuts, e, new CutState.Cut(result, hash, collision, cut.Map));
            return;
        }
        // The last good cut stays. With none, as after an undo and a redo of a refused first cut, the source draws.
        var reason = derived is CutResult.Refused refused ? refused.Reason : ((CutResult.Refused)collided!).Reason;
        foreach (var (guid, suffix) in new[] { (result, ""), (collision, CollisionSuffix) })
        {
            if (guid != null && _shell.Mesh.Meshes.Find(guid) == null && !File.Exists(ResultPath(document, e, guid, suffix)))
            {
                _shell.Mesh.Meshes.Add(new MeshDocument(ResultPath(document, e, guid, suffix), guid, inputs.SourceMesh, saved: false));
            }
        }
        Change(cuts, e, new CutState.Refused(result, hash, reason, collision));
    }

    // Sets a result's document to a mesh: the open one, or the file's when it holds that mesh, else a new one.
    void Put(SceneDocument document, SceneEntity target, string result, MeshData mesh, string suffix)
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
        var path = ResultPath(document, target, result, suffix);
        // A file that holds the cut, as at the scene's open, is what the host draws already, cooked.
        if (File.Exists(path) && MeshDocument.Open(path, result) is ({ } saved, _) && MeshFile.Write(saved.Data) == MeshFile.Write(mesh))
        {
            return;
        }
        meshes.Add(new MeshDocument(path, result, mesh, saved: false));
    }

    // The target no longer has a result: its documents close.
    void Drop(SceneCuts cuts, ulong id)
    {
        if (cuts.Targets.GetValueOrDefault(id) is not { } state)
        {
            return;
        }
        Close(state.Result);
        Close(state.Collision);
        var refused = state is CutState.Refused;
        cuts.Targets.Remove(id);
        if (refused)
        {
            ProblemsChanged?.Invoke();
        }
    }

    void Close(string? result)
    {
        if (result != null)
        {
            _shell.Mesh.CloseMesh(result);
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
            if (MeshCutters.TargetLayer(entity) != null && MeshCutters.EditableMesh(entity) is { } mesh && !Ready(mesh))
            {
                return null;
            }
            if (entity.Components.Find(c => c.Id == SceneEdits.MeshCutterId) is { } cutter
                && CutterFields.Of(cutter) is { Shape: CutterShape.Mesh, Mesh.Length: > 0 } fields && !Ready(fields.Mesh))
            {
                return null;
            }
        }
        return MeshCuts.Plan(expansion, MeshOf);
    }

    // Whether a mesh that a cut reads is there to read: open, or in the index. A mesh file that the index has but that
    // cannot be read is not, so that it does not read as no cutter. A model's mesh is there, and is no target.
    bool Ready(string guid) =>
        _shell.Mesh.Meshes.Find(guid) != null || _shell.Assets.Find(guid) != null && (OnDisk(guid) == null || MeshOf(guid) != null);

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
    // after an undo makes the same file. A collision result's ends .collision.cut.mesh.
    string ResultPath(SceneDocument document, SceneEntity target, string result, string suffix)
    {
        if (_shell.Assets.Find(result) is { } asset && _shell.Assets.FullPath(asset) is { } indexed)
        {
            return indexed;
        }
        var directory = Path.Combine(Path.GetDirectoryName(document.Path)!, $"{Path.GetFileNameWithoutExtension(document.Path)}_meshes");
        var name = string.Concat(target.Name.Select(c => Path.GetInvalidFileNameChars().Contains(c) || c == ' ' ? '_' : c));
        return Path.Combine(directory, $"{(name.Length > 0 ? name + "_" : "")}{target.Id:x16}{(suffix != "" ? suffix : ".cut" + MeshFile.Extension)}");
    }

    static string Label(SceneEntity e) => e.Name.Length > 0 ? e.Name : $"{e.Id:x16}";
}
