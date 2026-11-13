using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using static Cinnabar.Editor.Materials.CanvasDrawing;

namespace Cinnabar.Editor.Decisions;

/// <summary>
/// A consideration's response curve in a small graph (see docs/editor/decision-editor.md#utility): the input from 0 to
/// 1 across, labeled with its range, and the score up. A drag of a handle changes the fields that it stands for, in one
/// undo entry, and Escape puts them back; a double click on a table adds a point, and a right click on one removes it.
/// The live view puts a dot where the agent's input last was on the curve.
/// </summary>
sealed class CurveGraph : Control
{
    const double Pad = 14;
    const double HandleRadius = 5;
    const int Samples = 96;

    static readonly IBrush Body = new SolidColorBrush(Color.Parse("#202024"));
    static readonly IPen GridPen = new Pen(new SolidColorBrush(Color.Parse("#2E2E34")), 1);
    static readonly IPen AxisPen = new Pen(new SolidColorBrush(Color.Parse("#4A4A52")), 1);
    static readonly IPen CurvePen = new Pen(new SolidColorBrush(Color.Parse("#8FA9C7")), 2);
    static readonly IBrush HandleBrush = new SolidColorBrush(Color.Parse("#E4E4E8"));
    static readonly IBrush HotBrush = new SolidColorBrush(Palette.Accent);
    static readonly IBrush LiveBrush = new SolidColorBrush(Color.Parse("#5BC47F"));
    static readonly IBrush LabelBrush = new SolidColorBrush(Color.Parse("#8A8A92"));

    readonly DecisionEditor _editor;
    readonly int _node;
    // A drag of a handle, from the curve as it was when it began.
    (CurveHandle Handle, ResponseCurve Start)? _drag;
    CurveHandle? _hot;

    public CurveGraph(DecisionEditor editor, int node)
    {
        _editor = editor;
        _node = node;
        Width = 220;
        Height = 120;
        Focusable = true;
    }

    /// <summary>The agent's input, from 0 to 1, and its score, as the live view last had them, or null.</summary>
    public (double Input, double Score)? Live { get; set; }

    ResponseCurve? Curve => _editor.Document.Graph.Find(_node) is { } node ? ResponseCurve.Of(node) : null;

    Rect Plot => new(Pad, 4, Math.Max(1, Bounds.Width - Pad - 6), Math.Max(1, Bounds.Height - Pad - 4));

    Point ToScreen(double x, double y)
    {
        var p = Plot;
        return new Point(p.X + Math.Clamp(x, 0, 1) * p.Width, p.Bottom - Math.Clamp(y, 0, 1) * p.Height);
    }

    Vec2 ToCurve(Point at)
    {
        var p = Plot;
        return new Vec2((at.X - p.X) / p.Width, (p.Bottom - at.Y) / p.Height);
    }

    public override void Render(DrawingContext context)
    {
        var plot = Plot;
        context.FillRectangle(Body, new Rect(Bounds.Size));
        for (var i = 1; i < 4; i++)
        {
            var x = plot.X + plot.Width * i / 4;
            var y = plot.Y + plot.Height * i / 4;
            context.DrawLine(GridPen, new Point(x, plot.Y), new Point(x, plot.Bottom));
            context.DrawLine(GridPen, new Point(plot.X, y), new Point(plot.Right, y));
        }
        context.DrawRectangle(null, AxisPen, plot);
        if (Curve is not { } curve)
        {
            return;
        }
        var line = new StreamGeometry();
        using (var g = line.Open())
        {
            for (var i = 0; i <= Samples; i++)
            {
                var x = (double)i / Samples;
                var at = ToScreen(x, curve.Evaluate(x));
                if (i == 0)
                {
                    g.BeginFigure(at, false);
                }
                else
                {
                    g.LineTo(at);
                }
            }
            g.EndFigure(false);
        }
        context.DrawGeometry(null, CurvePen, line);
        foreach (var handle in curve.Handles())
        {
            var hot = _drag?.Handle == handle || _hot == handle;
            context.DrawEllipse(hot ? HotBrush : HandleBrush, null, ToScreen(handle.At.X, handle.At.Y), HandleRadius - 1, HandleRadius - 1);
        }
        if (Live is { } live)
        {
            context.DrawEllipse(LiveBrush, null, ToScreen(live.Input, live.Score), 5, 5);
        }
        if (_editor.Document.Graph.Find(_node) is { } node)
        {
            var (min, max) = ResponseCurve.RangeOf(node);
            DrawText(context, ResponseCurve.Write(min), new Point(plot.X, plot.Bottom + 1), 9, LabelBrush, 60);
            var high = ResponseCurve.Write(max);
            DrawText(context, high, new Point(plot.Right - TextWidth(high, 9), plot.Bottom + 1), 9, LabelBrush, 60);
        }
    }

    CurveHandle? HandleAt(Point at)
    {
        if (Curve is not { } curve)
        {
            return null;
        }
        foreach (var handle in curve.Handles().Reverse())
        {
            var p = ToScreen(handle.At.X, handle.At.Y);
            if (Math.Abs(p.X - at.X) <= HandleRadius + 2 && Math.Abs(p.Y - at.Y) <= HandleRadius + 2)
            {
                return handle;
            }
        }
        return null;
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        var at = e.GetPosition(this);
        var point = e.GetCurrentPoint(this);
        _editor.Select([_node]);
        Focus();
        if (Curve is not { } curve)
        {
            return;
        }
        var handle = HandleAt(at);
        if (point.Properties.IsRightButtonPressed)
        {
            if (handle is { Kind: CurveHandleKind.Point } p && curve.RemovePoint(p.Index) is { } fewer)
            {
                _editor.SetField(_node, "points", fewer);
            }
            e.Handled = true;
            return;
        }
        if (!point.Properties.IsLeftButtonPressed)
        {
            return;
        }
        if (e.ClickCount == 2 && curve.Kind == "table" && handle == null)
        {
            if (curve.AddPoint(ToCurve(at).X) is { } more)
            {
                _editor.SetField(_node, "points", more);
            }
            e.Handled = true;
            return;
        }
        // A drag is this graph's only when it opens its own entry.
        if (handle is { } h && _editor.BeginFieldDrag(h.Kind == CurveHandleKind.Point ? "Move Point" : $"Drag {h.Kind}"))
        {
            _drag = (h, curve);
            e.Pointer.Capture(this);
            e.Handled = true;
            InvalidateVisual();
        }
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        var at = e.GetPosition(this);
        if (_drag is { } drag)
        {
            _editor.DragFields(_node, drag.Start.Drag(drag.Handle, ToCurve(at)));
            InvalidateVisual();
            return;
        }
        var hot = HandleAt(at);
        if (hot != _hot)
        {
            _hot = hot;
            Cursor = hot != null ? new Cursor(StandardCursorType.Hand) : Cursor.Default;
            InvalidateVisual();
        }
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);
        if (_drag != null)
        {
            _drag = null;
            _editor.EndFieldDrag();
            e.Pointer.Capture(null);
            InvalidateVisual();
        }
    }

    protected override void OnPointerCaptureLost(PointerCaptureLostEventArgs e)
    {
        base.OnPointerCaptureLost(e);
        if (_drag != null)
        {
            _drag = null;
            _editor.EndFieldDrag();
        }
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (e.Key == Key.Escape && _drag != null)
        {
            _drag = null;
            _editor.EndFieldDrag(cancel: true);
            InvalidateVisual();
            e.Handled = true;
        }
    }

    protected override void OnPointerExited(PointerEventArgs e)
    {
        base.OnPointerExited(e);
        if (_hot != null)
        {
            _hot = null;
            InvalidateVisual();
        }
    }
}
