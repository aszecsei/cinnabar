using Cinnabar.Editor.Maths;

namespace Cinnabar.Editor.Tools;

/// <summary>
/// The part of a 2D canvas that a control shows: the canvas point at its top left and the scale from canvas units to
/// control units. Zooming keeps the canvas point under the pointer where it is.
/// </summary>
public readonly record struct Canvas2DView(Vec2 Offset, double Zoom)
{
    /// <summary>The factor of one wheel notch.</summary>
    public const double WheelStep = 1.15;

    /// <summary>The canvas point under a point of the control.</summary>
    public Vec2 ToCanvas(double x, double y) => new(x / Zoom + Offset.X, y / Zoom + Offset.Y);

    /// <summary>The point of the control that shows a canvas point.</summary>
    public Vec2 ToView(Vec2 canvas) => new((canvas.X - Offset.X) * Zoom, (canvas.Y - Offset.Y) * Zoom);

    /// <summary>A distance of dx and dy in the control, in canvas units.</summary>
    public Vec2 ToCanvasDelta(double dx, double dy) => new Vec2(dx, dy) * (1 / Zoom);

    /// <summary>
    /// The view that shows <paramref name="extent"/> in the middle of a control of the given size, with a margin around
    /// it, as large as <paramref name="maxZoom"/> allows and as small as <paramref name="minZoom"/>.
    /// </summary>
    public static Canvas2DView Fit(GraphRect extent, double width, double height, double margin, double minZoom, double maxZoom)
    {
        var zoom = Math.Clamp(Math.Min((width - 2 * margin) / extent.Width, (height - 2 * margin) / extent.Height), minZoom, maxZoom);
        return new Canvas2DView(new Vec2(extent.X + extent.Width / 2 - width / 2 / zoom, extent.Y + extent.Height / 2 - height / 2 / zoom), zoom);
    }

    /// <summary>Moves the view by a drag of dx and dy in the control: the canvas follows the pointer.</summary>
    public Canvas2DView Pan(double dx, double dy) => this with { Offset = Offset - ToCanvasDelta(dx, dy) };

    /// <summary>Scales the zoom by <paramref name="factor"/>, within the limits, about the control's point (x, y).</summary>
    public Canvas2DView ZoomAbout(double x, double y, double factor, double minZoom, double maxZoom)
    {
        var anchor = ToCanvas(x, y);
        var zoom = Math.Clamp(Zoom * factor, minZoom, maxZoom);
        return new Canvas2DView(new Vec2(anchor.X - x / zoom, anchor.Y - y / zoom), zoom);
    }
}
