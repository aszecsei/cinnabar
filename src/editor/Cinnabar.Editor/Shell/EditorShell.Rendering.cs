using System.Text.Json;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Link.Protocol;
using LogLevel = Cinnabar.Editor.Panels.LogLevel;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// How the viewport draws (see docs/editor/viewport.md#viewport): the debug view, the features that it turns off, the exposure
/// offset, the icons and shapes of lights, volumes and cameras, and its quality in place of the game's. The game draws them while the editor is linked. The
/// settings are the user's, in <c>viewport.json</c>, so they stay across sessions.
/// </summary>
public sealed partial class EditorShell
{
    /// <summary>The settings of a viewport that shows the lit scene, with every feature, the icons and the selection's shapes.</summary>
    public static readonly ViewportSettings DefaultViewportSettings =
        new(DebugView.Lit, false, false, false, false, false, false, false, false, false, 0, true, HelperMode.Selected, ViewportPreset.Game, ViewportAa.Game, 0);

    /// <summary>The viewport's choice that keeps the game's quality.</summary>
    public const string GameQualityLabel = "Game's";

    /// <summary>The viewport's quality presets, as the ribbon shows them, in <see cref="ViewportPreset"/>'s order.</summary>
    public static IReadOnlyList<string> ViewportPresetNames { get; } = [GameQualityLabel, "Low", "Medium", "High", "Ultra"];

    /// <summary>The viewport's anti-aliasing, as the ribbon shows it, in <see cref="ViewportAa"/>'s order.</summary>
    public static IReadOnlyList<string> ViewportAaNames { get; } = [GameQualityLabel, "Off", "TAA", "FXAA", "SMAA", "FSR"];

    /// <summary>The viewport's render scales, as the ribbon shows them, and their values; 0 keeps the game's.</summary>
    public static IReadOnlyList<(string Label, float Scale)> ViewportRenderScales { get; } =
        [(GameQualityLabel, 0), ("100%", 1), ("75%", 0.75f), ("67%", 2f / 3), ("50%", 0.5f)];

    public string ViewportRenderScale =>
        ViewportRenderScales.FirstOrDefault(s => Math.Abs(s.Scale - ViewportSettings.RenderScale) < 1e-3f).Label ?? GameQualityLabel;

    public void SetViewportRenderScale(string label)
    {
        if (ViewportRenderScales.FirstOrDefault(s => s.Label == label) is { Label: not null } choice)
        {
            ViewportSettings = ViewportSettings with { RenderScale = choice.Scale };
        }
    }

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
            WriteSetting("viewport", EditorSettings.ViewportFileName, JsonSerializer.Serialize(value));
            Commands.InvalidateAll();
            ViewportSettingsChanged?.Invoke();
        }
    }

    public event Action? ViewportSettingsChanged;

    /// <summary>The debug views, by their names as the ribbon shows them.</summary>
    public static IReadOnlyList<string> DebugViewNames { get; } = [.. Enum.GetValues<DebugView>().Select(v => FieldValues.Humanize(SnakeCase(v.ToString())))];

    public static string DebugViewName(DebugView view) => DebugViewNames[(int)view];

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
