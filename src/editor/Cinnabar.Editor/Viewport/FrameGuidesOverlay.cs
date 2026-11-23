using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Viewport;

/// <summary>
/// What the frame guides draw over a viewport's frame (see docs/editor/cutscene-editor.md#frame-guides): the guides, the
/// drawn camera's aspect when the view looks through one, and the line of camera info.
/// </summary>
public sealed record FrameGuideState(FrameGuideSettings Guides, double? CameraAspect, string? Info);

/// <summary>
/// The frame guides over a viewport (see docs/editor/cutscene-editor.md#frame-guides), drawn by the editor over the frame
/// that the game shares, so they are in no capture and cost the game nothing. It lays them out in the frame's pixels with
/// <see cref="FrameGuides"/>, and maps them to the control through the frame's place in it, which a Fit or a 100% scale
/// letterboxes. It takes no input.
/// </summary>
public sealed class FrameGuidesOverlay : Control
{
    static readonly IBrush MaskBrush = new SolidColorBrush(Color.FromArgb(153, 0, 0, 0));
    static readonly IPen FramePen = new Pen(new SolidColorBrush(Color.FromArgb(160, 255, 255, 255)), 1);
    static readonly IPen ActionPen = new Pen(new SolidColorBrush(Color.FromArgb(140, 255, 210, 74)), 1, new DashStyle([4, 3], 0));
    static readonly IPen TitlePen = new Pen(new SolidColorBrush(Color.FromArgb(140, 120, 200, 255)), 1, new DashStyle([4, 3], 0));
    static readonly IPen ThirdsPen = new Pen(new SolidColorBrush(Color.FromArgb(90, 255, 255, 255)), 1);
    static readonly IBrush InfoBrush = new SolidColorBrush(Color.FromArgb(230, 255, 255, 255));
    static readonly IBrush InfoBack = new SolidColorBrush(Color.FromArgb(140, 0, 0, 0));

    readonly ViewportControl _control;
    readonly Func<FrameGuideState> _state;

    public FrameGuidesOverlay(ViewportControl control, Func<FrameGuideState> state)
    {
        _control = control;
        _state = state;
        IsHitTestVisible = false;
    }

    public override void Render(DrawingContext context)
    {
        var state = _state();
        if (!state.Guides.Any || _control.Session is not { FrameSize: { Width: > 0, Height: > 0 } size })
        {
            return;
        }
        Rect? ToControl(FrameRect r) =>
            _control.ControlPoint(new Vec2(r.X, r.Y)) is { } a && _control.ControlPoint(new Vec2(r.Right, r.Bottom)) is { } b ? new Rect(a, b) : null;
        var guides = state.Guides;
        var framed = FrameGuides.Fit(size.Width, size.Height, FrameGuides.AspectOf(guides.Aspect, guides.Custom, state.CameraAspect));
        if (guides.Mask)
        {
            foreach (var bar in FrameGuides.Bars(size.Width, size.Height, framed))
            {
                if (ToControl(bar) is { } r)
                {
                    context.FillRectangle(MaskBrush, r);
                }
            }
            if (ToControl(framed) is { } edge)
            {
                context.DrawRectangle(FramePen, edge);
            }
        }
        if (guides.Safe)
        {
            if (ToControl(FrameGuides.Inset(framed, FrameGuides.ActionSafe)) is { } action)
            {
                context.DrawRectangle(ActionPen, action);
            }
            if (ToControl(FrameGuides.Inset(framed, FrameGuides.TitleSafe)) is { } title)
            {
                context.DrawRectangle(TitlePen, title);
            }
        }
        if (guides.Thirds && ToControl(framed) is { } area)
        {
            var (xs, ys) = FrameGuides.Thirds(framed);
            foreach (var x in xs)
            {
                if (_control.ControlPoint(new Vec2(x, framed.Y)) is { } top)
                {
                    context.DrawLine(ThirdsPen, new Point(top.X, area.Top), new Point(top.X, area.Bottom));
                }
            }
            foreach (var y in ys)
            {
                if (_control.ControlPoint(new Vec2(framed.X, y)) is { } left)
                {
                    context.DrawLine(ThirdsPen, new Point(area.Left, left.Y), new Point(area.Right, left.Y));
                }
            }
            var centre = area.Center;
            context.DrawLine(ThirdsPen, centre - new Point(6, 0), centre + new Point(6, 0));
            context.DrawLine(ThirdsPen, centre - new Point(0, 6), centre + new Point(0, 6));
        }
        if (guides.CameraInfo && !string.IsNullOrEmpty(state.Info) && ToControl(framed) is { } shot)
        {
            var text = new FormattedText(state.Info, System.Globalization.CultureInfo.InvariantCulture, FlowDirection.LeftToRight, Typeface.Default, 12, InfoBrush);
            // Under the toolbar, at the framed shot's top left.
            var at = new Point(shot.Left + 8, Math.Max(shot.Top, 0) + 40);
            context.FillRectangle(InfoBack, new Rect(at.X - 4, at.Y - 2, text.Width + 8, text.Height + 4), 3);
            context.DrawText(text, at);
        }
    }
}
