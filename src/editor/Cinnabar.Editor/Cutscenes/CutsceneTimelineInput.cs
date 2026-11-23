using Avalonia;
using Avalonia.Input;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Cutscenes;

/// <summary>
/// The timeline's gestures (see docs/editor/cutscene-editor.md#the-timeline), with no window: the view passes its
/// pointer, wheel and Esc here, and draws what this holds. A press selects; a drag moves, trims, ripples or slips, as
/// one undo entry that Esc cancels; a drag in empty space selects in a box; the ruler moves the playhead, its handles
/// set the range and the length, and its marker flags select and move markers. Tests drive it as the view does.
/// </summary>
public sealed class CutsceneTimelineInput
{
    enum Gesture
    {
        None,
        /// <summary>A press that has not moved past the slop: on release, a click.</summary>
        Click,
        Move,
        Trim,
        Slip,
        Box,
        Scrub,
        Handle,
        Pan,
    }

    readonly CutsceneEditor _editor;
    CutsceneTimelineLayout? _layout;
    Gesture _gesture;
    CutsceneHit? _press;
    Point _pressAt;
    Point _pointer;
    // What the press would drag once it moves: a move, a trim, a slip or a handle.
    Gesture _pending;
    bool _ripple;
    // The grabbed item's span when the drag began, and the paths that the drag moves.
    (int Start, int End) _grabbed;
    IReadOnlyList<string> _moving = [];
    List<int> _targets = [];
    (int Start, int End) _range;
    // Whether the range was all of the length when a drag of a handle began, so it stays all of it.
    bool _full;
    // The button that started the gesture, whose release alone ends it.
    MouseButton _button;
    bool _fitted;

    public CutsceneTimelineInput(CutsceneEditor editor) => _editor = editor;

    /// <summary>The part of the time in view, which the curve editor shares (<see cref="CutsceneEditor.TimeView"/>).</summary>
    public TimelineView View
    {
        get => _editor.TimeView;
        private set => _editor.SetTimeView(value);
    }

    public double ScrollY { get; private set; }

    public double Width { get; private set; }

    public double Height { get; private set; }

    /// <summary>The time area's width, right of the header gutter.</summary>
    public double TimeWidth => Math.Max(Width - CutsceneTimelineLayout.Gutter, 1);

    /// <summary>The rows, built again when the cutscene, its folds, its locks or its filter change.</summary>
    public CutsceneTimelineLayout Layout => _layout ??= _editor.Layout();

    /// <summary>The time that a drag snapped to, which the view draws as a guide, or null.</summary>
    public int? Guide { get; private set; }

    /// <summary>The box of a box select, corner to corner, or null.</summary>
    public (Point From, Point To)? Box => _gesture == Gesture.Box ? (_pressAt, _pointer) : null;

    /// <summary>What a drag has done so far, in the ruler's units, which the view shows by the pointer, or null.</summary>
    public string? Tooltip { get; private set; }

    public Point Pointer => _pointer;

    /// <summary>Whether a drag that changes the cutscene is under way.</summary>
    public bool Dragging => _gesture is Gesture.Move or Gesture.Trim or Gesture.Slip or Gesture.Handle;

    /// <summary>The view should draw again.</summary>
    public event Action? Invalidated;

    /// <summary>Forgets the rows, after the cutscene or its folds change.</summary>
    public void Refresh()
    {
        _layout = null;
        ClampScroll();
        Invalidated?.Invoke();
    }

    /// <summary>Scrolls the rows so that the row of a binding or a track is in view, when the layout has it.</summary>
    public void Reveal(string path)
    {
        _layout = null;
        if (Layout.Rows.FirstOrDefault(r => r.Path == path) is not { } row)
        {
            return;
        }
        var height = Math.Max(Height - CutsceneTimelineLayout.RulerHeight, CutsceneTimelineLayout.RowHeight);
        if (row.Top < ScrollY || row.Top + CutsceneTimelineLayout.RowHeight > ScrollY + height)
        {
            ScrollY = row.Top - (height - CutsceneTimelineLayout.RowHeight) / 2;
        }
        ClampScroll();
        Invalidated?.Invoke();
    }

    /// <summary>The control's size. The first one with a width fits the whole cutscene.</summary>
    public void Resize(double width, double height)
    {
        Width = width;
        Height = height;
        if (!_fitted && width > CutsceneTimelineLayout.Gutter)
        {
            _fitted = true;
            Frame();
        }
        ClampScroll();
        Invalidated?.Invoke();
    }

    /// <summary>F: fits the selection's span in the view, or the whole cutscene when nothing on the timeline is selected.</summary>
    public void Frame()
    {
        var span = Layout.SpanOf(_editor.SelectedPaths.ToHashSet()) is { } s && s.End > s.Start ? s : (0, Math.Max(Layout.Length, 1));
        View = TimelineView.Fit(span.Item1, span.Item2, TimeWidth, TimelineZoom.Ticks);
        Invalidated?.Invoke();
    }

    /// <summary>Shows a part of the time, as tests do to put ticks on whole pixels.</summary>
    internal void SetView(TimelineView view)
    {
        _fitted = true;
        View = view;
        Invalidated?.Invoke();
    }

    /// <summary>Whether the view follows the playhead while the preview plays (<see cref="CutsceneEditor.Follow"/>).</summary>
    public bool Follow
    {
        get => _editor.Follow;
        private set => _editor.SetFollow(value);
    }

    /// <summary>A play began: the view follows the playhead again.</summary>
    public void OnPlayStarted()
    {
        Follow = true;
        ShowPlayhead();
    }

    /// <summary>
    /// Pans the view so the playhead is in it, as Home, End and the jumps to an edge move it, and centres it there. While
    /// the preview plays, the view pages when the playhead leaves it, so the playhead starts again near the edge that it
    /// comes from, and not at all once a pan or a zoom by hand turned <see cref="Follow"/> off.
    /// </summary>
    public void ShowPlayhead()
    {
        var x = View.X(_editor.Playhead);
        var outside = x < 0 || x > TimeWidth;
        if (_editor.PlayingRate is { } rate)
        {
            if (Follow && outside)
            {
                var margin = TimeWidth / 10;
                var at = rate > 0 ? margin : TimeWidth - margin;
                View = View with { Start = _editor.Playhead - at * View.PerPixel };
            }
        }
        else if (outside)
        {
            View = View with { Start = _editor.Playhead - TimeWidth / 2 * View.PerPixel };
        }
        Invalidated?.Invoke();
    }

    void ClampScroll() => ScrollY = Math.Clamp(ScrollY, 0, Math.Max(Layout.ContentHeight - (Height - CutsceneTimelineLayout.RulerHeight), 0));

    double TickAt(double x) => View.At(x - CutsceneTimelineLayout.Gutter);

    /// <summary>
    /// The wheel: over the time area, zooms about the pointer, and with Shift, scrolls the time; over the headers,
    /// scrolls the rows.
    /// </summary>
    public void Wheel(double x, double y, double delta, KeyModifiers modifiers)
    {
        if (x < CutsceneTimelineLayout.Gutter)
        {
            ScrollY -= delta * CutsceneTimelineLayout.RowHeight * 3;
            ClampScroll();
        }
        else if (modifiers.HasFlag(KeyModifiers.Shift))
        {
            View = View.Pan(delta * 60);
            Follow = false;
        }
        else
        {
            View = View.ZoomAbout(x - CutsceneTimelineLayout.Gutter, Math.Pow(1.25, -delta));
            Follow = false;
        }
        Invalidated?.Invoke();
    }

    /// <summary>A press. Returns whether the view should capture the pointer.</summary>
    public bool Press(double x, double y, MouseButton button, KeyModifiers modifiers)
    {
        if (_gesture != Gesture.None)
        {
            return false;
        }
        _pressAt = _pointer = new Point(x, y);
        _button = button;
        if (button == MouseButton.Middle || (button == MouseButton.Right && modifiers.HasFlag(KeyModifiers.Alt)))
        {
            _gesture = Gesture.Pan;
            Follow = false;
            return true;
        }
        if (button != MouseButton.Left)
        {
            return false;
        }
        var hit = Layout.HitTest(x, y, View, ScrollY);
        _press = hit;
        _ripple = false;
        switch (hit.Kind)
        {
            case CutsceneHitKind.Ruler:
                _gesture = Gesture.Scrub;
                _editor.SetPlayhead(SnapToFrame(hit.Tick));
                return true;
            case CutsceneHitKind.RangeStart or CutsceneHitKind.RangeEnd or CutsceneHitKind.Length:
                _gesture = Gesture.Click;
                _pending = Gesture.Handle;
                _range = Layout.Range;
                return true;
            case CutsceneHitKind.Fold:
                _editor.ToggleFold(hit.Row!.Path);
                return false;
            case CutsceneHitKind.Lock when hit.Row!.TrackId is { } track:
                _editor.SetLocked(track, !_editor.Locked.Contains(track));
                return false;
            // A track that its asset mutes stays muted: its M is the asset's.
            case CutsceneHitKind.Mute when hit.Row!.TrackId is { } track && !hit.Row.AssetMuted:
                _editor.SetMuted(track, !_editor.Muted.Contains(track));
                return false;
            case CutsceneHitKind.Solo when hit.Row!.TrackId is { } track:
                _editor.SetSoloed(track, !_editor.Soloed.Contains(track));
                return false;
            case CutsceneHitKind.Header:
                _editor.Select([hit.Row!.Path], ModeOf(modifiers));
                return false;
            case CutsceneHitKind.Key or CutsceneHitKind.Trigger or CutsceneHitKind.Marker or CutsceneHitKind.Body or CutsceneHitKind.StartEdge or CutsceneHitKind.EndEdge:
            {
                // A press on a selected item with no modifier keeps the selection, so a drag moves all of it.
                var selected = hit.Paths.All(_editor.SelectedPaths.Contains);
                if (!selected || (modifiers & (KeyModifiers.Shift | KeyModifiers.Control)) != 0)
                {
                    _editor.Select(hit.Paths, ModeOf(modifiers));
                }
                _gesture = Gesture.Click;
                _pending = hit.Kind switch
                {
                    CutsceneHitKind.StartEdge or CutsceneHitKind.EndEdge => Gesture.Trim,
                    CutsceneHitKind.Body when modifiers.HasFlag(KeyModifiers.Alt) => Gesture.Slip,
                    _ => Gesture.Move,
                };
                _ripple = _pending == Gesture.Trim && modifiers.HasFlag(KeyModifiers.Shift);
                return true;
            }
            case CutsceneHitKind.Empty:
                _gesture = Gesture.Click;
                _pending = Gesture.Box;
                return true;
            default:
                return false;
        }
    }

    static SelectMode ModeOf(KeyModifiers modifiers) =>
        modifiers.HasFlag(KeyModifiers.Control) ? SelectMode.Toggle : modifiers.HasFlag(KeyModifiers.Shift) ? SelectMode.Add : SelectMode.Replace;

    int SnapToFrame(double tick) => (int)(Math.Round(tick / _editor.FrameTicks) * _editor.FrameTicks);

    public void Move(double x, double y, KeyModifiers modifiers)
    {
        var last = _pointer;
        _pointer = new Point(x, y);
        // Esc or an undo can end the drag's entry under the gesture.
        if (Dragging && !_editor.Document.InTransaction)
        {
            Reset();
        }
        switch (_gesture)
        {
            case Gesture.Click when Gestures.MovedPast(_pointer - _pressAt):
                Start();
                if (_gesture != Gesture.Click)
                {
                    Move(x, y, modifiers);
                }
                return;
            case Gesture.Pan:
                View = View.Pan(x - last.X);
                ScrollY -= y - last.Y;
                ClampScroll();
                break;
            case Gesture.Scrub:
                _editor.SetPlayhead(SnapToFrame(TickAt(x)));
                break;
            case Gesture.Move or Gesture.Trim or Gesture.Slip or Gesture.Handle:
                Step(TickAt(x) - _press!.Tick, !modifiers.HasFlag(KeyModifiers.Control) && _editor.Snap);
                break;
            case Gesture.Box:
                break;
            default:
                // Over a binding's header that is not bound, the tip says why.
                var tip = Layout.HitTest(x, y, View, ScrollY) is { Kind: CutsceneHitKind.Header, Row.Binding: { State: not CutsceneBindingState.Bound, Reason: { } reason } } ? reason : null;
                if (tip != Tooltip)
                {
                    Tooltip = tip;
                    Invalidated?.Invoke();
                }
                return;
        }
        Invalidated?.Invoke();
    }

    /// <summary>The binding's row under a point, for a drop on it, or null.</summary>
    public CutsceneTimelineRow? BindingRowAt(double x, double y) =>
        Layout.HitTest(x, y, View, ScrollY) is { Row: { Kind: CutsceneRowKind.Binding } row } ? row : null;

    // The press moved past the slop: the pending drag begins.
    void Start()
    {
        var hit = _press!;
        switch (_pending)
        {
            case Gesture.Box:
                _gesture = Gesture.Box;
                return;
            case Gesture.Handle:
            {
                var handle = hit.Kind == CutsceneHitKind.Length ? "Set Length" : "Set Range";
                if (!_editor.BeginDrag(handle))
                {
                    Reset();
                    return;
                }
                _grabbed = hit.Kind switch
                {
                    CutsceneHitKind.RangeStart => (_range.Start, _range.Start),
                    CutsceneHitKind.RangeEnd => (_range.End, _range.End),
                    _ => (Layout.Length, Layout.Length),
                };
                _moving = [];
                _full = _range == (0, Layout.Length);
                _targets = Layout.SnapTargets(new HashSet<string>());
                _gesture = Gesture.Handle;
                return;
            }
        }
        if (_editor.Locked.Count > 0 && hit.Row?.TrackId is { } track && _editor.Locked.Contains(track))
        {
            Reset();
            return;
        }
        var item = Layout.Rows.SelectMany(r => r.Bars.Concat(r.Points).Concat(r.Keys)).Concat(Layout.Markers).FirstOrDefault(i => i.Path == hit.Paths[0]);
        if (item == null)
        {
            Reset();
            return;
        }
        _grabbed = (item.Start, item.End);
        _moving = _pending == Gesture.Move ? [.. _editor.SelectedPaths] : [hit.Paths[0]];
        var label = _pending switch
        {
            Gesture.Trim => _ripple ? "Ripple Trim" : "Trim",
            Gesture.Slip => "Slip",
            _ => "Move",
        };
        // What moves does not snap to itself: a moving section's keys move with it.
        var moving = new HashSet<string>(_moving);
        foreach (var path in _moving)
        {
            moving.UnionWith(Layout.Rows.SelectMany(r => r.Keys).Where(k => k.Path.StartsWith(path + "/", StringComparison.Ordinal)).Select(k => k.Path));
        }
        _targets = Layout.SnapTargets(moving);
        if (!_editor.BeginDrag(label))
        {
            Reset();
            return;
        }
        _gesture = _pending;
    }

    // A step of the drag by the pointer's ticks from the press, snapped.
    void Step(double raw, bool snap)
    {
        var targets = _targets.Append(_editor.Playhead).Order().ToList();
        var perPixel = View.PerPixel;
        var frame = _editor.FrameTicks;
        Guide = null;
        switch (_gesture)
        {
            case Gesture.Move:
            {
                // Whichever edge of the grabbed item lands on a target, or else its start on a frame.
                var (start, guide) = TimelineSnap.Snap(_grabbed.Start + raw, targets, perPixel, frame, snap);
                var delta = start - _grabbed.Start;
                if (guide == null && _grabbed.End != _grabbed.Start)
                {
                    var (end, endGuide) = TimelineSnap.Snap(_grabbed.End + raw, targets, perPixel, frame, snap);
                    if (endGuide != null)
                    {
                        (delta, guide) = (end - _grabbed.End, endGuide);
                    }
                }
                Guide = guide;
                var paths = _moving;
                _editor.StepDrag(f => CutsceneEdits.Move(f, paths, delta, _editor.Locked));
                Tooltip = Describe(_grabbed.Start + delta, _grabbed.End + delta, delta);
                break;
            }
            case Gesture.Trim:
            {
                var edge = _press!.Kind == CutsceneHitKind.StartEdge ? CutsceneEdge.Start : CutsceneEdge.End;
                var from = edge == CutsceneEdge.Start ? _grabbed.Start : _grabbed.End;
                var (to, guide) = TimelineSnap.Snap(from + raw, targets, perPixel, frame, snap);
                Guide = guide;
                var path = _moving[0];
                var ripple = _ripple;
                _editor.StepDrag(f => CutsceneEdits.Trim(f, path, edge, to - from, ripple, _editor.Locked, _editor.ChildStart));
                var now = _editor.File.Find(path);
                Tooltip = Describe(now?.Start ?? _grabbed.Start, now?.End ?? _grabbed.End, (edge == CutsceneEdge.Start ? now?.Start : now?.End) - from ?? 0);
                break;
            }
            case Gesture.Slip:
            {
                var delta = snap ? (int)(Math.Round(raw / frame) * frame) : (int)Math.Round(raw);
                var path = _moving[0];
                _editor.StepDrag(f => CutsceneEdits.Slip(f, path, delta, _editor.Locked, _editor.ChildStart));
                Tooltip = $"slip {Units(delta)}";
                break;
            }
            case Gesture.Handle:
            {
                var (to, guide) = TimelineSnap.Snap(_grabbed.Start + raw, targets, perPixel, frame, snap);
                Guide = guide;
                var kind = _press!.Kind;
                var range = _range;
                var full = _full;
                _editor.StepDrag(f =>
                {
                    switch (kind)
                    {
                        case CutsceneHitKind.RangeStart:
                            CutsceneEdits.SetRange(f, to, range.End);
                            break;
                        case CutsceneHitKind.RangeEnd:
                            CutsceneEdits.SetRange(f, range.Start, to);
                            break;
                        default:
                            CutsceneEdits.SetLength(f, to);
                            // A range that was all of the length stays all of it.
                            if (!full)
                            {
                                CutsceneEdits.SetRange(f, range.Start, Math.Min(range.End, f.Length ?? range.End));
                            }
                            break;
                    }
                    return [];
                });
                Tooltip = kind == CutsceneHitKind.Length ? $"length {Units(_editor.File.Length ?? 0)}" : $"range {Units(CutsceneEdits.RangeOf(_editor.File).Start)} – {Units(CutsceneEdits.RangeOf(_editor.File).End)}";
                break;
            }
        }
    }

    string Units(int ticks) => ticks < 0 ? "-" + Units(-ticks) : _editor.ShowFrames ? $"{CutsceneTime.Frames(ticks, _editor.File.Rate)}f" : CutsceneTime.Timecode(ticks, _editor.File.Rate);

    string Describe(int start, int end, int delta) =>
        start == end
            ? $"{Units(start)}  ·  Δ {Units(delta)}"
            : $"{Units(start)} – {Units(end)}  ·  length {Units(end - start)}  ·  Δ {Units(delta)}";

    /// <summary>A release. Only the button that started the gesture ends it.</summary>
    public void Release(double x, double y, KeyModifiers modifiers, MouseButton button = MouseButton.Left)
    {
        if (_gesture == Gesture.None || button != _button)
        {
            return;
        }
        _pointer = new Point(x, y);
        switch (_gesture)
        {
            case Gesture.Click when _press is { } hit:
                if (_pending == Gesture.Box)
                {
                    // A click in empty space clears the selection, unless Shift or Ctrl adds to it.
                    if (ModeOf(modifiers) == SelectMode.Replace)
                    {
                        _editor.Select([], SelectMode.Replace);
                    }
                }
                else if (_pending != Gesture.Handle && modifiers == KeyModifiers.None)
                {
                    _editor.Select(hit.Paths, SelectMode.Replace);
                }
                break;
            case Gesture.Box:
            {
                var paths = Layout.InBox(_pressAt.X, _pressAt.Y, x, y, View, ScrollY);
                _editor.Select(paths, ModeOf(modifiers));
                break;
            }
            case Gesture.Move or Gesture.Trim or Gesture.Slip or Gesture.Handle:
                _editor.EndDrag(cancel: false);
                break;
        }
        Reset();
        Invalidated?.Invoke();
    }

    /// <summary>The pointer's capture was lost: a drag commits what it did, as a release would.</summary>
    public void LostCapture()
    {
        if (_gesture != Gesture.None)
        {
            Release(_pointer.X, _pointer.Y, KeyModifiers.None, _button);
        }
    }

    /// <summary>
    /// Esc: cancels a drag, so the cutscene and the undo stack are as they were, or a box, or else clears the selection.
    /// Returns whether it did something.
    /// </summary>
    public bool Escape()
    {
        if (Dragging)
        {
            _editor.EndDrag(cancel: true);
            Reset();
            Invalidated?.Invoke();
            return true;
        }
        if (_gesture != Gesture.None)
        {
            Reset();
            Invalidated?.Invoke();
            return true;
        }
        if (_editor.SelectedPaths.Count > 0)
        {
            _editor.Select([], SelectMode.Replace);
            return true;
        }
        return false;
    }

    void Reset()
    {
        _gesture = Gesture.None;
        _pending = Gesture.None;
        _press = null;
        _moving = [];
        Guide = null;
        Tooltip = null;
    }
}
