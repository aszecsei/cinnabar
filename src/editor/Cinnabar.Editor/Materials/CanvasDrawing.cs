using System.Globalization;
using Avalonia;
using Avalonia.Media;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Materials;

/// <summary>What the graph editors' canvases draw alike: the background, the grid and text.</summary>
static class CanvasDrawing
{
    static readonly Typeface Font = new("Inter");
    static readonly IBrush CanvasBrush = new SolidColorBrush(Color.Parse("#1C1C1F"));
    static readonly IPen MinorGrid = new Pen(new SolidColorBrush(Color.Parse("#242428")), 1);
    static readonly IPen MajorGrid = new Pen(new SolidColorBrush(Color.Parse("#2C2C31")), 1);

    public static void DrawBackground(DrawingContext context, Size size, Canvas2DView view)
    {
        context.FillRectangle(CanvasBrush, new Rect(size));
        var step = 20.0;
        var topLeft = view.ToCanvas(0, 0);
        var bottomRight = view.ToCanvas(size.Width, size.Height);
        if (step * view.Zoom < 6)
        {
            step = 100;
        }
        for (var x = Math.Floor(topLeft.X / step) * step; x <= bottomRight.X; x += step)
        {
            var vx = (x - view.Offset.X) * view.Zoom;
            context.DrawLine(Math.Abs(x % 100) < 0.5 ? MajorGrid : MinorGrid, new Point(vx, 0), new Point(vx, size.Height));
        }
        for (var y = Math.Floor(topLeft.Y / step) * step; y <= bottomRight.Y; y += step)
        {
            var vy = (y - view.Offset.Y) * view.Zoom;
            context.DrawLine(Math.Abs(y % 100) < 0.5 ? MajorGrid : MinorGrid, new Point(0, vy), new Point(size.Width, vy));
        }
    }

    public static void DrawText(DrawingContext context, string text, Point at, double size, IBrush brush, double maxWidth, bool bold = false)
    {
        var formatted = new FormattedText(text, CultureInfo.CurrentCulture, FlowDirection.LeftToRight,
            bold ? new Typeface(Font.FontFamily, FontStyle.Normal, FontWeight.SemiBold) : Font, size, brush)
        {
            MaxTextWidth = Math.Max(maxWidth, 1),
            MaxLineCount = 1,
            Trimming = TextTrimming.CharacterEllipsis,
        };
        context.DrawText(formatted, at);
    }

    public static double TextWidth(string text, double size) =>
        new FormattedText(text, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, Font, size, Brushes.White).Width;
}
