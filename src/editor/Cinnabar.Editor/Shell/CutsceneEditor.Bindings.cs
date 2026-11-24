using Cinnabar.Editor.Content;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Shell;

/// <summary>A broken binding whose entity the next entity selected in the viewport or the Outliner becomes.</summary>
public sealed record BindingPick(int Binding);

/// <summary>An entity of an open scene that a broken binding could point at: it has the binding's name.</summary>
public sealed record BindingCandidate(PossessRef Entity, string Name, string Scene);

/// <summary>
/// The second part of a cutscene's binding edits (see docs/editor/cutscene-editor.md#bindings): converting a binding to
/// another kind, picking a broken one's entity, script slots and their stand-ins, and spawning a prefab at a place.
/// </summary>
public sealed partial class CutsceneEditor
{
    // Each script slot's stand-in, by its binding's ID: each user's, saved with the timeline's view, never in the asset.
    // It stays when its binding stops being a slot, so an undo that makes it one again finds it, and the preview text
    // ignores it meanwhile.
    readonly Dictionary<int, string> _standIns;

    /// <summary>
    /// The text that the preview cooks: the document's, with each script slot's stand-in in place of its
    /// <c>provided = true</c> (see <see cref="CutsceneStandIns.PreviewText"/>).
    /// </summary>
    public string CookText
    {
        get
        {
            // The keying's waits read it often, so the text is made again only when the document or a stand-in changes.
            var text = Document.Text;
            if (_cookText is not { } made || !string.Equals(made.Source, text, StringComparison.Ordinal) || made.StandIns != _standInsVersion)
            {
                made = (text, _standInsVersion, CutsceneStandIns.PreviewText(text, _standIns));
                _cookText = made;
            }
            return made.Text;
        }
    }

    // The last CookText, with the document's text and the stand-ins' version that it was made from.
    (string Source, int StandIns, string Text)? _cookText;
    int _standInsVersion;

    /// <summary>A script slot's stand-in, as <c>@&lt;guid&gt;/&lt;id&gt;</c> or <c>$&lt;guid&gt;</c>, or null for none.</summary>
    public string? StandInOf(int binding) => _standIns.GetValueOrDefault(binding);

    /// <summary>
    /// Sets or, with null, clears a script slot's stand-in. It is no edit of the document, so it is in no undo entry: it
    /// saves with the user's view of the timeline and cooks the preview again.
    /// </summary>
    public void SetStandIn(int binding, string? standIn)
    {
        if (standIn == StandInOf(binding))
        {
            return;
        }
        if (standIn == null)
        {
            _standIns.Remove(binding);
        }
        else
        {
            _standIns[binding] = standIn;
        }
        _standInsVersion++;
        SaveView();
        Checks.Schedule();
        _entityBindings = BindingsOfEntities(_shell.Selection.Entities);
        Changed?.Invoke();
    }

    /// <summary>Why the selected script slot cannot stand in the selected entity, or null when it can.</summary>
    public string? StandInRefusal()
    {
        if (SelectedBinding is not { Id: { } id } binding || !CutsceneBindings.IsProvided(binding))
        {
            return "No script slot is selected.";
        }
        if (_shell.Selection.Entities is not [var handle])
        {
            return "Select one entity.";
        }
        if (_shell.Keying.PossessOf(handle) is not { } entity)
        {
            return "The entity is not one that a scene names: the game spawned it, or its scene has no GUID yet.";
        }
        return BindingOfEntity(entity) is { } other && other != id ? "A binding possesses that entity already." : null;
    }

    /// <summary>Makes the selected entity the selected script slot's stand-in.</summary>
    public void StandInSelection()
    {
        if (StandInRefusal() == null && SelectedBinding?.Id is { } id && _shell.Keying.PossessOf(_shell.Selection.Entities[0]) is { } entity)
        {
            SetStandIn(id, CutsceneBindings.Format(entity));
        }
    }

    /// <summary>The prefabs that the asset index knows, by GUID, with their names, in name order.</summary>
    public List<(string Guid, string Name)> KnownPrefabs() =>
        [.. _shell.Assets.Assets.Values.Where(a => a.Kind == Link.Cook.AssetKind.Prefab).Select(a => (a.Guid, PrefabName(a))).OrderBy(p => p.Item2, StringComparer.OrdinalIgnoreCase)];

    /// <summary>
    /// The entity that a binding possesses, or that a script slot's stand-in names, or null: for a spawned binding, a
    /// slot with a prefab or no stand-in, and a value that is not a scene link.
    /// </summary>
    PossessRef? PossessedBy(CutsceneBlock binding) =>
        PossessRef.Parse(binding.Get("possess")) ?? (CutsceneBindings.IsProvided(binding) && binding.Id is { } id ? PossessRef.Parse(StandInOf(id)) : null);

    /// <summary>The binding that possesses an entity, or whose script slot's stand-in it is, or null.</summary>
    internal int? BindingOfEntity(PossessRef entity) =>
        CutsceneKeying.BindingOf(File, entity)
        ?? File.Bindings.FirstOrDefault(b => b.Id is { } id && CutsceneBindings.IsProvided(b) && PossessRef.Parse(StandInOf(id)) == entity)?.Id;

    /// <summary>
    /// Adds a script slot, a binding that a script gives when it plays the cutscene, named as the script names it, as one
    /// undo entry, and selects its row.
    /// </summary>
    public void AddSlot(string name)
    {
        name = name.Trim();
        if (name.Length == 0 || Document.InTransaction)
        {
            return;
        }
        var id = 0;
        Key("Add Script Slot", f => id = CutsceneBindings.AddProvided(f, name));
        // A deleted slot's stand-in stays for an undo, and a new slot can take its ID: the new one starts with none.
        SetStandIn(id, null);
        SelectBindings([id]);
    }

    // Convert (see docs/editor/cutscene-editor.md#convert).

    /// <summary>Why the selected binding cannot become one of a kind, or null when it can.</summary>
    public string? ConvertRefusal(CutsceneBindingKind to)
    {
        if (Document.InTransaction)
        {
            return "A drag is under way in the cutscene.";
        }
        if (SelectedBinding is not { Id: { } id } binding)
        {
            return "No binding is selected.";
        }
        var info = InfoOf(binding);
        if (info.Kind == to)
        {
            return to switch
            {
                CutsceneBindingKind.Possessed => "The binding possesses an entity already.",
                CutsceneBindingKind.Spawned => "The binding spawns a prefab already.",
                _ => "A script gives the binding's entity already.",
            };
        }
        if (info.Kind == CutsceneBindingKind.Unknown)
        {
            return "The binding has none of possess, spawn and provided, or more than one. Fix its text first.";
        }
        return to switch
        {
            CutsceneBindingKind.Spawned => SpawnSource(binding).Refusal,
            CutsceneBindingKind.Possessed => ChildrenRefusal(id) ?? PossessTarget(binding).Refusal,
            CutsceneBindingKind.Provided => ChildrenRefusal(id),
            _ => "A binding cannot become that kind.",
        };
    }

    // A spawned binding that other bindings name as their parent must stay one, as the cooker says.
    string? ChildrenRefusal(int id) => CutsceneBindings.ChildrenOf(File, id) is { Count: > 0 } children
        ? $"Other bindings spawn under it: {string.Join(", ", children.Take(3).Select(c => c.Name))}. A parent is a spawned binding."
        : null;

    // The prefab and the pose that a binding spawns when it converts: those of the entity that it possesses, or that a
    // slot's stand-in names, when that entity is the root of a whole prefab's instance in an open scene; or a slot's
    // prefab stand-in, where it is.
    (string? Prefab, Pose? Pose, string? Refusal) SpawnSource(CutsceneBlock binding)
    {
        if (CutsceneBindings.IsProvided(binding) && binding.Id is { } slot && StandInOf(slot) is { } standIn && CutsceneStandIns.IsPrefab(standIn))
        {
            return (standIn.Trim()[1..], null, null);
        }
        if (PossessedBy(binding) is not { } entity)
        {
            return (null, null, CutsceneBindings.IsProvided(binding)
                ? "The slot has no stand-in. Give it one, and the binding spawns that."
                : "The binding does not name an entity.");
        }
        if (_shell.SceneOfGuid(entity.SceneGuid) is not { } scene)
        {
            return (null, null, "The entity's scene is not open, so the editor cannot tell its prefab.");
        }
        if (scene.Expanded.Flat.Find(entity.Id) is not { } found)
        {
            return (null, null, "The entity is not in its scene.");
        }
        if (scene.Expanded.InstanceOf(entity.Id) is not { Prefab.Length: > 0 } instance)
        {
            return (null, null, "The entity is not the root of a prefab's instance, so there is no prefab to spawn.");
        }
        if (instance.IsInstanceRoot && scene.Scene.Find(instance.Instance) is { Node: not 0 })
        {
            return (null, null, "The instance takes only a part of its prefab, and a spawn takes the whole prefab.");
        }
        return (instance.Prefab, SceneEdits.WorldPose(scene.Expanded.Flat, found) ?? Pose.Identity, null);
    }

    // The entity that a binding possesses when it converts: the one entity selected, or a slot's stand-in.
    (PossessRef? Entity, string? Refusal) PossessTarget(CutsceneBlock binding)
    {
        if (CutsceneBindings.IsProvided(binding) && PossessedBy(binding) is { } standIn && _shell.Selection.Entities.Count == 0)
        {
            return (standIn, null);
        }
        if (_shell.Selection.Entities is not [var handle])
        {
            return (null, "Select the one entity for the binding to possess.");
        }
        if (_shell.Keying.PossessOf(handle) is not { } entity)
        {
            return (null, "The entity is not one that a scene names: the game spawned it, or its scene has no GUID yet.");
        }
        return BindingOfEntity(entity) is { } other && other != binding.Id
            ? (null, "Another binding possesses that entity.")
            : (entity, null);
    }

    /// <summary>
    /// Makes the selected binding one of another kind, keeping its ID, its name and its tracks, as one undo entry (see
    /// docs/editor/cutscene-editor.md#convert). A possessed binding spawns its entity's prefab where the entity is; a
    /// spawned one possesses the selected entity; a script slot's stand-in becomes what it binds, and what a binding
    /// bound becomes the new slot's stand-in.
    /// </summary>
    public void Convert(CutsceneBindingKind to)
    {
        if (ConvertRefusal(to) != null || SelectedBinding is not { Id: { } id } binding)
        {
            return;
        }
        // What the binding bound, which a slot keeps as its stand-in.
        string? kept = binding.Get("possess")?.Trim() ?? binding.Get("spawn")?.Trim();
        switch (to)
        {
            case CutsceneBindingKind.Spawned when SpawnSource(binding) is ({ } prefab, var pose, null):
                Key("Convert to Spawned", f => CutsceneBindings.ToSpawned(f, id, prefab, pose));
                break;
            case CutsceneBindingKind.Possessed when PossessTarget(binding) is ({ } entity, null):
                Key("Convert to Possessed", f => CutsceneBindings.ToPossessed(f, id, entity));
                break;
            case CutsceneBindingKind.Provided:
                Key("Convert to Script Slot", f => CutsceneBindings.ToProvided(f, id));
                if (kept != null && CutsceneBindings.IsProvided(File.Bindings.First(b => b.Id == id)))
                {
                    SetStandIn(id, kept);
                }
                break;
        }
    }

    // Pick (see docs/editor/cutscene-editor.md#rebind-and-delete).

    /// <summary>
    /// The broken binding that the next entity selected becomes, or null when this cutscene has no pick armed. The shell
    /// holds the one pick, so at most one cutscene has one.
    /// </summary>
    public BindingPick? Picking => _shell.BindingPickOf(this);

    // The shell armed or ended this cutscene's pick.
    internal void OnPickChanged() => Changed?.Invoke();

    /// <summary>Why the selected binding's entity cannot be picked, or null when it can.</summary>
    public string? PickRefusal()
    {
        if (Document.InTransaction)
        {
            return "A drag is under way in the cutscene.";
        }
        if (SelectedBinding is not { } binding)
        {
            return "No binding is selected.";
        }
        return binding.Get("possess") == null ? "Only a possessed binding is pointed at an entity. Convert it first." : null;
    }

    /// <summary>
    /// Arms a pick of the selected binding's entity: the next entity selected in the viewport or the Outliner becomes it,
    /// as one undo entry. Esc or another row cancels it.
    /// </summary>
    public void ArmPick()
    {
        if (PickRefusal() == null && SelectedBinding?.Id is { } id)
        {
            SetPicking(new BindingPick(id));
        }
    }

    /// <summary>Cancels this cutscene's armed pick. False when it had none.</summary>
    public bool CancelPick()
    {
        if (Picking == null)
        {
            return false;
        }
        SetPicking(null);
        return true;
    }

    void SetPicking(BindingPick? pick) => _shell.SetBindingPick(this, pick);

    // An armed pick ends when its binding is no longer the selected one, or no longer possesses.
    void EndStalePick()
    {
        if (Picking is { } pick && (SelectedBinding?.Id != pick.Binding || File.Bindings.FirstOrDefault(b => b.Id == pick.Binding)?.Get("possess") == null))
        {
            SetPicking(null);
        }
    }

    // While a pick is armed, a newly selected entity that a scene names becomes the binding's, and the pick ends. One that
    // another binding has does not: the pick stays armed, and so does its row's selection. True when the pick took the
    // selection, so the row sync leaves it.
    bool TakePick(IReadOnlyList<ulong> next)
    {
        if (Picking is not { } pick || next is not [var handle] || _shell.Keying.PossessOf(handle) is not { } entity)
        {
            return false;
        }
        if (BindingOfEntity(entity) is { } other && other != pick.Binding)
        {
            return true;
        }
        SetPicking(null);
        RebindTo(pick.Binding, entity);
        return true;
    }

    /// <summary>
    /// The entities of the open scenes that a broken possessed binding could point at: those with the binding's name, which
    /// is the entity's name when it was possessed, up to eight.
    /// </summary>
    public List<BindingCandidate> CandidatesOf(CutsceneBlock binding)
    {
        if (binding.Name is not { Length: > 0 } name || binding.Get("possess") == null || InfoOf(binding).State != CutsceneBindingState.Broken)
        {
            return [];
        }
        var found = new List<BindingCandidate>();
        foreach (var scene in _shell.Scenes)
        {
            if (_shell.GuidOf(scene) is not { Length: 32 } guid)
            {
                continue;
            }
            foreach (var entity in scene.Expanded.Flat.Entities.Where(e => e.Name == name))
            {
                var target = new PossessRef(guid.ToLowerInvariant(), entity.Id);
                if (BindingOfEntity(target) == null)
                {
                    found.Add(new BindingCandidate(target, entity.Name, scene.Title));
                }
                if (found.Count == 8)
                {
                    return found;
                }
            }
        }
        return found;
    }

    /// <summary>Points a possessed binding at an entity of a scene, keeping its tracks, as one undo entry.</summary>
    public void RebindTo(int binding, PossessRef entity)
    {
        if (Document.InTransaction || File.Bindings.FirstOrDefault(b => b.Id == binding)?.Get("possess") == null
            || BindingOfEntity(entity) is { } other && other != binding)
        {
            return;
        }
        Key("Rebind", f => CutsceneBindings.Rebind(f, binding, entity));
    }

    // Spawn Prefab and a spawn at a place (see docs/editor/cutscene-editor.md#possess-and-spawn).

    /// <summary>The view should open its prefab picker, which spawns the prefab picked: Spawn Prefab.</summary>
    public event Action? SpawnPrefabRequested;

    public void RequestSpawnPrefab() => SpawnPrefabRequested?.Invoke();

    /// <summary>
    /// Adds a binding that spawns a prefab, by GUID, at a place in the world in World_Position units, with its first
    /// transform key there at the playhead, as one undo entry, and selects its row.
    /// </summary>
    public void SpawnAt(string prefab, IReadOnlyList<long> position)
    {
        if (Document.InTransaction || position.Count != 3)
        {
            return;
        }
        var name = _shell.Assets.Find(prefab) is { } a ? PrefabName(a) : "Prefab";
        var id = 0;
        Key("Add Binding", f => id = CutsceneBindings.AddSpawnAt(f, prefab, name, position, Playhead));
        SelectBindings([id]);
    }
}
