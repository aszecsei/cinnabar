using System.Globalization;

namespace Cinnabar.Editor.Document;

/// <summary>
/// The edits of a cutscene's bindings themselves (see docs/editor/cutscene-editor.md#bindings): add one that possesses
/// an entity or spawns a prefab, point one at another entity, and remove one with its tracks. As the keying edits do,
/// they read and write only the lines they need, and leave the rest to the cooker.
/// </summary>
public static class CutsceneBindings
{
    // The settings whose value is a binding's ID, on a binding, a track or a section.
    static readonly string[] IdSettings = ["parent", "camera", "look_at", "follow", "focus"];

    /// <summary>A binding's <c>possess</c> value for an entity: <c>@&lt;guid&gt;/&lt;id&gt;</c>.</summary>
    public static string Format(PossessRef entity) => $"@{entity.SceneGuid}/{entity.Id:x16}";

    /// <summary>The prefab's GUID that a binding's <c>spawn = $&lt;guid&gt;</c> names, or null.</summary>
    public static string? SpawnOf(CutsceneBlock binding) =>
        binding.Get("spawn")?.Trim() is ['$', .. var guid] && guid.Length > 0 ? guid : null;

    /// <summary>
    /// Adds a binding with one setting, <c>possess</c> or <c>spawn</c>, after the last binding, or with none, before the
    /// first track. Its name is the one given, or with a number after it when another binding has that name. Returns its ID.
    /// </summary>
    public static int Add(CutsceneFile file, string name, string key, string value)
    {
        var id = file.NextId(CutsceneBlockKind.Binding);
        var names = file.Bindings.Select(b => b.Name).ToHashSet();
        var unique = name;
        for (var n = 2; names.Contains(unique); n++)
        {
            unique = $"{name} {n}";
        }
        var binding = CutsceneBlock.Of(CutsceneBlockKind.Binding, $"binding {id.ToString(CultureInfo.InvariantCulture)} {TextQuote.Quote(unique)}");
        var children = file.Root.Children.ToList();
        var last = children.FindLastIndex(c => c.Kind == CutsceneBlockKind.Binding);
        var index = last >= 0 ? last + 1 : children.FindIndex(c => c.Kind == CutsceneBlockKind.Track);
        file.Insert(file.Root, index >= 0 ? index : children.Count, binding);
        binding.Set(key, value);
        return id;
    }

    /// <summary>Adds a binding that spawns a prefab, as <c>spawn = $&lt;guid&gt;</c>, as <see cref="Add"/> does. Returns its ID.</summary>
    public static int AddSpawn(CutsceneFile file, string prefabGuid, string name) => Add(file, name, "spawn", $"${prefabGuid}");

    /// <summary>
    /// Points a possessed binding at another entity: its <c>possess</c> changes, and its tracks, which name it by ID,
    /// stay. False for a binding that is not there or that spawns.
    /// </summary>
    public static bool Rebind(CutsceneFile file, int binding, PossessRef entity)
    {
        if (file.Bindings.FirstOrDefault(b => b.Id == binding) is not { } block || block.Get("spawn") != null)
        {
            return false;
        }
        block.Set("possess", Format(entity));
        return true;
    }

    /// <summary>The tracks of a binding, which name it with <c>binding = &lt;id&gt;</c>.</summary>
    public static List<CutsceneBlock> TracksOf(CutsceneFile file, int binding) =>
        [.. file.Tracks.Where(t => CutsceneEdits.BindingOf(t) == binding)];

    /// <summary>
    /// The blocks outside a binding and its tracks that name it by ID: another binding's <c>parent</c> or constraints, a
    /// camera cut's <c>camera</c> or constraints, a transform track's <c>space = relative &lt;id&gt;</c>, an event's
    /// <c>value = entity &lt;id&gt;</c>, and a sub-sequence's <c>bind &lt;child&gt; = &lt;id&gt;</c>. Removing the
    /// binding would leave them naming nothing.
    /// </summary>
    public static List<CutsceneBlock> ReferencesTo(CutsceneFile file, int binding)
    {
        // What a remove takes with it: the binding, and its tracks with everything under them.
        var removed = TracksOf(file, binding).SelectMany(t => t.Descendants()).ToHashSet();
        if (file.Bindings.FirstOrDefault(b => b.Id == binding) is { } own)
        {
            removed.Add(own);
        }
        return [.. file.Root.Descendants().Where(b => !removed.Contains(b) && b.Settings.Any(s => Names(s.Key, s.Value, binding)))];
    }

    static bool Names(string key, string value, int binding)
    {
        var words = value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        string? id = key switch
        {
            _ when IdSettings.Contains(key) => words is [var w] ? w : null,
            "space" => words is ["relative", var w] ? w : null,
            "value" => words is ["entity", var w] ? w : null,
            _ when key.StartsWith("bind ", StringComparison.Ordinal) => words is [var w] ? w : null,
            _ => null,
        };
        return id != null && int.TryParse(id, NumberStyles.None, CultureInfo.InvariantCulture, out var named) && named == binding;
    }

    /// <summary>
    /// Removes a binding and its tracks. False, with nothing removed, for a binding that is not there or that other
    /// blocks still name (see <see cref="ReferencesTo"/>).
    /// </summary>
    public static bool Remove(CutsceneFile file, int binding)
    {
        if (file.Bindings.FirstOrDefault(b => b.Id == binding) is not { } block || ReferencesTo(file, binding).Count > 0)
        {
            return false;
        }
        foreach (var track in TracksOf(file, binding))
        {
            file.Remove(track);
        }
        file.Remove(block);
        return true;
    }
}
