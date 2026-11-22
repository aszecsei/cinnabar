using Cinnabar.Editor.Cutscenes;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Shell;

/// <summary>What a field's key button shows: its state, why it takes no key now or null, and its tooltip.</summary>
public sealed record KeyButton(KeyState State, string? Refusal, string Tip);

/// <summary>
/// Keys from the inspector and the viewport (see docs/editor/cutscene-editor.md#keying): the cutscene that holds the
/// preview takes them, at its playhead, for the entities that its bindings possess. A field that the preview or an
/// override holds is keyed as the world shows it, which the game sends with the values; the document's value is the
/// value of a field that nothing holds.
/// </summary>
public sealed class Keying
{
    readonly EditorShell _shell;

    internal Keying(EditorShell shell) => _shell = shell;

    /// <summary>The cutscene that keys take: the one that holds the preview, in Edit.</summary>
    public CutsceneEditor? Cutscene => _shell.IsEditing ? _shell.CutscenePreview.Owner : null;

    /// <summary>What a key button shows may have changed: the playhead, the cutscene's text, the preview or the values.</summary>
    public event Action? Changed;

    internal void Raise()
    {
        Changed?.Invoke();
        _shell.Commands.InvalidateAll();
    }

    /// <summary>The entity that a binding would possess for a handle, or null for one of no scene, or of a scene with no GUID yet.</summary>
    public PossessRef? PossessOf(ulong handle) =>
        _shell.World.Find(handle) is { SceneId: not 0 } node && _shell.SceneOf(node) is { } scene && _shell.GuidOf(scene) is { Length: 32 } guid
            ? new PossessRef(guid.ToLowerInvariant(), node.SceneId)
            : null;

    /// <summary>The binding of the keyed cutscene that possesses an entity, or null.</summary>
    public int? BindingOf(ulong handle) =>
        Cutscene is { } cutscene && PossessOf(handle) is { } entity ? CutsceneKeying.BindingOf(cutscene.File, entity) : null;

    /// <summary>
    /// What keys a field of a bound entity: a pose part for a root's Transform or a child's Local_Transform, or the field
    /// for another field that a property track animates. Null for an entity that no binding possesses, and for a field
    /// that no track keys.
    /// </summary>
    public KeyTarget? TargetOf(ulong handle, ulong component, FieldInfo field)
    {
        if (BindingOf(handle) is not { } binding || _shell.World.Find(handle) is not { } node)
        {
            return null;
        }
        var poseComponent = node.Parent != 0 ? SceneEdits.LocalTransformId : SceneEdits.TransformId;
        if (component is SceneEdits.TransformId or SceneEdits.LocalTransformId or SceneEdits.PreviousTransformId)
        {
            if (component != poseComponent)
            {
                return null;
            }
            return field.Name switch
            {
                "position" or "offset" => new KeyTarget.Pose(binding, PosePart.Position),
                "rotation" => new KeyTarget.Pose(binding, PosePart.Rotation),
                "scale" => new KeyTarget.Pose(binding, PosePart.Scale),
                _ => null,
            };
        }
        return KeyValues.Shape(field) is { } shape ? new KeyTarget.Property(binding, component, field.Name, shape) : null;
    }

    /// <summary>What a field's key button shows at the playhead, or null for a field that has none.</summary>
    public KeyButton? StateOf(ulong handle, ulong component, FieldInfo field)
    {
        if (Cutscene is not { } cutscene || TargetOf(handle, component, field) is not { } target)
        {
            return null;
        }
        var file = cutscene.File;
        var refusal = CutsceneKeying.Refusal(file, target, cutscene.Locked) ?? (cutscene.Document.InTransaction ? "A drag is under way in the cutscene." : null);
        var (values, wait) = ValuesOf(handle, target);
        var state = CutsceneKeying.StateOf(file, target, cutscene.Playhead,
            values == null || wait != null ? null : keys => !Same(target, keys, values));
        refusal ??= wait ?? (values == null ? "The game has not sent the field's value." : CutsceneKeying.Refusal(target, values));
        var where = $"at {CutsceneTime.Timecode(cutscene.Playhead, cutscene.File.Rate)} in {Path.GetFileNameWithoutExtension(cutscene.Document.Path)}";
        var tip = state switch
        {
            KeyState.None => $"Add a track and key the field {where}.",
            KeyState.Track => $"Key the field {where}.",
            KeyState.Keyed => $"A key holds the field {where}. Click to key it again.",
            _ => $"The field differs from its key {where}. Click to key what it shows.",
        };
        return new KeyButton(state, refusal, refusal == null ? tip : $"{tip}\n{refusal}");
    }

    /// <summary>Keys a field at the playhead, adding its track when it has none, as one undo entry.</summary>
    public void Key(ulong handle, ulong component, FieldInfo field)
    {
        if (TargetOf(handle, component, field) is { } target && StateOf(handle, component, field) is { Refusal: null })
        {
            Edit($"Key {FieldValues.Humanize(field.Name)}", file => SetKeys(file, handle, target, TrackName(target, field)));
        }
    }

    /// <summary>Adds the track that keys a field, with no key, as one undo entry.</summary>
    public void AddTrack(ulong handle, ulong component, FieldInfo field)
    {
        if (Cutscene is { } cutscene && TargetOf(handle, component, field) is { } target && CutsceneKeying.TrackOf(cutscene.File, target) == null)
        {
            Edit("Add Track", file => CutsceneKeying.AddTrack(file, target, TrackName(target, field)));
        }
    }

    /// <summary>Removes a field's keys at the playhead, as one undo entry.</summary>
    public void RemoveKey(ulong handle, ulong component, FieldInfo field)
    {
        if (Cutscene is { } cutscene && TargetOf(handle, component, field) is { } target && CanRemoveKey(handle, component, field))
        {
            Edit("Remove Key", file => CutsceneKeying.RemoveKeys(file, target, cutscene.Playhead, cutscene.Locked));
        }
    }

    /// <summary>Whether a field has keys at the playhead that its track lets go.</summary>
    public bool CanRemoveKey(ulong handle, ulong component, FieldInfo field) =>
        Cutscene is { Document.InTransaction: false } cutscene && TargetOf(handle, component, field) is { } target
        && CutsceneKeying.Refusal(cutscene.File, target, cutscene.Locked) == null
        && CutsceneKeying.KeysAt(cutscene.File, target, cutscene.Playhead).Any(k => k != null);

    /// <summary>Shows the cutscene's tab and selects the track that keys a field, unfolded and in view.</summary>
    public void GoToTrack(ulong handle, ulong component, FieldInfo field)
    {
        if (Cutscene is { } cutscene && TargetOf(handle, component, field) is { } target && CutsceneKeying.TrackOf(cutscene.File, target) is { } track)
        {
            _shell.Layout.ShowDocument(cutscene);
            cutscene.Reveal(track);
        }
    }

    /// <summary>Why Key Transform cannot act now, or null when it can.</summary>
    public string? KeyTransformRefusal() => Refusal(BoundSelection().Select(e => (e.Handle, Parts(e.Binding, PosePart.Position, PosePart.Rotation, PosePart.Scale))));

    /// <summary>Keys the position, rotation and scale of each selected entity that a binding possesses, as one undo entry.</summary>
    public void KeyTransform()
    {
        if (KeyTransformRefusal() == null)
        {
            Edit("Key Transform", file =>
            {
                foreach (var (handle, binding) in BoundSelection())
                {
                    foreach (var target in Parts(binding, PosePart.Position, PosePart.Rotation, PosePart.Scale))
                    {
                        SetKeys(file, handle, target, "Transform");
                    }
                }
            });
        }
    }

    /// <summary>Why Key Tracked Fields cannot act now, or null when it can.</summary>
    public string? KeyTrackedFieldsRefusal() => Refusal(BoundSelection().Select(e => (e.Handle, Tracked(e.Handle, e.Binding))));

    /// <summary>Keys every field of each selected bound entity that a track animates, as one undo entry.</summary>
    public void KeyTrackedFields()
    {
        if (KeyTrackedFieldsRefusal() == null)
        {
            Edit("Key Tracked Fields", file =>
            {
                foreach (var (handle, binding) in BoundSelection())
                {
                    foreach (var target in Tracked(handle, binding))
                    {
                        SetKeys(file, handle, target, "Transform");
                    }
                }
            });
        }
    }

    // The one way a key goes into the cutscene: one entry in its history, which Undo then follows, even from the viewport.
    void Edit(string label, Action<CutsceneFile> edit)
    {
        if (Cutscene is { } cutscene)
        {
            cutscene.Key(label, edit);
        }
    }

    // The selected entities that a binding of the keyed cutscene possesses.
    List<(ulong Handle, int Binding)> BoundSelection() =>
        [.. _shell.Selection.Entities.Select(h => (Handle: h, Binding: BindingOf(h))).Where(e => e.Binding != null).Select(e => (e.Handle, e.Binding!.Value))];

    static List<KeyTarget> Parts(int binding, params PosePart[] parts) => [.. parts.Select(p => (KeyTarget)new KeyTarget.Pose(binding, p))];

    // The targets of a binding that a track animates: its property tracks whose field the entity has, and the pose parts
    // that its transform track keys.
    List<KeyTarget> Tracked(ulong handle, int binding)
    {
        if (Cutscene is not { } cutscene || _shell.World.Find(handle) is not { } node)
        {
            return [];
        }
        var targets = new List<KeyTarget>();
        foreach (var track in cutscene.File.Tracks.Where(t => CutsceneEdits.BindingOf(t) == binding && t.TrackKind == "property"))
        {
            if (ulong.TryParse(track.Get("component")?.Trim(), out var component) && node.Components.Contains(component)
                && _shell.World.Type(component)?.Fields.FirstOrDefault(f => f.Name == TextQuote.Unquote(track.Get("field")?.Trim() ?? "")) is { } field
                && TargetOf(handle, component, field) is { } target)
            {
                targets.Add(target);
            }
        }
        if (cutscene.File.Tracks.LastOrDefault(t => CutsceneEdits.BindingOf(t) == binding && t.TrackKind == "transform") is { } transform)
        {
            var channels = transform.Descendants().Where(b => b.Kind == CutsceneBlockKind.Channel).Select(c => c.Name ?? "").ToHashSet();
            foreach (var part in new[] { PosePart.Position, PosePart.Rotation, PosePart.Scale })
            {
                var target = new KeyTarget.Pose(binding, part);
                if (CutsceneKeying.ChannelsOf(target).Any(channels.Contains))
                {
                    targets.Add(target);
                }
            }
        }
        return targets;
    }

    // Why the targets of some entities cannot all be keyed now, or null when they can.
    string? Refusal(IEnumerable<(ulong Handle, List<KeyTarget> Targets)> entities)
    {
        if (Cutscene is not { } cutscene)
        {
            return "No cutscene holds the preview.";
        }
        if (cutscene.Document.InTransaction)
        {
            return "A drag is under way in the cutscene.";
        }
        var any = false;
        foreach (var (handle, targets) in entities)
        {
            foreach (var target in targets)
            {
                any = true;
                var (values, wait) = ValuesOf(handle, target);
                var why = CutsceneKeying.Refusal(cutscene.File, target, cutscene.Locked) ?? wait
                    ?? (values == null ? "The game has not sent the entity's values." : CutsceneKeying.Refusal(target, values));
                if (why != null)
                {
                    return why;
                }
            }
        }
        return any ? null : "No selected entity is bound in the cutscene, or has a field with a track.";
    }

    void SetKeys(CutsceneFile file, ulong handle, KeyTarget target, string trackName)
    {
        if (Cutscene is not { } cutscene)
        {
            return;
        }
        if (CutsceneKeying.NeedsOrigin(file, target) && WorldPose(handle) is { } world)
        {
            CutsceneKeying.SetOrigin(file, target, PoseKeys.OriginNear(world.Units).Meters);
        }
        if (ValuesOf(handle, target, file) is ({ } values, null))
        {
            CutsceneKeying.SetKeys(file, target, cutscene.Playhead, values, trackName, cutscene.Locked);
        }
    }

    static string TrackName(KeyTarget target, FieldInfo field) => target is KeyTarget.Pose ? "Transform" : FieldValues.Humanize(field.Name);

    // A target's values for keys at the playhead, one for each channel, and why they must wait, or null. A field that
    // the preview or an override holds takes what the world shows, which is current only while the preview stands at the
    // playhead and the game has shown it there.
    (double[]? Values, string? Wait) ValuesOf(ulong handle, KeyTarget target, CutsceneFile? file = null)
    {
        if (Cutscene is not { } cutscene || _shell.World.Find(handle) is not { } node || _shell.World.Values(handle) is not { } values)
        {
            return (null, null);
        }
        file ??= cutscene.File;
        var component = target switch
        {
            KeyTarget.Property p => p.Component,
            _ => node.Parent != 0 ? SceneEdits.LocalTransformId : SceneEdits.TransformId,
        };
        var document = values.Components.FirstOrDefault(c => c.Id == component)?.Data;
        if (document == null || _shell.World.Type(component) is not { } type)
        {
            return (null, null);
        }
        var held = type.Fields.Any(f => _shell.World.IsHeld(handle, component, Fnv.Hash64(System.Text.Encoding.UTF8.GetBytes(f.Name))));
        var shown = document;
        if (held)
        {
            if (Fresh(handle) is { } wait)
            {
                return (null, wait);
            }
            shown = _shell.World.ShownOf(handle, component) ?? document;
        }
        FieldInfo? Field(string name) => type.Fields.FirstOrDefault(f => f.Name == name);
        switch (target)
        {
            case KeyTarget.Property p:
                return (Field(p.Field) is { } f ? KeyValues.Numbers(f, shown) : null, null);
            case KeyTarget.Pose { Part: PosePart.Scale }:
                return (Field("scale") is { } scale ? KeyValues.Numbers(scale, shown) : null, null);
        }
        var part = ((KeyTarget.Pose)target).Part;
        if (CutsceneKeying.OriginOf(file, target) is { } originMeters)
        {
            // An absolute track keys the world's pose: a child's composed Transform.
            if (WorldPose(handle, held) is not { } world)
            {
                return (null, null);
            }
            if (part == PosePart.Rotation)
            {
                return (PoseKeys.Unwrap(PoseKeys.Euler(world.Rotation), CutsceneKeying.NearKeys(file, target, cutscene.Playhead)), null);
            }
            var origin = CutsceneKeying.NeedsOrigin(file, target) ? PoseKeys.OriginNear(world.Units).Units : PoseKeys.Units(originMeters);
            return (PoseKeys.AbsolutePosition(world.Units, origin), null);
        }
        if (Field("rotation") is not { } rotationField || KeyValues.Numbers(rotationField, document) is not [var ox, var oy, var oz, var ow]
            || KeyValues.Numbers(rotationField, shown) is not [var sx, var sy, var sz, var sw])
        {
            return (null, null);
        }
        var own = new Quat(ox, oy, oz, ow);
        if (part == PosePart.Rotation)
        {
            return (PoseKeys.Unwrap(PoseKeys.RelativeRotation(own, new Quat(sx, sy, sz, sw)), CutsceneKeying.NearKeys(file, target, cutscene.Playhead)), null);
        }
        Vec3 offset;
        if (node.Parent != 0)
        {
            if (Field("offset") is not { } offsetField || KeyValues.Numbers(offsetField, document) is not { } a || KeyValues.Numbers(offsetField, shown) is not { } b)
            {
                return (null, null);
            }
            offset = Vec3.From(b) - Vec3.From(a);
        }
        else
        {
            if (Field("position") is not { } positionField || KeyValues.Units(positionField, document) is not { } a || KeyValues.Units(positionField, shown) is not { } b)
            {
                return (null, null);
            }
            offset = new Vec3((b[0] - a[0]) / PoseKeys.UnitsPerMeter, (b[1] - a[1]) / PoseKeys.UnitsPerMeter, (b[2] - a[2]) / PoseKeys.UnitsPerMeter);
        }
        return (PoseKeys.RelativePosition(offset, own), null);
    }

    // The entity's pose in the world, from its Transform as the world shows it, or as the document has it when nothing
    // holds the pose.
    (long[] Units, Quat Rotation)? WorldPose(ulong handle, bool? held = null)
    {
        if (_shell.World.Values(handle) is not { } values || _shell.World.Type(SceneEdits.TransformId) is not { } type)
        {
            return null;
        }
        var shown = held != false ? _shell.World.ShownOf(handle, SceneEdits.TransformId) : null;
        var bytes = shown ?? values.Components.FirstOrDefault(c => c.Id == SceneEdits.TransformId)?.Data;
        if (bytes == null || type.Fields.FirstOrDefault(f => f.Name == "position") is not { } position
            || type.Fields.FirstOrDefault(f => f.Name == "rotation") is not { } rotation
            || KeyValues.Units(position, bytes) is not { } units || KeyValues.Numbers(rotation, bytes) is not [var x, var y, var z, var w])
        {
            return null;
        }
        return (units, new Quat(x, y, z, w));
    }

    // Why what the world shows of an entity is not yet the playhead's, or null when it is.
    string? Fresh(ulong handle)
    {
        if (_shell.CutscenePreview.State is not CutscenePreviewState.Open open || open.Editor != Cutscene)
        {
            return "Another preview holds the field. Key it when the preview is this cutscene's.";
        }
        if (open.Playing)
        {
            return "Pause the preview to key.";
        }
        if (_shell.World.ShownPreviewOf(handle) is not { } shown || shown.Ticket != open.Ticket || shown.Tick != open.Editor.Playhead)
        {
            return "Waiting for the preview to show the playhead.";
        }
        return null;
    }

    static bool Same(KeyTarget target, IReadOnlyList<double?> keys, IReadOnlyList<double> values)
    {
        if (target is KeyTarget.Pose { Part: PosePart.Rotation })
        {
            return PoseKeys.SameRotation(keys, values);
        }
        var stepped = target is KeyTarget.Property { Shape: PropertyShape.Stepped };
        return keys.Select((k, i) => k == null || i >= values.Count || KeyValues.Same(k.Value, values[i], stepped)).All(same => same);
    }
}
