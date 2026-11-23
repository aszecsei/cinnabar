using Cinnabar.Editor.Document;
using Cinnabar.Editor.Model;
using FieldInfo = Cinnabar.Editor.Link.Protocol.FieldInfo;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// Where an edit of a field goes (see docs/editor/cutscene-editor.md#where-an-edit-goes): the scene, a value over the
/// preview, a key, or nowhere, with why. A field that the cutscene's preview holds never goes to the scene.
/// </summary>
public abstract record FieldRoute
{
    private protected FieldRoute()
    {
    }

    /// <summary>The scene, as every edit outside a cutscene does.</summary>
    public sealed record Scene : FieldRoute
    {
        public static readonly Scene Instance = new();
    }

    /// <summary>A value over the preview at the playhead, which Enter or the key button keys.</summary>
    public sealed record Preview : FieldRoute
    {
        public static readonly Preview Instance = new();
    }

    /// <summary>A key at the playhead, with auto-key on.</summary>
    public sealed record Key : FieldRoute
    {
        public static readonly Key Instance = new();
    }

    /// <summary>Nowhere now, and why.</summary>
    public sealed record Refused(string Why) : FieldRoute;
}

/// <summary>
/// An open edit of a field, which a drag previews in and then commits or cancels: the scene's entry, or a drag of values
/// over the preview or of keys. Once it ends, by its owner or by another, it does nothing, and <see cref="Ended"/> says so.
/// </summary>
public interface IFieldEdit
{
    /// <summary>Whether the edit is still open.</summary>
    bool IsOpen { get; }

    /// <summary>Applies the operations, from where the edit began. False when it has ended or they do not fit.</summary>
    bool Preview(IReadOnlyList<Operation> ops);

    bool Preview(Operation op) => Preview([op]);

    void Commit();

    void Cancel();

    /// <summary>The edit ended, committed or not. It is raised once.</summary>
    event Action<bool>? Ended;
}

/// <summary>
/// Where a field editor's edits go for the entities it edits, by their scene IDs (see
/// docs/editor/cutscene-editor.md#where-an-edit-goes). The properties panel gives one to the rows that have a key
/// button. An edit whose route is the scene is not this sink's.
/// </summary>
public sealed class FieldSink
{
    readonly Keying _keying;
    readonly IReadOnlyDictionary<ulong, ulong> _handles;
    readonly ulong _component;
    readonly FieldInfo _field;

    internal FieldSink(Keying keying, IReadOnlyDictionary<ulong, ulong> handles, ulong component, FieldInfo field) =>
        (_keying, _handles, _component, _field) = (keying, handles, component, field);

    /// <summary>Where an edit of the field goes now.</summary>
    public FieldRoute Route => _keying.Route([.. _handles.Values], _component, _field);

    /// <summary>
    /// Applies an edit that does not go to the scene, as one undo entry when it keys. Null when it goes to the scene, and
    /// otherwise whether it applied; a refusal goes to the console.
    /// </summary>
    public bool? Write(string label, IReadOnlyList<Operation> ops)
    {
        switch (Route)
        {
            case FieldRoute.Scene:
                return null;
            case FieldRoute.Refused refused:
                _keying.Refuse(label, refused.Why);
                return false;
            case FieldRoute.Key:
                return _keying.KeySet(label, Values(ops));
            default:
                return _keying.SetValues(Values(ops));
        }
    }

    /// <summary>
    /// Opens a drag of the field that does not go to the scene: <paramref name="Routed"/> is false when it goes to the
    /// scene, and <paramref name="Edit"/> is null when it cannot open now.
    /// </summary>
    public (bool Routed, IFieldEdit? Edit) Begin(string label)
    {
        switch (Route)
        {
            case FieldRoute.Scene:
                return (false, null);
            case FieldRoute.Refused refused:
                _keying.Refuse(label, refused.Why);
                return (true, null);
            case FieldRoute.Key:
                return (true, _keying.BeginKeyDrag(label, Values));
            default:
                return (true, _keying.BeginValueDrag(Values));
        }
    }

    // The field's values in the operations, by entity. Other operations, such as a volume setting's flag, are the scene's.
    List<(ValueKey Key, SceneValue Value)> Values(IReadOnlyList<Operation> ops) =>
        [.. ops.OfType<SetField>()
            .Where(op => op.Component == _component && op.Field == _field.Name && op.Value != null && _handles.ContainsKey(op.Id))
            .Select(op => (new ValueKey(_handles[op.Id], _component, _field.Name), op.Value!))];
}

public sealed partial class Keying
{
    bool _autoKey;
    bool _autoKeyAddTracks;

    /// <summary>
    /// Whether an edit of a field of a bound entity keys it at the playhead instead of setting the scene (see
    /// docs/editor/cutscene-editor.md#auto-key). It is the session's, not saved.
    /// </summary>
    public bool AutoKey
    {
        get => _autoKey;
        set
        {
            if (_autoKey != value)
            {
                _autoKey = value;
                Raise();
            }
        }
    }

    /// <summary>Whether the red border of auto-key shows: it is on, and a cutscene holds the preview, so it acts.</summary>
    public bool AutoKeyShows => _autoKey && Cutscene != null;

    /// <summary>Whether auto-key adds the track of a field that has none, which otherwise goes to the scene.</summary>
    public bool AutoKeyAddTracks
    {
        get => _autoKeyAddTracks;
        set
        {
            if (_autoKeyAddTracks != value)
            {
                _autoKeyAddTracks = value;
                Raise();
            }
        }
    }

    /// <summary>Where edits of a field go, for the field editor of some entities, by their scene IDs and handles.</summary>
    public FieldSink Sink(IReadOnlyDictionary<ulong, ulong> handles, ulong component, FieldInfo field) => new(this, handles, component, field);

    /// <summary>
    /// Where an edit of a field of entities goes. They must agree: a field that some send to the scene and others to
    /// the cutscene is refused.
    /// </summary>
    public FieldRoute Route(IReadOnlyList<ulong> handles, ulong component, FieldInfo field) =>
        Merge([.. handles.Select(h => RouteOf(h, component, field))]);

    /// <summary>
    /// Where a gizmo drag of entities goes: their Transform's, or a child's Local_Transform's, position as a field
    /// of each goes. They must agree, as for <see cref="Route"/>.
    /// </summary>
    public FieldRoute PoseRoute(IReadOnlyList<ulong> handles)
    {
        var routes = new List<FieldRoute>();
        foreach (var handle in handles)
        {
            var child = _shell.World.Find(handle) is { Parent: not 0 };
            var component = child ? SceneEdits.LocalTransformId : SceneEdits.TransformId;
            if (_shell.World.Type(component)?.Fields.FirstOrDefault(f => f.Name == (child ? "offset" : "position")) is { } field)
            {
                routes.Add(RouteOf(handle, component, field));
            }
        }
        return Merge(routes);
    }

    static FieldRoute Merge(List<FieldRoute> all)
    {
        var routes = all.Distinct().ToList();
        return routes switch
        {
            [] => FieldRoute.Scene.Instance,
            [var one] => one,
            _ when routes.OfType<FieldRoute.Refused>().FirstOrDefault() is { } refused => refused,
            _ => new FieldRoute.Refused("The selected entities' fields go to different places: the scene, values over the preview or keys. Edit them apart."),
        };
    }

    /// <summary>
    /// An entity's pose as the world shows it while a cutscene holds the preview, with values over the preview: where a
    /// gizmo drag that goes to the cutscene starts. Null for one that nothing holds, whose pose is the document's.
    /// </summary>
    public Pose? ShownWorldPose(ulong handle)
    {
        if (Cutscene == null || _shell.World.Type(SceneEdits.TransformId) is not { } type || _shell.World.Find(handle) is not { } node)
        {
            return null;
        }
        var bytes = (node.Parent == 0 ? _shell.PreviewValues.ComponentOf(handle, SceneEdits.TransformId) : null)
            ?? (ComponentHeld(handle, SceneEdits.TransformId, type) || _shell.PreviewValues.ComponentOf(handle, SceneEdits.LocalTransformId) != null
                ? _shell.World.ShownOf(handle, SceneEdits.TransformId)
                : null);
        FieldInfo? Field(string name) => type.Fields.FirstOrDefault(f => f.Name == name);
        if (bytes == null || Field("position") is not { } p || KeyValues.Units(p, bytes) is not { } units
            || Field("rotation") is not { } r || KeyValues.Numbers(r, bytes) is not [var x, var y, var z, var w]
            || Field("scale") is not { } sc || KeyValues.Numbers(sc, bytes) is not { Length: 3 } scale)
        {
            return null;
        }
        return new Pose(units, new Maths.Quat(x, y, z, w), scale);
    }

    /// <summary>
    /// Opens a gizmo drag of entities, by their scene IDs and handles, that goes to the cutscene: of values over the
    /// preview, or with <paramref name="keys"/>, of keys. Null when it cannot open.
    /// </summary>
    internal IFieldEdit? BeginPoseDrag(string label, IReadOnlyDictionary<ulong, ulong> handles, bool keys)
    {
        List<(ValueKey Key, SceneValue Value)> Values(IReadOnlyList<Operation> ops) =>
            [.. ops.OfType<SetField>()
                .Where(op => op.Component is SceneEdits.TransformId or SceneEdits.LocalTransformId && op.Value != null && handles.ContainsKey(op.Id))
                .Select(op => (new ValueKey(handles[op.Id], op.Component, op.Field), op.Value!))];
        return keys ? BeginKeyDrag(label, Values) : BeginValueDrag(Values);
    }

    FieldRoute RouteOf(ulong handle, ulong component, FieldInfo field)
    {
        if (Cutscene is not { } cutscene || _shell.World.Type(component) is not { } type)
        {
            return FieldRoute.Scene.Instance;
        }
        var held = _shell.World.IsHeld(handle, component, Hash(field.Name)) || _shell.PreviewValues.ValueOf(handle, component, field.Name) != null;
        if (TargetOf(handle, component, field) is not { } target)
        {
            if (held)
            {
                return new FieldRoute.Refused("The preview holds this field, and no track keys it, so an edit would not show.");
            }
            // Auto-key that adds tracks asks once whether to possess an entity that no binding has.
            if (_autoKey && _autoKeyAddTracks && CandidateOf(handle, component, field) != null && PossessOf(handle) is { } entity
                && !cutscene.DeclinedPossess.Contains(entity))
            {
                _ = AskAutoPossess(handle);
                return new FieldRoute.Refused("No binding possesses this entity. Answer whether to possess it, then edit it again.");
            }
            return FieldRoute.Scene.Instance;
        }
        var keys = _autoKey && (_autoKeyAddTracks || CutsceneKeying.TrackOf(cutscene.File, target) != null);
        if (!held && !keys)
        {
            return FieldRoute.Scene.Instance;
        }
        if (cutscene.Document.InTransaction)
        {
            return new FieldRoute.Refused("A drag is under way in the cutscene.");
        }
        if (_shell.CutscenePreview.State is not CutscenePreviewState.Open open || open.Editor != cutscene)
        {
            return new FieldRoute.Refused("The cutscene's preview is not open. Edit the field when it shows.");
        }
        if (open.Playing)
        {
            return new FieldRoute.Refused("Pause the preview to change a field that the cutscene holds.");
        }
        // The value starts from what the world shows of its component, unless values over the preview already hold it.
        if (_shell.PreviewValues.ComponentOf(handle, component) == null && ComponentHeld(handle, component, type) && Fresh(handle) is { } wait)
        {
            return new FieldRoute.Refused(wait);
        }
        if (keys && CutsceneKeying.Refusal(cutscene.File, target, cutscene.Locked) is { } why)
        {
            return new FieldRoute.Refused(why);
        }
        return keys ? FieldRoute.Key.Instance : FieldRoute.Preview.Instance;
    }

    /// <summary>
    /// A component's bytes as the rows of the properties panel show them: what the world shows of a component that the
    /// preview or values over it hold, while a cutscene holds the preview, since its edits go there. Null for the
    /// document's.
    /// </summary>
    public byte[]? ShownComponent(ulong handle, ulong component)
    {
        if (Cutscene == null || _shell.World.Type(component) is not { } type)
        {
            return null;
        }
        return _shell.PreviewValues.ComponentOf(handle, component)
            ?? (ComponentHeld(handle, component, type) ? _shell.World.ShownOf(handle, component) : null);
    }

    internal void Refuse(string label, string why) =>
        _shell.Console.Add(LogLevel.Warning, $"edit: cannot {label.ToLowerInvariant()}: {why}");

    // What the world shows of a component, as values over the preview start from: the document's for one that nothing holds.
    byte[]? Base(ulong handle, ulong component)
    {
        if (_shell.World.Values(handle)?.Components.FirstOrDefault(c => c.Id == component)?.Data is not { } document
            || _shell.World.Type(component) is not { } type)
        {
            return null;
        }
        return ComponentHeld(handle, component, type) ? _shell.World.ShownOf(handle, component) : document;
    }

    /// <summary>Sets values over the preview, which the world shows until they are keyed or dropped.</summary>
    internal bool SetValues(IReadOnlyList<(ValueKey Key, SceneValue Value)> values) =>
        Cutscene is { } cutscene && _shell.PreviewValues.Set(cutscene, values, Base);

    /// <summary>
    /// Keys values at the playhead, as one undo entry: they show over the preview at once, and stay until it shows the
    /// keyed text.
    /// </summary>
    internal bool KeySet(string label, IReadOnlyList<(ValueKey Key, SceneValue Value)> values)
    {
        if (Cutscene is not { } cutscene || !SetValues(values))
        {
            return false;
        }
        var before = cutscene.Document.Text;
        Edit(label, file => SetValueKeys(file, values));
        _shell.PreviewValues.Keyed();
        return cutscene.Document.Text != before;
    }

    // Keys the fields that values set, each from the values over the preview.
    void SetValueKeys(CutsceneFile file, IEnumerable<(ValueKey Key, SceneValue Value)> values)
    {
        foreach (var (handle, component, field) in values.Select(v => v.Key).Distinct())
        {
            if (_shell.World.Type(component)?.Fields.FirstOrDefault(f => f.Name == field) is { } info && TargetOf(handle, component, info) is { } target)
            {
                SetKeys(file, handle, target, TrackName(target, info));
            }
        }
    }

    /// <summary>Whether Enter can key the values over the preview: some are not keyed, and each takes a key now.</summary>
    public string? KeyPreviewValuesRefusal()
    {
        if (_shell.PreviewValues.State is not PreviewValuesState.Holding holding)
        {
            return "No values over the preview wait for a key.";
        }
        return Refusal(holding.Values.Keys.GroupBy(k => k.Handle).Select(g => (g.Key, Targets(g))));

        List<KeyTarget> Targets(IEnumerable<ValueKey> keys) =>
            [.. keys.Select(k => _shell.World.Type(k.Component)?.Fields.FirstOrDefault(f => f.Name == k.Field) is { } f ? TargetOf(k.Handle, k.Component, f) : null)
                .OfType<KeyTarget>()];
    }

    /// <summary>Keys the values over the preview at the playhead, as one undo entry: Enter.</summary>
    public void KeyPreviewValues()
    {
        if (KeyPreviewValuesRefusal() == null && _shell.PreviewValues.State is PreviewValuesState.Holding holding)
        {
            Edit("Key Preview Values", file => SetValueKeys(file, holding.Values.Select(v => (v.Key, v.Value))));
            _shell.PreviewValues.Keyed();
        }
    }

    /// <summary>Opens a drag of values over the preview. A cancel puts the values back as they were.</summary>
    internal IFieldEdit BeginValueDrag(Func<IReadOnlyList<Operation>, List<(ValueKey Key, SceneValue Value)>> values) =>
        new ValueDrag(this, _shell.PreviewValues.State, values, keys: null);

    /// <summary>
    /// Opens a drag of keys, as one undo entry in the cutscene from here to its commit. Null when the cutscene has a drag
    /// under way.
    /// </summary>
    internal IFieldEdit? BeginKeyDrag(string label, Func<IReadOnlyList<Operation>, List<(ValueKey Key, SceneValue Value)>> values)
    {
        if (Cutscene?.BeginHeldDrag(label) is not { } drag)
        {
            return null;
        }
        return new ValueDrag(this, _shell.PreviewValues.State, values, drag);
    }

    // A drag of values over the preview, and with a cutscene's drag, of keys from them. Each step sets the values from
    // where the drag began, which show over the preview at once, as the cutscene does not cook a drag's steps. A drag of
    // keys lasts as long as the cutscene's drag: one that another ends, as Esc in the timeline does, ends it too, and its
    // values go back as they were.
    sealed class ValueDrag : IFieldEdit
    {
        readonly Keying _keying;
        readonly PreviewValuesState _before;
        readonly Func<IReadOnlyList<Operation>, List<(ValueKey Key, SceneValue Value)>> _values;
        readonly CutsceneDrag? _keys;
        readonly int _position;
        bool _open = true;

        public ValueDrag(Keying keying, PreviewValuesState before, Func<IReadOnlyList<Operation>, List<(ValueKey Key, SceneValue Value)>> values, CutsceneDrag? keys)
        {
            (_keying, _before, _values, _keys) = (keying, before, values, keys);
            if (keys != null)
            {
                _position = keys.Editor.Document.Position;
                keys.Ended += OnKeysEnded;
            }
        }

        public bool IsOpen => _open && (_keys == null || _keys.IsOpen);

        public event Action<bool>? Ended;

        public bool Preview(IReadOnlyList<Operation> ops)
        {
            if (!IsOpen)
            {
                return false;
            }
            var set = _values(ops);
            if (!_keying.SetValues(set))
            {
                return false;
            }
            _keys?.Step(file =>
            {
                _keying.SetValueKeys(file, set);
                return [];
            });
            return true;
        }

        public void Commit() => End(commit: true);

        public void Cancel() => End(commit: false);

        void End(bool commit)
        {
            if (!_open)
            {
                return;
            }
            if (_keys != null)
            {
                // The cutscene's drag ends, and its Ended finishes this one.
                if (_keys.IsOpen)
                {
                    _keys.End(cancel: !commit);
                }
                else
                {
                    Finish(committed: false);
                }
                return;
            }
            Finish(commit);
        }

        void OnKeysEnded(bool committed)
        {
            if (_open && committed && _keys!.Editor.Document.Position != _position)
            {
                _keying._shell.Edited(new UndoTarget.Cutscene(_keys.Editor));
            }
            Finish(committed);
        }

        // The one end: values that were keyed settle; values of a cancelled drag go back as they were, unless they have
        // gone since, with the session or the playhead that they were set at.
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
            if (committed && _keys != null)
            {
                _keying._shell.PreviewValues.Keyed();
            }
            else if (!committed && _keying._shell.PreviewValues.State is PreviewValuesState.Live now
                && (_before is not PreviewValuesState.Live was || (was.Ticket == now.Ticket && was.Tick == now.Tick)))
            {
                _keying._shell.PreviewValues.Restore(_before);
            }
            Ended?.Invoke(committed);
        }
    }
}
