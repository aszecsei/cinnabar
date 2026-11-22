using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// An open cutscene in its editor (see docs/editor/cutscene-editor.md#the-tab): its document, the block that is
/// selected, and the problems of the last check of its text on their blocks. The view turns input into calls here, so
/// tests can drive the editor without a window. Blocks are named by path, since an undo reads the file again and
/// replaces its block objects.
/// </summary>
public sealed class CutsceneEditor : IGraphEditor
{
    readonly EditorShell _shell;
    readonly List<GraphProblem> _problems = [];
    readonly PreviewCook _cook;
    readonly List<string> _selection = [];
    readonly HashSet<string> _folds = [];
    readonly HashSet<int> _locked;
    int _playhead;
    bool _snap = true;
    bool _showFrames;
    bool _timelineFocused;

    internal CutsceneEditor(EditorShell shell, CutsceneDocument document)
    {
        _shell = shell;
        Document = document;
        _cook = new PreviewCook(() => _shell.PreviewCooker.Linked, () => Document.Text, text => _shell.PreviewCooker.CookPreview(Guid, text), ShowProblems);
        Document.Changed += OnDocumentChanged;
        var view = shell.CutsceneTimelineSettingsOf(Guid);
        _showFrames = view.ShowFrames;
        _locked = [.. view.Locked];
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
        Changed?.Invoke();
        _shell.Commands.InvalidateAll();
        if (!Document.InTransaction)
        {
            _cook.Schedule();
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
        var hits = paths.Distinct().Where(p => File.Find(p) != null).ToList();
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
        Changed?.Invoke();
        _shell.Commands.InvalidateAll();
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
    }

    /// <summary>The playhead in ticks: where a split, Home and End act. It is the editor's, not the document's, so it is in no undo entry.</summary>
    public int Playhead => _playhead;

    public event Action? PlayheadChanged;

    /// <summary>The timeline should fit the selection, or the whole cutscene, in its view: F.</summary>
    public event Action? FrameRequested;

    public void RequestFrame() => FrameRequested?.Invoke();

    /// <summary>Moves the playhead, inside the length.</summary>
    public void SetPlayhead(int ticks)
    {
        var at = Math.Clamp(ticks, 0, File.Length ?? 0);
        if (at == _playhead)
        {
            return;
        }
        _playhead = at;
        PlayheadChanged?.Invoke();
        _shell.Commands.InvalidateAll();
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

    void SaveView() => _shell.SaveCutsceneTimelineSettings(Guid, new CutsceneTimelineView(_showFrames, [.. _locked.Order()]));

    /// <summary>The track of the primary selection: the selected track, or the track of a selected section, event or key.</summary>
    public CutsceneBlock? SelectedTrack => Selected is { } block ? CutsceneEdits.TrackOf(block) : null;

    /// <summary>
    /// Whether the timeline has the keyboard: its commands act only then, as their keys are bare letters that the
    /// viewport and the other panels use too. The view sets it.
    /// </summary>
    public bool TimelineFocused
    {
        get => _timelineFocused;
        set
        {
            if (_timelineFocused != value)
            {
                _timelineFocused = value;
                if (!value)
                {
                    EndNudge();
                }
                _shell.Commands.InvalidateAll();
            }
        }
    }

    /// <summary>The ticks of a frame at the cutscene's display rate.</summary>
    public int FrameTicks => CutsceneFile.TicksPerSecond / File.Rate;

    /// <summary>Whether any selected block is one that a move, a nudge or a delete changes.</summary>
    public bool CanEditSelection => !Document.InTransaction && _selection.Any(p => File.Find(p) is
        { Kind: CutsceneBlockKind.Section or CutsceneBlockKind.Trigger or CutsceneBlockKind.Range or CutsceneBlockKind.Key } b
        && !CutsceneEdits.IsLocked(b, _locked));

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
        if (text != Document.Text)
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
        ProblemsChanged?.Invoke();
    }

    /// <summary>The last check's error, or null when the text cooked.</summary>
    public string? CookError { get; private set; }

    public void Dispose()
    {
        _cook.Dispose();
        Document.Changed -= OnDocumentChanged;
    }
}
