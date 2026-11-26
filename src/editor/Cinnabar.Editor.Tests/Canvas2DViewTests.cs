using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Tests;

/// <summary>The 2D canvas's view without a control: the maps between canvas and control, framing, panning and zooming.</summary>
public sealed class Canvas2DViewTests
{
    static void Near(Vec2 expected, Vec2 actual)
    {
        Assert.Equal(expected.X, actual.X, 9);
        Assert.Equal(expected.Y, actual.Y, 9);
    }

    [Fact]
    public void CanvasAndControlPointsMapBothWaysAndADistanceScalesByTheZoom()
    {
        var view = new Canvas2DView(new Vec2(-200, -150), 2);

        // The top left of the control shows the offset, and each control unit is half a canvas unit.
        Near(new Vec2(-200, -150), view.ToCanvas(0, 0));
        Near(new Vec2(-150, -100), view.ToCanvas(100, 100));
        Near(new Vec2(100, 100), view.ToView(new Vec2(-150, -100)));
        Near(new Vec2(37, 12), view.ToView(view.ToCanvas(37, 12)));
        Near(new Vec2(20, 40), new Canvas2DView(new Vec2(5, 5), 0.5).ToCanvasDelta(10, 20));
    }

    [Fact]
    public void PanningMovesTheCanvasWithThePointer()
    {
        var view = new Canvas2DView(new Vec2(10, 20), 2);
        var panned = view.Pan(8, -4);

        // A drag right and up shows canvas that lies left and down, and the point under the pointer follows it.
        Near(new Vec2(6, 22), panned.Offset);
        Assert.Equal(2, panned.Zoom);
        Near(view.ToCanvas(30, 30), panned.ToCanvas(38, 26));
    }

    [Fact]
    public void ZoomingKeepsThePointUnderThePointerAndStopsAtItsLimits()
    {
        var view = new Canvas2DView(new Vec2(-200, -150), 1);
        var zoomed = view.ZoomAbout(120, 80, Math.Pow(Canvas2DView.WheelStep, 3), 0.2, 2);
        Assert.Equal(Math.Pow(Canvas2DView.WheelStep, 3), zoomed.Zoom, 9);
        Near(view.ToCanvas(120, 80), zoomed.ToCanvas(120, 80));

        var near = new Canvas2DView(new Vec2(0, 0), 1.9);
        var closest = near.ZoomAbout(50, 50, 10, 0.2, 2);
        Assert.Equal(2, closest.Zoom);
        Near(near.ToCanvas(50, 50), closest.ToCanvas(50, 50));
        Assert.Equal(0.2, near.ZoomAbout(50, 50, 0.001, 0.2, 2).Zoom);
    }

    [Fact]
    public void FittingCentersTheExtentAtTheTighterSidesZoomWithinTheLimits()
    {
        // The width is the tighter fit: (520 - 80) / 400 = 1.1, and the zoom stops at 1.
        var view = Canvas2DView.Fit(new GraphRect(100, 50, 400, 200), 520, 360, 40, 0.2, 1);
        Assert.Equal(1, view.Zoom);
        Near(new Vec2(260, 180), view.ToView(new Vec2(300, 150)));

        // (540 - 40) / 1000 = 0.5 along the width.
        view = Canvas2DView.Fit(new GraphRect(0, 0, 1000, 100), 540, 400, 20, 0.2, 1);
        Assert.Equal(0.5, view.Zoom, 9);
        Near(new Vec2(270, 200), view.ToView(new Vec2(500, 50)));

        Assert.Equal(0.2, Canvas2DView.Fit(new GraphRect(0, 0, 100_000, 100_000), 400, 300, 40, 0.2, 1).Zoom);
    }
}
