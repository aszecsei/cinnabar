using Cinnabar.Editor.Content;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// An event that a behaviour's class handles, as an event key's name list offers it (see
/// docs/editor/cutscene-editor.md#events): the event's name, the script by GUID and its class, the line of its handler,
/// and the handler's parameters after self. For a range, the handler is on_&lt;name&gt;_begin, or without one,
/// on_&lt;name&gt;_end.
/// </summary>
public sealed record CutsceneHandlerChoice(string Name, string Script, string Class, uint Line, IReadOnlyList<HandlerParam> Params);

/// <summary>
/// A row of an event's payload: the handler's parameter's name and the kind that it takes, when the handler has that
/// parameter and a type for it, and the event's value there, which Set says it has.
/// </summary>
public sealed record CutsceneValueRow(string? Name, CutsceneValueKind? Takes, CutsceneEventValue? Value, bool Set)
{
    /// <summary>What is wrong with the value for the parameter: another kind than it takes, or null.</summary>
    public string? Mismatch => Takes is { } kind && Value is { } v && v.Kind != kind
        ? $"{Name} takes {CutsceneEventValue.Word(kind)}, and this sends {CutsceneEventValue.Word(v.Kind)}."
        : null;
}

// An event track's events (see docs/editor/cutscene-editor.md#events): the handlers that the behaviours on the track's
// binding define, or every behaviour's for a track without one, from the index, which the cooker fills from the scripts.
public sealed partial class CutsceneEditor
{
    /// <summary>
    /// The events that a trigger or a range can name: the handlers of the behaviours of its track's binding's entity, or
    /// of every behaviour script for a track without a binding, by script and then by name. Null when that is not known:
    /// the binding's entity is not loaded, is gone, is a script slot without a stand-in, or has a script that the index
    /// does not have yet.
    /// </summary>
    public IReadOnlyList<CutsceneHandlerChoice>? HandlerChoices(CutsceneBlock ev)
    {
        if (ev.Kind is not (CutsceneBlockKind.Trigger or CutsceneBlockKind.Range) || ev.Parent is not { Kind: CutsceneBlockKind.Track } track)
        {
            return null;
        }
        return ChoicesFor(CutsceneEdits.BindingOf(track), ev.Kind == CutsceneBlockKind.Range);
    }

    // The events of a binding's behaviours, or of every behaviour for none, or null when they are not known.
    IReadOnlyList<CutsceneHandlerChoice>? ChoicesFor(int? bindingId, bool range)
    {
        List<Asset> scripts;
        if (bindingId is { } id)
        {
            if (File.Bindings.FirstOrDefault(b => b.Id == id) is not { } binding || BehavioursOf(binding) is not { } guids)
            {
                return null;
            }
            var found = guids.Select(_shell.Assets.Find).ToList();
            if (found.Any(a => a == null))
            {
                return null;
            }
            scripts = [.. found.OfType<Asset>()];
        }
        else
        {
            scripts = [.. _shell.Assets.Behaviours];
        }
        return [.. scripts.SelectMany(s => ChoicesOf(s, range))];
    }

    // A script's events by name: each handler's for a trigger, and for a range, each name with an on_<name>_begin or an
    // on_<name>_end, with the begin's parameters and line when it has both.
    static IEnumerable<CutsceneHandlerChoice> ChoicesOf(Asset script, bool range)
    {
        var handlers = AssetIndex.HandlersOf(script);
        if (!range)
        {
            return handlers.Select(h => new CutsceneHandlerChoice(h.Name, script.Guid, script.Behaviour, h.Line, h.Params));
        }
        var events = new SortedDictionary<string, CutsceneHandlerChoice>(StringComparer.Ordinal);
        foreach (var h in handlers)
        {
            foreach (var (suffix, wins) in (ReadOnlySpan<(string, bool)>)[("_begin", true), ("_end", false)])
            {
                if (h.Name.Length > suffix.Length && h.Name.EndsWith(suffix, StringComparison.Ordinal))
                {
                    var name = h.Name[..^suffix.Length];
                    if (wins || !events.ContainsKey(name))
                    {
                        events[name] = new CutsceneHandlerChoice(name, script.Guid, script.Behaviour, h.Line, h.Params);
                    }
                }
            }
        }
        return events.Values;
    }

    /// <summary>The handler that an event's name reaches, the first in the name list's order, or null.</summary>
    public CutsceneHandlerChoice? HandlerOf(CutsceneBlock ev) =>
        ev.Name is { } name ? HandlerChoices(ev)?.FirstOrDefault(c => c.Name == name) : null;

    /// <summary>
    /// What a trigger's or a range's name lacks (see docs/editor/cutscene-editor.md#events): no behaviour that its track
    /// sends to has its handler, or null when one does, or when the behaviours are not known. A native handler of the
    /// game's can still take the event, so it is a warning, and the cooker takes the name.
    /// </summary>
    public string? HandlerWarning(CutsceneBlock ev)
    {
        if (ev.Name is not { } name || HandlerChoices(ev) is not { } choices || choices.Any(c => c.Name == name))
        {
            return null;
        }
        var handler = ev.Kind == CutsceneBlockKind.Range ? $"on_{name}_begin or on_{name}_end" : $"on_{name}";
        var who = CutsceneEdits.BindingOf(ev.Parent) is { } id && File.Bindings.FirstOrDefault(b => b.Id == id)?.Name is { } binding
            ? $"No behaviour of {binding}"
            : "No behaviour script";
        return $"{who} has {handler}. A native handler of the game's can still take it.";
    }

    /// <summary>
    /// Adds a trigger at the playhead and selects it (see docs/editor/cutscene-editor.md#events): on the selected event
    /// track, or on an event track of the selected binding or of the selected track's binding, which it adds when there is
    /// none. Its name is the first that the track's behaviours handle, or <c>event</c>.
    /// </summary>
    public void AddEvent()
    {
        if (Document.InTransaction)
        {
            return;
        }
        var target = Selected is { Kind: CutsceneBlockKind.Binding } b ? b : Selected is { } block ? CutsceneEdits.TrackOf(block) : null;
        var targetPath = target == null ? null : CutsceneFile.PathOf(target);
        // The track that the event goes on sends to the target's binding, or, on an event track, to the track's.
        var binding = target?.Kind == CutsceneBlockKind.Binding ? target.Id : CutsceneEdits.BindingOf(target);
        var name = ChoicesFor(binding, range: false) is [var first, ..] ? first.Name : "event";
        string? path = null;
        Key("Add Event", f => path = CutsceneEdits.AddEvent(f, targetPath == null ? null : f.Find(targetPath), _playhead, name, _locked));
        if (path == null || File.Find(path) is not { } added || CutsceneEdits.TrackOf(added) is not { } track)
        {
            return;
        }
        if (binding is { } id && File.Bindings.FirstOrDefault(x => x.Id == id) is { } owner)
        {
            _folds.Remove(CutsceneFile.PathOf(owner));
        }
        Select([path], SelectMode.Replace);
        RevealRequested?.Invoke(CutsceneFile.PathOf(track));
    }

    /// <summary>Why Jump to Handler cannot run, or null when the selected event's name reaches a handler.</summary>
    public string? JumpToHandlerRefusal() =>
        Selected is not { Kind: CutsceneBlockKind.Trigger or CutsceneBlockKind.Range } ev ? "Select a trigger or a range."
        : HandlerOf(ev) == null ? "No behaviour has this event's handler."
        : null;

    /// <summary>Opens the script of the selected event's handler at its line, in the script editor that the settings name.</summary>
    public void JumpToHandler()
    {
        if (Selected is { } ev && HandlerOf(ev) is { } handler && _shell.Assets.Find(handler.Script) is { } script
            && _shell.Assets.FullPath(script) is { } path)
        {
            _shell.OpenScript(path, handler.Line);
        }
    }

    /// <summary>
    /// The kind of value that a handler's parameter takes, from its annotation, or null for one that takes any.
    /// </summary>
    public static CutsceneValueKind? KindOf(HandlerParamKind kind) => kind switch
    {
        HandlerParamKind.Number => CutsceneValueKind.Number,
        HandlerParamKind.Bool => CutsceneValueKind.Bool,
        HandlerParamKind.String => CutsceneValueKind.String,
        HandlerParamKind.Vector => CutsceneValueKind.Vector,
        HandlerParamKind.Entity => CutsceneValueKind.Entity,
        HandlerParamKind.Position => CutsceneValueKind.Position,
        HandlerParamKind.Asset => CutsceneValueKind.Asset,
        _ => null,
    };

    /// <summary>
    /// The payload rows of a trigger or a range (see docs/editor/cutscene-editor.md#payloads): one for each of its
    /// handler's parameters, with the parameter's name and the kind that it takes, then one for each value past them.
    /// A row's value is null when the event has fewer values than its handler takes. At most four.
    /// </summary>
    public IReadOnlyList<CutsceneValueRow> ValueRows(CutsceneBlock ev)
    {
        var values = ev.Values.Select(CutsceneEventValue.Parse).ToList();
        var parameters = HandlerOf(ev)?.Params ?? [];
        var rows = new List<CutsceneValueRow>();
        for (var i = 0; i < Math.Min(Math.Max(values.Count, parameters.Count), CutsceneEventValue.Max); i++)
        {
            var p = i < parameters.Count ? parameters[i] : null;
            rows.Add(new CutsceneValueRow(p?.Name, p == null ? null : KindOf(p.Kind), i < values.Count ? values[i] : null, i < values.Count));
        }
        return rows;
    }

    /// <summary>Renames the selected trigger or range, as one undo entry. False for a name that an event cannot have.</summary>
    public bool RenameEvent(string name)
    {
        name = name.Trim();
        if (Selected is not { Kind: CutsceneBlockKind.Trigger or CutsceneBlockKind.Range } || !CutsceneBlock.IsEventName(name))
        {
            return false;
        }
        EditSelected("Rename Event", b => b.SetName(name));
        return true;
    }

    /// <summary>
    /// Sets a value of the selected trigger or range, as one undo entry. Past its last value, the values between take
    /// their parameters' defaults, so the value lands at its parameter.
    /// </summary>
    public void SetEventValue(int index, CutsceneEventValue value)
    {
        if (Selected is not { Kind: CutsceneBlockKind.Trigger or CutsceneBlockKind.Range } ev || index is < 0 or >= CutsceneEventValue.Max)
        {
            return;
        }
        var rows = ValueRows(ev);
        var firstBinding = File.Bindings.Select(b => b.Id).OfType<int>().Cast<int?>().FirstOrDefault();
        var lines = ev.Values.ToList();
        while (lines.Count < index)
        {
            var kind = lines.Count < rows.Count ? rows[lines.Count].Takes : null;
            lines.Add(CutsceneEventValue.Default(kind ?? CutsceneValueKind.Number, firstBinding).Format());
        }
        var line = value.Format();
        if (index < lines.Count)
        {
            lines[index] = line;
        }
        else
        {
            lines.Add(line);
        }
        EditSelected("Set Event Value", b => b.SetValues(lines));
    }

    /// <summary>Removes a value of the selected trigger or range, as one undo entry. The later values move up.</summary>
    public void RemoveEventValue(int index)
    {
        if (Selected is not { Kind: CutsceneBlockKind.Trigger or CutsceneBlockKind.Range } ev || index < 0 || index >= ev.Values.Count)
        {
            return;
        }
        var lines = ev.Values.ToList();
        lines.RemoveAt(index);
        EditSelected("Remove Event Value", b => b.SetValues(lines));
    }

    /// <summary>Sets <c>fire_when_skipped</c> or <c>fire_on_seek</c> on the selected trigger or range, as one undo entry.</summary>
    public void SetEventFlag(string key, bool on)
    {
        if (Selected is { Kind: CutsceneBlockKind.Trigger or CutsceneBlockKind.Range } && key is "fire_when_skipped" or "fire_on_seek")
        {
            EditSelected(on ? $"Set {key}" : $"Clear {key}", b => b.Set(key, on ? "true" : null));
        }
    }

    // The scripts of a binding's entity's behaviours, by GUID, as the scene or the prefab sets them: a possessed entity's,
    // a spawned prefab's root's, or a slot's stand-in's. Null when the entity is not known.
    IReadOnlyList<string>? BehavioursOf(CutsceneBlock binding)
    {
        if (TargetOf(binding) is not { } target)
        {
            return null;
        }
        if (target.Trim() is ['$', .. var prefab] && prefab.Length > 0)
        {
            return _shell.PrefabRootBehaviours(prefab);
        }
        return PossessRef.Parse(target) is { } entity && _shell.SceneOfGuid(entity.SceneGuid)?.Expanded.Flat.Find(entity.Id) is { } found
            ? [.. found.Behaviours.Select(b => b.Script)]
            : null;
    }

    // What a binding binds, as a prefab's $guid or an entity's @scene/id: what it spawns or possesses, or a slot's stand-in.
    string? TargetOf(CutsceneBlock binding) =>
        binding.Get("provided") != null ? binding.Id is { } id ? StandInOf(id) : null : binding.Get("spawn") ?? binding.Get("possess");
}
