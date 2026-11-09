namespace Cinnabar.Editor.Document;

/// <summary>
/// The weather map's files (see docs/editor/shell-and-panels.md#weather-map): the PNG that the editor writes into a
/// content root, and the `.meta` file that gives a new one its GUID and its import settings before the daemon owns it,
/// as a new mesh's does (see docs/content/daemon-and-operations.md#asset-operations).
/// </summary>
public static class WeatherMapFile
{
    /// <summary>The import settings that a weather map cooks with: a data texture, whose channels stay as they are, read at its first level.</summary>
    public const string Usage = "data";

    /// <summary>The `.meta` file of a new weather map with a GUID: the daemon's comment, the GUID, and its import settings.</summary>
    public static string MetaText(string guid) =>
        "# cinnabar asset metadata. Keep this file next to its asset (see docs/content/identity-and-cooking.md#identity).\n" +
        $"guid = {guid}\n" +
        $"usage = {Usage}\n" +
        "mips = false\n";

    /// <summary>A new asset's GUID, 32 hex digits as the daemon writes them.</summary>
    public static string NewGuid() => Guid.NewGuid().ToString("N");

    /// <summary>Where a scene's new weather map goes: `textures/&lt;scene stem&gt;_weather.png` under a content root, whose `_weather` suffix the cooker reads as a data texture.</summary>
    public static string PathFor(string contentRoot, string scenePath) =>
        Path.Combine(contentRoot, "textures", Path.GetFileNameWithoutExtension(scenePath) + "_weather.png");

    /// <summary>Whether a file's name has the weather suffix, so the cooker takes it as a data texture without a setting.</summary>
    public static bool HasWeatherSuffix(string path) =>
        Path.GetFileNameWithoutExtension(path).EndsWith("_weather", StringComparison.OrdinalIgnoreCase);

    /// <summary>Writes bytes to a temporary file and moves it over the target, so a crash or a cook never sees half a file.</summary>
    public static void WriteAtomically(string path, byte[] bytes)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + ".tmp";
        File.WriteAllBytes(temporary, bytes);
        File.Move(temporary, path, overwrite: true);
    }
}
