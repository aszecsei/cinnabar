namespace Cinnabar.Editor.Maths;

public static class Angles
{
    /// <summary>Degrees wrapped to [0, 360).</summary>
    public static double Wrap360(double degrees) => ((degrees % 360) + 360) % 360;

    /// <summary>Degrees wrapped to (-180, 180].</summary>
    public static double Wrap180(double degrees)
    {
        var wrapped = degrees % 360;
        return wrapped > 180 ? wrapped - 360 : wrapped <= -180 ? wrapped + 360 : wrapped;
    }
}
