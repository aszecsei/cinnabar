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
public sealed partial class Keying
{
    readonly EditorShell _shell;

    internal Keying(EditorShell shell) => _shell = shell;

    /// <summary>The cutscene that keys take: the one that holds the preview, in Edit.</summary>
    public CutsceneEditor? Cutscene => _shell.IsEditing ? _shell.CutscenePreview.Owner : null;

    /// <summary>What a key button shows may have changed: the playhead, the cutscene's text, the preview or the values.</summary>
    public event Action? Changed;

    internal void Raise()
    {
        // Values over the preview go with the session, the playhead or the text that they were set or keyed at.
        _shell.PreviewValues.Follow();
        FollowWatches();
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
    public KeyTarget? TargetOf(ulong handle, ulong component, FieldInfo field) =>
        BindingOf(handle) is { } binding ? TargetFor(handle, binding, component, field) : null;

    /// <summary>
    /// What would key a field of an entity that no binding possesses yet, once a binding possesses it, or null: for one
    /// that a binding possesses, that the cutscene cannot name, or with no cutscene.
    /// </summary>
    public KeyTarget? CandidateOf(ulong handle, ulong component, FieldInfo field) =>
        Cutscene != null && BindingOf(handle) == null && PossessOf(handle) != null ? TargetFor(handle, 0, component, field) : null;

    KeyTarget? TargetFor(ulong handle, int binding, ulong component, FieldInfo field)
    {
        if (_shell.World.Find(handle) is not { } node)
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
        if (Cutscene is not { } cutscene)
        {
            return null;
        }
        if (TargetOf(handle, component, field) is not { } target)
        {
            return CandidateOf(handle, component, field) == null
                ? null
                : new KeyButton(KeyState.None, cutscene.Document.InTransaction ? "A drag is under way in the cutscene." : null,
                    $"No binding of {Path.GetFileNameWithoutExtension(cutscene.Document.Path)} possesses this entity. Click to possess it, then add a track and key the field.");
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
        if (CandidateOf(handle, component, field) != null)
        {
            _ = PossessThen([handle], "Possess and Key", component, field, key: true);
            return;
        }
        if (TargetOf(handle, component, field) is { } target && StateOf(handle, component, field) is { Refusal: null })
        {
            Edit($"Key {FieldValues.Humanize(field.Name)}", file => SetKeys(file, handle, target, TrackName(target, field)));
            // Values over the preview of this field alone are keyed now, and stay until the preview shows the key.
            if (_shell.PreviewValues.State is PreviewValuesState.Holding holding
                && holding.Values.Keys.All(k => k.Handle == handle && k.Component == component && k.Field == field.Name))
            {
                _shell.PreviewValues.Keyed();
            }
        }
    }

    /// <summary>Adds the track that keys a field, with no key, as one undo entry.</summary>
    public void AddTrack(ulong handle, ulong component, FieldInfo field)
    {
        if (CandidateOf(handle, component, field) != null)
        {
            _ = PossessThen([handle], "Possess and Add Track", component, field, key: false);
            return;
        }
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

    /// <summary>
    /// What a field's key button shows for several entities, the primary one last: their state when they agree, and
    /// otherwise a track's, with a tooltip that says so. Null unless a track can key the field of each.
    /// </summary>
    public KeyButton? StateOf(IReadOnlyList<ulong> handles, ulong component, FieldInfo field)
    {
        if (handles.Count > 1 && Cutscene is { } cutscene && handles.Any(h => CandidateOf(h, component, field) != null)
            && handles.All(h => TargetOf(h, component, field) != null || CandidateOf(h, component, field) != null))
        {
            return new KeyButton(KeyState.None, cutscene.Document.InTransaction ? "A drag is under way in the cutscene." : null,
                $"No binding of {Path.GetFileNameWithoutExtension(cutscene.Document.Path)} possesses some of the {handles.Count} selected entities. Click to possess them, then key the field of each.");
        }
        if (handles.Count == 1)
        {
            return StateOf(handles[0], component, field);
        }
        var states = handles.Select(h => StateOf(h, component, field)).ToList();
        if (states.Count == 0 || states.Any(s => s == null))
        {
            return null;
        }
        var refusal = states.Select(s => s!.Refusal).FirstOrDefault(r => r != null);
        var same = states.Select(s => s!.State).Distinct().Count() == 1;
        var state = same ? states[0]!.State : KeyState.Track;
        var tip = same
            ? $"{states[^1]!.Tip.Split('\n')[0]} For each of the {handles.Count} selected entities."
            : $"The {handles.Count} selected entities' keys differ at the playhead. Click to key the field of each.";
        return new KeyButton(state, refusal, refusal == null ? tip : $"{tip}\n{refusal}");
    }

    /// <summary>Keys a field of several entities at the playhead, adding tracks where they have none, as one undo entry.</summary>
    public void Key(IReadOnlyList<ulong> handles, ulong component, FieldInfo field)
    {
        if (handles.Count > 1 && handles.Any(h => CandidateOf(h, component, field) != null))
        {
            _ = PossessThen(handles, "Possess and Key", component, field, key: true);
            return;
        }
        if (StateOf(handles, component, field) is not { Refusal: null })
        {
            return;
        }
        Edit($"Key {FieldValues.Humanize(field.Name)}", file =>
        {
            foreach (var handle in handles)
            {
                if (TargetOf(handle, component, field) is { } target)
                {
                    SetKeys(file, handle, target, TrackName(target, field));
                }
            }
        });
    }

    /// <summary>Adds the tracks that key a field of several entities, where they have none, as one undo entry.</summary>
    public void AddTrack(IReadOnlyList<ulong> handles, ulong component, FieldInfo field)
    {
        if (Cutscene is not { } cutscene)
        {
            return;
        }
        var targets = handles.Select(h => TargetOf(h, component, field)).OfType<KeyTarget>().Where(t => CutsceneKeying.TrackOf(cutscene.File, t) == null).ToList();
        if (targets.Count > 0)
        {
            Edit("Add Track", file => targets.ForEach(t => CutsceneKeying.AddTrack(file, t, TrackName(t, field))));
        }
    }

    /// <summary>Removes a field's keys at the playhead from several entities, as one undo entry.</summary>
    public void RemoveKey(IReadOnlyList<ulong> handles, ulong component, FieldInfo field)
    {
        if (Cutscene is not { } cutscene)
        {
            return;
        }
        var targets = handles.Where(h => CanRemoveKey(h, component, field)).Select(h => TargetOf(h, component, field)).OfType<KeyTarget>().ToList();
        if (targets.Count > 0)
        {
            Edit("Remove Key", file => targets.ForEach(t => CutsceneKeying.RemoveKeys(file, t, cutscene.Playhead, cutscene.Locked)));
        }
    }

    /// <summary>Why Key Transform cannot act now, or null when it can.</summary>
    public string? KeyTransformRefusal() => Cutscene is { Document.InTransaction: false } && PossessableSelection().Count > 0
        ? null
        : Refusal(BoundSelection().Select(e => (e.Handle, Parts(e.Binding, PosePart.Position, PosePart.Rotation, PosePart.Scale))));

    /// <summary>
    /// Keys the position, rotation and scale of each selected entity that a binding possesses, as one undo entry. When
    /// some selected entities have no binding, it asks first whether to possess them, and keys them too.
    /// </summary>
    public void KeyTransform()
    {
        if (PossessableSelection() is { Count: > 0 } unbound && _shell.World.Type(SceneEdits.TransformId) is { } type
            && type.Fields.FirstOrDefault(f => f.Name == "position") is { } position)
        {
            _ = PossessThen([.. _shell.Selection.Entities], "Possess and Key Transform", SceneEdits.TransformId, position, key: true, pose: true);
            return;
        }
        if (KeyTransformRefusal() == null)
        {
            KeyBoundTransforms();
        }
    }

    void KeyBoundTransforms() =>
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

    // The selected entities that no binding possesses, which the cutscene can name.
    List<ulong> PossessableSelection() =>
        Cutscene == null ? [] : [.. _shell.Selection.Entities.Where(h => BindingOf(h) == null && PossessOf(h) != null)];

    /// <summary>
    /// Asks whether to possess entities that no binding possesses (see docs/editor/cutscene-editor.md#possessing). The
    /// window answers; with no window, as in tests, nothing is asked and nothing possessed.
    /// </summary>
    public Func<IReadOnlyList<string>, string, Task<bool>>? AskPossess { get; set; }

    // The one question that is open, so a second click or edit does not ask again while it is.
    bool _asking;

    // Asks to possess the entities that no binding possesses, then in one undo entry adds their bindings and keys a field
    // of all of them, or with pose, their position, rotation and scale; or without key, adds the field's tracks.
    async Task PossessThen(IReadOnlyList<ulong> handles, string label, ulong component, FieldInfo field, bool key, bool pose = false)
    {
        if (Cutscene is not { } cutscene || AskPossess is not { } ask || _asking)
        {
            return;
        }
        var unbound = handles.Where(h => BindingOf(h) == null && PossessOf(h) != null).ToList();
        bool yes;
        _asking = true;
        try
        {
            yes = await ask([.. unbound.Select(h => _shell.World.Find(h)?.Name ?? "?")], Path.GetFileNameWithoutExtension(cutscene.Document.Path));
        }
        finally
        {
            _asking = false;
        }
        if (Cutscene != cutscene)
        {
            return;
        }
        if (!yes)
        {
            // Key Transform still keys the selected entities that a binding has.
            if (pose && KeyTransformRefusal() == null && BoundSelection().Count > 0)
            {
                KeyBoundTransforms();
            }
            return;
        }
        Edit(label, file =>
        {
            var bindings = handles.ToDictionary(h => h, h => BindingOf(h));
            foreach (var handle in unbound)
            {
                if (PossessOf(handle) is { } entity)
                {
                    bindings[handle] = CutsceneKeying.AddBinding(file, entity, _shell.World.Find(handle)?.Name ?? "Entity");
                }
            }
            foreach (var (handle, binding) in bindings)
            {
                if (binding is not { } b)
                {
                    continue;
                }
                var targets = pose ? Parts(b, PosePart.Position, PosePart.Rotation, PosePart.Scale) : [.. new[] { TargetFor(handle, b, component, field) }.OfType<KeyTarget>()];
                foreach (var target in targets)
                {
                    if (key)
                    {
                        SetKeys(file, handle, target, pose ? "Transform" : TrackName(target, field));
                    }
                    else
                    {
                        CutsceneKeying.AddTrack(file, target, TrackName(target, field));
                    }
                }
            }
        });
    }

    /// <summary>
    /// With auto-key and add tracks on, an edit of an entity that no binding possesses asks once whether to possess it.
    /// A yes possesses it, as one undo entry, so its next edit keys; a no sends its edits to the scene while the tab is
    /// open.
    /// </summary>
    async Task AskAutoPossess(ulong handle)
    {
        if (Cutscene is not { } cutscene || AskPossess is not { } ask || _asking || PossessOf(handle) is not { } entity)
        {
            return;
        }
        bool yes;
        _asking = true;
        try
        {
            yes = await ask([_shell.World.Find(handle)?.Name ?? "?"], Path.GetFileNameWithoutExtension(cutscene.Document.Path));
        }
        finally
        {
            _asking = false;
        }
        if (Cutscene != cutscene)
        {
            return;
        }
        if (!yes)
        {
            cutscene.DeclinedPossess.Add(entity);
            Raise();
            return;
        }
        if (BindingOf(handle) == null)
        {
            Edit($"Possess {_shell.World.Find(handle)?.Name}", file => CutsceneKeying.AddBinding(file, entity, _shell.World.Find(handle)?.Name ?? "Entity"));
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
        // Values over the preview are the editor's own, so their component needs no word from the game.
        var overlay = _shell.PreviewValues.ComponentOf(handle, component);
        var held = overlay != null || ComponentHeld(handle, component, type);
        var shown = overlay ?? document;
        if (held && overlay == null)
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
        if (CutsceneKeying.RelativeToOf(file, target) is { } relativeTo)
        {
            // A track relative to another binding keys the world's pose in the other's pose, as the game measures them.
            if (overlay != null && node.Parent != 0 && _shell.World.ShownPreviewOf(handle)?.Values != _shell.PreviewValues.Serial)
            {
                return (null, "Waiting for the preview to show the values.");
            }
            if (HandleOfBinding(relativeTo) is not { } other)
            {
                return (null, $"Its track is relative to binding {relativeTo}, which possesses no entity of an open scene.");
            }
            var otherHeld = _shell.World.Type(SceneEdits.TransformId) is { } transformType && ComponentHeld(other, SceneEdits.TransformId, transformType);
            if (otherHeld && Fresh(other) is { } otherWait)
            {
                return (null, otherWait);
            }
            if (WorldPose(handle, held) is not { } shownPose || WorldPose(other, otherHeld) is not { } otherPose)
            {
                return (null, $"Waiting for the game to send the pose of binding {relativeTo}.");
            }
            var (inOther, rotation) = PoseKeys.RelativeTo(shownPose.Units, shownPose.Rotation, otherPose.Units, otherPose.Rotation);
            return part == PosePart.Rotation
                ? (PoseKeys.Unwrap(PoseKeys.Euler(rotation), CutsceneKeying.NearKeys(file, target, cutscene.Playhead)), null)
                : (inOther, null);
        }
        if (CutsceneKeying.OriginOf(file, target) is { } originMeters)
        {
            // An absolute track keys the world's pose: a child's composed Transform, which the game composes, so values
            // over a child's Local_Transform key once the world shows them.
            if (overlay != null && node.Parent != 0 && _shell.World.ShownPreviewOf(handle)?.Values != _shell.PreviewValues.Serial)
            {
                return (null, "Waiting for the preview to show the values.");
            }
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
        var shown = _shell.PreviewValues.ComponentOf(handle, SceneEdits.TransformId)
            ?? (held != false ? _shell.World.ShownOf(handle, SceneEdits.TransformId) : null);
        var bytes = shown ?? values.Components.FirstOrDefault(c => c.Id == SceneEdits.TransformId)?.Data;
        if (bytes == null || type.Fields.FirstOrDefault(f => f.Name == "position") is not { } position
            || type.Fields.FirstOrDefault(f => f.Name == "rotation") is not { } rotation
            || KeyValues.Units(position, bytes) is not { } units || KeyValues.Numbers(rotation, bytes) is not [var x, var y, var z, var w])
        {
            return null;
        }
        return (units, new Quat(x, y, z, w));
    }

    // The entity that a binding of the keyed cutscene possesses in an open scene, or null: for a spawned binding, or one
    // whose scene is not open.
    ulong? HandleOfBinding(int binding)
    {
        if (Cutscene?.File.Bindings.FirstOrDefault(b => b.Id == binding) is not { } block || PossessRef.Parse(block.Get("possess")) is not { } entity
            || _shell.SceneOfGuid(entity.SceneGuid) is not { } scene || _shell.World.FindScene(scene.Number, entity.Id) is not { } node)
        {
            return null;
        }
        return node.Handle;
    }

    // The entities that the keyed cutscene's tracks are relative to, which the editor watches so their poses are at hand.
    readonly HashSet<ulong> _watched = [];

    /// <summary>Whether keying watches an entity, as the other binding of a track relative to it.</summary>
    public bool Watches(ulong handle) => _watched.Contains(handle);

    // The one writer of the watches: those of the cutscene that holds the preview now, and none without one.
    void FollowWatches()
    {
        var wanted = new HashSet<ulong>();
        if (Cutscene is { } cutscene)
        {
            foreach (var track in cutscene.File.Tracks.Where(t => t.TrackKind == "transform"))
            {
                if (CutsceneEdits.BindingOf(track) is { } binding && CutsceneKeying.RelativeToOf(cutscene.File, new KeyTarget.Pose(binding, PosePart.Position)) is { } other
                    && HandleOfBinding(other) is { } handle)
                {
                    wanted.Add(handle);
                }
            }
        }
        foreach (var gone in _watched.Except(wanted).ToList())
        {
            _watched.Remove(gone);
            _shell.Unwatch(gone);
        }
        foreach (var added in wanted.Except(_watched).ToList())
        {
            _watched.Add(added);
            _shell.Watch(added);
        }
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
        // The game keeps the preview's time within the cutscene's range, so past its end the world holds the end's pose.
        var playhead = Math.Clamp(open.Editor.Playhead, open.RangeStart, Math.Max(open.RangeStart, open.RangeEnd));
        if (_shell.World.ShownPreviewOf(handle) is not { } shown || shown.Ticket != open.Ticket || shown.Tick != playhead)
        {
            return "Waiting for the preview to show the playhead.";
        }
        // Values over the preview from before the last were dropped may still show in fields that the editor does not
        // hold now.
        if (!_shell.PreviewValues.Shows(shown.Values))
        {
            return "Waiting for the preview to show the values.";
        }
        // The world must show the cutscene as the tab has it: its unsaved text's blob, or the saved file unchanged.
        if (open.Unsaved ? shown.Blob == 0 || shown.Blob != open.Editor.CleanBlob : open.Editor.Document.IsDirty)
        {
            return "Waiting for the preview to show the cutscene's last edit.";
        }
        return null;
    }

    // Whether something in the world holds a field of an entity's component, so the world may show another value.
    bool ComponentHeld(ulong handle, ulong component, ComponentType type) =>
        type.Fields.Any(f => _shell.World.IsHeld(handle, component, Hash(f.Name)));

    static ulong Hash(string field) => Fnv.Hash64(System.Text.Encoding.UTF8.GetBytes(field));

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
