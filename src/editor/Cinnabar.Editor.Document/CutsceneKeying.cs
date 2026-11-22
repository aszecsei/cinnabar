using System.Globalization;

namespace Cinnabar.Editor.Document;

/// <summary>What a field's key button shows at the playhead (see docs/editor/cutscene-editor.md#keying).</summary>
public enum KeyState
{
    /// <summary>No track animates the field.</summary>
    None,
    /// <summary>A track animates the field, with no key at the playhead.</summary>
    Track,
    /// <summary>A key at the playhead holds the field's value.</summary>
    Keyed,
    /// <summary>A key is at the playhead, and the world shows another value.</summary>
    Differs,
}

/// <summary>A part of a pose that a transform track keys.</summary>
public enum PosePart
{
    Position,
    Rotation,
    Scale,
}

/// <summary>How a property track keys a field: its channels, and whether its keys step.</summary>
public enum PropertyShape
{
    /// <summary>An f32, in the channel <c>value</c>.</summary>
    Number,
    /// <summary>An integer, a bool or an enum, in the channel <c>value</c>, with constant keys.</summary>
    Stepped,
    /// <summary>A <c>[2]f32</c>, in <c>x</c> and <c>y</c>.</summary>
    Vector2,
    /// <summary>A <c>[3]f32</c>, in <c>x</c>, <c>y</c> and <c>z</c>.</summary>
    Vector3,
    /// <summary>A color, in <c>r</c>, <c>g</c> and <c>b</c>.</summary>
    Color,
}

/// <summary>What a key is of: a binding's component field, through a property track, or a part of its pose, through a transform track.</summary>
public abstract record KeyTarget(int Binding)
{
    public sealed record Property(int Binding, ulong Component, string Field, PropertyShape Shape) : KeyTarget(Binding);

    public sealed record Pose(int Binding, PosePart Part) : KeyTarget(Binding);
}

/// <summary>
/// The entity that a binding possesses: its scene's GUID, in lowercase hex, and its scene ID, with an instance's path
/// folded as <see cref="ScenePath.Id(IReadOnlyList{ulong})"/> folds it.
/// </summary>
public readonly record struct PossessRef(string SceneGuid, ulong Id)
{
    /// <summary>A binding's <c>possess</c> value, <c>@&lt;guid&gt;/&lt;id&gt;</c> or <c>@&lt;guid&gt;/&lt;instance&gt;#&lt;entity&gt;</c>, or null.</summary>
    public static PossessRef? Parse(string? text)
    {
        if (text?.Trim() is not ['@', .. var rest] || rest.IndexOf('/') is not 32 || !rest[..32].All(Uri.IsHexDigit))
        {
            return null;
        }
        var path = new List<ulong>();
        foreach (var part in rest[33..].Split('#'))
        {
            if (part.Length is < 1 or > 16 || !ulong.TryParse(part, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out var id))
            {
                return null;
            }
            path.Add(id);
        }
        var folded = ScenePath.Id(path);
        return folded == 0 ? null : new PossessRef(rest[..32].ToLowerInvariant(), folded);
    }
}

/// <summary>
/// Keys made from the inspector and the viewport (see docs/editor/cutscene-editor.md#keying): which track, section and
/// channel animate a field, what a field's key button shows at a time, and the edits that add a track and set or
/// remove the keys at a time. The text's lines are the cooker's to judge, so these read and write only what they need.
/// </summary>
public static class CutsceneKeying
{
    /// <summary>The binding that possesses an entity, or null.</summary>
    public static int? BindingOf(CutsceneFile file, PossessRef entity) =>
        file.Bindings.FirstOrDefault(b => b.Id != null && PossessRef.Parse(b.Get("possess")) == entity)?.Id;

    /// <summary>The track that keys a target: the property track of its field, or the binding's last transform track.</summary>
    public static CutsceneBlock? TrackOf(CutsceneFile file, KeyTarget target) => target switch
    {
        KeyTarget.Property p => file.Tracks.FirstOrDefault(t => t.TrackKind == "property" && t.Id != null
            && CutsceneEdits.BindingOf(t) == p.Binding
            && ulong.TryParse(t.Get("component")?.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var c) && c == p.Component
            && Unquote(t.Get("field")) == p.Field),
        _ => file.Tracks.LastOrDefault(t => t.TrackKind == "transform" && t.Id != null && CutsceneEdits.BindingOf(t) == target.Binding),
    };

    /// <summary>Why a target's track takes no key from the editor, or null when it does.</summary>
    public static string? Refusal(CutsceneFile file, KeyTarget target, IReadOnlySet<int>? locked)
    {
        if (TrackOf(file, target) is not { } track)
        {
            return null;
        }
        if (CutsceneEdits.IsLocked(track, locked))
        {
            return "Its track is locked.";
        }
        if (target is KeyTarget.Pose && SpaceOf(track) is not ("relative" or "absolute"))
        {
            return "Its track is relative to another binding, which keys from here cannot measure yet.";
        }
        return null;
    }

    /// <summary>Why values, one for each of the target's channels, cannot be its keys, or null when they can.</summary>
    public static string? Refusal(KeyTarget target, IReadOnlyList<double> values)
    {
        foreach (var value in values)
        {
            if (!double.IsFinite(value) || !float.IsFinite((float)value))
            {
                return "The field's value is not a finite number.";
            }
            if (target is KeyTarget.Property { Shape: PropertyShape.Stepped } && (Math.Abs(value) > 1 << 24 || value != Math.Floor(value)))
            {
                return "A key holds a whole number up to 2^24, and the field's value is not one.";
            }
        }
        return null;
    }

    /// <summary>The channels that a target's keys go in, as a section names them.</summary>
    public static IReadOnlyList<string> ChannelsOf(KeyTarget target, CutsceneBlock? section = null) => target switch
    {
        KeyTarget.Pose { Part: PosePart.Position } => ["position_x", "position_y", "position_z"],
        KeyTarget.Pose { Part: PosePart.Rotation } => ["rotation_x", "rotation_y", "rotation_z"],
        KeyTarget.Pose => ["scale_x", "scale_y", "scale_z"],
        KeyTarget.Property { Shape: PropertyShape.Vector2 } => ["x", "y"],
        // A color's section may name its channels x, y and z, which the cooker takes as r, g and b.
        KeyTarget.Property { Shape: PropertyShape.Color } when Channel(section, "x") != null => ["x", "y", "z"],
        KeyTarget.Property { Shape: PropertyShape.Color } => ["r", "g", "b"],
        KeyTarget.Property { Shape: PropertyShape.Vector3 } when Channel(section, "r") != null => ["r", "g", "b"],
        KeyTarget.Property { Shape: PropertyShape.Vector3 } => ["x", "y", "z"],
        _ => ["value"],
    };

    /// <summary>The section that keys at a time go in: the last one of the track over the time that is not additive.</summary>
    public static CutsceneBlock? SectionAt(CutsceneBlock track, int tick) =>
        track.Children.LastOrDefault(s => s.Kind == CutsceneBlockKind.Section && !Additive(s) && s.Start <= tick && tick <= s.End);

    /// <summary>
    /// The keys of a target at a time, one for each of its channels in <see cref="ChannelsOf"/>'s order, null where a
    /// channel has none, in the section that keys there. Empty when no such section is over the time.
    /// </summary>
    public static IReadOnlyList<double?> KeysAt(CutsceneFile file, KeyTarget target, int tick)
    {
        if (TrackOf(file, target) is not { } track || SectionAt(track, tick) is not { Start: { } start } section)
        {
            return [];
        }
        return [.. ChannelsOf(target, section).Select(name =>
            Channel(section, name) is { } channel && KeyAt(channel, tick - start) is { KeyValue: { } text }
            && double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var value) ? value : (double?)null)];
    }

    /// <summary>
    /// What a target's key button shows at a time. <paramref name="differs"/> says whether the keys there, as
    /// <see cref="KeysAt"/> gives them, differ from what the world shows, or is null when the editor does not know what
    /// it shows.
    /// </summary>
    public static KeyState StateOf(CutsceneFile file, KeyTarget target, int tick, Func<IReadOnlyList<double?>, bool>? differs)
    {
        if (TrackOf(file, target) is null)
        {
            return KeyState.None;
        }
        var keys = KeysAt(file, target, tick);
        if (keys.All(k => k == null))
        {
            return KeyState.Track;
        }
        return differs?.Invoke(keys) == true ? KeyState.Differs : KeyState.Keyed;
    }

    /// <summary>Adds the track that keys a target, after the binding's last track, with no section. Returns its path.</summary>
    public static string AddTrack(CutsceneFile file, KeyTarget target, string name)
    {
        if (TrackOf(file, target) is { } there && (target is KeyTarget.Property || there.TrackKind == "transform"))
        {
            return CutsceneFile.PathOf(there);
        }
        var id = file.NextId(CutsceneBlockKind.Track);
        var track = CutsceneBlock.Of(CutsceneBlockKind.Track, $"track {Format(id)} {(target is KeyTarget.Pose ? "transform" : "property")} {TextQuote.Quote(name)}");
        file.Insert(file.Root, CutsceneEdits.InsertAt(file, target.Binding), track);
        track.Set("binding", Format(target.Binding));
        if (target is KeyTarget.Property p)
        {
            track.Set("component", p.Component.ToString(CultureInfo.InvariantCulture));
            track.Set("field", TextQuote.Quote(p.Field));
        }
        return CutsceneFile.PathOf(track);
    }

    /// <summary>
    /// Sets a target's keys at a time, one value for each of its channels in <see cref="ChannelsOf"/>'s order, adding its
    /// track, a section and the channels as they are needed (see
    /// docs/editor/cutscene-editor.md#where-a-key-goes). A key at that time takes the new value and keeps its
    /// interpolation. Does nothing on a track that <see cref="Refusal(CutsceneFile, KeyTarget, IReadOnlySet{int}?)"/>
    /// refuses.
    /// </summary>
    public static void SetKeys(CutsceneFile file, KeyTarget target, int tick, IReadOnlyList<double> values, string trackName,
        IReadOnlySet<int>? locked = null)
    {
        if (values.Count != ChannelsOf(target).Count || Refusal(file, target, locked) != null || Refusal(target, values) != null)
        {
            return;
        }
        var track = file.Find(AddTrack(file, target, trackName))!;
        var section = SectionFor(file, track, tick);
        var time = tick - section.Start!.Value;
        var interpolation = target is KeyTarget.Property { Shape: PropertyShape.Stepped } ? "constant" : "auto";
        var names = ChannelsOf(target, section);
        for (var i = 0; i < names.Count; i++)
        {
            var channel = Channel(section, names[i]) ?? AddChannel(file, section, names[i]);
            var value = target is KeyTarget.Property { Shape: PropertyShape.Stepped } ? values[i].ToString("0", CultureInfo.InvariantCulture) : Format(values[i]);
            if (KeyAt(channel, time) is { } existing)
            {
                existing.SetKeyValue(value);
                continue;
            }
            file.Insert(channel, channel.Children.Count, CutsceneBlock.Of(CutsceneBlockKind.Key,
                $"{IndentUnder(channel)}key {Format(time)} {value} {interpolation}"));
            CutsceneFile.SortChildren(channel);
        }
    }

    /// <summary>
    /// Whether a position key of an absolute track needs the track's origin set first: the track has no <c>origin</c>, and
    /// no section that is not additive keys its position yet.
    /// </summary>
    public static bool NeedsOrigin(CutsceneFile file, KeyTarget target) =>
        target is KeyTarget.Pose { Part: PosePart.Position } && TrackOf(file, target) is { } track && SpaceOf(track) == "absolute"
        && track.Get("origin") == null
        && !track.Children.Where(s => s.Kind == CutsceneBlockKind.Section && !Additive(s))
            .SelectMany(s => s.Children)
            .Any(c => c.Kind == CutsceneBlockKind.Channel && c.Name?.StartsWith("position_", StringComparison.Ordinal) == true);

    /// <summary>A target's absolute track's origin in meters, <c>[0, 0, 0]</c> when it has none, or null for another track.</summary>
    public static double[]? OriginOf(CutsceneFile file, KeyTarget target)
    {
        if (TrackOf(file, target) is not { } track || SpaceOf(track) != "absolute")
        {
            return null;
        }
        if (track.Get("origin")?.Trim().TrimStart('[').TrimEnd(']').Split(',') is not [var x, var y, var z])
        {
            return [0, 0, 0];
        }
        double Meters(string text) => double.TryParse(text.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var m) ? m : 0;
        return [Meters(x), Meters(y), Meters(z)];
    }

    /// <summary>Sets a target's absolute track's origin, in whole meters, which the cooker turns into units exactly.</summary>
    public static void SetOrigin(CutsceneFile file, KeyTarget target, IReadOnlyList<long> meters)
    {
        if (TrackOf(file, target) is { } track && SpaceOf(track) == "absolute")
        {
            track.Set("origin", $"[{string.Join(", ", meters.Select(m => m.ToString(CultureInfo.InvariantCulture)))}]");
        }
    }

    /// <summary>Removes a target's keys at a time, and a channel that loses its last key.</summary>
    public static void RemoveKeys(CutsceneFile file, KeyTarget target, int tick, IReadOnlySet<int>? locked = null)
    {
        if (Refusal(file, target, locked) != null || TrackOf(file, target) is not { } track || SectionAt(track, tick) is not { Start: { } start } section)
        {
            return;
        }
        var paths = ChannelsOf(target, section)
            .Select(name => Channel(section, name) is { } channel ? KeyAt(channel, tick - start) : null)
            .OfType<CutsceneBlock>()
            .Select(CutsceneFile.PathOf)
            .ToList();
        CutsceneEdits.Delete(file, paths, ripple: false, locked);
    }

    /// <summary>A number as a key writes it: the shortest text that reads back as the same f32, with no exponent.</summary>
    public static string Format(double value)
    {
        var single = (float)value;
        if (single == 0)
        {
            return "0";
        }
        var text = single.ToString("R", CultureInfo.InvariantCulture);
        if (!text.Contains('E'))
        {
            return text;
        }
        // Below 1e-28 a decimal holds nothing, and such a key is 0 to the cooker's f32 anyway.
        return decimal.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var exact) ? exact.ToString(CultureInfo.InvariantCulture) : "0";
    }

    static string Format(int value) => value.ToString(CultureInfo.InvariantCulture);

    static string? Unquote(string? text) => text == null ? null : TextQuote.Unquote(text.Trim()) ?? text.Trim();

    static string SpaceOf(CutsceneBlock track) => track.Get("space")?.Trim() ?? "relative";

    static bool Additive(CutsceneBlock section) => section.Get("blend")?.Trim() == "additive";

    static CutsceneBlock? Channel(CutsceneBlock? section, string name) =>
        section?.Children.FirstOrDefault(c => c.Kind == CutsceneBlockKind.Channel && c.Name == name);

    static CutsceneBlock? KeyAt(CutsceneBlock channel, int time) =>
        channel.Children.FirstOrDefault(k => k.Kind == CutsceneBlockKind.Key && k.Start == time);

    // The section that a key at a time goes in: the one over the time, or a new one over the length when the track has
    // none that is not additive, or the nearest one, grown to the time.
    static CutsceneBlock SectionFor(CutsceneFile file, CutsceneBlock track, int tick)
    {
        if (SectionAt(track, tick) is { } over)
        {
            return over;
        }
        var sections = track.Children.Where(s => s.Kind == CutsceneBlockKind.Section && !Additive(s) && s.Start != null && s.End != null).ToList();
        if (sections.Count == 0)
        {
            var id = file.NextId(CutsceneBlockKind.Section);
            var length = Math.Max(file.Length ?? tick, tick);
            var section = CutsceneBlock.Of(CutsceneBlockKind.Section, $"{IndentUnder(track)}section {Format(id)} 0 {Format(length)}");
            file.Insert(track, track.Children.Count, section);
            CutsceneFile.SortChildren(track);
            return section;
        }
        var before = sections.Where(s => s.End < tick).MaxBy(s => s.End!.Value);
        var after = sections.Where(s => s.Start > tick).MinBy(s => s.Start!.Value);
        var grow = before != null && (after == null || tick - before.End!.Value <= after.Start!.Value - tick) ? before : after!;
        var path = CutsceneFile.PathOf(grow);
        // Keys keep their times on the cutscene's time, so a section grown at its start moves its keys back by the growth.
        if (grow.End < tick)
        {
            CutsceneEdits.Trim(file, path, CutsceneEdge.End, tick - grow.End!.Value, ripple: false);
        }
        else
        {
            CutsceneEdits.Trim(file, path, CutsceneEdge.Start, tick - grow.Start!.Value, ripple: false);
        }
        return file.Find(path) ?? grow;
    }

    static CutsceneBlock AddChannel(CutsceneFile file, CutsceneBlock section, string name)
    {
        var channel = CutsceneBlock.Of(CutsceneBlockKind.Channel, $"{IndentUnder(section)}channel {name}");
        file.Insert(section, section.Children.Count, channel);
        return channel;
    }

    // The indent of a block under this one: as its children's, or a tab more than its keyword line.
    static string IndentUnder(CutsceneBlock parent)
    {
        if (parent.Children.FirstOrDefault()?.Head is { } child)
        {
            return CutsceneBlock.Indent(child);
        }
        return parent.Head is { } head ? CutsceneBlock.Indent(head) + "\t" : "";
    }
}
