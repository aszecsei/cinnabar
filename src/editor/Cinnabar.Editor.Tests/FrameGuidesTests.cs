using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Tests;

/// <summary>The frame guides' rectangles and the lens's field of view (see docs/editor/cutscene-editor.md#frame-guides).</summary>
public class FrameGuidesTests
{
    // Each choice on a 1920 × 1080 frame: a wider aspect has bars above and below, a narrower one at the sides.
    [Theory]
    [InlineData(GuideAspect.Scope, 0, 138.32635983, 1920, 803.34728033)]
    [InlineData(GuideAspect.Academy, 240, 0, 1440, 1080)]
    public void EachAspectFramesTheLargestCentredRectangleOfA1080pFrame(GuideAspect aspect, double x, double y, double w, double h)
    {
        var r = FrameGuides.Fit(1920, 1080, FrameGuides.AspectOf(aspect, 2, null));
        Assert.Equal(x, r.X, 6);
        Assert.Equal(y, r.Y, 6);
        Assert.Equal(w, r.Width, 6);
        Assert.Equal(h, r.Height, 6);
    }

    [Fact]
    public void OnA43FrameTheWideAspectsHaveBarsAboveAndBelow()
    {
        var wide = FrameGuides.Fit(1024, 768, FrameGuides.AspectOf(GuideAspect.Wide, 2, null));
        Assert.Equal(new FrameRect(0, 96, 1024, 576), wide);
        var academy = FrameGuides.Fit(1024, 768, FrameGuides.AspectOf(GuideAspect.Academy, 2, null));
        Assert.Equal(new FrameRect(0, 0, 1024, 768), academy);
        Assert.Empty(FrameGuides.Bars(1024, 768, academy));
        Assert.Equal([new FrameRect(0, 0, 1024, 96), new FrameRect(0, 672, 1024, 96)], FrameGuides.Bars(1024, 768, wide));
    }

    // The runtime's cases (lib/engine/render/lens_test.odin): 2 × atan(sensor height / (2 × focal length)).
    [Theory]
    [InlineData(18, 24)]
    [InlineData(50, 18.66)]
    [InlineData(200, 13.365)]
    public void TheLensFieldOfViewMatchesTheRuntimeAndTurnsBackIntoItsFocalLength(double focal, double sensor)
    {
        var fov = Lens.VerticalFov(focal, sensor);
        Assert.Equal(2 * Math.Atan(sensor / (2 * focal)), fov, 12);
        Assert.Equal(focal, Lens.FocalLength(fov, sensor), 9);
    }

    [Fact]
    public void AZeroLensIsA35mmLensOnAFullFrameSensor()
    {
        Assert.Equal(2 * Math.Atan(24.0 / 70), Lens.VerticalFov(0, 0), 12);
        // The editor camera's 60° on the default sensor is about a 20.8 mm lens.
        Assert.Equal(20.78, Lens.FocalLength(Math.PI / 3, 0), 2);
    }
}
