namespace Cinnabar.Editor.Tools;

/// <summary>The aspect that a view's mask frames (see docs/editor/cutscene-editor.md#frame-guides).</summary>
public enum GuideAspect
{
    /// <summary>The drawn camera's sensor's, which the presentation track's letterbox uses too: 16:9 without one.</summary>
    Camera,
    /// <summary>2.39:1, the anamorphic widescreen.</summary>
    Scope,
    /// <summary>1.85:1, the flat widescreen.</summary>
    Flat,
    /// <summary>16:9.</summary>
    Wide,
    /// <summary>4:3.</summary>
    Academy,
    /// <summary>The view's own value.</summary>
    Custom,
}

/// <summary>
/// The guides that the editor draws over one view's frame (see docs/editor/cutscene-editor.md#frame-guides): a mask outside
/// an aspect, the action and title safe areas, a rule-of-thirds grid with a centre mark, and the camera's name and lens.
/// Each user's, per view.
/// </summary>
public sealed record FrameGuideSettings(
    bool Mask = false,
    GuideAspect Aspect = GuideAspect.Camera,
    double Custom = 2.0,
    bool Safe = false,
    bool Thirds = false,
    bool CameraInfo = false)
{
    /// <summary>Whether any guide is drawn.</summary>
    public bool Any => Mask || Safe || Thirds || CameraInfo;
}

/// <summary>A rectangle of a frame, in its pixels from its top left.</summary>
public readonly record struct FrameRect(double X, double Y, double Width, double Height)
{
    public double Right => X + Width;

    public double Bottom => Y + Height;
}

/// <summary>The rectangles and lines of the frame guides, in a frame's pixels: the pure part, which tests call.</summary>
public static class FrameGuides
{
    /// <summary>The action safe area's share of the framed width and height.</summary>
    public const double ActionSafe = 0.93;

    /// <summary>The title safe area's share of the framed width and height.</summary>
    public const double TitleSafe = 0.90;

    /// <summary>The lowest and highest custom aspect.</summary>
    public const double MinAspect = 1;

    public const double MaxAspect = 4;

    /// <summary>The aspect that a choice names, as width over height. <paramref name="camera"/> is the drawn camera's, or null without one.</summary>
    public static double AspectOf(GuideAspect aspect, double custom, double? camera) => aspect switch
    {
        GuideAspect.Camera => camera is > 0 and var a ? a : 16.0 / 9,
        GuideAspect.Scope => 2.39,
        GuideAspect.Flat => 1.85,
        GuideAspect.Wide => 16.0 / 9,
        GuideAspect.Academy => 4.0 / 3,
        _ => Math.Clamp(custom, MinAspect, MaxAspect),
    };

    /// <summary>The label of a choice, as the menu shows it.</summary>
    public static string Label(GuideAspect aspect) => aspect switch
    {
        GuideAspect.Camera => "Camera",
        GuideAspect.Scope => "2.39:1",
        GuideAspect.Flat => "1.85:1",
        GuideAspect.Wide => "16:9",
        GuideAspect.Academy => "4:3",
        _ => "Custom",
    };

    /// <summary>
    /// The largest rectangle of an aspect, centred in a frame: the full height with bars at the sides for an aspect
    /// narrower than the frame's, and the full width with bars above and below for a wider one.
    /// </summary>
    public static FrameRect Fit(double width, double height, double aspect)
    {
        if (width <= 0 || height <= 0 || aspect <= 0)
        {
            return new FrameRect(0, 0, Math.Max(width, 0), Math.Max(height, 0));
        }
        if (width / height > aspect)
        {
            var w = height * aspect;
            return new FrameRect((width - w) / 2, 0, w, height);
        }
        var h = width / aspect;
        return new FrameRect(0, (height - h) / 2, width, h);
    }

    /// <summary>A rectangle scaled about its centre by a share of its width and height, as the safe areas are of the framed rectangle.</summary>
    public static FrameRect Inset(FrameRect r, double share) =>
        new(r.X + r.Width * (1 - share) / 2, r.Y + r.Height * (1 - share) / 2, r.Width * share, r.Height * share);

    /// <summary>The rule of thirds: the two lines across and the two lines down, as x and y in the frame.</summary>
    public static (double[] Xs, double[] Ys) Thirds(FrameRect r) =>
        ([r.X + r.Width / 3, r.X + 2 * r.Width / 3], [r.Y + r.Height / 3, r.Y + 2 * r.Height / 3]);

    /// <summary>The bars outside a framed rectangle: the parts of the frame that the mask covers, none, two or four.</summary>
    public static IReadOnlyList<FrameRect> Bars(double width, double height, FrameRect framed)
    {
        var bars = new List<FrameRect>();
        if (framed.Y > 0)
        {
            bars.Add(new FrameRect(0, 0, width, framed.Y));
        }
        if (framed.Bottom < height)
        {
            bars.Add(new FrameRect(0, framed.Bottom, width, height - framed.Bottom));
        }
        if (framed.X > 0)
        {
            bars.Add(new FrameRect(0, framed.Y, framed.X, framed.Height));
        }
        if (framed.Right < width)
        {
            bars.Add(new FrameRect(framed.Right, framed.Y, width - framed.Right, framed.Height));
        }
        return bars;
    }

    /// <summary>
    /// The camera's line of text: its name and its focal length, and the shot's name when it differs, as
    /// <c>Close Shot · 50 mm · Wide Shot</c>.
    /// </summary>
    public static string CameraInfo(string? camera, double? focalLength, string? shot)
    {
        var parts = new List<string>();
        if (!string.IsNullOrEmpty(camera))
        {
            parts.Add(camera);
        }
        if (focalLength is > 0 and var mm)
        {
            parts.Add($"{mm.ToString("0.#", System.Globalization.CultureInfo.InvariantCulture)} mm");
        }
        if (!string.IsNullOrEmpty(shot) && shot != camera)
        {
            parts.Add(shot);
        }
        return string.Join(" · ", parts);
    }
}
