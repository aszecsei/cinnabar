using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using static Cinnabar.Editor.Materials.CanvasDrawing;

namespace Cinnabar.Editor.Graphs;

/// <summary>What a graph canvas's editor does for the gestures that every graph canvas has: selection, drags and deletes.</summary>
public interface IGraphCanvasEditor
{
    IReadOnlyCollection<int> Selection { get; }

    void Select(IEnumerable<int> ids, SelectMode mode = SelectMode.Replace);

    /// <summary>Where the selected things are now, which a drag's steps start from.</summary>
    Dictionary<int, Vec2> MoveStarts();

    /// <summary>A drag of the selected things: begin, a move per step by the drag's offset from its start, then end.</summary>
    void BeginMove();

    void MoveSelected(IReadOnlyDictionary<int, Vec2> starts, Vec2 offset);

    void EndMove(bool cancel = false);

    void DeleteSelected();
}

public enum CanvasPressKind
{
    /// <summary>Nothing: a click clears the selection, and a drag draws a box.</summary>
    Empty,

    /// <summary>A thing that a click selects and a drag moves.</summary>
    Select,

    /// <summary>A drag of the canvas's own, such as a link from a port, which it follows until the release.</summary>
    Connect,
}

/// <summary>What a press of the left button at a point takes, and the thing that it is on.</summary>
public readonly record struct CanvasPress(CanvasPressKind Kind, int Id = 0);

/// <summary>
/// What the graph editors' canvases do alike (see docs/editor/animation-graph-editor.md#the-canvas): a graph drawn in
/// the canvas's own units under a pan and a zoom, framed when it first has a size. The left button selects (Shift adds,
/// Ctrl toggles), drags what is selected, drags a box, and starts the drags that a canvas has of its own. The right or
/// middle button pans, and a right click without a drag, Space or Tab opens the canvas's add menu. The wheel zooms
/// about the mouse. Delete deletes what is selected, F frames the graph, and Escape cancels a drag.
/// </summary>
public abstract class NodeGraphCanvas : Control
{
    protected const double MinZoom = 0.2;
    protected const double MaxZoom = 2;

    static readonly IBrush BoxFill = new SolidColorBrush(Color.Parse("#22E34234"));
    static readonly IPen BoxPen = new Pen(new SolidColorBrush(Palette.Accent), 1);

    enum Gesture
    {
        None,
        Click,
        Move,
        Box,
        Connect,
        Pan,
        PanClick,
    }

    readonly IGraphCanvasEditor _editor;
    Canvas2DView _view = new(new Vec2(-200, -150), 1);
    Gesture _gesture;
    Point _start;
    Point _last;
    int _pressed;
    Dictionary<int, Vec2> _moveStarts = [];
    bool _framed;

    protected NodeGraphCanvas(IGraphCanvasEditor editor)
    {
        _editor = editor;
        Focusable = true;
        ClipToBounds = true;
    }

    /// <summary>Where the graph's things are now, which framing and a box read.</summary>
    protected abstract IGraphLayout Layout { get; }

    /// <summary>The pan and the zoom.</summary>
    protected Canvas2DView View => _view;

    /// <summary>Whether a drag of the canvas's own is under way.</summary>
    protected bool Connecting => _gesture == Gesture.Connect;

    /// <summary>Whether no button is down.</summary>
    protected bool Idle => _gesture == Gesture.None;

    /// <summary>What a press of the left button at a point of the canvas takes. A Connect starts the canvas's own drag.</summary>
    protected abstract CanvasPress PressAt(Vec2 at, KeyModifiers modifiers);

    /// <summary>The canvas's own drag moved to a point.</summary>
    protected virtual void ConnectMoved(Vec2 at)
    {
    }

    /// <summary>The canvas's own drag ended at a point.</summary>
    protected virtual void EndConnect(Vec2 at)
    {
    }

    /// <summary>The canvas's own drag was cancelled.</summary>
    protected virtual void CancelConnect()
    {
    }

    /// <summary>The mouse moved to a point with no button down, so the canvas can show what a press there would take.</summary>
    protected virtual void Hover(Vec2 at)
    {
    }

    /// <summary>The mouse left the canvas.</summary>
    protected virtual void HoverEnded()
    {
    }

    /// <summary>Draws the graph, in canvas units.</summary>
    protected abstract void DrawGraph(DrawingContext context);

    /// <summary>Opens the menu that adds a node at a point of the canvas.</summary>
    protected abstract void OpenAddMenu(Vec2 at);

    protected override Size ArrangeOverride(Size finalSize)
    {
        var size = base.ArrangeOverride(finalSize);
        // The graph starts framed, once the canvas has a size.
        if (!_framed && finalSize.Width > 0 && finalSize.Height > 0)
        {
            _framed = true;
            Frame(finalSize);
        }
        return size;
    }

    protected Vec2 ToCanvas(Point p) => _view.ToCanvas(p.X, p.Y);

    /// <summary>Pans and zooms so the whole graph is in view.</summary>
    public void Frame() => Frame(Bounds.Size);

    void Frame(Size size)
    {
        if (Layout.Extent() is not { } extent || size.Width <= 0)
        {
            return;
        }
        const double Margin = 40;
        _view = Canvas2DView.Fit(extent, size.Width, size.Height, Margin, MinZoom, 1);
        InvalidateVisual();
    }

    /// <summary>The middle of the view, in canvas units, where a node that the view adds goes.</summary>
    public Vec2 Middle => ToCanvas(new Point(Bounds.Width / 2, Bounds.Height / 2));

    public override void Render(DrawingContext context)
    {
        DrawBackground(context, Bounds.Size, _view);
        using (context.PushTransform(Matrix.CreateTranslation(-_view.Offset.X, -_view.Offset.Y) * Matrix.CreateScale(_view.Zoom, _view.Zoom)))
        {
            DrawGraph(context);
        }
        if (_gesture == Gesture.Box)
        {
            context.DrawRectangle(BoxFill, BoxPen, new Rect(_start, _last).Normalize());
        }
    }

    static SelectMode ModeOf(KeyModifiers modifiers) =>
        modifiers.HasFlag(KeyModifiers.Shift) ? SelectMode.Add : modifiers.HasFlag(KeyModifiers.Control) ? SelectMode.Toggle : SelectMode.Replace;

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        if (_gesture != Gesture.None)
        {
            return;
        }
        Focus();
        var point = e.GetCurrentPoint(this);
        _start = _last = point.Position;
        if (point.Properties.IsRightButtonPressed || point.Properties.IsMiddleButtonPressed)
        {
            _gesture = point.Properties.IsRightButtonPressed ? Gesture.PanClick : Gesture.Pan;
        }
        else if (point.Properties.IsLeftButtonPressed)
        {
            var press = PressAt(ToCanvas(point.Position), e.KeyModifiers);
            switch (press.Kind)
            {
                case CanvasPressKind.Connect:
                    _gesture = Gesture.Connect;
                    break;
                case CanvasPressKind.Select:
                    if (!_editor.Selection.Contains(press.Id) || e.KeyModifiers != KeyModifiers.None)
                    {
                        _editor.Select([press.Id], ModeOf(e.KeyModifiers));
                    }
                    _pressed = press.Id;
                    _gesture = Gesture.Click;
                    break;
                default:
                    _pressed = 0;
                    _gesture = Gesture.Click;
                    break;
            }
        }
        if (_gesture != Gesture.None)
        {
            e.Pointer.Capture(this);
            e.Handled = true;
        }
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        var position = e.GetPosition(this);
        var delta = position - _last;
        _last = position;
        var moved = position - _start;
        var far = Gestures.MovedPast(moved);
        switch (_gesture)
        {
            case Gesture.None:
                Hover(ToCanvas(position));
                break;
            case Gesture.PanClick when far:
                _gesture = Gesture.Pan;
                break;
            case Gesture.Pan:
                _view = _view.Pan(delta.X, delta.Y);
                InvalidateVisual();
                break;
            case Gesture.Click when far:
                if (_pressed != 0)
                {
                    _moveStarts = _editor.MoveStarts();
                    _editor.BeginMove();
                    _gesture = Gesture.Move;
                }
                else
                {
                    _gesture = Gesture.Box;
                }
                break;
            case Gesture.Move:
                _editor.MoveSelected(_moveStarts, _view.ToCanvasDelta(moved.X, moved.Y));
                break;
            case Gesture.Box:
                InvalidateVisual();
                break;
            case Gesture.Connect:
                ConnectMoved(ToCanvas(position));
                InvalidateVisual();
                break;
        }
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);
        var position = e.GetPosition(this);
        var gesture = _gesture;
        // The gesture ends before what it does, so a drag of the canvas's own is over when its end draws.
        _gesture = Gesture.None;
        switch (gesture)
        {
            case Gesture.PanClick:
                OpenAddMenu(ToCanvas(position));
                break;
            case Gesture.Click:
                if (_pressed == 0)
                {
                    _editor.Select([], ModeOf(e.KeyModifiers) == SelectMode.Replace ? SelectMode.Replace : SelectMode.Add);
                }
                else if (e.KeyModifiers == KeyModifiers.None)
                {
                    _editor.Select([_pressed]);
                }
                break;
            case Gesture.Move:
                _editor.EndMove();
                break;
            case Gesture.Box:
                _editor.Select(Layout.InBox(ToCanvas(_start), ToCanvas(position)), ModeOf(e.KeyModifiers));
                break;
            case Gesture.Connect:
                EndConnect(ToCanvas(position));
                break;
        }
        e.Pointer.Capture(null);
        InvalidateVisual();
    }

    protected override void OnPointerExited(PointerEventArgs e)
    {
        base.OnPointerExited(e);
        HoverEnded();
    }

    protected override void OnPointerCaptureLost(PointerCaptureLostEventArgs e)
    {
        base.OnPointerCaptureLost(e);
        switch (_gesture)
        {
            case Gesture.Move:
                _editor.EndMove();
                break;
            case Gesture.Connect:
                CancelConnect();
                break;
        }
        _gesture = Gesture.None;
        InvalidateVisual();
    }

    protected override void OnPointerWheelChanged(PointerWheelEventArgs e)
    {
        base.OnPointerWheelChanged(e);
        var at = e.GetPosition(this);
        _view = _view.ZoomAbout(at.X, at.Y, Math.Pow(Canvas2DView.WheelStep, e.Delta.Y), MinZoom, MaxZoom);
        InvalidateVisual();
        e.Handled = true;
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        switch (e.Key)
        {
            case Key.Delete or Key.Back:
                _editor.DeleteSelected();
                break;
            case Key.F when e.KeyModifiers == KeyModifiers.None:
                Frame();
                break;
            case Key.Space or Key.Tab when e.KeyModifiers == KeyModifiers.None:
                OpenAddMenu(ToCanvas(_last));
                break;
            case Key.Escape when _gesture == Gesture.Move:
                _editor.EndMove(cancel: true);
                _gesture = Gesture.None;
                break;
            case Key.Escape when _gesture == Gesture.Connect:
                CancelConnect();
                _gesture = Gesture.None;
                InvalidateVisual();
                break;
            default:
                return;
        }
        e.Handled = true;
    }
}
