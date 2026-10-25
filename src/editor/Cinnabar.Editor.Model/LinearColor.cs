using System.Globalization;

namespace Cinnabar.Editor.Model;

/// <summary>
/// Converts the game's linear colors to and from the sRGB that a screen and a color picker show. A linear value above 1
/// is brighter than the screen's white: sRGB holds the color, and the scale is kept apart, as in <see cref="Split"/>.
/// </summary>
public static class LinearColor
{
    public static double ToSrgb(double linear)
    {
        var c = Math.Clamp(linear, 0, 1);
        return c <= 0.0031308 ? c * 12.92 : 1.055 * Math.Pow(c, 1 / 2.4) - 0.055;
    }

    public static double FromSrgb(double srgb)
    {
        var c = Math.Clamp(srgb, 0, 1);
        return c <= 0.04045 ? c / 12.92 : Math.Pow((c + 0.055) / 1.055, 2.4);
    }

    /// <summary>A linear color as a color of at most 1 and the scale that brings it back, at least 1.</summary>
    public static (double[] Color, double Scale) Split(IReadOnlyList<double> rgb)
    {
        var scale = Math.Max(1, rgb.Take(3).Max());
        return ([.. rgb.Take(3).Select(v => v / scale)], scale);
    }

    /// <summary>The 8-bit sRGB of a linear color, as #rrggbb.</summary>
    public static string Hex(IReadOnlyList<double> rgb) =>
        "#" + string.Concat(rgb.Take(3).Select(v => ((int)Math.Round(ToSrgb(v) * 255)).ToString("x2", CultureInfo.InvariantCulture)));

    /// <summary>The linear color of #rrggbb or rrggbb, or null.</summary>
    public static double[]? ParseHex(string text)
    {
        var hex = text.Trim().TrimStart('#');
        if (hex.Length != 6 || !int.TryParse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var value))
        {
            return null;
        }
        return [FromSrgb(((value >> 16) & 0xff) / 255.0), FromSrgb(((value >> 8) & 0xff) / 255.0), FromSrgb((value & 0xff) / 255.0)];
    }

    /// <summary>Hue in degrees, saturation and value, of an sRGB color in [0, 1].</summary>
    public static (double H, double S, double V) Hsv(double r, double g, double b)
    {
        var max = Math.Max(r, Math.Max(g, b));
        var delta = max - Math.Min(r, Math.Min(g, b));
        var h = delta == 0 ? 0
            : max == r ? 60 * (((g - b) / delta % 6 + 6) % 6)
            : max == g ? 60 * ((b - r) / delta + 2)
            : 60 * ((r - g) / delta + 4);
        return (h, max == 0 ? 0 : delta / max, max);
    }

    /// <summary>The sRGB color in [0, 1] of a hue in degrees, a saturation and a value.</summary>
    public static double[] FromHsv(double h, double s, double v)
    {
        var c = v * s;
        var x = c * (1 - Math.Abs(h / 60 % 2 - 1));
        var m = v - c;
        var (r, g, b) = ((h % 360 + 360) % 360 / 60) switch
        {
            < 1 => (c, x, 0.0),
            < 2 => (x, c, 0.0),
            < 3 => (0.0, c, x),
            < 4 => (0.0, x, c),
            < 5 => (x, 0.0, c),
            _ => (c, 0.0, x),
        };
        return [r + m, g + m, b + m];
    }
}
