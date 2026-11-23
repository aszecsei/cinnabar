using Cinnabar.Editor.Cutscenes;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using FieldInfo = Cinnabar.Editor.Link.Protocol.FieldInfo;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// Where the lens of a camera binding is edited (see docs/editor/cutscene-editor.md#lens): a spawned camera's by its
/// binding's ID, a possessed camera's through its entity as the inspector edits it, or nowhere, with why.
/// </summary>
public abstract record LensTarget
{
    private protected LensTarget()
    {
    }

    /// <summary>A camera that the binding spawns from a prefab, whose entity only the game has.</summary>
    public sealed record Spawned(int Binding, string Prefab) : LensTarget;

    /// <summary>A camera that the binding possesses, by the entity's handle.</summary>
    public sealed record Possessed(int Binding, ulong Handle) : LensTarget;

    /// <summary>No lens to edit, and why.</summary>
    public sealed record Refused(string Why) : LensTarget;
}

/// <summary>A drag of a lens field, from a scrub in the details strip: each step sets the field, and the end commits or cancels.</summary>
public interface ILensDrag
{
    /// <summary>Sets the field. False once the drag has ended, or when the value does not apply.</summary>
    bool Step(double value);

    void End(bool cancel);
}

/// <summary>
/// The lens of a cutscene's camera bindings (see docs/editor/cutscene-editor.md#lens): its values at the playhead, its key
/// buttons, and its edits. A spawned camera's values show over the preview by its binding's ID. A possessed camera's go
/// through <see cref="Keying"/> while this tab holds the preview, as the inspector's do, so each field has one held value.
/// </summary>
public sealed partial class CutsceneEditor
{
    const ulong LensComponent = CinematicCameraText.CinematicCameraId;

    /// <summary>The shell, for the views of the tab that follow its values and keys.</summary>
    internal EditorShell Shell => _shell;

    const string DragUnderWay = "A drag is under way in the cutscene.";

    const string NotShown = "Open the preview and pause it to hold a value over it, or turn on auto-key to key the value.";

    /// <summary>The lens fields that the details strip shows, in its order.</summary>
    public static readonly IReadOnlyList<string> LensFields = ["focal_length", "sensor_width", "sensor_height", "focus_distance", "aperture", "focus_offset"];

    /// <summary>A field's value as the runtime takes it: 0 or less is the default for the focal length, the sensor and the focus distance.</summary>
    public static double EffectiveLens(string field, double value) => field switch
    {
        "focal_length" when value <= 0 => Tools.Lens.DefaultFocalLength,
        "sensor_width" when value <= 0 => Tools.Lens.DefaultSensorWidth,
        "sensor_height" when value <= 0 => Tools.Lens.DefaultSensorHeight,
        "focus_distance" when value <= 0 => Tools.Lens.DefaultFocusDistance,
        _ => value,
    };

    /// <summary>Where a camera binding's lens is edited.</summary>
    public LensTarget LensTargetOf(int binding)
    {
        if (File.Bindings.FirstOrDefault(b => b.Id == binding) is not { } block)
        {
            return new LensTarget.Refused("The binding is not in the cutscene.");
        }
        if (CutsceneBindings.SpawnOf(block) is { } prefab)
        {
            return _shell.PrefabRootHas(prefab, LensComponent)
                ? new LensTarget.Spawned(binding, prefab)
                : new LensTarget.Refused("The root of the prefab that the binding spawns has no Cinematic Camera, so it has no lens.");
        }
        if (HandleOf(binding) is { } handle && _shell.World.Find(handle) is { } node)
        {
            return node.Components.Contains(LensComponent)
                ? new LensTarget.Possessed(binding, handle)
                : new LensTarget.Refused("The entity that the binding possesses has no Cinematic Camera, so it has no lens.");
        }
        return new LensTarget.Refused("The binding's entity is not loaded, so its lens cannot show.");
    }

    static KeyTarget LensKeyTarget(int binding, string field) => new KeyTarget.Property(binding, LensComponent, field, PropertyShape.Number);

    FieldInfo? LensField(string field) => _shell.World.Type(LensComponent)?.Fields.FirstOrDefault(f => f.Name == field);

    // A possessed camera's fields go through Keying while this tab holds the preview, as the inspector's do.
    bool ThroughKeying(LensTarget target) => target is LensTarget.Possessed && _shell.Keying.Cutscene == this;

    /// <summary>
    /// A lens field's value at the playhead, as the field holds it (0 for a default), or null when the editor does not
    /// know it: a value over the preview, else the track's curve, else the spawned prefab's or the possessed entity's.
    /// </summary>
    public double? LensValue(int binding, string field)
    {
        switch (LensTargetOf(binding))
        {
            case LensTarget.Spawned spawned:
                if (_shell.PreviewValues.BindingValueOf(binding, LensComponent, field) is { Kind: SceneValueKind.Number, Numbers: [var held, ..] })
                {
                    return held.Float;
                }
                if (CutsceneKeying.ValuesAt(File, LensKeyTarget(binding, field), Playhead) is [{ } keyed])
                {
                    return keyed;
                }
                return _shell.PrefabRootNumber(spawned.Prefab, LensComponent, field) ?? 0;
            case LensTarget.Possessed possessed:
                if (LensField(field) is not { } info)
                {
                    return null;
                }
                var bytes = _shell.Keying.ShownComponent(possessed.Handle, LensComponent)
                    ?? _shell.World.Values(possessed.Handle)?.Components.FirstOrDefault(c => c.Id == LensComponent)?.Data;
                return bytes != null && KeyValues.Numbers(info, bytes) is [var value, ..] ? value : null;
            default:
                return null;
        }
    }

    /// <summary>What a lens field's key button shows at the playhead, or null when the binding has no lens.</summary>
    public KeyButton? LensKey(int binding, string field)
    {
        var target = LensTargetOf(binding);
        if (target is LensTarget.Refused)
        {
            return null;
        }
        if (ThroughKeying(target))
        {
            return LensField(field) is { } info ? _shell.Keying.StateOf(((LensTarget.Possessed)target).Handle, LensComponent, info) : null;
        }
        var key = LensKeyTarget(binding, field);
        var value = LensValue(binding, field);
        var refusal = CutsceneKeying.Refusal(File, key, Locked) ?? (Document.InTransaction ? DragUnderWay : null)
            ?? (value == null ? "The editor does not know the field's value." : null);
        var state = CutsceneKeying.StateOf(File, key, Playhead,
            value is not { } shown ? null : keys => keys is [{ } k, ..] && Math.Abs(k - shown) > 1e-5);
        var where = $"at {CutsceneTime.Timecode(Playhead, File.Rate)}";
        var tip = state switch
        {
            KeyState.None => $"Add a track and key the field {where}.",
            KeyState.Track => $"Key the field {where}.",
            KeyState.Keyed => $"A key holds the field {where}. Click to key it again.",
            _ => $"The field differs from its key {where}. Click to key what it shows.",
        };
        return new KeyButton(state, refusal, refusal == null ? tip : $"{tip}\n{refusal}");
    }

    /// <summary>Keys a lens field at the playhead with its value, adding its track when it has none, as one undo entry.</summary>
    public void KeyLens(int binding, string field)
    {
        var target = LensTargetOf(binding);
        if (ThroughKeying(target))
        {
            if (LensField(field) is { } info)
            {
                _shell.Keying.Key(((LensTarget.Possessed)target).Handle, LensComponent, info);
            }
            return;
        }
        if (LensKey(binding, field) is not { Refusal: null } || LensValue(binding, field) is not { } value)
        {
            return;
        }
        var tick = Playhead;
        Key($"Key {FieldValues.Humanize(field)}", f => CutsceneKeying.SetKeys(f, LensKeyTarget(binding, field), tick, [value], FieldValues.Humanize(field), Locked));
        _shell.PreviewValues.Keyed([], [], [new BindingFieldKey(binding, LensComponent, field)]);
    }

    /// <summary>Adds the track of a lens field, with no key, as one undo entry.</summary>
    public void AddLensTrack(int binding, string field)
    {
        var target = LensTargetOf(binding);
        if (ThroughKeying(target))
        {
            if (LensField(field) is { } info)
            {
                _shell.Keying.AddTrack(((LensTarget.Possessed)target).Handle, LensComponent, info);
            }
            return;
        }
        var key = LensKeyTarget(binding, field);
        if (target is not LensTarget.Refused && CutsceneKeying.TrackOf(File, key) == null)
        {
            Key("Add Track", f => CutsceneKeying.AddTrack(f, key, FieldValues.Humanize(field)));
        }
    }

    /// <summary>Whether a lens field has keys at the playhead that its track lets go.</summary>
    public bool CanRemoveLensKey(int binding, string field)
    {
        var target = LensTargetOf(binding);
        if (ThroughKeying(target))
        {
            return LensField(field) is { } info && _shell.Keying.CanRemoveKey(((LensTarget.Possessed)target).Handle, LensComponent, info);
        }
        var key = LensKeyTarget(binding, field);
        return target is not LensTarget.Refused && !Document.InTransaction && CutsceneKeying.Refusal(File, key, Locked) == null
            && CutsceneKeying.KeysAt(File, key, Playhead).Any(k => k != null);
    }

    /// <summary>Removes a lens field's keys at the playhead, as one undo entry.</summary>
    public void RemoveLensKey(int binding, string field)
    {
        if (CanRemoveLensKey(binding, field))
        {
            var tick = Playhead;
            Key("Remove Key", f => CutsceneKeying.RemoveKeys(f, LensKeyTarget(binding, field), tick, Locked));
        }
    }

    /// <summary>Selects the track of a lens field and shows it on the timeline.</summary>
    public void GoToLensTrack(int binding, string field)
    {
        if (CutsceneKeying.TrackOf(File, LensKeyTarget(binding, field)) is { } track)
        {
            Reveal(track);
        }
    }

    /// <summary>
    /// Sets lens fields at the playhead, as a typed value, a sensor or a picked focus does (see
    /// docs/editor/cutscene-editor.md#lens): keyed as one undo entry with auto-key, otherwise held over the preview until
    /// Enter or a key button keys them. A possessed camera's go where the inspector's go. Null when they apply, and
    /// otherwise why not.
    /// </summary>
    public string? SetLens(int binding, IReadOnlyList<(string Field, double Value)> values, string label)
    {
        if (values.Count == 0)
        {
            return null;
        }
        return LensTargetOf(binding) switch
        {
            LensTarget.Refused refused => refused.Why,
            LensTarget.Possessed possessed => SetPossessedLens(possessed, values, label),
            _ => SetSpawnedLens(binding, values, label),
        };
    }

    string? SetPossessedLens(LensTarget.Possessed possessed, IReadOnlyList<(string Field, double Value)> values, string label)
    {
        if (_shell.World.Find(possessed.Handle) is not { } node)
        {
            return "The binding's entity is not loaded.";
        }
        var scene = new List<Operation>();
        foreach (var (field, value) in values)
        {
            if (LensField(field) is not { } info)
            {
                return $"The world has no field {field} in Cinematic Camera.";
            }
            var op = new SetField(node.SceneId, LensComponent, field, SceneEdits.Floats(value));
            switch (_shell.Keying.Sink(new Dictionary<ulong, ulong> { [node.SceneId] = possessed.Handle }, LensComponent, info).Write(label, [op]))
            {
                case null:
                    scene.Add(op);
                    break;
                case false:
                    return "The edit did not apply: the console says why.";
            }
        }
        if (scene.Count == 0)
        {
            return null;
        }
        if (_shell.SceneOf(node) != _shell.Scene)
        {
            return "The camera is in a scene that is not active. Make its scene active to edit its lens there.";
        }
        return _shell.Edit(label, [.. scene]) ? null : "The scene did not take the edit: the console says why.";
    }

    string? SetSpawnedLens(int binding, IReadOnlyList<(string Field, double Value)> values, string label)
    {
        if (Document.InTransaction)
        {
            return DragUnderWay;
        }
        var set = values.Select(v => (new BindingFieldKey(binding, LensComponent, v.Field), SceneEdits.Floats(v.Value))).ToList();
        if (!KeysLens(binding, values.Select(v => v.Field)))
        {
            return _shell.PreviewValues.SetBindingFields(this, set) ? null : NotShown;
        }
        foreach (var (field, _) in values)
        {
            if (CutsceneKeying.Refusal(File, LensKeyTarget(binding, field), Locked) is { } why)
            {
                return why;
            }
        }
        var shown = _shell.PreviewValues.SetBindingFields(this, set);
        var tick = Playhead;
        Key(label, f =>
        {
            foreach (var (field, value) in values)
            {
                CutsceneKeying.SetKeys(f, LensKeyTarget(binding, field), tick, [(float)value], FieldValues.Humanize(field), Locked);
            }
        });
        if (shown)
        {
            _shell.PreviewValues.Keyed([], [], set.Select(s => s.Item1));
        }
        return null;
    }

    // Whether auto-key keys a spawned camera's fields: it is on, and their tracks are there or it adds them.
    bool KeysLens(int binding, IEnumerable<string> fields) =>
        _shell.Keying.AutoKey && (_shell.Keying.AutoKeyAddTracks || fields.All(f => CutsceneKeying.TrackOf(File, LensKeyTarget(binding, f)) != null));

    /// <summary>
    /// Opens a drag of a lens field, as a scrub does: one undo entry with auto-key, otherwise values held over the preview.
    /// Null, with why, when it cannot open now.
    /// </summary>
    public ILensDrag? BeginLensDrag(int binding, string field, string label, out string? refusal)
    {
        refusal = null;
        switch (LensTargetOf(binding))
        {
            case LensTarget.Refused refused:
                refusal = refused.Why;
                return null;
            case LensTarget.Possessed possessed:
                return BeginPossessedLensDrag(possessed, field, label, out refusal);
        }
        if (Document.InTransaction)
        {
            refusal = DragUnderWay;
            return null;
        }
        CutsceneDrag? keys = null;
        if (KeysLens(binding, [field]))
        {
            if (CutsceneKeying.Refusal(File, LensKeyTarget(binding, field), Locked) is { } why)
            {
                refusal = why;
                return null;
            }
            keys = BeginHeldDrag(label);
        }
        else if (_shell.CutscenePreview.State is not CutscenePreviewState.Open { Playing: false } open || open.Editor != this)
        {
            refusal = NotShown;
            return null;
        }
        return new BindingLensDrag(this, binding, field, keys);
    }

    ILensDrag? BeginPossessedLensDrag(LensTarget.Possessed possessed, string field, string label, out string? refusal)
    {
        refusal = null;
        if (_shell.World.Find(possessed.Handle) is not { } node || LensField(field) is not { } info)
        {
            refusal = "The binding's entity is not loaded.";
            return null;
        }
        var (routed, edit) = _shell.Keying.Sink(new Dictionary<ulong, ulong> { [node.SceneId] = possessed.Handle }, LensComponent, info).Begin(label);
        if (!routed)
        {
            if (_shell.SceneOf(node) != _shell.Scene)
            {
                refusal = "The camera is in a scene that is not active. Make its scene active to edit its lens there.";
                return null;
            }
            edit = _shell.TryBeginEdit(label, "a lens drag", commitIfInterrupted: true);
        }
        if (edit == null)
        {
            refusal = "The edit cannot open now: the console says why.";
            return null;
        }
        return new FieldLensDrag(edit, node.SceneId, field);
    }

    // A possessed camera's drag: the inspector's edit of its field, to the scene, the values or the keys.
    sealed class FieldLensDrag(IFieldEdit edit, ulong sceneId, string field) : ILensDrag
    {
        public bool Step(double value) => edit.Preview(new SetField(sceneId, LensComponent, field, SceneEdits.Floats(value)));

        public void End(bool cancel)
        {
            if (!edit.IsOpen)
            {
                return;
            }
            if (cancel)
            {
                edit.Cancel();
            }
            else
            {
                edit.Commit();
            }
        }
    }

    // A spawned camera's drag: each step sets the field over the preview, which shows at once, and with the cutscene's
    // drag, keys it. A drag of keys lasts as long as the cutscene's drag: one that another ends, as Esc in the timeline
    // does, ends it too. A cancelled drag's values go back as they were.
    sealed class BindingLensDrag : ILensDrag
    {
        readonly CutsceneEditor _editor;
        readonly int _binding;
        readonly string _field;
        readonly CutsceneDrag? _keys;
        readonly PreviewValuesState _before;
        readonly int _position;
        bool _open = true;

        public BindingLensDrag(CutsceneEditor editor, int binding, string field, CutsceneDrag? keys)
        {
            (_editor, _binding, _field, _keys) = (editor, binding, field, keys);
            _before = editor._shell.PreviewValues.State;
            _position = editor.Document.Position;
            if (keys != null)
            {
                keys.Ended += OnKeysEnded;
            }
        }

        bool IsOpen => _open && (_keys == null || _keys.IsOpen);

        public bool Step(double value)
        {
            if (!IsOpen)
            {
                return false;
            }
            var shown = _editor._shell.PreviewValues.SetBindingFields(_editor, [(new BindingFieldKey(_binding, LensComponent, _field), SceneEdits.Floats(value))]);
            if (_keys == null)
            {
                return shown;
            }
            var tick = _editor.Playhead;
            _keys.Step(f =>
            {
                CutsceneKeying.SetKeys(f, LensKeyTarget(_binding, _field), tick, [(float)value], FieldValues.Humanize(_field), _editor.Locked);
                return [];
            });
            return true;
        }

        public void End(bool cancel)
        {
            if (!_open)
            {
                return;
            }
            if (_keys is { IsOpen: true })
            {
                // The cutscene's drag ends, and its Ended finishes this one.
                _keys.End(cancel);
                return;
            }
            Finish(committed: !cancel && _keys == null);
        }

        void OnKeysEnded(bool committed)
        {
            if (_open && committed && _editor.Document.Position != _position)
            {
                _editor._shell.Edited(new UndoTarget.Cutscene(_editor));
            }
            Finish(committed);
        }

        // The one end: keyed values settle; a cancelled drag's values go back, unless they have gone since with the
        // session or the playhead that they were set at.
        void Finish(bool committed)
        {
            if (!_open)
            {
                return;
            }
            _open = false;
            if (_keys != null)
            {
                _keys.Ended -= OnKeysEnded;
            }
            var values = _editor._shell.PreviewValues;
            if (committed && _keys != null)
            {
                values.Keyed([], [], [new BindingFieldKey(_binding, LensComponent, _field)]);
            }
            else if (!committed && values.State is PreviewValuesState.Live now
                && (_before is not PreviewValuesState.Live was || (was.Ticket == now.Ticket && was.Tick == now.Tick)))
            {
                values.Restore(_before);
            }
        }
    }
}
