using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Rendering;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Viewport;

/// <summary>
/// The view gizmo in a scene view's corner (see docs/editor/viewport.md#view-gizmo): the world's axes as the view's
/// camera sees them, with a handle at each end that turns the view to look from there, a square in the middle that
/// switches between orthographic and perspective, and under them the view's name and projection, which switch it too.
/// Only the left button acts on it: the wheel and the other buttons pass to the viewport, so the camera's controls work
/// over it.
/// </summary>
public sealed class ViewGizmoControl : Control, ICustomHitTest
{
    // The disc's side and the distance from its middle to a handle, in pixels of the window.
    const double Disc = 96;
    const double Radius = 34;
    const double LabelHeight = 18;

    static readonly Typeface Face = new("Inter", FontStyle.Normal, FontWeight.SemiBold);
    static readonly Color[] AxisColors = [Palette.AxisX, Palette.AxisY, Palette.AxisZ];
    static readonly string[] Letters = ["X", "Y", "Z"];
    static readonly IBrush Backdrop = new SolidColorBrush(Color.FromArgb(0x30, 0x20, 0x20, 0x24));
    static readonly IBrush HoverBackdrop = new SolidColorBrush(Color.FromArgb(0x80, 0x20, 0x20, 0x24));
    static readonly IBrush LabelBrush = new SolidColorBrush(Color.FromArgb(0xd0, 0xff, 0xff, 0xff));
    static readonly IBrush CenterBrush = new SolidColorBrush(Color.FromArgb(0xe0, 0xcc, 0xcc, 0xcc));
    static readonly IPen CenterPen = new Pen(CenterBrush, 1.5);
    static readonly IPen HotPen = new Pen(Brushes.White, 1.5);

    readonly EditorShell _shell;
    readonly EditorViewport _viewport;
    ViewGizmoPart _hot;
    bool _labelHot;
    bool _over;

    public ViewGizmoControl(EditorShell shell, EditorViewport viewport)
    {
        _shell = shell;
        _viewport = viewport;
        Width = Disc;
        Height = Disc + LabelHeight;
        AttachedToVisualTree += (_, _) => _viewport.Camera.Changed += InvalidateVisual;
        DetachedFromVisualTree += (_, _) => _viewport.Camera.Changed -= InvalidateVisual;
    }

    EditorCamera Camera => _viewport.Camera;

    // The whole square takes the mouse, drawn on or not; a press that misses every part goes on to the viewport.
    public bool HitTest(Point point) => new Rect(Bounds.Size).Contains(point);

    static Point Middle => new(Disc / 2, Disc / 2);

    Rect LabelRect => new(0, Disc, Disc, LabelHeight);

    ViewGizmoPart PartAt(Point point) =>
        ViewGizmo.Hit(ViewGizmo.Layout(Camera.Rotation, Radius), new Vec2(point.X - Middle.X, point.Y - Middle.Y), Radius);

    public override void Render(DrawingContext context)
    {
        var middle = Middle;
        context.DrawEllipse(_over ? HoverBackdrop : Backdrop, null, middle, Disc / 2, Disc / 2);
        foreach (var handle in ViewGizmo.Layout(Camera.Rotation, Radius))
        {
            var color = AxisColors[handle.Axis];
            // A handle that points away is dimmer, so the near ones read first.
            var fade = 1 - 0.35 * Math.Max(handle.Depth, 0);
            var at = new Point(middle.X + handle.Offset.X, middle.Y + handle.Offset.Y);
            var hot = handle.Part == _hot;
            if (handle.Positive)
            {
                var brush = new SolidColorBrush(color, fade);
                context.DrawLine(new Pen(brush, 2), middle, at);
                context.DrawEllipse(brush, hot ? HotPen : null, at, ViewGizmo.PositiveHandle * Radius, ViewGizmo.PositiveHandle * Radius);
                var letter = new FormattedText(Letters[handle.Axis], CultureInfo.InvariantCulture, FlowDirection.LeftToRight, Face, 10, Brushes.White);
                context.DrawText(letter, new Point(at.X - letter.Width / 2, at.Y - letter.Height / 2));
            }
            else
            {
                var r = ViewGizmo.NegativeHandle * Radius;
                context.DrawEllipse(new SolidColorBrush(color, 0.35 * fade), hot ? HotPen : new Pen(new SolidColorBrush(color, fade), 1), at, r, r);
            }
        }
        // The middle is drawn over the handles, and takes the mouse first: filled for orthographic, an outline for perspective.
        var half = ViewGizmo.CenterHalf * Radius;
        var square = new Rect(middle.X - half, middle.Y - half, 2 * half, 2 * half);
        context.DrawRectangle(Camera.IsOrthographic ? CenterBrush : null, _hot == ViewGizmoPart.Center ? HotPen : CenterPen, square);

        var label = new FormattedText(ViewGizmo.Label(Camera), CultureInfo.InvariantCulture, FlowDirection.LeftToRight, Face, 11, _labelHot ? Brushes.White : LabelBrush);
        if (_labelHot)
        {
            context.DrawRectangle(HoverBackdrop, null, LabelRect, 3, 3);
        }
        context.DrawText(label, new Point((Disc - label.Width) / 2, Disc + (LabelHeight - label.Height) / 2));
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        Hover(e.GetPosition(this));
    }

    protected override void OnPointerExited(PointerEventArgs e)
    {
        base.OnPointerExited(e);
        _over = false;
        SetHot(ViewGizmoPart.None, label: false);
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        var point = e.GetCurrentPoint(this);
        if (!point.Properties.IsLeftButtonPressed || e.KeyModifiers != KeyModifiers.None)
        {
            return;
        }
        var part = PartAt(point.Position);
        var onLabel = LabelRect.Contains(point.Position);
        if (part == ViewGizmoPart.None && !onLabel)
        {
            return;
        }
        // The gizmo acts on its own view, which becomes the one that the tools and the View tab act on.
        _shell.ActivateViewport(_viewport);
        if (ViewGizmo.AxisOf(part) is { } axis)
        {
            _shell.LookAlong(_viewport, axis);
        }
        else
        {
            _shell.ToggleProjection(_viewport);
        }
        e.Handled = true;
    }

    void Hover(Point position)
    {
        _over = new Rect(0, 0, Disc, Disc).Contains(position) || LabelRect.Contains(position);
        SetHot(PartAt(position), LabelRect.Contains(position));
    }

    void SetHot(ViewGizmoPart part, bool label)
    {
        if (part == _hot && label == _labelHot)
        {
            InvalidateVisual();
            return;
        }
        _hot = part;
        _labelHot = label;
        Cursor = part != ViewGizmoPart.None || label ? new Cursor(StandardCursorType.Hand) : Cursor.Default;
        ToolTip.SetTip(this, part switch
        {
            ViewGizmoPart.None when label => "Switch between orthographic and perspective",
            ViewGizmoPart.None => null,
            ViewGizmoPart.Center => "Switch between orthographic and perspective",
            _ => $"{ViewGizmo.AxisOf(part)}: look along {Direction(ViewGizmo.AxisOf(part)!.Value)}",
        });
        InvalidateVisual();
    }

    static string Direction(ViewAxis axis) => ViewGizmo.Direction(axis) switch
    {
        { X: > 0 } => "+X",
        { X: < 0 } => "−X",
        { Y: > 0 } => "+Y",
        { Y: < 0 } => "−Y",
        { Z: > 0 } => "+Z",
        _ => "−Z",
    };
}
