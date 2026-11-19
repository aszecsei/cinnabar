using Cinnabar.Editor.Document;
using Cinnabar.Editor.Model;
using Wire = Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The parts of the open scenes in the game's world (see docs/editor/document-and-scenes.md#parts). The game's world
/// has a scene for each part of a document: its base, with the document's number, and a part for each sublevel that
/// has entities and is loaded, each with a number of its own. Operations name the part of their entity, and what the
/// game reports by part comes back to the document's number here, so the rest of the editor knows only documents.
/// </summary>
public sealed partial class EditorShell
{
    // What the game's world has of each open scene, by the scene's number.
    readonly Dictionary<uint, SceneParts> _parts = [];
    // The scene's number of each part's number that the game has had, so a report about a part finds its document.
    readonly Dictionary<uint, uint> _baseOfPart = [];
    // The sublevels that Edit does not load. Every other sublevel loads (see docs/editor/document-and-scenes.md#parts).
    readonly HashSet<string> _unloadedSublevels = new(StringComparer.Ordinal);

    /// <summary>What the game's world has of one open scene.</summary>
    sealed class SceneParts
    {
        // The number of each sublevel's part that the game's world has.
        public readonly Dictionary<string, uint> Numbers = new(StringComparer.Ordinal);
        // The sublevel of each entity, as the game was told it: "" for the base.
        public readonly Dictionary<ulong, string> SublevelOf = [];
        // The GUID of each part's sub-asset, as hex, or "" before the scene's first cook. "" is the base.
        public readonly Dictionary<string, string> Guids = new(StringComparer.Ordinal);
    }

    /// <summary>Whether Edit loads a sublevel's parts of the open scenes. Every sublevel loads until <see cref="SetSublevelLoaded"/> says otherwise.</summary>
    public bool IsSublevelLoaded(string sublevel) => sublevel == "" || !_unloadedSublevels.Contains(sublevel);

    /// <summary>
    /// Loads or unloads a sublevel's parts of every open scene in the game's world. Each part goes alone, as an
    /// <c>Add_Scene</c> or a <c>Remove_Scene</c>, and the other parts' entities keep their handles.
    /// </summary>
    public void SetSublevelLoaded(string sublevel, bool loaded)
    {
        if (sublevel == "" || (loaded ? !_unloadedSublevels.Remove(sublevel) : !_unloadedSublevels.Add(sublevel)))
        {
            return;
        }
        // Outside Edit the world is the game's: Stop sends the scenes again, with the choice.
        if (!IsEditing)
        {
            return;
        }
        foreach (var document in _scenes)
        {
            var parts = PartsOf(document);
            if (!loaded)
            {
                if (parts.Numbers.Remove(sublevel, out var number) && Host.Linked)
                {
                    Host.Send(new Wire.RemoveScene(number, ++_sceneTicket));
                }
                continue;
            }
            var entities = document.Expanded.Flat.Entities.Where(e => parts.SublevelOf.GetValueOrDefault(e.Id) == sublevel).ToList();
            if (entities.Count > 0)
            {
                var number = NewPart(document, parts, sublevel);
                if (Host.Linked)
                {
                    Host.Send(new Wire.AddScene(Part(document, parts, number, sublevel, entities), ++_sceneTicket));
                }
            }
        }
    }

    /// <summary>
    /// Puts an entity of the active scene in a sublevel, or with "" in the base, with its descendants, as one undo entry.
    /// The game moves them to the part of their new sublevel, and they keep their handles.
    /// </summary>
    public bool SetSublevel(ulong sceneId, string sublevel)
    {
        if (Scene?.Expanded.Flat.Find(sceneId) is not { } entity)
        {
            return false;
        }
        var flat = Scene.Expanded.Flat;
        if (flat.SublevelOf(entity) == sublevel)
        {
            return false;
        }
        var label = sublevel == "" ? $"Move {Label(entity)} to the base" : $"Move {Label(entity)} to {sublevel}";
        try
        {
            return Edit(label, new SetSublevel(sceneId, sublevel == "" ? null : sublevel));
        }
        catch (InvalidOperationException e)
        {
            Console.Add(LogLevel.Error, $"edit: {e.Message}");
            return false;
        }
    }

    // The scene's base and its loaded parts, as the game's world gets them, numbered. A part keeps its number while it
    // has entities and is loaded. One that has none, or is not loaded, loses it, and a new number is never used again.
    IEnumerable<Wire.LoadedScene> PartsToLoad(SceneDocument document)
    {
        var parts = PartsOf(document);
        parts.Guids.Clear();
        parts.SublevelOf.Clear();
        var flat = document.Expanded.Flat;
        var bySublevel = new SortedDictionary<string, List<SceneEntity>>(StringComparer.Ordinal) { [""] = [] };
        foreach (var e in flat.Entities)
        {
            var sublevel = flat.SublevelOf(e);
            parts.SublevelOf[e.Id] = sublevel;
            if (!bySublevel.TryGetValue(sublevel, out var list))
            {
                bySublevel[sublevel] = list = [];
            }
            list.Add(e);
        }
        foreach (var sublevel in parts.Numbers.Keys.ToList())
        {
            if (!bySublevel.ContainsKey(sublevel) || !IsSublevelLoaded(sublevel))
            {
                parts.Numbers.Remove(sublevel);
            }
        }
        var loaded = new List<Wire.LoadedScene> { Part(document, parts, document.Number, "", bySublevel[""]) };
        foreach (var (sublevel, entities) in bySublevel)
        {
            if (sublevel != "" && IsSublevelLoaded(sublevel))
            {
                var number = parts.Numbers.TryGetValue(sublevel, out var kept) ? kept : NewPart(document, parts, sublevel);
                loaded.Add(Part(document, parts, number, sublevel, entities));
            }
        }
        return loaded;
    }

    // One part of a scene, with its references to the scene's other parts as the cooker writes them.
    Wire.LoadedScene Part(SceneDocument document, SceneParts parts, uint number, string sublevel, IEnumerable<SceneEntity> entities) =>
        new(number,
            [.. entities.Select(e => Encode(document, parts, sublevel, SceneSnapshot.Entity(e)))],
            SceneSnapshot.GuidBytes(PartGuid(document, parts, sublevel)),
            sublevel == "" ? 0 : document.Number,
            sublevel);

    // Forgets what the game's world had of a scene that closed, and its parts' numbers.
    void ForgetParts(SceneDocument document)
    {
        _parts.Remove(document.Number);
        foreach (var part in _baseOfPart.Where(p => p.Value == document.Number).Select(p => p.Key).ToList())
        {
            _baseOfPart.Remove(part);
        }
    }

    SceneParts PartsOf(SceneDocument document)
    {
        if (!_parts.TryGetValue(document.Number, out var parts))
        {
            _parts[document.Number] = parts = new SceneParts();
        }
        return parts;
    }

    uint NewPart(SceneDocument document, SceneParts parts, string sublevel)
    {
        var number = ++_lastSceneNumber;
        parts.Numbers[sublevel] = number;
        _baseOfPart[number] = document.Number;
        return number;
    }

    // The GUID of a part's sub-asset (see docs/content/kinds/scenes.md#sublevels), or of the scene for the base, as hex,
    // or "" when the scene has not cooked it yet.
    string PartGuid(SceneDocument document, SceneParts parts, string sublevel)
    {
        if (parts.Guids.TryGetValue(sublevel, out var known))
        {
            return known;
        }
        var guid = sublevel == "" ? AssetGuidOf(document.Path) ?? "" : SubassetGuidOf(document.Path, ProjectSettings.SublevelPrefix + sublevel) ?? "";
        parts.Guids[sublevel] = guid;
        return guid;
    }

    // The operations of a document's edit, each naming the part of its entity. An entity whose sublevel changed moves
    // to its new part, with its descendants, and the fields whose references now cross a part, or no longer do, go
    // again. An entity of a sublevel that is not loaded is left out. A part that an entity needs before the game has
    // it goes first, alone, as an Add_Scene.
    void SendRouted(SceneDocument document, IEnumerable<Wire.Operation> operations)
    {
        var parts = PartsOf(document);
        var flat = document.Expanded.Flat;
        var pending = new List<Wire.Operation>();

        string Now(ulong id) => flat.Find(id) is { } e ? flat.SublevelOf(e) : parts.SublevelOf.GetValueOrDefault(id, "");
        string Was(ulong id) => parts.SublevelOf.TryGetValue(id, out var s) ? s : Now(id);
        void Flush()
        {
            if (pending.Count > 0 && Host.Linked)
            {
                Host.Send(new Wire.ApplyOperations([.. pending]));
            }
            pending.Clear();
        }
        // The number of a loaded part, which the game gets as an empty Add_Scene if it does not have it yet.
        uint Ensure(string sublevel)
        {
            if (sublevel == "")
            {
                return document.Number;
            }
            if (parts.Numbers.TryGetValue(sublevel, out var number))
            {
                return number;
            }
            number = NewPart(document, parts, sublevel);
            Flush();
            if (Host.Linked)
            {
                Host.Send(new Wire.AddScene(Part(document, parts, number, sublevel, []), ++_sceneTicket));
            }
            return number;
        }
        void Stamp(Wire.Operation op, string sublevel)
        {
            if (IsSublevelLoaded(sublevel))
            {
                pending.Add(Encode(document, parts, sublevel, op) with { Scene = Ensure(sublevel) });
            }
        }
        void Move(ulong root)
        {
            var (from, to) = (Was(root), Now(root));
            var subtree = Subtree(flat, root);
            foreach (var e in subtree)
            {
                parts.SublevelOf[e.Id] = to;
            }
            if (from == to)
            {
                return;
            }
            var fromNumber = from == "" ? document.Number : parts.Numbers.GetValueOrDefault(from);
            var (fromLoaded, toLoaded) = (IsSublevelLoaded(from) && fromNumber != 0, IsSublevelLoaded(to));
            if (fromLoaded && toLoaded)
            {
                // The game loads a part that it does not have, and unloads one that has no entity left.
                var toNumber = to == "" ? document.Number : parts.Numbers.TryGetValue(to, out var n) ? n : NewPart(document, parts, to);
                pending.Add(new SetSublevel(root, null).ToWire() with
                {
                    Scene = fromNumber,
                    Target = toNumber,
                    Sublevel = to,
                    Guid = SceneSnapshot.GuidBytes(PartGuid(document, parts, to)),
                });
                if (from != "" && !parts.SublevelOf.ContainsValue(from))
                {
                    parts.Numbers.Remove(from);
                }
            }
            else if (fromLoaded)
            {
                // Into a sublevel that is not loaded: the game drops them. Children first, as a destroy sends them.
                foreach (var e in Enumerable.Reverse(subtree))
                {
                    pending.Add(new DestroyEntity(e.Id).ToWire() with { Scene = fromNumber });
                }
            }
            else if (toLoaded)
            {
                // Out of a sublevel that is not loaded: the game gets them. Parents first.
                foreach (var e in subtree)
                {
                    Stamp(new CreateEntity(e).ToWire(), to);
                }
            }
            ResendCrossing(subtree.Select(e => e.Id).ToHashSet());
        }
        // A field that refers across the moved entities' edge changes whether it crosses a part.
        void ResendCrossing(HashSet<ulong> moved)
        {
            foreach (var e in flat.Entities)
            {
                var holder = parts.SublevelOf.GetValueOrDefault(e.Id, "");
                foreach (var c in e.Components)
                {
                    foreach (var f in c.Fields.Where(f => Crosses(moved, e.Id, f.Value)))
                    {
                        Stamp(new SetField(e.Id, c.Id, f.Name, f.Value).ToWire(), holder);
                    }
                }
                foreach (var b in e.Behaviours)
                {
                    foreach (var f in b.Fields.Where(f => Crosses(moved, e.Id, f.Value)))
                    {
                        Stamp(new SetBehaviourField(e.Id, b.Script, f.Name, f.Value).ToWire(), holder);
                    }
                }
            }
        }

        foreach (var op in operations)
        {
            switch (op.Kind)
            {
                case Wire.OperationKind.CreateEntity:
                    foreach (var created in op.Created)
                    {
                        var sublevel = Now(created.Id);
                        parts.SublevelOf[created.Id] = sublevel;
                        Stamp(op with { Entity = created.Id, Created = [created] }, sublevel);
                    }
                    break;
                case Wire.OperationKind.DestroyEntity:
                    var was = Was(op.Entity);
                    parts.SublevelOf.Remove(op.Entity);
                    if (IsSublevelLoaded(was) && (was == "" || parts.Numbers.ContainsKey(was)))
                    {
                        pending.Add(op with { Scene = was == "" ? document.Number : parts.Numbers[was] });
                    }
                    break;
                case Wire.OperationKind.SetSublevel:
                    Move(op.Entity);
                    break;
                case Wire.OperationKind.SetParent:
                    // A new parent in another sublevel takes the entity there first, so the parent is in its part.
                    if (Was(op.Entity) != Now(op.Entity))
                    {
                        Move(op.Entity);
                    }
                    Stamp(op, Now(op.Entity));
                    break;
                default:
                    Stamp(op, Now(op.Entity));
                    break;
            }
        }
        Flush();
    }

    // The entity and its descendants in the flat scene, parents first.
    static List<SceneEntity> Subtree(Scene flat, ulong root)
    {
        var result = new List<SceneEntity>();
        if (flat.Find(root) is not { } first)
        {
            return result;
        }
        var children = flat.Entities.Where(e => e.Parent != 0).ToLookup(e => e.Parent);
        result.Add(first);
        for (var i = 0; i < result.Count; i++)
        {
            result.AddRange(children[result[i].Id]);
        }
        return result;
    }

    static bool Crosses(HashSet<ulong> moved, ulong holder, SceneValue value) =>
        value.Kind == SceneValueKind.Entity && value.Scene == "" && value.Entity != 0 && moved.Contains(holder) != moved.Contains(value.Entity);

    // An operation's references, as the game's world needs them: one from its entity's part to an entity of another
    // part names that part's GUID, as the cooker writes it (see docs/content/kinds/scenes.md#sublevels).
    Wire.Operation Encode(SceneDocument document, SceneParts parts, string sublevel, Wire.Operation op) => op with
    {
        Created = [.. op.Created.Select(e => Encode(document, parts, parts.SublevelOf.GetValueOrDefault(e.Id, sublevel), e))],
        Components = [.. op.Components.Select(c => c with { Fields = Encode(document, parts, sublevel, c.Fields) })],
        Fields = Encode(document, parts, sublevel, op.Fields),
    };

    Wire.SceneEntity Encode(SceneDocument document, SceneParts parts, string sublevel, Wire.SceneEntity e) => e with
    {
        Components = [.. e.Components.Select(c => c with { Fields = Encode(document, parts, sublevel, c.Fields) })],
        Behaviours = [.. e.Behaviours.Select(b => b with { Fields = Encode(document, parts, sublevel, b.Fields) })],
    };

    Wire.SceneField[] Encode(SceneDocument document, SceneParts parts, string sublevel, Wire.SceneField[] fields)
    {
        if (!fields.Any(f => f.Value.Kind == Wire.SceneValueKind.Entity))
        {
            return fields;
        }
        return [.. fields.Select(f =>
        {
            var v = f.Value;
            if (v.Kind != Wire.SceneValueKind.Entity || v.Entity == 0 || v.Scene.Any(b => b != 0)
                || !parts.SublevelOf.TryGetValue(v.Entity, out var target) || target == sublevel)
            {
                return f;
            }
            return f with { Value = v with { Scene = SceneSnapshot.GuidBytes(PartGuid(document, parts, target)) } };
        })];
    }

    // What the game reports by part, by the document's number, and the references that name one of the document's own
    // parts as local, as the document stores them.
    Link.ILinkMessage FromParts(Link.ILinkMessage message)
    {
        if (_baseOfPart.Count == 0)
        {
            return message;
        }
        return message switch
        {
            Wire.EntitySnapshot s => s with { Entities = [.. s.Entities.Select(i => i with { Scene = DocumentNumber(i.Scene) })] },
            Wire.EntityDelta d => d with { Changed = [.. d.Changed.Select(i => i with { Scene = DocumentNumber(i.Scene) })] },
            Wire.PickResult p => p with { Hits = [.. p.Hits.Select(h => h with { Scene = DocumentNumber(h.Scene) })] },
            Wire.EditProblems e => e with { Problems = [.. e.Problems.Select(p => p with { Scene = DocumentNumber(p.Scene) })] },
            Wire.BehaviourOperations b => b with { Operations = [.. b.Operations.Select(FromPart)] },
            Wire.GameCommandResult r => r with { Operations = [.. r.Operations.Select(FromPart)] },
            _ => message,
        };
    }

    uint DocumentNumber(uint number) => _baseOfPart.GetValueOrDefault(number, number);

    Wire.Operation FromPart(Wire.Operation op)
    {
        var number = DocumentNumber(op.Scene);
        if (number == op.Scene && !_parts.ContainsKey(number))
        {
            return op;
        }
        var own = SceneByNumber(number) is { } document && _parts.TryGetValue(number, out var parts)
            ? parts.Numbers.Keys.Append("").Select(s => PartGuid(document, parts, s)).Where(g => g != "").ToHashSet(StringComparer.OrdinalIgnoreCase)
            : [];
        Wire.SceneField[] Local(Wire.SceneField[] fields) => [.. fields.Select(f =>
            f.Value.Kind == Wire.SceneValueKind.Entity && own.Contains(Convert.ToHexStringLower(f.Value.Scene))
                ? f with { Value = f.Value with { Scene = new byte[16] } }
                : f)];
        return op with
        {
            Scene = number,
            Fields = Local(op.Fields),
            Components = [.. op.Components.Select(c => c with { Fields = Local(c.Fields) })],
            Created = [.. op.Created.Select(e => e with
            {
                Components = [.. e.Components.Select(c => c with { Fields = Local(c.Fields) })],
                Behaviours = [.. e.Behaviours.Select(b => b with { Fields = Local(b.Fields) })],
            })],
        };
    }
}
