using System.Collections.Immutable;
using Cinnabar.Editor.Content;
using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Shell;

/// <summary>A sub-sequence that a cutscene tab shows in context: the section that plays it, by path in its parent, and its GUID.</summary>
public sealed record CutsceneLevel(string SectionPath, string Guid);

/// <summary>
/// The way down from a tab's own cutscene to the level that it shows (see docs/editor/cutscene-editor.md#sub-sequences):
/// a sub-sequence section in the tab's cutscene, then one in that child, and so on. Empty shows the tab's own cutscene.
/// </summary>
public sealed record CutsceneLevels(ImmutableList<CutsceneLevel> Path)
{
    public static readonly CutsceneLevels Root = new(ImmutableList<CutsceneLevel>.Empty);

    public int Depth => Path.Count;

    public CutsceneLevels Down(CutsceneLevel level) => new(Path.Add(level));

    public CutsceneLevels Up(int depth) => new(Path.RemoveRange(depth, Path.Count - depth));
}

// Sub-sequences in context: the child's tracks in the tab, at the parent's time, while the preview plays the parent.
public sealed partial class CutsceneEditor
{
    // A child that the tab holds: the levels on the way down, and each one shown before with changes, until it saves.
    sealed class LevelHold(CutsceneDocuments.Lease lease, CookChecks<GraphProblem> checks) : IDisposable
    {
        public CutsceneDocuments.Lease Lease { get; } = lease;

        public CookChecks<GraphProblem> Checks { get; } = checks;

        public CutsceneDocument Document => Lease.Document;

        public void Dispose()
        {
            Checks.Dispose();
            Lease.Dispose();
        }
    }

    // What the tab showed of a level when it went to another, which it shows again when it comes back.
    sealed record LevelView(IReadOnlyList<string> Selection, IReadOnlyList<string> Folds, IReadOnlyList<string> HiddenCurves, IReadOnlyList<string> ShownCurves);

    CutsceneDocument _shown;
    CutsceneLevels _levels = CutsceneLevels.Root;
    readonly Dictionary<string, LevelHold> _levelHolds = new(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<string, LevelView> _levelViews = new(StringComparer.OrdinalIgnoreCase);
    bool _localTime;

    /// <summary>The way down to the level that the tab shows. Only <see cref="SetLevels"/> changes it.</summary>
    public CutsceneLevels Levels => _levels;

    /// <summary>
    /// Why a camera's look, pilot and values over the preview wait for the top level: the game plays the tab's own
    /// cutscene, whose binding IDs are not the sub-sequence's.
    /// </summary>
    public const string InContextCameraRefusal = "The preview plays the tab's own cutscene. Go up to it to look through, pilot or preview a binding's values.";

    /// <summary>Whether the tab shows a sub-sequence in context, not its own cutscene.</summary>
    public bool InContext => _levels.Depth > 0;

    /// <summary>The level that the tab shows changed.</summary>
    public event Action? LevelsChanged;

    /// <summary>The checks of the shown level's text: the tab's own, or the child's.</summary>
    internal CookChecks<GraphProblem> ShownChecks => InContext ? _levelHolds[ShownGuid].Checks : Checks;

    /// <summary>Whether the shown level's text as it is now has cooked clean, so the game can play it: always at the top level, whose wait is the tab's.</summary>
    public bool ShownCookedCurrent => !InContext || ShownChecks.State is CheckState.Clean { Text: var text } && text == ChildCookText(Document);

    // The stand-ins of the tab's own cutscene, which its preview text puts in.
    IReadOnlyDictionary<int, string> RootStandIns => InContext ? _shell.CutsceneTimelineSettingsOf(Guid).StandIns ?? [] : _standIns;

    // A child's preview text, with its slots' stand-ins: the shown level's, or those saved in its settings.
    string ChildCookText(CutsceneDocument document) =>
        CutsceneStandIns.PreviewText(document.Text, document == _shown ? _standIns : _shell.CutsceneTimelineSettingsOf(document.Guid).StandIns ?? []);

    /// <summary>
    /// Every document that the tab holds: its own, the levels on the way down, and the levels shown before with changes.
    /// Save writes each one with changes, and the tab's title marks them.
    /// </summary>
    public IEnumerable<IGraphDocument> Documents => [RootDocument, .. _levelHolds.Values.Select(h => h.Document).Where(d => d != RootDocument)];

    /// <summary>The shown level's document: Undo and Redo move its history alone.</summary>
    public IGraphDocument UndoDocument => Document;

    /// <summary>Whether closing the tab would lose changes that no other tab holds.</summary>
    public bool LosesChangesOnClose => (RootDocument.IsDirty && _rootLease.IsLast) || _levelHolds.Values.Any(h => h.Document.IsDirty && h.Lease.IsLast);

    /// <summary>Whether any document that the tab holds has changes.</summary>
    public bool IsDirty => Documents.Any(d => d.IsDirty);

    /// <summary>The GUIDs of the children that the tab holds whose unsaved text cooked clean, so the preview plays it.</summary>
    public IEnumerable<string> UnsavedChildren() => _levelHolds.Values.Where(h => h.Checks.CookedClean).Select(h => h.Document.Guid);

    /// <summary>
    /// The names of the levels, from the tab's own cutscene to the shown one, which the breadcrumb bar shows: each
    /// cutscene's file name.
    /// </summary>
    public IReadOnlyList<string> Breadcrumbs =>
    [
        System.IO.Path.GetFileNameWithoutExtension(RootDocument.Path),
        .. _levels.Path.Select(l => _levelHolds.TryGetValue(l.Guid, out var hold) ? System.IO.Path.GetFileNameWithoutExtension(hold.Document.Path) : l.Guid),
    ];

    /// <summary>Whether the ruler shows the shown level's own time in context, not the tab's. The tab's, and not saved.</summary>
    public bool LocalTime
    {
        get => _localTime;
        set
        {
            if (_localTime != value)
            {
                _localTime = value;
                Changed?.Invoke();
            }
        }
    }

    // The map of each level's section into its child, from the top down. A level whose section no longer reads maps
    // nothing, until the checks of the way down take it off.
    List<SubSequenceMap?> Maps()
    {
        var maps = new List<SubSequenceMap?>(_levels.Depth);
        var parent = RootFile;
        foreach (var level in _levels.Path)
        {
            var child = _levelHolds[level.Guid].Document.Graph;
            maps.Add(parent.Find(level.SectionPath) is { } section ? SubSequenceMap.Of(section, child) : null);
            parent = child;
        }
        return maps;
    }

    // A time of the tab's own cutscene on the shown level's time, with the loops of each level on the way down.
    (int Ticks, List<int> Loops) Down(int ticks, List<SubSequenceMap?> maps)
    {
        var loops = new List<int>(maps.Count);
        foreach (var map in maps)
        {
            var (child, wraps) = map?.ToChild(ticks) ?? (ticks, 0);
            ticks = child;
            loops.Add(wraps);
        }
        return (ticks, loops);
    }

    int ToShown(int ticks) => InContext ? Down(ticks, Maps()).Ticks : ticks;

    // A time of the shown level on the tab's own cutscene's time, on the passes of the loops that the playhead is on.
    int ToRoot(int ticks)
    {
        if (!InContext)
        {
            return ticks;
        }
        var maps = Maps();
        var loops = Down(_playhead, maps).Loops;
        for (var i = maps.Count - 1; i >= 0; i--)
        {
            ticks = maps[i]?.ToParent(ticks, loops[i]) ?? ticks;
        }
        return ticks;
    }

    /// <summary>
    /// The time that the ruler shows at a time of the shown level: in context, the tab's own cutscene's time, mapped up
    /// through each section's trim and scale on the playhead's passes of the loops, and on past the section's edges at
    /// the same rate; the shown level's own time with <see cref="LocalTime"/>.
    /// </summary>
    public int RulerTicks(int ticks)
    {
        if (!InContext || _localTime)
        {
            return ticks;
        }
        var maps = Maps();
        var loops = Down(_playhead, maps).Loops;
        double t = ticks;
        for (var i = maps.Count - 1; i >= 0; i--)
        {
            if (maps[i] is { } map)
            {
                var span = t - map.TrimStart + (map.Loop ? (double)loops[i] * (map.TrimEnd - map.TrimStart) : 0);
                t = map.Start + span / map.Scale;
            }
        }
        return (int)Math.Round(t);
    }

    /// <summary>The span of the shown level's time that its section plays, which the timeline leaves unshaded, or null at the top level.</summary>
    public (int Start, int End)? ContextSpan => InContext && Maps()[^1] is { } map ? map.Span : null;

    /// <summary>The selected sub-sequence section, by path, when the primary selection is one with a child.</summary>
    public string? SelectedSubSequence => Selected is { Kind: CutsceneBlockKind.Section } section
        && CutsceneEdits.TrackOf(section)?.TrackKind == "sub_sequence" && CutsceneSubSequences.GuidOf(section) != null
        ? CutsceneFile.PathOf(section)
        : null;

    /// <summary>Why a section cannot open in context, or null when it can.</summary>
    public string? OpenSubSequenceRefusal(string? sectionPath)
    {
        if (Documents.Any(d => d.InTransaction))
        {
            return "A drag is under way in the cutscene.";
        }
        if (sectionPath == null || File.Find(sectionPath) is not { Kind: CutsceneBlockKind.Section } section
            || CutsceneEdits.TrackOf(section)?.TrackKind != "sub_sequence" || CutsceneSubSequences.GuidOf(section) is not { } guid)
        {
            return "No sub-sequence section is selected.";
        }
        if (string.Equals(guid, Guid, StringComparison.OrdinalIgnoreCase) || _levels.Path.Any(l => string.Equals(l.Guid, guid, StringComparison.OrdinalIgnoreCase)))
        {
            return "The sub-sequence plays a cutscene above it, which is a cycle.";
        }
        return _shell.Assets.Find(guid) is { Kind: Link.Cook.AssetKind.Cutscene } ? null : $"No cutscene has the GUID {guid}.";
    }

    /// <summary>
    /// Shows a sub-sequence section's child in the tab, in context (see docs/editor/cutscene-editor.md#sub-sequences): its
    /// tracks, with the ruler on the tab's time, while the preview plays the tab's cutscene. Edits go to the child's
    /// document. Returns whether it opened.
    /// </summary>
    public bool OpenSubSequence(string sectionPath)
    {
        if (OpenSubSequenceRefusal(sectionPath) is { } why)
        {
            _shell.Console.Add(Model.LogLevel.Info, $"cutscene: {why}");
            return false;
        }
        var guid = CutsceneSubSequences.GuidOf(File.Find(sectionPath)!)!;
        if (!_levelHolds.ContainsKey(guid))
        {
            if (_shell.CutsceneDocuments.Acquire(guid) is not { } lease)
            {
                return false;
            }
            var document = lease.Document;
            var checks = new CookChecks<GraphProblem>(_shell, guid, () => ChildCookText(document), () => document.Path,
                l => new GraphProblem(null, l.Text, l.Error, l.Line));
            checks.Changed += () =>
            {
                if (document == _shown)
                {
                    ProblemsChanged?.Invoke();
                    _shell.Keying.Raise();
                }
            };
            checks.CookedCleanChanged += () => _shell.CutscenePreview.OnChildrenChanged(this);
            _levelHolds[guid] = new LevelHold(lease, checks);
            _ = checks.CookNow();
        }
        return SetLevels(_levels.Down(new CutsceneLevel(sectionPath, guid)));
    }

    /// <summary>Shows the level above the shown one: Backspace, or the crumb before the last. Nothing at the top level.</summary>
    public bool UpOneLevel() => InContext && GoToLevel(_levels.Depth - 1);

    /// <summary>Shows a level on the way down, by depth: 0 is the tab's own cutscene. A click on a crumb.</summary>
    public bool GoToLevel(int depth) => depth >= 0 && depth < _levels.Depth && SetLevels(_levels.Up(depth));

    // What Open in Own Tab opens: the sub-sequence shown in context, or else the selected one's child.
    string? OwnTabGuid => InContext ? ShownGuid : SelectedSubSequence is { } path ? CutsceneSubSequences.GuidOf(File.Find(path)!) : null;

    /// <summary>Whether Open in Own Tab has a cutscene to open.</summary>
    public bool CanOpenInOwnTab => OwnTabGuid is { } guid && _shell.Assets.Find(guid) is { Kind: Link.Cook.AssetKind.Cutscene };

    /// <summary>
    /// Opens the sub-sequence shown in context, or the selected one's child, as its own asset in its own tab, on its own
    /// time. Both tabs show one document.
    /// </summary>
    public void OpenInOwnTab()
    {
        if (OwnTabGuid is { } guid && _shell.Assets.Find(guid) is { Kind: Link.Cook.AssetKind.Cutscene } asset)
        {
            _shell.OpenAsset(asset);
        }
    }

    /// <summary>
    /// The one writer of <see cref="Levels"/>. It keeps what the tab showed of the old level, shows the new level's
    /// document with what the tab showed of it before, lets go of each child off the way down that has no changes, and
    /// tells the preview. Refused while a drag is under way in any level.
    /// </summary>
    bool SetLevels(CutsceneLevels next)
    {
        if (next == _levels || Documents.Any(d => d.InTransaction))
        {
            return false;
        }
        Document.EndMerge();
        _levelViews[ShownGuid] = new LevelView([.. _selection], [.. _folds], [.. _hiddenCurves], _shownCurves);
        Unobserve();
        _levels = next;
        _shown = InContext ? _levelHolds[next.Path[^1].Guid].Document : RootDocument;
        // A child let go here is no longer observed, so it is let go before the documents that stay are.
        ReleaseIdle();
        Observe();

        // The view of the level, and its own locks and stand-ins, since its tracks' and bindings' IDs are its own.
        var settings = _shell.CutsceneTimelineSettingsOf(ShownGuid);
        _locked.Clear();
        _locked.UnionWith(settings.Locked);
        _standIns.Clear();
        foreach (var (binding, standIn) in InContext ? settings.StandIns ?? [] : _shell.CutsceneTimelineSettingsOf(Guid).StandIns ?? [])
        {
            _standIns[binding] = standIn;
        }
        _standInsVersion++;
        var view = _levelViews.GetValueOrDefault(ShownGuid);
        _folds.Clear();
        _folds.UnionWith(view?.Folds ?? []);
        _hiddenCurves.Clear();
        _hiddenCurves.UnionWith(view?.HiddenCurves ?? []);
        _shownCurves = view?.ShownCurves ?? [];
        FilterText = "";
        _keysUnder = null;
        Replace((view?.Selection ?? []).Where(p => File.Find(p) != null));
        _entityBindings = BindingsOfEntities(_shell.Selection.Entities);
        EndStalePick();

        LevelsChanged?.Invoke();
        Changed?.Invoke();
        ProblemsChanged?.Invoke();
        PlayheadChanged?.Invoke();
        RequestFrame();
        _shell.CutscenePreview.OnChildrenChanged(this);
        _shell.Keying.Raise();
        return true;
    }

    // The shown document's changes are the timeline's; the others' can take a section on the way down away, change
    // what the preview plays, or change the tab's dirty mark.
    void Observe()
    {
        Document.Changed += OnDocumentChanged;
        foreach (var document in Documents.Where(d => d != Document))
        {
            document.Changed += OnOtherLevelChanged;
        }
    }

    void Unobserve()
    {
        Document.Changed -= OnDocumentChanged;
        foreach (var document in Documents.Where(d => d != Document))
        {
            document.Changed -= OnOtherLevelChanged;
        }
    }

    void OnOtherLevelChanged()
    {
        if (!RootDocument.InTransaction)
        {
            Checks.Schedule();
            _shell.CutscenePreview.OnMixChanged(this);
        }
        foreach (var hold in _levelHolds.Values.Where(h => h.Document != Document && !h.Document.InTransaction))
        {
            hold.Checks.Schedule();
        }
        // A level whose section was deleted, or now plays another cutscene, is gone, and the tab shows the deepest one
        // that is still on the way down.
        if (ValidDepth() is var depth && depth < _levels.Depth)
        {
            SetLevels(_levels.Up(depth));
            return;
        }
        Unobserve();
        ReleaseIdle();
        Observe();
        Changed?.Invoke();
        PlayheadChanged?.Invoke();
    }

    // How many levels from the top still have their section, playing their child.
    int ValidDepth()
    {
        var parent = RootFile;
        for (var i = 0; i < _levels.Depth; i++)
        {
            var level = _levels.Path[i];
            if (parent.Find(level.SectionPath) is not { Kind: CutsceneBlockKind.Section } section
                || CutsceneEdits.TrackOf(section)?.TrackKind != "sub_sequence"
                || !string.Equals(CutsceneSubSequences.GuidOf(section), level.Guid, StringComparison.OrdinalIgnoreCase))
            {
                return i;
            }
            parent = _levelHolds[level.Guid].Document.Graph;
        }
        return _levels.Depth;
    }

    // Lets go of each child that is off the way down and has no changes, which a save or an undo can leave.
    void ReleaseIdle()
    {
        foreach (var (guid, hold) in _levelHolds.ToList())
        {
            if (!hold.Document.IsDirty && _levels.Path.All(l => !string.Equals(l.Guid, guid, StringComparison.OrdinalIgnoreCase)))
            {
                _levelHolds.Remove(guid);
                hold.Dispose();
            }
        }
    }

    /// <summary>A new cook link has cooked no previews: each child's checks start again, as the tab's own do.</summary>
    internal void RestartLevels()
    {
        foreach (var hold in _levelHolds.Values)
        {
            _ = hold.Checks.Restart();
        }
    }

    void DisposeLevels()
    {
        foreach (var document in Documents.Where(d => d != Document))
        {
            document.Changed -= OnOtherLevelChanged;
        }
        foreach (var hold in _levelHolds.Values)
        {
            hold.Dispose();
        }
        _levelHolds.Clear();
    }
}
