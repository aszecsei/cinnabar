using Avalonia;
using Avalonia.Input;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Cutscenes;

/// <summary>
/// The curve editor's gestures (see docs/editor/cutscene-editor.md#curves), with no window: the view passes its
/// pointer, wheel and Esc here, and draws what this holds. A press on a key selects it, and a drag moves the selected
/// keys in time and value; a drag of a selected key's handle sets its slope; each drag is one undo entry that Esc
/// cancels. A double-click on a curve adds a key there. A drag in empty space selects in a box. The middle button pans,
/// and Alt and the right button zoom each axis. The time is the timeline's (<see cref="CutsceneEditor.TimeView"/>),
/// and the value axis is this pane's. Tests drive it as the view does.
/// </summary>
public sealed class CutsceneCurveInput
{
    enum Gesture
    {
        None,
        /// <summary>A press that has not moved past the slop: on release, a click.</summary>
        Click,
        Keys,
        Handle,
        Box,
        Pan,
        Zoom,
    }

    /// <summary>The height of a row of the curve list, left of the curves.</summary>
    public const double ListRowHeight = 20;

    /// <summary>The width of a list row's eye, which shows and hides its curve.</summary>
    public const double EyeWidth = 24;

    readonly CutsceneEditor _editor;
    CutsceneCurveLayout? _layout;
    CutsceneCurveLayout? _list;
    Gesture _gesture;
    Gesture _pending;
    CurveHit _press = CurveHit.Nothing;
    Point _pressAt;
    Point _pointer;
    MouseButton _button;
    // What a key drag moves, by row, and the times that it snaps to.
    List<(CurveRow Row, List<string> Paths)> _moving = [];
    // The hold on the cutscene's drag while a key or a handle drag is under way: its steps and its end act only while it
    // is still the cutscene's open drag, so a drag that another ends commits no other's entry.
    CutsceneDrag? _drag;
    List<int> _targets = [];
    // The views when a zoom by drag began.
    TimelineView _zoomTime;
    ValueAxis _zoomValue;
    // The curves that the value axis was last fitted to, so a new set of curves fits again.
    IReadOnlyList<string> _fittedTo = [];
    bool _fittedNormalized;

    public CutsceneCurveInput(CutsceneEditor editor) => _editor = editor;

    /// <summary>The value axis, which is this pane's own.</summary>
    public ValueAxis Value { get; private set; } = new(1, 2.0 / 200);

    public double Width { get; private set; }

    public double Height { get; private set; }

    /// <summary>The time area's width, right of the curve list.</summary>
    public double TimeWidth => Math.Max(Width - CutsceneTimelineLayout.Gutter, 1);

    /// <summary>The shared time, this pane's values and the normalized view, as the geometry takes them.</summary>
    public CurveView View => new(_editor.TimeView, Value, _editor.CurvesNormalized);

    /// <summary>The curves that show, built again when the cutscene, the selection or the hidden curves change.</summary>
    public CutsceneCurveLayout Layout => _layout ??= CutsceneCurveLayout.Build(_editor.File, _editor.ShownCurves, _editor.HiddenCurves, _editor.Stepped, _editor.Locked);

    /// <summary>The curve list's rows: every curve that the selection shows, hidden or not.</summary>
    public CutsceneCurveLayout List => _list ??= CutsceneCurveLayout.Build(_editor.File, _editor.ShownCurves, null, _editor.Stepped, _editor.Locked);

    /// <summary>The selected keys and other blocks, by path.</summary>
    public IReadOnlySet<string> Selected => _editor.SelectedPaths.ToHashSet();

    /// <summary>The time that a key drag snapped to, which the view draws as a guide, or null.</summary>
    public int? Guide { get; private set; }

    /// <summary>The box of a box select, corner to corner, or null.</summary>
    public (Point From, Point To)? Box => _gesture == Gesture.Box ? (_pressAt, _pointer) : null;

    /// <summary>What a drag has done so far, which the view shows by the pointer, or null.</summary>
    public string? Tooltip { get; private set; }

    public Point Pointer => _pointer;

    /// <summary>Whether a drag that changes the cutscene is under way.</summary>
    public bool Dragging => _gesture is Gesture.Keys or Gesture.Handle;

    /// <summary>The view should draw again.</summary>
    public event Action? Invalidated;

    /// <summary>
    /// Forgets the curves, after the cutscene, the selection or the hidden curves change. A new set of curves, or a change
    /// of the normalized view, fits the value axis to them.
    /// </summary>
    public void Refresh()
    {
        _layout = null;
        _list = null;
        var refit = !_editor.ShownCurves.SequenceEqual(_fittedTo) || _fittedNormalized != _editor.CurvesNormalized;
        if (refit && Height > 0 && Layout.Rows.Count > 0)
        {
            FitValues();
        }
        Invalidated?.Invoke();
    }

    /// <summary>The control's size.</summary>
    public void Resize(double width, double height)
    {
        Width = width;
        Height = height;
        Refresh();
    }

    /// <summary>Shows a part of the values, as tests do to put values on whole pixels.</summary>
    internal void SetValue(ValueAxis value)
    {
        _fittedTo = _editor.ShownCurves;
        _fittedNormalized = _editor.CurvesNormalized;
        Value = value;
        Invalidated?.Invoke();
    }

    // Fits the value axis to every curve, keeping the time.
    void FitValues()
    {
        _fittedTo = _editor.ShownCurves;
        _fittedNormalized = _editor.CurvesNormalized;
        if (Layout.FrameSpan(new HashSet<string>(), _editor.CurvesNormalized) is { } span)
        {
            Value = ValueAxis.Fit(span.Min, span.Max, Height);
        }
    }

    /// <summary>
    /// F in the curve editor: fits the selected keys, or every curve when none of its keys are selected, in time and in
    /// value. The time is the timeline's too.
    /// </summary>
    public void Frame()
    {
        if (Layout.FrameSpan(Selected, _editor.CurvesNormalized) is not { } span)
        {
            return;
        }
        var (start, end) = span.End > span.Start ? (span.Start, span.End) : (span.Start - CutsceneFile.TicksPerSecond / 2, span.End + CutsceneFile.TicksPerSecond / 2);
        _editor.SetTimeView(TimelineView.Fit(start, end, TimeWidth, TimelineZoom.Ticks));
        _editor.SetFollow(false);
        _fittedTo = _editor.ShownCurves;
        _fittedNormalized = _editor.CurvesNormalized;
        Value = ValueAxis.Fit(span.Min, span.Max, Height);
        Invalidated?.Invoke();
    }

    double TickAt(double x) => _editor.TimeView.At(x - CutsceneTimelineLayout.Gutter);

    /// <summary>The wheel over the curves: zooms the time about the pointer, or with Shift, the values.</summary>
    public void Wheel(double x, double y, double delta, KeyModifiers modifiers)
    {
        if (x < CutsceneTimelineLayout.Gutter)
        {
            return;
        }
        if (modifiers.HasFlag(KeyModifiers.Shift))
        {
            Value = Value.ZoomAbout(y, Math.Pow(1.25, -delta));
        }
        else
        {
            _editor.SetTimeView(_editor.TimeView.ZoomAbout(x - CutsceneTimelineLayout.Gutter, Math.Pow(1.25, -delta)));
            _editor.SetFollow(false);
        }
        Invalidated?.Invoke();
    }

    /// <summary>A press, with its click count. Returns whether the view should capture the pointer.</summary>
    public bool Press(double x, double y, MouseButton button, KeyModifiers modifiers, int clicks = 1)
    {
        if (_gesture != Gesture.None)
        {
            return false;
        }
        _pressAt = _pointer = new Point(x, y);
        _button = button;
        if (button == MouseButton.Middle)
        {
            _gesture = Gesture.Pan;
            _editor.SetFollow(false);
            return true;
        }
        if (button == MouseButton.Right && modifiers.HasFlag(KeyModifiers.Alt))
        {
            _gesture = Gesture.Zoom;
            (_zoomTime, _zoomValue) = (_editor.TimeView, Value);
            _editor.SetFollow(false);
            return true;
        }
        if (button != MouseButton.Left)
        {
            return false;
        }
        if (x < CutsceneTimelineLayout.Gutter)
        {
            PressList(x, y, modifiers);
            return false;
        }
        var hit = Layout.HitTest(x, y, View, Selected);
        _press = hit;
        switch (hit.Kind)
        {
            case CurveHitKind.Curve when clicks >= 2 && !hit.Row!.Locked:
                _editor.AddCurveKey(hit.Row.Path, hit.Tick);
                return false;
            case CurveHitKind.Handle:
                _gesture = Gesture.Click;
                _pending = Gesture.Handle;
                return true;
            case CurveHitKind.Key:
            {
                // A press on a selected key with no modifier keeps the selection, so a drag moves all of it.
                var path = hit.Path!;
                if (!_editor.SelectedPaths.Contains(path) || (modifiers & (KeyModifiers.Shift | KeyModifiers.Control)) != 0)
                {
                    _editor.Select([path], ModeOf(modifiers));
                }
                _gesture = Gesture.Click;
                _pending = Gesture.Keys;
                return true;
            }
            default:
                _gesture = Gesture.Click;
                _pending = Gesture.Box;
                return true;
        }
    }

    // A click in the curve list: on the eye, shows or hides the curve; on the name, selects its keys.
    void PressList(double x, double y, KeyModifiers modifiers)
    {
        var index = (int)Math.Floor(y / ListRowHeight);
        if (index < 0 || index >= List.Rows.Count)
        {
            return;
        }
        var row = List.Rows[index];
        if (x < EyeWidth)
        {
            _editor.SetCurveHidden(row.Path, !_editor.HiddenCurves.Contains(row.Path));
        }
        else if (!_editor.HiddenCurves.Contains(row.Path))
        {
            _editor.Select(row.KeyPaths, ModeOf(modifiers));
        }
    }

    static SelectMode ModeOf(KeyModifiers modifiers) =>
        modifiers.HasFlag(KeyModifiers.Control) ? SelectMode.Toggle : modifiers.HasFlag(KeyModifiers.Shift) ? SelectMode.Add : SelectMode.Replace;

    public void Move(double x, double y, KeyModifiers modifiers)
    {
        var last = _pointer;
        _pointer = new Point(x, y);
        // Another holder, such as Esc in the timeline or a field, can end the drag under the gesture.
        if (Dragging && _drag is not { IsOpen: true })
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
                _editor.SetTimeView(_editor.TimeView.Pan(x - last.X));
                Value = Value.Pan(y - last.Y);
                break;
            case Gesture.Zoom:
            {
                // Right shows less time, and up shows less value: each axis zooms about the press.
                var time = _zoomTime.ZoomAbout(_pressAt.X - CutsceneTimelineLayout.Gutter, Math.Exp(-(x - _pressAt.X) / 150));
                _editor.SetTimeView(time);
                Value = _zoomValue.ZoomAbout(_pressAt.Y, Math.Exp((y - _pressAt.Y) / 150));
                break;
            }
            case Gesture.Keys:
                StepKeys(modifiers);
                break;
            case Gesture.Handle:
                StepHandle();
                break;
            case Gesture.Box:
                break;
            default:
                return;
        }
        Invalidated?.Invoke();
    }

    // The press moved past the slop: the pending drag begins.
    void Start()
    {
        switch (_pending)
        {
            case Gesture.Box:
                _gesture = Gesture.Box;
                return;
            case Gesture.Handle when !_press.Row!.Locked && _editor.BeginHeldDrag("Drag Tangent") is { } drag:
                _drag = drag;
                _gesture = Gesture.Handle;
                return;
            case Gesture.Keys:
            {
                var selected = Selected;
                _moving = [.. Layout.Rows.Where(r => !r.Locked)
                    .Select(r => (r, r.KeyPaths.Where(selected.Contains).ToList()))
                    .Where(m => m.Item2.Count > 0)];
                if (_moving.Count == 0 || _editor.BeginHeldDrag("Move Keys") is not { } drag)
                {
                    Reset();
                    return;
                }
                _drag = drag;
                // What the timeline's drags snap to, but the moving keys.
                _targets = _editor.Layout().SnapTargets(_moving.SelectMany(m => m.Paths).ToHashSet());
                _gesture = Gesture.Keys;
                return;
            }
        }
        Reset();
    }

    // A step of a key drag, from the press: in time, snapped as the timeline snaps, and in value, which value snapping
    // puts the grabbed key on a grid line of; Shift keeps the axis that has moved more, and Ctrl snaps neither.
    void StepKeys(KeyModifiers modifiers)
    {
        var dx = _pointer.X - _pressAt.X;
        var dy = _pointer.Y - _pressAt.Y;
        if (modifiers.HasFlag(KeyModifiers.Shift))
        {
            (dx, dy) = Math.Abs(dx) >= Math.Abs(dy) ? (dx, 0.0) : (0.0, dy);
        }
        var view = View;
        var row = _press.Row!;
        var grabbed = row.TickOf(_press.Index);
        var targets = _targets.Append(_editor.Playhead).Order().ToList();
        var snap = dx != 0 && !modifiers.HasFlag(KeyModifiers.Control) && _editor.Snap;
        var (tick, guide) = TimelineSnap.Snap(grabbed + dx * view.Time.PerPixel, targets, view.Time.PerPixel, _editor.FrameTicks, snap);
        Guide = guide;
        var ticks = dx == 0 ? 0 : tick - grabbed;
        // A shown value's change, which a normalized curve scales back to its own.
        var shown = -dy * view.Value.PerPixel;
        var normalized = view.Normalized;
        if (dy != 0 && _editor.ValueSnap && !modifiers.HasFlag(KeyModifiers.Control))
        {
            var from = row.Shown(row.Keys[_press.Index].Value, normalized);
            shown = ValueAxis.SnapTo(from + shown, view.Value.GridStep) - from;
        }
        var moving = _moving;
        _drag?.Step(f =>
        {
            foreach (var (r, paths) in moving)
            {
                // A stepped field's keys stay whole.
                var by = shown * r.Scale(normalized);
                CutsceneCurveEdits.MoveKeys(f, paths, 0, r.Stepped ? Math.Round(by) : by, _editor.Locked);
            }
            return CutsceneEdits.Move(f, [.. moving.SelectMany(m => m.Paths)], ticks, _editor.Locked);
        });
        var value = row.Keys[_press.Index].Value + shown * row.Scale(normalized);
        Tooltip = $"{Units(grabbed + ticks)}  ·  {CutsceneKeying.Format(value)}";
    }

    // A step of a handle drag: the slope from the key to the pointer, and a weighted key's weight from how far across it is.
    void StepHandle()
    {
        var row = _press.Row!;
        var slope = CutsceneCurveLayout.SlopeAt(row, _press.Index, _press.Side, View, _pointer.X, _pointer.Y);
        var weight = CutsceneCurveLayout.WeightAt(row, _press.Index, _press.Side, View, _pointer.X);
        var path = _press.Path!;
        var side = _press.Side;
        _drag?.Step(f =>
        {
            CutsceneCurveEdits.SetSlope(f, path, side, slope, _editor.Locked, weight);
            return [];
        });
        Tooltip = $"slope {CutsceneKeying.Format(slope)}/s" + (weight is { } w ? $"  ·  weight {CutsceneKeying.Format((float)w)}" : "");
    }

    string Units(int ticks) => ticks < 0 ? "-" + Units(-ticks) : _editor.ShowFrames ? $"{CutsceneTime.Frames(ticks, _editor.File.Rate)}f" : CutsceneTime.Timecode(ticks, _editor.File.Rate);

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
            case Gesture.Click when _pending == Gesture.Box:
                // A click in empty space clears the selection, unless Shift or Ctrl adds to it. The curves stay.
                if (ModeOf(modifiers) == SelectMode.Replace)
                {
                    _editor.Select([], SelectMode.Replace);
                }
                break;
            case Gesture.Click when _pending == Gesture.Keys && modifiers == KeyModifiers.None && _press.Path is { } path:
                _editor.Select([path], SelectMode.Replace);
                break;
            case Gesture.Box:
                _editor.Select(Layout.InBox(_pressAt.X, _pressAt.Y, x, y, View), ModeOf(modifiers));
                break;
            case Gesture.Keys or Gesture.Handle:
                _drag?.End(cancel: false);
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
            _drag?.End(cancel: true);
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
        _press = CurveHit.Nothing;
        _moving = [];
        _drag = null;
        Guide = null;
        Tooltip = null;
    }
}
