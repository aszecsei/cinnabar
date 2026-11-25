using System.Collections.Immutable;
using System.Text;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Model;
using ComponentType = Cinnabar.Editor.Link.Protocol.ComponentType;
using CutscenePreviewValues = Cinnabar.Editor.Link.Protocol.CutscenePreviewValues;
using FieldInfo = Cinnabar.Editor.Link.Protocol.FieldInfo;
using OverrideField = Cinnabar.Editor.Link.Protocol.OverrideField;
using OverrideTarget = Cinnabar.Editor.Link.Protocol.OverrideTarget;
using OverrideTargetKind = Cinnabar.Editor.Link.Protocol.OverrideTargetKind;
using OverrideTransform = Cinnabar.Editor.Link.Protocol.OverrideTransform;

namespace Cinnabar.Editor.Shell;

/// <summary>A pose that the values give a binding of the cutscene, by its ID: a world position in World_Position units and a rotation.</summary>
public sealed record BindingPose(long[] Position, Quat Rotation);

/// <summary>A field of a binding's entity, by the binding's ID, the component's ID and the field's name.</summary>
public readonly record struct BindingFieldKey(int Binding, ulong Component, string Field);

/// <summary>A field of an entity, by its handle, its component's ID and its name.</summary>
public readonly record struct ValueKey(ulong Handle, ulong Component, string Field);

/// <summary>
/// The values that the world shows over the cutscene preview, outside the document and the cutscene (see
/// docs/editor/cutscene-editor.md#preview-values). Each state carries what belongs to it. Only <see cref="PreviewValues"/>
/// makes them.
/// </summary>
public abstract record PreviewValuesState
{
    private protected PreviewValuesState()
    {
    }

    /// <summary>No values.</summary>
    public sealed record Empty : PreviewValuesState
    {
        public static readonly Empty Instance = new();
    }

    /// <summary>
    /// Values over the preview of a session, at its playhead. <paramref name="Serial"/> names them in the world's shown
    /// values, and <paramref name="First"/> is the serial that they started with when the state left Empty, so values
    /// that the world shows from any serial since then are its own. <paramref name="Values"/> are the set fields, and
    /// <paramref name="Components"/> are each set field's component's bytes with them written, from what the world
    /// showed before the first one.
    /// </summary>
    public abstract record Live(
        ulong Ticket,
        CutsceneEditor Editor,
        int Tick,
        ulong Serial,
        ulong First,
        ImmutableDictionary<ValueKey, SceneValue> Values,
        ImmutableDictionary<(ulong Handle, ulong Component), byte[]> Components) : PreviewValuesState
    {
        /// <summary>
        /// The poses of bindings that the editor has no entity for, as a spawned camera that a view pilots (see
        /// docs/editor/cutscene-editor.md#pilot), by binding ID. The game finds each binding's entity.
        /// </summary>
        public ImmutableDictionary<int, BindingPose> Bindings { get; init; } = ImmutableDictionary<int, BindingPose>.Empty;

        /// <summary>
        /// The fields of bindings that the editor has no entity for, as a spawned camera's lens (see
        /// docs/editor/cutscene-editor.md#lens). The game finds each binding's entity.
        /// </summary>
        public ImmutableDictionary<BindingFieldKey, SceneValue> BindingFields { get; init; } = ImmutableDictionary<BindingFieldKey, SceneValue>.Empty;

        /// <summary>Whether values are set on bindings by their IDs, which only the preview's shown blob settles.</summary>
        public bool HasBindingValues => !Bindings.IsEmpty || !BindingFields.IsEmpty;
    }

    /// <summary>Values that are not keyed: Enter or a key button keys them, and the playhead's move drops them.</summary>
    public sealed record Holding(
        ulong Ticket,
        CutsceneEditor Editor,
        int Tick,
        ulong Serial,
        ulong First,
        ImmutableDictionary<ValueKey, SceneValue> Values,
        ImmutableDictionary<(ulong Handle, ulong Component), byte[]> Components)
        : Live(Ticket, Editor, Tick, Serial, First, Values, Components);

    /// <summary>
    /// Values that are keyed, which stay until the preview shows the text that keyed them, so the world does not show the
    /// old curve while the daemon cooks it.
    /// </summary>
    public sealed record Settling(
        ulong Ticket,
        CutsceneEditor Editor,
        int Tick,
        ulong Serial,
        ulong First,
        ImmutableDictionary<ValueKey, SceneValue> Values,
        ImmutableDictionary<(ulong Handle, ulong Component), byte[]> Components,
        string KeyedText)
        : Live(Ticket, Editor, Tick, Serial, First, Values, Components);
}

/// <summary>
/// The values that the world shows over the cutscene preview at its playhead (see
/// docs/editor/cutscene-editor.md#preview-values). A changed field that the preview holds shows here, not in the scene;
/// Enter or its key button keys it, and a move of the playhead drops it. <see cref="Become"/> is the one place that
/// <see cref="State"/> changes, and it sends the game each change. Serials only go up, so the editor knows the values
/// that the world showed.
/// </summary>
public sealed class PreviewValues(EditorShell shell)
{
    ulong _last;

    public PreviewValuesState State { get; private set; } = PreviewValuesState.Empty.Instance;

    /// <summary>The values changed.</summary>
    public event Action? Changed;

    /// <summary>The serial of the values that the world should show, or 0 for none.</summary>
    public ulong Serial => State is PreviewValuesState.Live live ? live.Serial : 0;

    /// <summary>Whether values that the world showed with a serial are this state's: 0 with none, or one since the state left Empty.</summary>
    public bool Shows(ulong serial) => State is PreviewValuesState.Live live ? serial >= live.First && serial <= live.Serial : serial == 0;

    /// <summary>Whether there are values that are not keyed.</summary>
    public bool Holding => State is PreviewValuesState.Holding;

    /// <summary>A component's bytes with the values written, or null when no value is set in it.</summary>
    public byte[]? ComponentOf(ulong handle, ulong component) =>
        State is PreviewValuesState.Live live && live.Components.TryGetValue((handle, component), out var bytes) ? bytes : null;

    /// <summary>The value of a field, or null when none is set.</summary>
    public SceneValue? ValueOf(ulong handle, ulong component, string field) =>
        State is PreviewValuesState.Live live && live.Values.TryGetValue(new ValueKey(handle, component, field), out var value) ? value : null;

    void Become(PreviewValuesState next)
    {
        var previous = State;
        State = next;
        Send(previous, next);
        Changed?.Invoke();
        shell.Keying.Raise();
    }

    void Send(PreviewValuesState previous, PreviewValuesState next)
    {
        if (!shell.Host.Linked)
        {
            return;
        }
        switch (next)
        {
            case PreviewValuesState.Live live when previous is not PreviewValuesState.Live p || p.Serial != live.Serial:
                shell.Host.Send(Message(live));
                break;
            case PreviewValuesState.Empty when previous is PreviewValuesState.Live p:
                shell.Host.Send(new CutscenePreviewValues(p.Ticket, p.Tick, ++_last, [], []));
                break;
        }
    }

    /// <summary>
    /// Sets fields over the preview at the playhead, with each one's component as it shows now in <paramref name="shown"/>
    /// when no value is set in it yet. False, with nothing set, when no session of the tab is open and paused.
    /// </summary>
    public bool Set(CutsceneEditor editor, IReadOnlyList<(ValueKey Key, SceneValue Value)> values, Func<ulong, ulong, byte[]?> shown)
    {
        if (shell.CutscenePreview.State is not CutscenePreviewState.Open { Playing: false } open || open.Editor != editor || values.Count == 0)
        {
            return false;
        }
        var tick = TickOf(open);
        var live = State is PreviewValuesState.Live l && l.Ticket == open.Ticket && l.Tick == tick ? l : null;
        var set = live?.Values ?? ImmutableDictionary<ValueKey, SceneValue>.Empty;
        var components = live?.Components ?? ImmutableDictionary<(ulong, ulong), byte[]>.Empty;
        foreach (var (key, value) in values)
        {
            if (shell.World.Type(key.Component) is not { } type || type.Fields.FirstOrDefault(f => f.Name == key.Field) is not { } field)
            {
                return false;
            }
            var bytes = components.TryGetValue((key.Handle, key.Component), out var b) ? (byte[])b.Clone() : shown(key.Handle, key.Component)?.ToArray();
            if (bytes == null || !KeyValues.Write(field, bytes, value))
            {
                return false;
            }
            components = components.SetItem((key.Handle, key.Component), bytes);
            set = set.SetItem(key, value);
        }
        var serial = ++_last;
        Become(new PreviewValuesState.Holding(open.Ticket, editor, tick, serial, live?.First ?? serial, set, components)
        {
            Bindings = live?.Bindings ?? ImmutableDictionary<int, BindingPose>.Empty,
            BindingFields = live?.BindingFields ?? ImmutableDictionary<BindingFieldKey, SceneValue>.Empty,
        });
        return true;
    }

    /// <summary>
    /// Sets a binding's world pose over the preview at the playhead, by its ID, as a piloted camera's (see
    /// docs/editor/cutscene-editor.md#pilot). False, with nothing set, when no session of the tab is open and paused.
    /// </summary>
    public bool SetBindingPose(CutsceneEditor editor, int binding, IReadOnlyList<long> position, Quat rotation)
    {
        // In context, the tab shows a sub-sequence, whose binding IDs the parent's blob does not have.
        if (shell.CutscenePreview.State is not CutscenePreviewState.Open { Playing: false } open || open.Editor != editor || editor.InContext || position.Count != 3)
        {
            return false;
        }
        var tick = TickOf(open);
        var live = State is PreviewValuesState.Live l && l.Ticket == open.Ticket && l.Tick == tick ? l : null;
        var serial = ++_last;
        Become(new PreviewValuesState.Holding(open.Ticket, editor, tick, serial, live?.First ?? serial,
            live?.Values ?? ImmutableDictionary<ValueKey, SceneValue>.Empty, live?.Components ?? ImmutableDictionary<(ulong, ulong), byte[]>.Empty)
        {
            Bindings = (live?.Bindings ?? ImmutableDictionary<int, BindingPose>.Empty).SetItem(binding, new BindingPose([.. position], rotation.Normalized())),
            BindingFields = live?.BindingFields ?? ImmutableDictionary<BindingFieldKey, SceneValue>.Empty,
        });
        return true;
    }

    /// <summary>
    /// Sets fields of bindings over the preview at the playhead, by their IDs, as a spawned camera's lens (see
    /// docs/editor/cutscene-editor.md#lens). False, with nothing set, when no session of the tab is open and paused, or
    /// when the world does not know a field.
    /// </summary>
    public bool SetBindingFields(CutsceneEditor editor, IReadOnlyList<(BindingFieldKey Key, SceneValue Value)> values)
    {
        if (shell.CutscenePreview.State is not CutscenePreviewState.Open { Playing: false } open || open.Editor != editor || editor.InContext || values.Count == 0)
        {
            return false;
        }
        if (values.Any(v => shell.World.Type(v.Key.Component)?.Fields.Any(f => f.Name == v.Key.Field) != true))
        {
            return false;
        }
        var tick = TickOf(open);
        var live = State is PreviewValuesState.Live l && l.Ticket == open.Ticket && l.Tick == tick ? l : null;
        var fields = live?.BindingFields ?? ImmutableDictionary<BindingFieldKey, SceneValue>.Empty;
        foreach (var (key, value) in values)
        {
            fields = fields.SetItem(key, value);
        }
        var serial = ++_last;
        Become(new PreviewValuesState.Holding(open.Ticket, editor, tick, serial, live?.First ?? serial,
            live?.Values ?? ImmutableDictionary<ValueKey, SceneValue>.Empty, live?.Components ?? ImmutableDictionary<(ulong, ulong), byte[]>.Empty)
        {
            Bindings = live?.Bindings ?? ImmutableDictionary<int, BindingPose>.Empty,
            BindingFields = fields,
        });
        return true;
    }

    /// <summary>A binding's field over the preview, or null when none is set.</summary>
    public SceneValue? BindingValueOf(int binding, ulong component, string field) =>
        State is PreviewValuesState.Live live ? live.BindingFields.GetValueOrDefault(new BindingFieldKey(binding, component, field)) : null;

    /// <summary>A binding's pose over the preview, or null when none is set.</summary>
    public BindingPose? PoseOf(int binding) => State is PreviewValuesState.Live live ? live.Bindings.GetValueOrDefault(binding) : null;

    // What the game last said that the world shows of the preview (see Cutscene_Preview_Shown), which settles a
    // binding's keyed pose, as no entity's values carry it.
    Link.Protocol.ShownPreview? _shown;

    /// <summary>The game said what the world shows of the preview.</summary>
    internal void OnPreviewShown(Link.Protocol.ShownPreview shown)
    {
        _shown = shown;
        Follow();
    }

    // The time that a session shows at the tab's playhead: the game holds its time within the cutscene's range.
    static int TickOf(CutscenePreviewState.Open open) =>
        Math.Clamp(open.Editor.RootPlayhead, open.RangeStart, Math.Max(open.RangeStart, open.RangeEnd));

    /// <summary>Puts back values as they were, as when a drag of them is cancelled.</summary>
    internal void Restore(PreviewValuesState state)
    {
        if (state is PreviewValuesState.Live live)
        {
            Become(live switch
            {
                PreviewValuesState.Holding h => h with { Serial = ++_last },
                PreviewValuesState.Settling s => s with { Serial = ++_last },
                _ => live,
            });
        }
        else
        {
            Drop();
        }
    }

    /// <summary>
    /// Some of the values are keyed in the cutscene's text as it is now. They settle only when they are all the values
    /// that are held: a held value that was not keyed must not drop with them when the preview shows the text, so until
    /// Enter keys the rest, all stay held, and the keyed ones show what their keys hold.
    /// </summary>
    public void Keyed(IEnumerable<ValueKey> values, IEnumerable<int> bindings, IEnumerable<BindingFieldKey> fields)
    {
        if (State is PreviewValuesState.Holding holding)
        {
            var (v, b, f) = (values.ToHashSet(), bindings.ToHashSet(), fields.ToHashSet());
            if (!holding.Values.Keys.All(v.Contains) || !holding.Bindings.Keys.All(b.Contains) || !holding.BindingFields.Keys.All(f.Contains))
            {
                return;
            }
        }
        Keyed();
    }

    /// <summary>All the values are keyed in the cutscene's text as it is now: they stay until the preview shows it.</summary>
    public void Keyed()
    {
        if (State is PreviewValuesState.Live live && live.Editor.Document.Text is var text)
        {
            Become(new PreviewValuesState.Settling(live.Ticket, live.Editor, live.Tick, live.Serial, live.First, live.Values, live.Components, text)
            {
                Bindings = live.Bindings,
                BindingFields = live.BindingFields,
            });
        }
    }

    /// <summary>Drops the values: the world shows the preview again.</summary>
    public void Drop()
    {
        if (State is PreviewValuesState.Live)
        {
            Become(PreviewValuesState.Empty.Instance);
        }
    }

    /// <summary>
    /// What may end the values changed: the session, its owner or its transport, the playhead, the cutscene's text, or
    /// the world's values. Values whose session is not the open and paused one, or whose tick is not the playhead, go.
    /// Keyed values go once the world shows the text that keyed them, or once the text changes again.
    /// </summary>
    internal void Follow()
    {
        if (State is not PreviewValuesState.Live live)
        {
            return;
        }
        if (shell.CutscenePreview.State is not CutscenePreviewState.Open { Playing: false } open || open.Ticket != live.Ticket
            || open.Editor != live.Editor || TickOf(open) != live.Tick || !shell.IsEditing)
        {
            Drop();
            return;
        }
        if (live is PreviewValuesState.Settling settling)
        {
            if (live.Editor.Document.Text != settling.KeyedText)
            {
                Drop();
                return;
            }
            var shown = open.Unsaved
                ? live.Editor.CleanBlob is { } blob
                    && (live.Components.Keys.Any(k => shell.World.ShownPreviewOf(k.Handle) is { } s && s.Ticket == open.Ticket && s.Blob == blob)
                        || (live.HasBindingValues && _shown is { } preview && preview.Ticket == open.Ticket && preview.Blob == blob))
                : !live.Editor.RootDocument.IsDirty;
            // In context, the keys went to the sub-sequence, whose last edit must have cooked too.
            if (shown && live.Editor.ShownCookedCurrent)
            {
                Drop();
            }
        }
    }

    // The values as the game takes them: a pose as a transform, from its component's bytes, and another field as itself.
    CutscenePreviewValues Message(PreviewValuesState.Live live)
    {
        var fields = new List<OverrideField>();
        var transforms = new List<OverrideTransform>();
        foreach (var ((handle, component), bytes) in live.Components)
        {
            if (shell.World.Find(handle) is not { } node || shell.World.Type(component) is not { } type)
            {
                continue;
            }
            var target = new OverrideTarget(OverrideTargetKind.SceneEntity, node.Scene, node.SceneId);
            var pose = node.Parent != 0 ? SceneEdits.LocalTransformId : SceneEdits.TransformId;
            if (component == pose && Pose(type, bytes, node.Parent != 0) is { } p)
            {
                transforms.Add(new OverrideTransform(target, p.Position, p.Rotation, p.Scale));
                continue;
            }
            foreach (var (key, value) in live.Values.Where(v => v.Key.Handle == handle && v.Key.Component == component))
            {
                fields.Add(new OverrideField(target, component, Hash(key.Field), SceneSnapshot.Value(value)));
            }
        }
        foreach (var (binding, pose) in live.Bindings)
        {
            var q = pose.Rotation;
            transforms.Add(new OverrideTransform(new OverrideTarget(OverrideTargetKind.Binding, 0, (ulong)binding), pose.Position,
                [(float)q.X, (float)q.Y, (float)q.Z, (float)q.W], [1, 1, 1]));
        }
        foreach (var (key, value) in live.BindingFields)
        {
            fields.Add(new OverrideField(new OverrideTarget(OverrideTargetKind.Binding, 0, (ulong)key.Binding), key.Component, Hash(key.Field),
                SceneSnapshot.Value(value)));
        }
        return new CutscenePreviewValues(live.Ticket, live.Tick, live.Serial, [.. fields], [.. transforms]);
    }

    static ulong Hash(string field) => Fnv.Hash64(Encoding.UTF8.GetBytes(field));

    // A Transform's or a Local_Transform's pose from its bytes: a root's position in World_Position units, and a child's
    // offset in the same units.
    static (long[] Position, float[] Rotation, float[] Scale)? Pose(ComponentType type, byte[] bytes, bool child)
    {
        FieldInfo? Field(string name) => type.Fields.FirstOrDefault(f => f.Name == name);
        long[]? position;
        if (child)
        {
            position = Field("offset") is { } offset && KeyValues.Numbers(offset, bytes) is [var x, var y, var z]
                ? [(long)Math.Round(x * PoseKeys.UnitsPerMeter), (long)Math.Round(y * PoseKeys.UnitsPerMeter), (long)Math.Round(z * PoseKeys.UnitsPerMeter)]
                : null;
        }
        else
        {
            position = Field("position") is { } p ? KeyValues.Units(p, bytes) : null;
        }
        if (position == null || Field("rotation") is not { } rotation || KeyValues.Numbers(rotation, bytes) is not { Length: 4 } r
            || Field("scale") is not { } scale || KeyValues.Numbers(scale, bytes) is not { Length: 3 } s)
        {
            return null;
        }
        return (position, [.. r.Select(v => (float)v)], [.. s.Select(v => (float)v)]);
    }
}
