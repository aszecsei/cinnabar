using System.Text.Json;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Link.Protocol;
using LogLevel = Cinnabar.Editor.Panels.LogLevel;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// How the viewport draws (see docs/editor.md#viewport): the debug view, the features that it turns off, the exposure
/// offset, and the icons and shapes of lights, volumes and cameras. The game draws them while the editor is linked. The
/// settings are the user's, in <c>viewport.json</c>, so they stay across sessions.
/// </summary>
public sealed partial class EditorShell
{
    /// <summary>The settings of a viewport that shows the lit scene, with every feature, the icons and the selection's shapes.</summary>
    public static readonly ViewportSettings DefaultViewportSettings = new(DebugView.Lit, false, false, false, false, false, false, false, false, 0, true, HelperMode.Selected);

    // How far one press of Exposure Up or Down moves the exposure, in stops.
    const float ExposureStep = 0.5f;

    ViewportSettings? _viewportSettings;

    public ViewportSettings ViewportSettings
    {
        get => _viewportSettings ??= LoadViewportSettings();
        set
        {
            if (value == ViewportSettings)
            {
                return;
            }
            _viewportSettings = value;
            SendViewportSettings();
            try
            {
                Settings.Write(EditorSettings.ViewportFileName, JsonSerializer.Serialize(value));
            }
            catch (IOException e)
            {
                Console.Add(LogLevel.Warning, $"viewport: cannot save its settings: {e.Message}");
            }
            Commands.InvalidateAll();
            ViewportSettingsChanged?.Invoke();
        }
    }

    public event Action? ViewportSettingsChanged;

    /// <summary>The debug views, by their names as the ribbon shows them.</summary>
    public static IReadOnlyList<string> DebugViewNames { get; } = [.. Enum.GetValues<DebugView>().Select(v => FieldValues.Humanize(SnakeCase(v.ToString())))];

    public static string DebugViewName(DebugView view) => DebugViewNames[(int)view];

    public void SetDebugView(string name)
    {
        var index = DebugViewNames.ToList().IndexOf(name);
        if (index >= 0)
        {
            ViewportSettings = ViewportSettings with { DebugView = (DebugView)index };
        }
    }

    public void ChangeExposure(float stops) => ViewportSettings = ViewportSettings with { ExposureOffset = stops == 0 ? 0 : ViewportSettings.ExposureOffset + stops * ExposureStep };

    void SendViewportSettings()
    {
        if (Host.Linked)
        {
            Host.Send(ViewportSettings);
        }
    }

    ViewportSettings LoadViewportSettings()
    {
        if (Settings.Read(EditorSettings.ViewportFileName) is not { } json)
        {
            return DefaultViewportSettings;
        }
        try
        {
            return JsonSerializer.Deserialize<ViewportSettings>(json) ?? DefaultViewportSettings;
        }
        catch (JsonException)
        {
            Console.Add(LogLevel.Warning, $"viewport: {Path.Combine(Settings.Directory, EditorSettings.ViewportFileName)} is not the viewport's settings, so the defaults are used");
            return DefaultViewportSettings;
        }
    }

    // LightingOnly is Lighting_Only, as the game names it, which Humanize shows as "Lighting Only".
    static string SnakeCase(string pascal) =>
        string.Concat(pascal.Select((c, i) => i > 0 && char.IsUpper(c) ? "_" + c : c.ToString()));
}
