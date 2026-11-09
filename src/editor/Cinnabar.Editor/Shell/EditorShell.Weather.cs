namespace Cinnabar.Editor.Shell;

/// <summary>The clouds' weather map (see docs/editor/shell-and-panels.md#weather-map), which the Weather Map panel paints.</summary>
public sealed partial class EditorShell
{
    WeatherMapSession? _weatherMaps;

    /// <summary>The weather map that the Weather Map panel edits: the shell's, so a panel that docking rebuilds shows the same one.</summary>
    public WeatherMapSession WeatherMaps => _weatherMaps ??= new WeatherMapSession(this);
}
