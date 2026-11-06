using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using Cinnabar.Editor.Viewport;

namespace Cinnabar.Editor.UiDocuments;

/// <summary>
/// The UI editor's canvas (see docs/editor/ui-editor.md#the-canvas): the game's drawing of the document on its screen,
/// with the selected element's rectangle, padding and clip outlined over it. A click picks the topmost element, the
/// middle or right button pans, the wheel zooms about the pointer, and F fits the screen.
/// </summary>
sealed class UiCanvas : Grid
{
    readonly EditorShell _shell;
    readonly UiEditor _editor;
    readonly ViewportControl? _viewport;
    readonly Overlay _overlay;
    readonly TextBlock _message = new() { Classes = { "empty" }, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(12) };

    public UiCanvas(EditorShell shell, UiEditor editor)
    {
        _shell = shell;
        _editor = editor;
        Background = new SolidColorBrush(Color.Parse("#141416"));
        ClipToBounds = true;
        Children.Add(_message);
        if (editor.Preview is not { } session)
        {
            _message.Text = $"Every one of the {EditorShell.MaxPreviews} previews is in use. Close another to see this document.";
            _overlay = new Overlay(this);
            return;
        }
        _viewport = new ViewportControl { Session = session };
        Children.Add(_viewport);
        _overlay = new Overlay(this);
        Children.Add(_overlay);
        var timer = new Avalonia.Threading.DispatcherTimer(TimeSpan.FromMilliseconds(250), Avalonia.Threading.DispatcherPriority.Background, (_, _) => ShowMessage());
        new ViewSubscriptions(this, attached: ShowMessage)
            .Add(timer.Start, timer.Stop)
            .Add(() => _editor.ViewChanged += _overlay.InvalidateVisual, () => _editor.ViewChanged -= _overlay.InvalidateVisual)
            .Add(() => _editor.SelectionChanged += Selected, () => _editor.SelectionChanged -= Selected)
            .Add(() => _editor.Changed += _overlay.InvalidateVisual, () => _editor.Changed -= _overlay.InvalidateVisual);
    }

    void Selected()
    {
        ShowMessage();
        _overlay.InvalidateVisual();
    }

    void ShowMessage()
    {
        if (_editor.Preview is not { } session)
        {
            return;
        }
        string? text = null;
        if (!_shell.Host.Linked)
        {
            text = "The canvas needs the host.";
        }
        else if (!session.HasPicture)
        {
            text = _editor.Waiting;
        }
        _message.Text = text ?? "";
        _message.IsVisible = text != null;
        _overlay.Note = _editor.Selected is { InTemplate: true } ? "A template does not draw: scripts copy it with Ui.add." : null;
    }

    // A point of the canvas in pixels of the preview, or null before the first frame.
    Vec2? Frame(Point p) => _viewport?.FramePoint(p);

    double FrameScale => _viewport?.FrameScale ?? 1;

    // A point of the screen on the canvas.
    Point? OnCanvas(double x, double y)
    {
        var (fx, fy) = _editor.ToPreview(x, y);
        return _viewport?.ControlPoint(new Vec2(fx, fy));
    }

    Rect? OnCanvas(UiRect r) =>
        OnCanvas(r.X0, r.Y0) is { } a && OnCanvas(r.X1, r.Y1) is { } b ? new Rect(a, b) : null;

    /// <summary>The outlines and the input, over the game's drawing.</summary>
    sealed class Overlay : Control
    {
        static readonly IPen SelectedPen = new Pen(new SolidColorBrush(Palette.Accent), 1.5);
        static readonly IPen ContentPen = new Pen(new SolidColorBrush(Color.FromArgb(0xc0, 0x4a, 0xa8, 0xe8)), 1, new DashStyle([3, 3], 0));
        static readonly IPen ClipPen = new Pen(new SolidColorBrush(Color.FromArgb(0xc0, 0xe8, 0xb0, 0x4a)), 1, new DashStyle([6, 3], 0));
        static readonly IPen HoverPen = new Pen(new SolidColorBrush(Color.FromArgb(0x90, 0xff, 0xff, 0xff)), 1);
        static readonly IPen ErrorPen = new Pen(new SolidColorBrush(Palette.Error), 1.5, new DashStyle([3, 2], 0));
        static readonly IBrush PaddingBrush = new SolidColorBrush(Color.FromArgb(0x30, 0x4a, 0xa8, 0xe8));
        static readonly IBrush NoteBrush = new SolidColorBrush(Color.FromArgb(0xd0, 0x20, 0x20, 0x24));

        readonly UiCanvas _canvas;
        int? _hovered;
        Point _press;
        Point _last;
        bool _panning;
        bool _clicking;

        public Overlay(UiCanvas canvas)
        {
            _canvas = canvas;
            Focusable = true;
            ClipToBounds = true;
        }

        public string? Note
        {
            get;
            set
            {
                field = value;
                InvalidateVisual();
            }
        }

        UiEditor Editor => _canvas._editor;

        public override void Render(DrawingContext context)
        {
            // Transparent, so the overlay takes the pointer over the whole canvas.
            context.FillRectangle(Brushes.Transparent, new Rect(Bounds.Size));
            if (Editor.LayoutCurrent)
            {
                foreach (var p in Editor.Problems)
                {
                    if (p.Node is { } n && Editor.BoxOf(n) is { Shown: true } b && _canvas.OnCanvas(b.Rect) is { } r)
                    {
                        context.DrawRectangle(null, ErrorPen, r);
                    }
                }
                if (_hovered is { } hovered && hovered != Editor.SelectedNode && Editor.BoxOf(hovered) is { Shown: true } h && _canvas.OnCanvas(h.Rect) is { } hr)
                {
                    context.DrawRectangle(null, HoverPen, hr);
                }
                if (Editor.SelectedNode is { } selected && Editor.BoxOf(selected) is { Shown: true } box)
                {
                    DrawSelected(context, box);
                }
            }
            if (Note is { } note)
            {
                var text = new FormattedText(note, System.Globalization.CultureInfo.CurrentCulture, FlowDirection.LeftToRight, Typeface.Default, 12, Brushes.White);
                var at = new Rect(8, Bounds.Height - text.Height - 16, text.Width + 16, text.Height + 8);
                context.FillRectangle(NoteBrush, at, 3);
                context.DrawText(text, new Point(at.X + 8, at.Y + 4));
            }
        }

        void DrawSelected(DrawingContext context, UiBox box)
        {
            if (_canvas.OnCanvas(box.Rect) is not { } rect)
            {
                return;
            }
            // The padding is the band between the rectangle and its content.
            if (_canvas.OnCanvas(box.Content) is { } content && content != rect)
            {
                using (context.PushGeometryClip(new RectangleGeometry(rect)))
                {
                    var outer = new RectangleGeometry(rect);
                    var inner = new RectangleGeometry(content);
                    context.DrawGeometry(PaddingBrush, null, new CombinedGeometry(GeometryCombineMode.Exclude, outer, inner));
                }
                context.DrawRectangle(null, ContentPen, content);
            }
            var screen = new UiRect(0, 0, Editor.Screen.Width, Editor.Screen.Height);
            if (box.Clip != screen && _canvas.OnCanvas(box.Clip) is { } clip)
            {
                context.DrawRectangle(null, ClipPen, clip);
            }
            context.DrawRectangle(null, SelectedPen, rect);
        }

        int? PickAt(Point p)
        {
            if (_canvas.Frame(p) is not { } frame)
            {
                return null;
            }
            var (x, y) = Editor.ToScreen(frame.X, frame.Y);
            return Editor.Pick(x, y);
        }

        protected override void OnPointerPressed(PointerPressedEventArgs e)
        {
            base.OnPointerPressed(e);
            Focus();
            var point = e.GetCurrentPoint(this);
            _press = _last = e.GetPosition(this);
            if (point.Properties.IsLeftButtonPressed)
            {
                _clicking = true;
            }
            else if (point.Properties.IsMiddleButtonPressed || point.Properties.IsRightButtonPressed)
            {
                _panning = true;
                e.Pointer.Capture(this);
            }
            e.Handled = true;
        }

        protected override void OnPointerMoved(PointerEventArgs e)
        {
            base.OnPointerMoved(e);
            var position = e.GetPosition(this);
            if (_panning)
            {
                var delta = (position - _last) * _canvas.FrameScale;
                _last = position;
                Editor.Pan(delta.X, delta.Y);
                return;
            }
            if (_clicking && Gestures.MovedPast(position - _press))
            {
                _clicking = false;
            }
            var hovered = PickAt(position);
            if (hovered != _hovered)
            {
                _hovered = hovered;
                InvalidateVisual();
            }
        }

        protected override void OnPointerReleased(PointerReleasedEventArgs e)
        {
            base.OnPointerReleased(e);
            if (_clicking)
            {
                Editor.Select(PickAt(e.GetPosition(this)));
            }
            _clicking = false;
            _panning = false;
            e.Pointer.Capture(null);
        }

        protected override void OnPointerExited(PointerEventArgs e)
        {
            base.OnPointerExited(e);
            _hovered = null;
            InvalidateVisual();
        }

        protected override void OnPointerWheelChanged(PointerWheelEventArgs e)
        {
            base.OnPointerWheelChanged(e);
            if (_canvas.Frame(e.GetPosition(this)) is { } about)
            {
                Editor.ZoomView(Editor.ViewScale * Math.Pow(Canvas2DView.WheelStep, e.Delta.Y), about.X, about.Y);
            }
            e.Handled = true;
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            base.OnKeyDown(e);
            switch (e.Key)
            {
                case Key.F:
                    Editor.Fit();
                    break;
                case Key.Escape:
                    Editor.Select(null);
                    break;
                case Key.Delete when Editor.SelectedNode is { } n:
                    Editor.Delete(n);
                    break;
                case Key.D when e.KeyModifiers == KeyModifiers.Control && Editor.SelectedNode is { } n:
                    Editor.Duplicate(n);
                    break;
                default:
                    return;
            }
            e.Handled = true;
        }
    }
}
