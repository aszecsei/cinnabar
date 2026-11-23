using Cinnabar.Editor.Content;
using Cinnabar.Editor.Cutscenes;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Shell;

/// <summary>A loop of the preview, from a tick to a later one.</summary>
public sealed record CutsceneLoop(int Start, int End);

/// <summary>Which of a cutscene tab's panes has the keyboard: the timeline, the curve editor, or neither.</summary>
public enum CutscenePane
{
    None,
    Timeline,
    Curves,
}

/// <summary>
/// An open cutscene in its editor (see docs/editor/cutscene-editor.md#the-tab): its document, the block that is
/// selected, and the problems of the last check of its text on their blocks. The view turns input into calls here, so
/// tests can drive the editor without a window. Blocks are named by path, since an undo reads the file again and
/// replaces its block objects.
/// </summary>
public sealed partial class CutsceneEditor : IGraphEditor
{
    readonly EditorShell _shell;
    readonly List<GraphProblem> _problems = [];
    readonly PreviewCook _cook;
    readonly List<string> _selection = [];
    readonly HashSet<string> _folds = [];
    readonly HashSet<int> _locked;
    readonly HashSet<int> _muted;
    readonly HashSet<int> _soloed;
    int _playhead;
    bool _snap = true;
    bool _showFrames;
    CutscenePane _pane;
    TimelineView _timeView = new(0, 1000, TimelineZoom.Ticks);
    bool _follow = true;
    bool _curvesOpen;
    bool _curvesNormalized;
    bool _valueSnap;
    readonly HashSet<string> _hiddenCurves = [];
    IReadOnlyList<string> _shownCurves = [];
    float _playRate = 1;
    int? _in;
    int? _out;
    bool _loop;
    bool _scrubSound;
    bool _previewEvents;

    internal CutsceneEditor(EditorShell shell, CutsceneDocument document)
    {
        _shell = shell;
        Document = document;
        _cook = new PreviewCook(() => _shell.PreviewCooker.Linked, () => CookText, text => _shell.PreviewCooker.CookPreview(Guid, text), ShowProblems);
        Document.Changed += OnDocumentChanged;
        var view = shell.CutsceneTimelineSettingsOf(Guid);
        _showFrames = view.ShowFrames;
        _locked = [.. view.Locked];
        _muted = [.. view.Muted ?? []];
        _soloed = [.. view.Soloed ?? []];
        _scrubSound = view.ScrubSound;
        _previewEvents = view.Events;
        _standIns = new(view.StandIns ?? []);
        // A binding's row shows its entity or prefab, which the open scenes and the asset index have.
        _shell.SceneChanged += OnBindingTargetsChanged;
        _shell.Assets.Changed += OnBindingTargetsChanged;
        _shell.Selection.Changed += OnEntitiesSelected;
        _entityBindings = BindingsOfEntities(_shell.Selection.Entities);
    }

    public CutsceneDocument Document { get; }

    IGraphDocument IGraphEditor.Document => Document;

    public string Noun => "cutscene";

    public string Guid => Document.Guid;

    public CutsceneFile File => Document.Graph;

    /// <summary>
    /// The paths of the selected blocks (see <see cref="CutsceneFile.PathOf"/>), in the order they were selected. The
    /// last is the primary one, which the details strip shows.
    /// </summary>
    public IReadOnlyList<string> SelectedPaths => _selection;

    /// <summary>The path of the primary selected block, or null for none.</summary>
    public string? Selection => _selection.Count > 0 ? _selection[^1] : null;

    /// <summary>The primary selected block, or null for none.</summary>
    public CutsceneBlock? Selected => Selection is { } path ? File.Find(path) : null;

    /// <summary>The problems of the last check, each with its line, or 0 for one of no line of this file.</summary>
    public IReadOnlyList<GraphProblem> Problems => _problems;

    /// <summary>The cutscene, its document's state or the selection changed.</summary>
    public event Action? Changed;

    public event Action? ProblemsChanged;

    void OnDocumentChanged()
    {
        // An undo or an edit can take selected blocks away. A key's path is its place in its channel, so another key can
        // have it after a delete, an undo or a cancel: a key stays selected only while its path holds the same line.
        _selection.RemoveAll(p => File.Find(p) is not { } block
            || (!_ownEdit && block.Kind == CutsceneBlockKind.Key && _keyLines.TryGetValue(p, out var line) && line != KeyLine(block)));
        FollowShownCurves();
        // A binding added or removed changes which bindings the selected entities have.
        _entityBindings = BindingsOfEntities(_shell.Selection.Entities);
        EndStalePick();
        Changed?.Invoke();
        _shell.Commands.InvalidateAll();
        if (!Document.InTransaction)
        {
            _cook.Schedule();
            // A track added, deleted or muted in the asset changes which tracks a solo silences.
            _shell.CutscenePreview.OnMixChanged(this);
        }
        if (_shell.CutscenePreview.Owner == this)
        {
            _shell.Keying.Raise();
        }
    }

    /// <summary>
    /// Selects a block alone, or with null, none. A block whose path another block has too, as two sections with one ID
    /// have, cannot be selected, since an edit could land on the other: the cooker reports the ID.
    /// </summary>
    public void Select(CutsceneBlock? block) => Select(block == null ? [] : [CutsceneFile.PathOf(block)], SelectMode.Replace);

    /// <summary>
    /// Selects blocks by path: in place of the selection, added to it, or each one in or out of it. A path that names no
    /// block, or two, is left out.
    /// </summary>
    public void Select(IEnumerable<string> paths, SelectMode mode)
    {
        // What the filter hides is not selected, so Delete never acts on what is not in view.
        var shown = ShownTracks();
        var hits = paths.Distinct().Where(p => File.Find(p) is { } b && InView(b, shown)).ToList();
        // The paths stay in the order they were selected, and a path selected again goes last, as the primary one.
        var hitSet = hits.ToHashSet();
        var current = _selection.ToHashSet();
        var kept = mode == SelectMode.Replace ? [] : _selection.Where(p => !hitSet.Contains(p)).ToList();
        var next = mode == SelectMode.Toggle
            ? [.. kept, .. hits.Where(p => !current.Contains(p))]
            : kept.Concat(hits).ToList();
        if (next.SequenceEqual(_selection))
        {
            return;
        }
        // A new selection ends a held nudge, so nudges of two selections are two entries.
        Document.EndMerge();
        Replace(next);
        EndStalePick();
        Changed?.Invoke();
        _shell.Commands.InvalidateAll();
        SelectBoundEntities();
    }

    /// <summary>The problems on a block's own lines.</summary>
    public IEnumerable<GraphProblem> ProblemsOf(CutsceneBlock block) => _problems.Where(p => p.Line > 0 && File.BlockAt(p.Line) == block);

    /// <summary>The block whose own lines hold a line, from 1, or null.</summary>
    public CutsceneBlock? BlockAt(int line) => File.BlockAt(line);

    /// <summary>An edit of the selected block in one undo entry. Nothing without a selection.</summary>
    public void EditSelected(string label, Action<CutsceneBlock> edit)
    {
        if (Selection is not { } path)
        {
            return;
        }
        Own(() => Document.Edit(label, f =>
        {
            if (f.Find(path) is { } block)
            {
                edit(block);
            }
        }));
    }

    /// <summary>
    /// Starts a drag of a field of the selected block, such as a scrub of a section's end: one undo entry from here to
    /// <see cref="EndField"/>, whose steps preview as they go. False when a drag is under way or nothing is selected.
    /// </summary>
    public bool BeginField(string label)
    {
        if (Document.InTransaction || Selection == null)
        {
            return false;
        }
        Document.Begin(label);
        return true;
    }

    /// <summary>A step of the drag. Nothing when none is under way.</summary>
    public void StepField(Action<CutsceneBlock> edit)
    {
        if (!Document.InTransaction || Selection is not { } path)
        {
            return;
        }
        Own(() => Document.Step(f =>
        {
            if (f.Find(path) is { } block)
            {
                edit(block);
            }
        }));
    }

    /// <summary>Ends the drag: commits its one undo entry, or with cancel, as with Esc, puts the text back as it was.</summary>
    public void EndField(bool cancel)
    {
        if (!Document.InTransaction)
        {
            return;
        }
        if (cancel)
        {
            Document.Cancel();
        }
        else
        {
            Document.Commit();
        }
        // Whoever ended it, the holder of a keying drag learns so.
        var held = _held;
        _held = null;
        held?.RaiseEnded(!cancel);
    }

    /// <summary>
    /// The entities that the designer chose not to possess when auto-key asked, for this tab: their edits go to the
    /// scene, and auto-key does not ask again.
    /// </summary>
    internal HashSet<PossessRef> DeclinedPossess { get; } = [];

    /// <summary>The playhead in ticks: where a split, Home and End act. It is the editor's, not the document's, so it is in no undo entry.</summary>
    public int Playhead => _playhead;

    public event Action? PlayheadChanged;

    /// <summary>The timeline should fit the selection, or the whole cutscene, in its view: F.</summary>
    public event Action? FrameRequested;

    public void RequestFrame() => FrameRequested?.Invoke();

    /// <summary>The view should put the keyboard in its search box: Ctrl+F.</summary>
    public event Action? FindRequested;

    public void RequestFind() => FindRequested?.Invoke();

    /// <summary>The view should put the keyboard in its time box: Ctrl+G.</summary>
    public event Action? GoToTimeRequested;

    public void RequestGoToTime() => GoToTimeRequested?.Invoke();

    /// <summary>The rate at which this tab's preview plays, below 0 backward, or null when it does not play.</summary>
    public float? PlayingRate => _shell.CutscenePreview.RateIn(this);

    /// <summary>The preview began to play, from a press of Space, J or L, or again when it opens. A loop's change while it plays is not a new play.</summary>
    public event Action? PlayStarted;

    internal void OnPlayStarted() => PlayStarted?.Invoke();

    /// <summary>J and L while K is not held: plays this tab's preview that way, faster on each press (see <see cref="CutscenePreview.Shuttle"/>).</summary>
    public void Shuttle(int direction) => _shell.CutscenePreview.Shuttle(this, direction);

    /// <summary>Moves the playhead, inside the length. The preview shows it, and a playing preview pauses.</summary>
    public void SetPlayhead(int ticks)
    {
        if (MovePlayhead(ticks))
        {
            _shell.CutscenePreview.OnScrub(this);
        }
    }

    /// <summary>Moves the playhead to the tick that the game reported, which the preview does not send back.</summary>
    public void SetPlayheadFromGame(int ticks) => MovePlayhead(ticks);

    bool MovePlayhead(int ticks)
    {
        var at = Math.Clamp(ticks, 0, File.Length ?? 0);
        if (at == _playhead)
        {
            return false;
        }
        _playhead = at;
        PlayheadChanged?.Invoke();
        _shell.CutscenePreview.OnPlayheadMoved(this);
        _shell.Commands.InvalidateAll();
        return true;
    }

    /// <summary>Moves the playhead by frames, and pauses a playing preview where it is, even at the end of the cutscene.</summary>
    public void Step(int frames)
    {
        _shell.CutscenePreview.Pause();
        SetPlayhead(_playhead + frames * FrameTicks);
    }

    /// <summary>Whether drags and nudges snap (see <see cref="TimelineSnap"/>). On at first; N turns it off and on.</summary>
    public bool Snap
    {
        get => _snap;
        set
        {
            if (_snap != value)
            {
                _snap = value;
                Changed?.Invoke();
                _shell.Commands.InvalidateAll();
            }
        }
    }

    /// <summary>Whether the ruler shows frames, not timecode. Each user's, for each cutscene.</summary>
    public bool ShowFrames
    {
        get => _showFrames;
        set
        {
            if (_showFrames != value)
            {
                _showFrames = value;
                SaveView();
                Changed?.Invoke();
                _shell.Commands.InvalidateAll();
            }
        }
    }

    /// <summary>The paths whose fold is not the default (see <see cref="CutsceneTimelineLayout.Build"/>).</summary>
    public IReadOnlySet<string> Folds => _folds;

    public void ToggleFold(string path)
    {
        if (!_folds.Remove(path))
        {
            _folds.Add(path);
        }
        Changed?.Invoke();
    }

    /// <summary>The IDs of the locked tracks, whose sections, events and keys no edit changes. Each user's, for each cutscene.</summary>
    public IReadOnlySet<int> Locked => _locked;

    public void SetLocked(int track, bool locked)
    {
        if (locked ? _locked.Add(track) : _locked.Remove(track))
        {
            SaveView();
            Changed?.Invoke();
            _shell.Commands.InvalidateAll();
        }
    }

    /// <summary>The IDs of the tracks that this user muted, which the preview does not play. Each user's, for each cutscene.</summary>
    public IReadOnlySet<int> Muted => _muted;

    /// <summary>The IDs of the tracks that this user soloed: with any, the preview plays only those. Each user's, for each cutscene.</summary>
    public IReadOnlySet<int> Soloed => _soloed;

    public void SetMuted(int track, bool muted) => Toggle(_muted, track, muted);

    public void SetSoloed(int track, bool soloed) => Toggle(_soloed, track, soloed);

    void Toggle(HashSet<int> set, int track, bool on)
    {
        if (on ? set.Add(track) : set.Remove(track))
        {
            SaveView();
            Changed?.Invoke();
            _shell.Commands.InvalidateAll();
            _shell.CutscenePreview.OnMixChanged(this);
        }
    }

    /// <summary>
    /// The IDs of the tracks that the preview silences because <see cref="Audible"/> says no. A track that the asset
    /// mutes is left out, since its blob mutes it already.
    /// </summary>
    public IEnumerable<int> SilentTracks() => File.Tracks
        .Where(t => t.Id is { } id && !Audible(id) && t.Get("muted")?.Trim() != "true")
        .Select(t => t.Id!.Value)
        .Distinct();

    /// <summary>Whether a scrub plays short grains of the sound under the playhead. On at first. Each user's, for each cutscene.</summary>
    public bool ScrubSound
    {
        get => _scrubSound;
        set => SetMix(ref _scrubSound, value);
    }

    /// <summary>Whether the event tracks send their events while the preview plays. Off at first. Each user's, for each cutscene.</summary>
    public bool PreviewEvents
    {
        get => _previewEvents;
        set => SetMix(ref _previewEvents, value);
    }

    void SetMix(ref bool field, bool value)
    {
        if (field != value)
        {
            field = value;
            SaveView();
            Changed?.Invoke();
            _shell.Commands.InvalidateAll();
            _shell.CutscenePreview.OnMixChanged(this);
        }
    }

    /// <summary>The slowest and the fastest that the play rate box and Space play.</summary>
    public const float MinPlayRate = 0.1f;

    public const float MaxPlayRate = 4f;

    /// <summary>The rate at which Space plays, from <see cref="MinPlayRate"/> to <see cref="MaxPlayRate"/>. The tab's, and not saved.</summary>
    public float PlayRate
    {
        get => _playRate;
        set
        {
            var rate = Math.Clamp(value, MinPlayRate, MaxPlayRate);
            if (_playRate != rate)
            {
                _playRate = rate;
                Changed?.Invoke();
            }
        }
    }

    /// <summary>The in point, which I sets at the playhead, or null for none: the loop starts there. The tab's, and not saved.</summary>
    public int? InPoint => _in;

    /// <summary>The out point, which O sets at the playhead, or null for none: the loop ends there. The tab's, and not saved.</summary>
    public int? OutPoint => _out;

    /// <summary>Whether playback loops over <see cref="LoopRange"/>. The tab's, and not saved.</summary>
    public bool Loop
    {
        get => _loop;
        set
        {
            if (_loop != value)
            {
                _loop = value;
                LoopChanged(plays: true);
            }
        }
    }

    /// <summary>
    /// What a loop plays: from the in point, or the start of the cutscene's range, to the out point, or the range's end,
    /// in time order. Null when that span is empty, so a play does not loop.
    /// </summary>
    public CutsceneLoop? LoopRange
    {
        get
        {
            var length = File.Length ?? 0;
            var range = CutsceneEdits.RangeOf(File);
            var a = Math.Clamp(_in ?? range.Start, 0, length);
            var b = Math.Clamp(_out ?? range.End, 0, length);
            var (start, end) = a <= b ? (a, b) : (b, a);
            return end > start ? new CutsceneLoop(start, end) : null;
        }
    }

    /// <summary>Sets the in point at the playhead, or with null, clears it.</summary>
    public void SetIn(int? tick)
    {
        if (_in != tick)
        {
            _in = tick;
            LoopChanged(plays: _loop);
        }
    }

    /// <summary>Sets the out point at the playhead, or with null, clears it.</summary>
    public void SetOut(int? tick)
    {
        if (_out != tick)
        {
            _out = tick;
            LoopChanged(plays: _loop);
        }
    }

    /// <summary>Clears the in and the out point, as one change.</summary>
    public void ClearInOut()
    {
        if (_in != null || _out != null)
        {
            _in = _out = null;
            LoopChanged(plays: _loop);
        }
    }

    // The points change the play only while it loops, and the loop's toggle always does.
    void LoopChanged(bool plays = true)
    {
        Changed?.Invoke();
        _shell.Commands.InvalidateAll();
        if (plays)
        {
            _shell.CutscenePreview.OnLoopChanged(this);
        }
    }

    /// <summary>
    /// Whether the shuttle's pause, K, is held: J and L step a frame then, and do not play. The K command sets it, and
    /// its key's release or the timeline's loss of the keyboard clears it.
    /// </summary>
    public bool ShuttleHeld { get; private set; }

    /// <summary>Shuttle Pause's key went down: J and L step until <see cref="EndShuttleHold"/>.</summary>
    public void BeginShuttleHold() => ShuttleHeld = true;

    /// <summary>Shuttle Pause's key went up, or the timeline lost the keyboard: J and L play again.</summary>
    public void EndShuttleHold() => ShuttleHeld = false;

    /// <summary>The key of Shuttle Pause, as keybindings.json has it, whose release ends <see cref="ShuttleHeld"/>.</summary>
    public string? ShuttlePauseShortcut => _shell.KeyBindings.ShortcutOf(EditorCommands.CutsceneShuttlePause);

    /// <summary>
    /// The IDs of the tracks of the selection: each selected track, and the track of each selected section, event or
    /// key. Empty when the selection holds none.
    /// </summary>
    public IReadOnlySet<int> SelectedTracks => _selection
        .Select(File.Find).OfType<CutsceneBlock>()
        .Select(CutsceneEdits.TrackOf).OfType<CutsceneBlock>()
        .Select(t => t.Id).OfType<int>()
        .ToHashSet();

    /// <summary>
    /// The times that Up and Down move the playhead to: the start and the end, and the keys and the edges of the sections,
    /// ranges and triggers of the selected tracks, or of every track that the filter shows when the selection holds
    /// none. A folded binding's tracks count.
    /// </summary>
    public List<int> KeyEdges()
    {
        var tracks = SelectedTracks;
        return CutsceneTimelineLayout.Build(File, new HashSet<string>(), RowFilter).KeyEdges(tracks.Count > 0 ? tracks : null);
    }

    /// <summary>
    /// Whether the preview plays a track (see docs/editor/cutscene-editor.md#mute-and-solo): not when the asset sets
    /// <c>muted = true</c>, which no player plays, nor when this user muted it, nor when this user soloed other tracks
    /// and not it. Mute and solo change no file but the user's settings. The preview's player (#551) asks this. A solo
    /// of a track that the cutscene no longer has counts for nothing, so a deleted track does not silence the others.
    /// </summary>
    public bool Audible(int track)
    {
        if (_muted.Contains(track) || (!_soloed.Contains(track) && _soloed.Any(id => File.Tracks.Any(t => t.Id == id))))
        {
            return false;
        }
        return File.Tracks.FirstOrDefault(t => t.Id == track)?.Get("muted")?.Trim() != "true";
    }

    void SaveView() => _shell.SaveCutsceneTimelineSettings(Guid,
        new CutsceneTimelineView(_showFrames, [.. _locked.Order()], [.. _muted.Order()], [.. _soloed.Order()], _scrubSound, _previewEvents,
            _standIns.Count == 0 ? null : new(_standIns)));

    /// <summary>The text that the track tree's search box filters by.</summary>
    public string FilterText { get; private set; } = "";

    /// <summary>Whether the timeline shows only the tracks with keys in the span that the selection had when this went on.</summary>
    public bool KeysUnderSelection => _keysUnder != null;

    // The keys-under-selection filter when it is on, with its span, or null for none, which hides nothing.
    sealed record KeysFilter((int Start, int End)? Span);

    KeysFilter? _keysUnder;

    /// <summary>Which rows the timeline shows, which every <see cref="CutsceneTimelineLayout.Build"/> of this editor takes.</summary>
    public CutsceneRowFilter RowFilter => new(FilterText, _keysUnder?.Span, SelectedOnly ? BindingsOfEntities(_shell.Selection.Entities) : null);

    /// <summary>The timeline's rows, as the filter and the folds have them, with each binding's state.</summary>
    public CutsceneTimelineLayout Layout() => CutsceneTimelineLayout.Build(File, _folds, RowFilter, InfoOf);

    public void SetFilterText(string text)
    {
        text = text.Trim();
        if (text != FilterText)
        {
            FilterText = text;
            FilterChanged();
        }
    }

    /// <summary>
    /// Turns the keys-under-selection filter on or off. On, it keeps the span of the selection as it is now, so that a
    /// click in the filtered rows does not change which rows there are. With nothing selected, it hides nothing.
    /// </summary>
    public void SetKeysUnderSelection(bool on)
    {
        if (on == KeysUnderSelection)
        {
            return;
        }
        _keysUnder = on ? new KeysFilter(SelectionSpan()) : null;
        FilterChanged();
    }

    // The paths of the tracks that the filter shows, or null when it shows them all.
    HashSet<string>? ShownTracks() => RowFilter.IsNone
        ? null
        : Layout().Rows.Where(r => r.Kind == CutsceneRowKind.Track).Select(r => r.Path).ToHashSet();

    // Whether a block is on no track, as a marker or a binding is, or on a track that the filter shows.
    static bool InView(CutsceneBlock block, HashSet<string>? shown) =>
        shown == null || block.Kind == CutsceneBlockKind.Binding || CutsceneEdits.TrackOf(block) is not { } track || shown.Contains(CutsceneFile.PathOf(track));

    // The span of the selected sections, events, keys and markers on the cutscene's time, or null for none.
    (int Start, int End)? SelectionSpan()
    {
        var blocks = _selection.Select(File.Find).OfType<CutsceneBlock>().Where(CutsceneEdits.IsTimed).ToList();
        var starts = blocks.Select(CutsceneEdits.AbsoluteStart).OfType<int>().ToList();
        var ends = blocks.Select(CutsceneEdits.AbsoluteEnd).OfType<int>().ToList();
        return starts.Count == 0 ? null : (starts.Min(), ends.Max());
    }

    // A filter hides rows: what is selected on a hidden track leaves the selection, so Delete never acts on what is not
    // in view.
    void FilterChanged()
    {
        var shown = ShownTracks();
        var kept = _selection.Where(p => File.Find(p) is not { } b || InView(b, shown)).ToList();
        if (kept.Count != _selection.Count)
        {
            Replace(kept);
        }
        Changed?.Invoke();
        _shell.Commands.InvalidateAll();
    }

    /// <summary>The track of the primary selection: the selected track, or the track of a selected section, event or key.</summary>
    public CutsceneBlock? SelectedTrack => Selected is { } block ? CutsceneEdits.TrackOf(block) : null;

    /// <summary>
    /// Whether the timeline or the curve editor has the keyboard: the timeline's commands act only then, as their keys
    /// are bare letters that the viewport and the other panels use too.
    /// </summary>
    public bool TimelineFocused => _pane != CutscenePane.None;

    /// <summary>Which pane has the keyboard. F, Delete and the tangent commands act on the curve editor while it does.</summary>
    public CutscenePane KeyboardPane => _pane;

    /// <summary>
    /// The one writer of <see cref="KeyboardPane"/>, which each pane's view calls as the focus moves. When neither pane
    /// has the keyboard, a held nudge and a held shuttle pause end.
    /// </summary>
    public void SetKeyboardPane(CutscenePane pane)
    {
        if (_pane == pane)
        {
            return;
        }
        _pane = pane;
        if (pane == CutscenePane.None)
        {
            EndNudge();
            EndShuttleHold();
        }
        _shell.Commands.InvalidateAll();
    }

    /// <summary>A pane lost the keyboard to something outside it: nothing has it, unless the other pane took it first.</summary>
    public void LeaveKeyboardPane(CutscenePane pane)
    {
        if (_pane == pane)
        {
            SetKeyboardPane(CutscenePane.None);
        }
    }

    /// <summary>
    /// The part of the cutscene's time that the timeline and the curve editor show, which they share, so a pan or a zoom
    /// of one moves the other. The tab's, and not saved.
    /// </summary>
    public TimelineView TimeView => _timeView;

    /// <summary>The time view changed.</summary>
    public event Action? TimeViewChanged;

    /// <summary>The one writer of <see cref="TimeView"/>.</summary>
    public void SetTimeView(TimelineView view)
    {
        if (view != _timeView)
        {
            _timeView = view;
            TimeViewChanged?.Invoke();
        }
    }

    /// <summary>
    /// Whether the time view follows the playhead while the preview plays. A play turns it on, and a pan or a zoom of the
    /// time by hand, in either pane, turns it off until the next play.
    /// </summary>
    public bool Follow => _follow;

    /// <summary>The one writer of <see cref="Follow"/>.</summary>
    public void SetFollow(bool follow) => _follow = follow;

    /// <summary>Whether the curve editor shows below the timeline: Ctrl+E. The tab's, and not saved.</summary>
    public bool CurvesOpen
    {
        get => _curvesOpen;
        set
        {
            if (_curvesOpen != value)
            {
                _curvesOpen = value;
                if (!value && _pane == CutscenePane.Curves)
                {
                    SetKeyboardPane(CutscenePane.Timeline);
                }
                Changed?.Invoke();
                _shell.Commands.InvalidateAll();
            }
        }
    }

    /// <summary>
    /// Whether a value drag in the curve editor puts the grabbed key's value on a grid line: Value Snap, off at first. The
    /// tab's, and not saved. Ctrl during a drag turns it off for that drag, as it does time snapping.
    /// </summary>
    public bool ValueSnap
    {
        get => _valueSnap;
        set
        {
            if (_valueSnap != value)
            {
                _valueSnap = value;
                Changed?.Invoke();
                _shell.Commands.InvalidateAll();
            }
        }
    }

    /// <summary>Whether the curve editor scales each curve to −1..1, for display only. The tab's, and not saved.</summary>
    public bool CurvesNormalized
    {
        get => _curvesNormalized;
        set
        {
            if (_curvesNormalized != value)
            {
                _curvesNormalized = value;
                Changed?.Invoke();
                _shell.Commands.InvalidateAll();
            }
        }
    }

    /// <summary>
    /// The paths of the channels whose curves the curve editor lists (see docs/editor/cutscene-editor.md#curves): each
    /// channel of a selected track, and the channel of a selected section, channel or key. A selection of keys only keeps
    /// the curves that showed before it and adds their own, so a click on a curve's key does not hide the other curves.
    /// </summary>
    public IReadOnlyList<string> ShownCurves => _shownCurves;

    // Follows the selection, from the selection's one writer, Replace, and after an edit that can take channels away.
    void FollowShownCurves()
    {
        var blocks = _selection.Select(File.Find).OfType<CutsceneBlock>().ToList();
        if (blocks.Count > 0 && blocks.All(b => b.Kind == CutsceneBlockKind.Key))
        {
            var kept = _shownCurves.Where(p => File.Find(p) is { Kind: CutsceneBlockKind.Channel }).ToList();
            var own = blocks.Select(b => CutsceneFile.PathOf(b.Parent!)).Distinct().Where(p => !kept.Contains(p));
            _shownCurves = [.. kept, .. own];
            return;
        }
        if (blocks.Count == 0)
        {
            // Nothing selected, as after a click in the curve editor's empty space: the curves stay.
            _shownCurves = [.. _shownCurves.Where(p => File.Find(p) is { Kind: CutsceneBlockKind.Channel })];
            return;
        }
        var channels = new List<string>();
        foreach (var block in blocks)
        {
            IEnumerable<CutsceneBlock> under = block.Kind switch
            {
                CutsceneBlockKind.Track => block.Children.Where(c => c.Kind == CutsceneBlockKind.Section).SelectMany(s => s.Children),
                CutsceneBlockKind.Section => block.Children,
                CutsceneBlockKind.Channel => [block],
                CutsceneBlockKind.Key => [block.Parent!],
                _ => [],
            };
            channels.AddRange(under.Where(c => c.Kind == CutsceneBlockKind.Channel).Select(CutsceneFile.PathOf));
        }
        _shownCurves = [.. channels.Distinct()];
    }

    /// <summary>The channels whose curves the designer hid in the curve editor's list. The tab's, and not saved.</summary>
    public IReadOnlySet<string> HiddenCurves => _hiddenCurves;

    public void SetCurveHidden(string channel, bool hidden)
    {
        if (hidden ? _hiddenCurves.Add(channel) : _hiddenCurves.Remove(channel))
        {
            Changed?.Invoke();
        }
    }

    /// <summary>The curve editor should fit the selected keys, or every curve it shows, in its view: F there.</summary>
    public event Action? FrameCurvesRequested;

    public void RequestFrameCurves() => FrameCurvesRequested?.Invoke();

    /// <summary>
    /// Whether a channel's field steps, as an integer, a bool or an enum does: its curve draws as steps, a new key on it
    /// is constant, and the tangent commands leave its keys. The shell knows from the game's component types.
    /// </summary>
    public bool Stepped(CutsceneBlock channel) => _shell.SteppedChannel(channel);

    /// <summary>The selected keys that a tangent command changes: on a curve that the runtime reads, not stepped, and not locked.</summary>
    public IReadOnlyList<string> TangentKeys => [.. _selection.Where(p => File.Find(p) is { Kind: CutsceneBlockKind.Key, Parent: { } channel } key
        && !CutsceneEdits.IsLocked(key, _locked) && !Stepped(channel) && CutsceneCurveEdits.KeysOf(channel) != null)];

    /// <summary>Sets the tangents of the selected keys, as one undo entry. Nothing when no key changes.</summary>
    public void SetTangents(TangentMode mode)
    {
        var keys = TangentKeys;
        if (Document.InTransaction || keys.Count == 0)
        {
            return;
        }
        var label = mode switch
        {
            TangentMode.Auto => "Auto Tangents",
            TangentMode.Unify => "Unify Tangents",
            TangentMode.Break => "Break Tangents",
            TangentMode.Linear => "Linear",
            TangentMode.Constant => "Constant",
            _ => "Flatten Tangents",
        };
        Own(() => Document.Edit(label, f => CutsceneCurveEdits.SetTangents(f, keys, mode, _locked)));
    }

    /// <summary>
    /// The selected keys that the curve editor's time and value boxes show and set: on a curve that the runtime reads, on
    /// a track that is not locked. Stepped curves' keys are among them.
    /// </summary>
    public IReadOnlyList<string> CurveKeys => [.. _selection.Where(p => File.Find(p) is { Kind: CutsceneBlockKind.Key, Parent: { } channel } key
        && !CutsceneEdits.IsLocked(key, _locked) && CutsceneCurveEdits.KeysOf(channel) != null)];

    /// <summary>The time on the cutscene's time that every one of <see cref="CurveKeys"/> has, or null when they differ or there are none.</summary>
    public int? CurveKeyTime
    {
        get
        {
            var times = CurveKeys.Select(File.Find).Select(b => CutsceneEdits.SectionOf(b!)?.Start + b!.Start).Distinct().ToList();
            return times.Count == 1 ? times[0] : null;
        }
    }

    /// <summary>The value that every one of <see cref="CurveKeys"/> has, or null when they differ or there are none.</summary>
    public float? CurveKeyValue
    {
        get
        {
            var values = CurveKeys.Select(p => CurveKey.Parse(File.Find(p)!)?.Value).Distinct().ToList();
            return values.Count == 1 ? values[0] : null;
        }
    }

    /// <summary>
    /// Sets the times of <see cref="CurveKeys"/> from a typed entry (see <see cref="CurveEntry"/>): timecode or frames at the
    /// display rate, or <c>+=</c> or <c>-=</c> one, as one undo entry, and selects them where they went. An offset moves
    /// them together, as a drag does, so at a section's edge they all stop and keep their spacing. Returns a problem, or
    /// null. An entry that does not read, or a time that would put two keys of one curve at one time, changes nothing.
    /// </summary>
    public string? SetCurveKeyTime(string text)
    {
        var keys = CurveKeys;
        if (Document.InTransaction || keys.Count == 0)
        {
            return null;
        }
        if (CurveEntry.ParseTime(text, File.Rate) is not { } entry)
        {
            return "a time is timecode or frames, or += or -= one";
        }
        string? problem = null;
        IReadOnlyList<string>? paths = null;
        if (entry.Op == CurveEntryOp.Set)
        {
            Own(() => Document.Edit("Set Key Time", f => paths = CutsceneCurveEdits.SetTimes(f, keys, t => entry.Apply(t), out problem, _locked)));
        }
        else
        {
            var delta = (int)Math.Clamp(entry.Op == CurveEntryOp.Add ? entry.Operand : -entry.Operand, int.MinValue, int.MaxValue);
            Own(() => Document.Edit("Set Key Time", f => paths = CutsceneEdits.Move(f, keys, delta, _locked)));
        }
        if (paths != null)
        {
            Select(paths, SelectMode.Replace);
        }
        return problem;
    }

    /// <summary>
    /// Sets the values of <see cref="CurveKeys"/> from a typed entry (see <see cref="CurveEntry"/>): a number, or <c>+=</c>
    /// or <c>-=</c> one, as one undo entry. A stepped curve's key takes a whole number. Returns a problem, or null. An
    /// entry that does not read changes nothing.
    /// </summary>
    public string? SetCurveKeyValue(string text)
    {
        var keys = CurveKeys;
        if (Document.InTransaction || keys.Count == 0)
        {
            return null;
        }
        if (CurveEntry.ParseValue(text) is not { } entry)
        {
            return "a value is a number, or += or -= one";
        }
        Own(() => Document.Edit("Set Key Value", f => CutsceneCurveEdits.SetValues(f, keys, entry.Apply, Stepped, _locked)));
        return null;
    }

    /// <summary>
    /// Weights the selected keys that a tangent command changes and that have handles, or when every one of them is
    /// weighted already, takes their weights away, as one undo entry: Weighted Tangents.
    /// </summary>
    public void ToggleWeighted()
    {
        var keys = WeighableKeys;
        if (Document.InTransaction || keys.Count == 0)
        {
            return;
        }
        var weighted = !keys.All(p => File.Find(p) is { } b && CurveKey.Parse(b) is { Weighted: true });
        Own(() => Document.Edit("Weighted Tangents", f => CutsceneCurveEdits.SetWeighted(f, keys, weighted, _locked)));
    }

    /// <summary>The selected keys that Weighted Tangents changes: of <see cref="TangentKeys"/>, the Bezier and automatic ones.</summary>
    public IReadOnlyList<string> WeighableKeys => [.. TangentKeys.Where(p => File.Find(p) is { } b && CurveKey.Parse(b) is { } k && CutsceneCurveEdits.Weighable(k))];

    /// <summary>
    /// The channels whose infinity the Pre-Infinity and Post-Infinity commands and boxes set: the channels of the selected
    /// keys, or with no key selected, every curve that the curve editor shows and does not hide. Each is one that the
    /// runtime reads, on a track that is not locked.
    /// </summary>
    public IReadOnlyList<string> InfinityCurves
    {
        get
        {
            var ofKeys = _selection.Select(File.Find).Where(b => b?.Kind == CutsceneBlockKind.Key).Select(b => CutsceneFile.PathOf(b!.Parent!)).Distinct().ToList();
            var channels = ofKeys.Count > 0 ? ofKeys : _shownCurves.Where(p => !_hiddenCurves.Contains(p));
            return [.. channels.Where(p => File.Find(p) is { Kind: CutsceneBlockKind.Channel } c && !CutsceneEdits.IsLocked(c, _locked)
                && CutsceneCurveEdits.KeysOf(c) != null)];
        }
    }

    /// <summary>The infinity on a side that every one of <see cref="InfinityCurves"/> has, or null when they differ or there are none.</summary>
    public CurveInfinity? Infinity(InfinitySide side)
    {
        var modes = InfinityCurves.Select(p => File.Find(p)!).Select(c => side == InfinitySide.Pre ? CutsceneCurveEdits.InfinityOf(c).Pre : CutsceneCurveEdits.InfinityOf(c).Post).Distinct().ToList();
        return modes.Count == 1 ? modes[0] : null;
    }

    /// <summary>
    /// Sets one side's infinity on <see cref="InfinityCurves"/>, as one undo entry. A curve that does not take the mode,
    /// such as an audio track's pitch for any but constant, keeps its own. Nothing when no curve changes.
    /// </summary>
    public void SetInfinity(InfinitySide side, CurveInfinity mode)
    {
        var curves = InfinityCurves;
        if (Document.InTransaction || curves.Count == 0)
        {
            return;
        }
        var label = side == InfinitySide.Pre ? "Pre-Infinity" : "Post-Infinity";
        Own(() => Document.Edit(label, f => CutsceneCurveEdits.SetInfinity(f, curves, side, mode, _locked)));
    }

    /// <summary>Sets one side's infinity on <see cref="InfinityCurves"/> to the mode after the one they share, or after constant when they differ.</summary>
    public void NextInfinity(InfinitySide side)
    {
        var count = Enum.GetValues<CurveInfinity>().Length;
        SetInfinity(side, (CurveInfinity)(((int)(Infinity(side) ?? CurveInfinity.Constant) + 1) % count));
    }

    /// <summary>
    /// Adds a key to a channel's curve at a tick on the cutscene's time, with the curve's value there, as one undo entry,
    /// and selects it: a double-click on a curve.
    /// </summary>
    public void AddCurveKey(string channel, int tick)
    {
        if (Document.InTransaction || File.Find(channel) is not { Kind: CutsceneBlockKind.Channel } block
            || CutsceneEdits.SectionOf(block) is not { Start: { } start })
        {
            return;
        }
        var stepped = Stepped(block);
        string? path = null;
        Own(() => Document.Edit("Add Key", f => path = CutsceneCurveEdits.AddKey(f, channel, tick - start, stepped, _locked)));
        if (path != null)
        {
            Select([path], SelectMode.Replace);
        }
    }

    /// <summary>The ticks of a frame at the cutscene's display rate.</summary>
    public int FrameTicks => CutsceneFile.TicksPerSecond / File.Rate;

    /// <summary>Whether any selected block is one that a move, a nudge or a delete changes.</summary>
    public bool CanEditSelection => !Document.InTransaction && _selection.Any(p => File.Find(p) is { } b
        && CutsceneEdits.IsTimed(b) && !CutsceneEdits.IsLocked(b, _locked));

    /// <summary>Whether any selected block is one that a copy takes.</summary>
    public bool CanCopy => _selection.Any(p => File.Find(p) is { } b && CutsceneEdits.IsTimed(b));

    /// <summary>Copies the selected sections, events, keys and markers to the shell's clipboard.</summary>
    public void Copy()
    {
        if (CutsceneEdits.Copy(File, _selection) is { } clip)
        {
            _shell.CutsceneClipboard = clip with { Source = Guid };
            _shell.Commands.InvalidateAll();
        }
    }

    /// <summary>Copies the selection, then deletes what of it is not locked, in one undo entry.</summary>
    public void Cut()
    {
        if (!CanEditSelection)
        {
            return;
        }
        Copy();
        var paths = _selection.ToList();
        Own(() => Document.Edit("Cut", f => CutsceneEdits.Delete(f, paths, ripple: false, _locked)));
        Replace([]);
        Changed?.Invoke();
        _shell.Commands.InvalidateAll();
    }

    /// <summary>
    /// Whether the clipboard holds something to paste here: a copy from this cutscene, since copied blocks name its
    /// bindings by ID.
    /// </summary>
    public bool CanPaste => !Document.InTransaction && _shell.CutsceneClipboard?.Source == Guid;

    /// <summary>
    /// The tracks that a paste needs and the cutscene lacks, by kind: the editor asks whether to add them before it
    /// pastes. The window answers with <see cref="Paste"/> and addTracks, or not at all for No.
    /// </summary>
    public event Action<IReadOnlyList<string>>? PasteTracksRequested;

    // What a paste goes onto: the selected binding or track, or the track of the selected section, event or key.
    CutsceneBlock? PasteTarget => Selected is { Kind: CutsceneBlockKind.Binding or CutsceneBlockKind.Track } b ? b
        : Selected is { } s ? CutsceneEdits.TrackOf(s) : null;

    /// <summary>
    /// Pastes the clipboard at the playhead (see docs/editor/cutscene-editor.md#copy-and-paste), in one undo entry, and
    /// selects what it pasted. When a track it needs is missing, it asks first through <see cref="PasteTracksRequested"/>
    /// and pastes nothing, unless addTracks says to add them.
    /// </summary>
    public void Paste(bool addTracks = false)
    {
        if (!CanPaste || _shell.CutsceneClipboard is not { } clip)
        {
            return;
        }
        var target = PasteTarget;
        if (!addTracks && CutsceneEdits.MissingTracks(File, clip, target) is { Count: > 0 } missing)
        {
            PasteTracksRequested?.Invoke(missing);
            return;
        }
        var targetPath = target != null ? CutsceneFile.PathOf(target) : null;
        IReadOnlyList<string> pasted = [];
        Own(() => Document.Edit("Paste", f => pasted = CutsceneEdits.Paste(f, clip, _playhead, targetPath != null ? f.Find(targetPath) : null, addTracks, _locked)));
        Select(pasted, SelectMode.Replace);
    }

    /// <summary>Whether a duplicate has something to copy.</summary>
    public bool CanDuplicate => !Document.InTransaction && CanCopy;

    /// <summary>
    /// Copies the selection onto its own tracks right after itself, offset by its span, or a frame for a single point,
    /// in one undo entry, and selects the copies. The clipboard does not change.
    /// </summary>
    public void Duplicate()
    {
        if (!CanDuplicate || CutsceneEdits.Copy(File, _selection) is not { } clip)
        {
            return;
        }
        var at = clip.Anchor + Math.Max(clip.Span, FrameTicks);
        IReadOnlyList<string> copies = [];
        Own(() => Document.Edit("Duplicate", f => copies = CutsceneEdits.Paste(f, clip, at, null, addTracks: false, _locked)));
        Select(copies, SelectMode.Replace);
    }

    /// <summary>
    /// Makes keys from the inspector or the viewport as one undo entry (see docs/editor/cutscene-editor.md#keying), which
    /// Undo then follows while no other editor's tab is active. Nothing during a drag. A key goes in among the keys of its
    /// channel, so a selected key whose line moves is let go, as after any edit that is not the timeline's.
    /// </summary>
    public void Key(string label, Action<CutsceneFile> edit)
    {
        if (Document.InTransaction)
        {
            return;
        }
        var before = Document.Text;
        Document.Edit(label, edit);
        if (Document.Text != before)
        {
            _shell.Edited(new UndoTarget.Cutscene(this));
        }
    }

    /// <summary>The timeline should scroll a row, by its binding's or its track's path, into view.</summary>
    public event Action<string>? RevealRequested;

    /// <summary>
    /// Selects a track and shows it on the timeline: its binding unfolds, and a filter that hides it clears.
    /// </summary>
    public void Reveal(CutsceneBlock track)
    {
        var path = CutsceneFile.PathOf(track);
        if (CutsceneEdits.BindingOf(track) is { } binding && File.Bindings.FirstOrDefault(b => b.Id == binding) is { } owner)
        {
            _folds.Remove(CutsceneFile.PathOf(owner));
        }
        if (!RowFilter.IsNone && Layout().Rows.All(r => r.Path != path))
        {
            FilterText = "";
            _keysUnder = null;
            FilterChanged();
        }
        Select(track);
        RevealRequested?.Invoke(path);
    }

    /// <summary>Adds a marker at the playhead, or with one there, keeps it, and selects it.</summary>
    public void AddMarker()
    {
        if (Document.InTransaction)
        {
            return;
        }
        var path = "";
        if (File.Markers.FirstOrDefault(m => m.Start == _playhead) is { } there)
        {
            path = CutsceneFile.PathOf(there);
        }
        else
        {
            Own(() => Document.Edit("Add Marker", f => path = CutsceneEdits.AddMarker(f, _playhead)));
        }
        Select([path], SelectMode.Replace);
    }

    /// <summary>
    /// Starts a drag on the timeline: one undo entry from here to <see cref="EndDrag"/>. False when a drag is under way.
    /// </summary>
    public bool BeginDrag(string label)
    {
        if (Document.InTransaction)
        {
            return false;
        }
        _dragSelection = [.. _selection];
        Document.Begin(label);
        return true;
    }

    /// <summary>
    /// Starts a drag from outside the timeline, such as auto-key's from the inspector or a gizmo, as
    /// <see cref="BeginDrag"/> does, and gives its holder a token. Null when a drag is under way. However the drag ends,
    /// by the token or by another, as with Esc in the timeline, the token's <see cref="CutsceneDrag.Ended"/> says so
    /// once, and then the token does nothing.
    /// </summary>
    public CutsceneDrag? BeginHeldDrag(string label)
    {
        if (!BeginDrag(label))
        {
            return null;
        }
        _held = new CutsceneDrag(this);
        return _held;
    }

    // The token of the drag that BeginHeldDrag started, while it is open.
    CutsceneDrag? _held;

    internal bool Holds(CutsceneDrag drag) => _held == drag && Document.InTransaction;

    // The selection when a drag began, which a cancel puts back, as the paths of moved keys change during it.
    List<string>? _dragSelection;

    /// <summary>
    /// A step of the drag, from the cutscene as it was when the drag began: the edit returns the paths of what it moved,
    /// which become the selection, since a key that passes another changes its path.
    /// </summary>
    public void StepDrag(Func<CutsceneFile, IReadOnlyList<string>> edit)
    {
        if (!Document.InTransaction)
        {
            return;
        }
        IReadOnlyList<string> moved = [];
        Own(() => Document.StepFromStart(f => moved = edit(f)));
        SetSelection(moved);
    }

    // The selection after an edit that returned the paths of what it moved.
    void SetSelection(IReadOnlyList<string> moved)
    {
        if (moved.Count > 0 && !moved.SequenceEqual(_selection))
        {
            Replace(moved);
            Changed?.Invoke();
        }
    }

    // The selection becomes paths, with each key's line, which tells a selected key from another that takes its path.
    void Replace(IEnumerable<string> paths)
    {
        _selection.Clear();
        _selection.AddRange(paths);
        _keyLines.Clear();
        foreach (var path in _selection)
        {
            if (File.Find(path) is { Kind: CutsceneBlockKind.Key } key)
            {
                _keyLines[path] = KeyLine(key);
            }
        }
        FollowShownCurves();
    }

    readonly Dictionary<string, string> _keyLines = [];

    static string KeyLine(CutsceneBlock key) => key.LineTexts.LastOrDefault() ?? "";

    /// <summary>
    /// Ends the drag: commits its one entry, or with cancel, as with Esc, puts the text back, and the selection as it was
    /// when the drag began.
    /// </summary>
    public void EndDrag(bool cancel)
    {
        var before = _dragSelection;
        _dragSelection = null;
        EndField(cancel);
        if (cancel && before != null && !before.SequenceEqual(_selection))
        {
            Replace(before.Where(p => File.Find(p) != null));
            Changed?.Invoke();
        }
    }

    /// <summary>
    /// Moves the selection by frames, as one undo entry while the key is held: <see cref="EndNudge"/> ends it, on the
    /// key's release or the timeline's loss of the keyboard.
    /// </summary>
    public void Nudge(int frames)
    {
        if (!CanEditSelection)
        {
            return;
        }
        var paths = _selection.ToList();
        IReadOnlyList<string> moved = [];
        Own(() => Document.EditMerged("Nudge", "nudge", f => moved = CutsceneEdits.Move(f, paths, frames * FrameTicks, _locked)));
        SetSelection(moved);
    }

    public void EndNudge() => Document.EndMerge();

    /// <summary>
    /// Where a sub-sequence's child starts to play, the start of its range, read from the child's file by GUID: what a
    /// section without a trim plays from, which a split, a trim and a slip move. 0 when the child cannot be read.
    /// </summary>
    public int ChildStart(string guid)
    {
        if (_shell.Assets.Find(guid) is not { } asset || _shell.Assets.FullPath(asset) is not { } path)
        {
            return 0;
        }
        try
        {
            return CutsceneFile.Parse(System.IO.File.ReadAllText(path)).File is { } child ? CutsceneEdits.RangeOf(child).Start : 0;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return 0;
        }
    }

    /// <summary>Whether a split at the playhead has a selected section to split.</summary>
    public bool CanSplit => !Document.InTransaction && _selection.Any(p => File.Find(p) is { Kind: CutsceneBlockKind.Section, Start: { } s, End: { } e } b
        && s < _playhead && _playhead < e && !CutsceneEdits.IsLocked(b, _locked));

    /// <summary>Splits the selected sections at the playhead, and selects both halves of each.</summary>
    public void Split()
    {
        if (!CanSplit)
        {
            return;
        }
        var paths = _selection.ToList();
        IReadOnlyList<string> halves = [];
        Own(() => Document.Edit("Split", f => halves = CutsceneEdits.Split(f, paths, _playhead, _locked, ChildStart)));
        Select(halves, SelectMode.Replace);
    }

    /// <summary>Deletes the selected sections, events and keys, and with ripple, closes each section's gap on its track.</summary>
    public void DeleteSelected(bool ripple)
    {
        if (!CanEditSelection)
        {
            return;
        }
        var paths = _selection.ToList();
        Own(() => Document.Edit(ripple ? "Ripple Delete" : "Delete", f => CutsceneEdits.Delete(f, paths, ripple, _locked)));
        // What was deleted is gone, and another key can have a deleted key's path, so nothing stays selected.
        if (_selection.Count > 0)
        {
            Replace([]);
            Changed?.Invoke();
            _shell.Commands.InvalidateAll();
        }
    }

    // An edit that this editor makes, during which the selection keeps every path that still names a block, and after
    // which each selected key's line is its new one.
    void Own(Action edit)
    {
        _ownEdit = true;
        try
        {
            edit();
        }
        finally
        {
            _ownEdit = false;
        }
        Replace([.. _selection]);
    }

    bool _ownEdit;

    /// <summary>Sends the unsaved text to the cook daemon now, and shows the answer's problems.</summary>
    public Task CookNow() => _cook.CookNow();

    /// <summary>Shows the answer to a check of a text, unless the cutscene has changed since it was sent.</summary>
    public void ShowProblems(string text, PreviewResult result)
    {
        if (text != CookText)
        {
            return;
        }
        _problems.Clear();
        foreach (var p in result.Problems)
        {
            var mine = string.Equals(Path.GetFullPath(p.File == "" ? "." : p.File), Document.Path, StringComparison.OrdinalIgnoreCase);
            var where = mine || p.File == "" ? "" : $"{Path.GetFileName(p.File)}:{p.Line}: ";
            _problems.Add(new GraphProblem(null, where + p.Text, p.Error, mine ? (int)p.Line : 0));
        }
        CookError = result.Error == "" ? null : result.Error;
        if (CookError == null)
        {
            // The daemon wrote this text's blob before it answered, so its file time names this text in the game.
            _cleanBlob = _shell.PreviewBlobTime(Guid) is var time and not 0 ? (text, time) : null;
            _shell.Keying.Raise();
        }
        ProblemsChanged?.Invoke();
        if (CookError == null && !CookedClean)
        {
            CookedClean = true;
            _shell.CutscenePreview.OnCooked(this);
        }
    }

    // The text of the last clean cook, and its blob's file time in the preview area.
    (string Text, long Blob)? _cleanBlob;

    /// <summary>
    /// The file time of the blob in the preview area that the daemon cooked from the tab's text as it is now, or null
    /// when the text has changed since its last clean cook. The preview shows the text when it plays that blob.
    /// </summary>
    public long? CleanBlob => _cleanBlob is { } clean && clean.Text == CookText ? clean.Blob : null;

    /// <summary>Whether the daemon cooked this tab's text clean, so its unsaved text is in the preview area.</summary>
    public bool CookedClean { get; private set; }

    /// <summary>The last check's error, or null when the text cooked.</summary>
    public string? CookError { get; private set; }

    public void Dispose()
    {
        _cook.Dispose();
        Document.Changed -= OnDocumentChanged;
        _shell.SceneChanged -= OnBindingTargetsChanged;
        _shell.Assets.Changed -= OnBindingTargetsChanged;
        _shell.Selection.Changed -= OnEntitiesSelected;
    }

    // Bindings (see docs/editor/cutscene-editor.md#bindings).

    void OnBindingTargetsChanged() => Changed?.Invoke();

    /// <summary>
    /// What a binding binds, and whether it is there, from the open scenes' documents and the asset index, not the game:
    /// a possessed entity of a scene that is not open is not loaded, and one of an open scene that lacks it, or of no
    /// scene that the index knows, is broken. A spawned binding is broken when its prefab is missing.
    /// </summary>
    public CutsceneBindingInfo InfoOf(CutsceneBlock binding) => BoundInfoOf(binding) with { Camera = IsCamera(binding) };

    CutsceneBindingInfo BoundInfoOf(CutsceneBlock binding)
    {
        var possess = binding.Get("possess");
        var spawn = binding.Get("spawn");
        var provided = binding.Get("provided");
        var kinds = (possess != null ? 1 : 0) + (spawn != null ? 1 : 0) + (provided != null ? 1 : 0);
        if (kinds != 1)
        {
            return new(CutsceneBindingKind.Unknown, null, CutsceneBindingState.Broken,
                kinds == 0 ? "It has none of possess, spawn and provided." : "It has more than one of possess, spawn and provided.");
        }
        if (provided != null)
        {
            if (provided.Trim() != "true")
            {
                return new(CutsceneBindingKind.Provided, null, CutsceneBindingState.Broken, $"Its provided, {provided.Trim()}, is not true.");
            }
            // A slot shows its stand-in, which only the preview uses: with none, its tracks do nothing there.
            if (binding.Id is not { } id || StandInOf(id) is not { } standIn)
            {
                return new(CutsceneBindingKind.Provided, null, CutsceneBindingState.Bound);
            }
            var target = CutsceneStandIns.IsPrefab(standIn) ? SpawnInfo(standIn) : PossessInfo(standIn);
            return target with { Kind = CutsceneBindingKind.Provided, Reason = target.Reason is { } why ? $"Its stand-in: {why}" : null };
        }
        return spawn != null ? SpawnInfo(spawn) : PossessInfo(possess!);
    }

    CutsceneBindingInfo SpawnInfo(string spawn)
    {
        if (spawn.Trim() is ['$', .. var guid] && guid.Length > 0 && _shell.Assets.Find(guid) is { Kind: AssetKind.Prefab } prefab)
        {
            return new(CutsceneBindingKind.Spawned, PrefabName(prefab), CutsceneBindingState.Bound);
        }
        // Before the cook daemon's first snapshot the index knows no asset, so a prefab is not known to be missing.
        return AssetsKnown
            ? new(CutsceneBindingKind.Spawned, null, CutsceneBindingState.Broken, $"Its prefab, {spawn.Trim()}, is missing.")
            : new(CutsceneBindingKind.Spawned, null, CutsceneBindingState.Bound);
    }

    CutsceneBindingInfo PossessInfo(string possess)
    {
        if (PossessRef.Parse(possess) is not { } entity)
        {
            return new(CutsceneBindingKind.Possessed, null, CutsceneBindingState.Broken, $"Its possess, {possess.Trim()}, is not a scene link.");
        }
        if (_shell.SceneOfGuid(entity.SceneGuid) is { } scene)
        {
            return scene.Expanded.Flat.Find(entity.Id) is { } found
                ? new(CutsceneBindingKind.Possessed, found.Name, CutsceneBindingState.Bound)
                : new(CutsceneBindingKind.Possessed, null, CutsceneBindingState.Broken, $"{System.IO.Path.GetFileName(scene.Path)} has no entity {entity.Id:x16}.");
        }
        if (_shell.Assets.Find(entity.SceneGuid) is { Kind: AssetKind.Scene } asset)
        {
            return new(CutsceneBindingKind.Possessed, null, CutsceneBindingState.NotLoaded, $"{System.IO.Path.GetFileName(asset.Path)} is not open.");
        }
        return AssetsKnown
            ? new(CutsceneBindingKind.Possessed, null, CutsceneBindingState.Broken, $"No scene has the GUID {entity.SceneGuid}.")
            : new(CutsceneBindingKind.Possessed, null, CutsceneBindingState.NotLoaded, "Its scene is not open.");
    }

    bool AssetsKnown => _shell.Assets.Linked || _shell.Assets.Assets.Count > 0;

    // A binding's name for a prefab: its file's name without the extension, or a subasset's name.
    static string PrefabName(Link.Cook.Asset asset) => AssetIndex.IsSubasset(asset) ? asset.Subasset : System.IO.Path.GetFileNameWithoutExtension(AssetIndex.Name(asset.Path));

    /// <summary>
    /// The entity in the game's world that a binding possesses, or a slot's stand-in, by handle, or null: for a spawned
    /// binding, a slot with a prefab or no stand-in, and one whose scene is not open or lacks it.
    /// </summary>
    public ulong? HandleOf(int binding)
    {
        if (File.Bindings.FirstOrDefault(b => b.Id == binding) is not { } block || PossessedBy(block) is not { } entity
            || _shell.SceneOfGuid(entity.SceneGuid) is not { } scene || _shell.World.FindScene(scene.Number, entity.Id) is not { } node)
        {
            return null;
        }
        return node.Handle;
    }

    // The IDs of the bindings that possess any of the entities.
    HashSet<int> BindingsOfEntities(IEnumerable<ulong> handles) =>
        [.. handles.Select(_shell.Keying.PossessOf).OfType<PossessRef>().Select(BindingOfEntity).OfType<int>()];

    // The entities that a possess would add a binding for: each one that a scene names and that no binding possesses
    // yet, once, with its name.
    List<(PossessRef Entity, string Name)> Possessable(IEnumerable<ulong> handles)
    {
        var found = new List<(PossessRef Entity, string Name)>();
        foreach (var handle in handles)
        {
            if (_shell.Keying.PossessOf(handle) is { } entity && BindingOfEntity(entity) == null && found.All(f => f.Entity != entity))
            {
                found.Add((entity, _shell.World.Find(handle)?.Name is { Length: > 0 } name ? name : $"Entity {entity.Id:x16}"));
            }
        }
        return found;
    }

    /// <summary>Why the selected entities cannot be possessed, or null when a binding can be added for one of them.</summary>
    public string? PossessRefusal() => PossessRefusal(_shell.Selection.Entities);

    string? PossessRefusal(IReadOnlyCollection<ulong> handles)
    {
        if (Document.InTransaction)
        {
            return "A drag is under way in the cutscene.";
        }
        if (handles.Count == 0)
        {
            return "No entity is selected.";
        }
        return Possessable(handles).Count > 0 ? null : "Each entity is bound already, or is not one that a scene names.";
    }

    /// <summary>
    /// Adds a binding that possesses each entity that no binding possesses yet, as one undo entry, and selects their
    /// rows. Entities that the game spawned, and those of a scene with no GUID yet, are left out.
    /// </summary>
    public void Possess(IEnumerable<ulong> handles)
    {
        var list = handles.ToList();
        if (PossessRefusal(list) != null)
        {
            return;
        }
        var entities = Possessable(list);
        List<int> ids = [];
        Key(entities.Count == 1 ? "Add Binding" : "Add Bindings", f => ids = [.. entities.Select(e => CutsceneKeying.AddBinding(f, e.Entity, e.Name))]);
        SelectBindings(ids);
    }

    /// <summary>
    /// An entity dropped on the timeline, as from the Outliner: it possesses the entity, or the whole selection when the
    /// entity is in it. With rebind, on a binding's row, it points that binding at the entity instead.
    /// </summary>
    public void DropEntity(ulong handle, string? bindingRow, bool rebind)
    {
        // A rebind names its binding by the row it was dropped on, and leaves both selections as they are.
        if (rebind && bindingRow != null)
        {
            Rebind(File.Find(bindingRow) is { Kind: CutsceneBlockKind.Binding } b ? b.Id : null, handle);
            return;
        }
        Possess(_shell.Selection.Contains(handle) ? _shell.Selection.Entities : [handle]);
    }

    /// <summary>The prefabs that assets dropped from the content browser place, by GUID: a prefab, or a file that makes one.</summary>
    public List<string> PrefabsOf(IEnumerable<string> assets) => [.. assets.Select(_shell.PrefabToPlace).OfType<string>().Distinct()];

    /// <summary>Adds a binding that spawns each prefab, by GUID, as one undo entry, and selects their rows.</summary>
    public void Spawn(IEnumerable<string> prefabs)
    {
        var named = prefabs.Distinct().Select(g => (Guid: g, Name: _shell.Assets.Find(g) is { } a ? PrefabName(a) : "Prefab")).ToList();
        if (named.Count == 0 || Document.InTransaction)
        {
            return;
        }
        List<int> ids = [];
        Key(named.Count == 1 ? "Add Binding" : "Add Bindings", f => ids = [.. named.Select(p => CutsceneBindings.AddSpawn(f, p.Guid, p.Name))]);
        SelectBindings(ids);
    }

    void SelectBindings(IEnumerable<int> ids)
    {
        var paths = ids.Select(id => File.Bindings.FirstOrDefault(b => b.Id == id)).OfType<CutsceneBlock>().Select(CutsceneFile.PathOf).ToList();
        if (paths.Count > 0)
        {
            Select(paths, SelectMode.Replace);
            RevealRequested?.Invoke(paths[^1]);
        }
    }

    /// <summary>The selected binding's block, when the primary selection is a binding's row, or null.</summary>
    public CutsceneBlock? SelectedBinding => Selected is { Kind: CutsceneBlockKind.Binding, Id: not null } b ? b : null;

    /// <summary>Why the selected binding cannot be pointed at an entity, or null when it can.</summary>
    public string? RebindRefusal(ulong handle) => RebindRefusal(SelectedBinding?.Id, handle);

    string? RebindRefusal(int? id, ulong handle)
    {
        if (Document.InTransaction)
        {
            return "A drag is under way in the cutscene.";
        }
        if (File.Bindings.FirstOrDefault(b => id != null && b.Id == id) is not { } binding)
        {
            return "No binding is selected.";
        }
        if (binding.Get("possess") == null)
        {
            return CutsceneBindings.IsProvided(binding)
                ? "A script gives the binding's entity. Set its stand-in, or convert it to a possessed binding."
                : "The binding spawns a prefab. Convert it to a possessed binding to point it at an entity.";
        }
        if (handle == 0)
        {
            return "No entity is selected.";
        }
        if (_shell.Keying.PossessOf(handle) is not { } entity)
        {
            return "The entity is not one that a scene names: the game spawned it, or its scene has no GUID yet.";
        }
        return BindingOfEntity(entity) is { } other
            ? other == binding.Id ? "The binding possesses that entity already." : "Another binding possesses that entity."
            : null;
    }

    /// <summary>Points the selected binding at an entity, keeping its tracks, as one undo entry.</summary>
    public void Rebind(ulong handle) => Rebind(SelectedBinding?.Id, handle);

    void Rebind(int? binding, ulong handle)
    {
        if (RebindRefusal(binding, handle) != null || binding is not { } id || _shell.Keying.PossessOf(handle) is not { } entity)
        {
            return;
        }
        Key("Rebind", f => CutsceneBindings.Rebind(f, id, entity));
    }

    /// <summary>
    /// Why the selected binding cannot be deleted, or null when it can, or when no binding's row is selected: blocks
    /// that name it by ID would be left naming nothing.
    /// </summary>
    public string? DeleteBindingRefusal()
    {
        if (SelectedBinding?.Id is not { } id)
        {
            return null;
        }
        if (Document.InTransaction)
        {
            return "A drag is under way in the cutscene.";
        }
        if (CutsceneBindings.TracksOf(File, id).Any(t => CutsceneEdits.IsLocked(t, _locked)))
        {
            return "A track of the binding is locked.";
        }
        var references = CutsceneBindings.ReferencesTo(File, id);
        if (references.Count == 0)
        {
            return null;
        }
        var names = references.Take(3).Select(b => b.Name ?? $"{b.Kind.ToString().ToLowerInvariant()} {b.Id}");
        return $"Other blocks name it: {string.Join(", ", names)}{(references.Count > 3 ? $" and {references.Count - 3} more" : "")}.";
    }

    /// <summary>Whether the primary selection is a binding's row that a delete removes.</summary>
    /// <remarks>A row that the filter hides is not deleted, so Delete never acts on what is not in view.</remarks>
    public bool CanDeleteBinding => SelectedBinding != null && DeleteBindingRefusal() == null && Layout().Rows.Any(r => r.Path == Selection);

    /// <summary>
    /// Deletes the selected binding and its tracks as one undo entry. A binding with tracks asks first, and one that
    /// other blocks name is not deleted.
    /// </summary>
    public async Task DeleteBinding()
    {
        if (!CanDeleteBinding || SelectedBinding is not { Id: { } id } binding)
        {
            return;
        }
        var text = Document.Text;
        var tracks = CutsceneBindings.TracksOf(File, id).Count;
        if (tracks > 0 && _shell.AskDeleteBinding is { } ask && !await ask(binding.Name ?? $"binding {id}", System.IO.Path.GetFileName(Document.Path), tracks))
        {
            return;
        }
        // The text can change while the question is open.
        if (Document.Text != text || Document.InTransaction)
        {
            return;
        }
        Own(() => Document.Edit("Delete Binding", f => CutsceneBindings.Remove(f, id)));
        Replace([]);
        Changed?.Invoke();
        _shell.Commands.InvalidateAll();
    }

    /// <summary>
    /// Whether the timeline shows only the bindings of the entities selected in the viewport or the Outliner, and their
    /// tracks.
    /// </summary>
    public bool SelectedOnly { get; private set; }

    public void SetSelectedOnly(bool on)
    {
        if (on != SelectedOnly)
        {
            SelectedOnly = on;
            FilterChanged();
        }
    }

    // While one side of the selection sync writes the other, the other does not write back.
    bool _syncing;

    // The bindings of the entities selected last. A resync gives the same entities new handles, so what is new is told
    // by binding, not by handle: the same bindings again select no row.
    HashSet<int> _entityBindings = [];

    // The timeline's selection of binding rows selects their entities: only when one of them is in the world, so a
    // click on a broken row keeps the entity that a rebind would use.
    void SelectBoundEntities()
    {
        if (_syncing)
        {
            return;
        }
        var handles = _selection.Select(File.Find).OfType<CutsceneBlock>()
            .Where(b => b.Kind == CutsceneBlockKind.Binding && b.Id != null)
            .Select(b => HandleOf(b.Id!.Value)).OfType<ulong>().ToList();
        if (handles.Count == 0)
        {
            return;
        }
        _syncing = true;
        try
        {
            _shell.Selection.Set(handles);
        }
        finally
        {
            _syncing = false;
        }
    }

    // An entity selected in the viewport or the Outliner selects its binding's row. Selecting an entity that no binding
    // possesses, or none, keeps the timeline's selection, so keys stay selected while the designer picks an entity.
    void OnEntitiesSelected(IReadOnlyList<ulong> old, IReadOnlyList<ulong> next)
    {
        if (SelectedOnly)
        {
            FilterChanged();
        }
        // An armed pick takes the entity, and the rebind it makes keeps the binding's row selected.
        if (!_syncing && TakePick(next))
        {
            _entityBindings = BindingsOfEntities(next);
            return;
        }
        // What a binding's convert and stand-in would take is the selected entity, which its details show.
        if (SelectedBinding != null)
        {
            Changed?.Invoke();
        }
        var now = BindingsOfEntities(next);
        var ids = now.Except(_entityBindings).ToHashSet();
        _entityBindings = now;
        if (_syncing || ids.Count == 0)
        {
            return;
        }
        var paths = File.Bindings.Where(b => b.Id is { } id && ids.Contains(id)).Select(CutsceneFile.PathOf).ToList();
        _syncing = true;
        try
        {
            Select(paths, SelectMode.Replace);
        }
        finally
        {
            _syncing = false;
        }
        RevealRequested?.Invoke(paths[0]);
    }
}

/// <summary>
/// The hold on a cutscene's drag that <see cref="CutsceneEditor.BeginHeldDrag"/> gives. Its steps and its end act only
/// while it is the cutscene's open drag.
/// </summary>
public sealed class CutsceneDrag
{
    readonly CutsceneEditor _editor;

    internal CutsceneDrag(CutsceneEditor editor) => _editor = editor;

    public CutsceneEditor Editor => _editor;

    /// <summary>Whether it is still the cutscene's open drag.</summary>
    public bool IsOpen => _editor.Holds(this);

    /// <summary>The drag ended, committed or not, by its holder or by another. It is raised once.</summary>
    public event Action<bool>? Ended;

    /// <summary>A step from the drag's start. Nothing once the drag has ended.</summary>
    public void Step(Func<CutsceneFile, IReadOnlyList<string>> edit)
    {
        if (IsOpen)
        {
            _editor.StepDrag(edit);
        }
    }

    /// <summary>Ends the drag: commits it, or with cancel, puts it back. Nothing once it has ended.</summary>
    public void End(bool cancel)
    {
        if (IsOpen)
        {
            _editor.EndDrag(cancel);
        }
    }

    internal void RaiseEnded(bool committed) => Ended?.Invoke(committed);
}
