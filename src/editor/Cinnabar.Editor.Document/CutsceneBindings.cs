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

    /// <summary>A binding's <c>spawn</c> value, or a stand-in's, for a prefab: <c>$&lt;guid&gt;</c>.</summary>
    public static string FormatPrefab(string prefabGuid) => $"${prefabGuid}";

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
    public static int AddSpawn(CutsceneFile file, string prefabGuid, string name) => Add(file, name, "spawn", FormatPrefab(prefabGuid));

    /// <summary>
    /// Adds a binding that a script gives when it plays the cutscene, as <c>provided = true</c>, as <see cref="Add"/>
    /// does. Returns its ID.
    /// </summary>
    public static int AddProvided(CutsceneFile file, string name) => Add(file, name, "provided", "true");

    /// <summary>Whether a binding is one that a script gives, with <c>provided = true</c>.</summary>
    public static bool IsProvided(CutsceneBlock binding) => binding.Get("provided")?.Trim() == "true";

    /// <summary>
    /// Adds a binding that spawns a prefab at a place in the world, in World_Position units, with a transform track that
    /// keys no offset from there at a time: the spawn's first key is at the place. Returns the binding's ID.
    /// </summary>
    public static int AddSpawnAt(CutsceneFile file, string prefabGuid, string name, IReadOnlyList<long> position, int tick)
    {
        var id = AddSpawn(file, prefabGuid, name);
        var block = file.Bindings.First(b => b.Id == id);
        block.Set("position", Meters(position));
        CutsceneKeying.SetKeys(file, new KeyTarget.Pose(id, PosePart.Position), tick, [0, 0, 0], "Transform");
        return id;
    }

    // The settings that only a spawned binding has, which the cooker refuses on another kind.
    static readonly string[] SpawnOnly = ["parent", "position", "rotation", "scale"];

    /// <summary>
    /// Points a possessed binding at another entity: its <c>possess</c> changes, and its tracks, which name it by ID,
    /// stay. False for a binding that is not there or that does not possess.
    /// </summary>
    public static bool Rebind(CutsceneFile file, int binding, PossessRef entity)
    {
        if (file.Bindings.FirstOrDefault(b => b.Id == binding) is not { } block || block.Get("possess") == null)
        {
            return false;
        }
        block.Set("possess", Format(entity));
        return true;
    }

    /// <summary>
    /// Makes a binding spawn a prefab at a pose: its <c>possess</c>, <c>provided</c> and <c>policy</c> go, and its
    /// <c>spawn</c> is set, and with a pose, its <c>position</c> (in meters, from World_Position units), <c>rotation</c> and <c>scale</c>.
    /// Its tracks stay. False for a binding that is not there.
    /// </summary>
    public static bool ToSpawned(CutsceneFile file, int binding, string prefabGuid, Pose? pose)
    {
        if (file.Bindings.FirstOrDefault(b => b.Id == binding) is not { } block)
        {
            return false;
        }
        foreach (var key in (string[])["possess", "provided", "policy"])
        {
            block.Set(key, null);
        }
        block.Set("spawn", FormatPrefab(prefabGuid));
        if (pose == null)
        {
            return true;
        }
        block.Set("position", Meters(pose.Position));
        var q = pose.Rotation.Normalized();
        block.Set("rotation", Numbers([q.X, q.Y, q.Z, q.W]));
        block.Set("scale", Numbers(pose.Scale));
        return true;
    }

    /// <summary>
    /// Makes a binding possess an entity: its <c>spawn</c>, <c>provided</c> and the settings only a spawn has go, and its
    /// <c>possess</c> is set. Its tracks stay. False for a binding that is not there.
    /// </summary>
    public static bool ToPossessed(CutsceneFile file, int binding, PossessRef entity)
    {
        if (file.Bindings.FirstOrDefault(b => b.Id == binding) is not { } block)
        {
            return false;
        }
        foreach (var key in (string[])["spawn", "provided", .. SpawnOnly])
        {
            block.Set(key, null);
        }
        block.Set("possess", Format(entity));
        return true;
    }

    /// <summary>
    /// Makes a binding one that a script gives: its <c>possess</c>, <c>spawn</c> and the settings only a spawn has go,
    /// and <c>provided = true</c> is set. Its <c>policy</c> and its tracks stay. False for a binding that is not there.
    /// </summary>
    public static bool ToProvided(CutsceneFile file, int binding)
    {
        if (file.Bindings.FirstOrDefault(b => b.Id == binding) is not { } block)
        {
            return false;
        }
        foreach (var key in (string[])["possess", "spawn", .. SpawnOnly])
        {
            block.Set(key, null);
        }
        block.Set("provided", "true");
        return true;
    }

    /// <summary>The bindings that name a binding as their <c>parent</c>, which the cooker requires to be a spawned one.</summary>
    public static List<CutsceneBlock> ChildrenOf(CutsceneFile file, int binding) =>
        [.. file.Bindings.Where(b => b.Id != binding && b.Get("parent")?.Trim() is { } p
            && int.TryParse(p, NumberStyles.None, CultureInfo.InvariantCulture, out var id) && id == binding)];

    // A position in World_Position units as a binding's position in meters, exactly.
    static string Meters(IReadOnlyList<long> units) => Numbers([.. units.Select(u => u / Pose.Unit)]);

    static string Numbers(IEnumerable<double> values) => $"[{string.Join(", ", values.Select(Number))}]";

    // The shortest text that reads back as the same double, with no exponent, which the cooker does not read.
    static string Number(double value)
    {
        var text = value.ToString("R", CultureInfo.InvariantCulture);
        if (!text.Contains('E'))
        {
            return text;
        }
        return Math.Abs(value) < 1e-20 ? "0" : ((decimal)value).ToString(CultureInfo.InvariantCulture);
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
