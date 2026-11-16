using Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Shell;

/// <summary>A setting of a viewport that is on or off, such as its bloom.</summary>
public sealed record ViewportToggle(string Command, string Label, string Description, Func<ViewportSettings, bool> IsOn,
    Func<ViewportSettings, bool, ViewportSettings> Set, string? Icon = null);

/// <summary>A setting of a viewport that is one of a list of options, such as its anti-aliasing.</summary>
public sealed record ViewportChoice(string Command, string Label, string Description, IReadOnlyList<string> Options,
    Func<ViewportSettings, string> Get, Func<ViewportSettings, string, ViewportSettings> Set);

/// <summary>
/// A viewport's settings as data (see docs/editor/viewport.md#toolbar): each toggle and each choice once, with how it reads
/// and changes a <see cref="ViewportSettings"/>. A viewport's toolbar builds its menus from them and changes its own
/// viewport, and the commands with the same IDs change the settings viewport, for the command palette and key
/// bindings. So the two cannot differ in what they offer.
/// </summary>
public static class ViewportOptions
{
    /// <summary>What a viewport draws, each on unless turned off.</summary>
    public static IReadOnlyList<ViewportToggle> Features { get; } =
    [
        Feature(EditorCommands.TemporalAa, "Temporal AA", "Smooth edges with temporal AA in the viewport.", s => s.NoTemporalAa, (s, v) => s with { NoTemporalAa = v }),
        Feature(EditorCommands.Bloom, "Bloom", "Draw bloom in the viewport.", s => s.NoBloom, (s, v) => s with { NoBloom = v }),
        Feature(EditorCommands.ToneMapping, "Tone Mapping", "Tone map and grade the viewport; off, a plain roll-off to white.", s => s.NoToneMapping, (s, v) => s with { NoToneMapping = v }),
        Feature(EditorCommands.Fog, "Fog", "Draw the volumes' fog in the viewport.", s => s.NoFog, (s, v) => s with { NoFog = v }),
        Feature(EditorCommands.Clouds, "Clouds", "Draw the atmosphere's volumetric clouds in the viewport.", s => s.NoClouds, (s, v) => s with { NoClouds = v }),
        Feature(EditorCommands.AmbientOcclusion, "Ambient Occlusion", "Darken the indirect light where surfaces meet.", s => s.NoAmbientOcclusion, (s, v) => s with { NoAmbientOcclusion = v }),
        Feature(EditorCommands.GlobalIllumination, "Global Illumination", "Light the viewport with the light that bounces; off, with the environment's ambient light.", s => s.NoGi, (s, v) => s with { NoGi = v }),
        Feature(EditorCommands.Shadows, "Shadows", "Draw the lights' shadows in the viewport.", s => s.NoShadows, (s, v) => s with { NoShadows = v }),
        Feature(EditorCommands.PostEffects, "Post Effects", "Run the game's post effects in the viewport.", s => s.NoPostEffects, (s, v) => s with { NoPostEffects = v }),
        Feature(EditorCommands.OcclusionCulling, "Occlusion Culling", "Leave out what other surfaces hide, by last frame's depth and this one's; off, only what is outside the view.", s => s.NoOcclusionCulling, (s, v) => s with { NoOcclusionCulling = v }),
        Feature(EditorCommands.MeshletHierarchy, "Meshlet Hierarchy", "Walk each mesh's hierarchy of meshlets to find the ones that its level of detail may draw; off, every meshlet of every level is tested. Both draw the same meshlets.", s => s.NoMeshletHierarchy, (s, v) => s with { NoMeshletHierarchy = v }),
    ];

    /// <summary>A measurement, which is off until asked for (see docs/rendering/lighting-and-shadows.md#quad-overdraw).</summary>
    public static ViewportToggle ShadingStats { get; } = new(EditorCommands.ShadingStats, "Shading Stats",
        "Count the forward pass's 2x2 quads and the pixels that they cover, which the Resource Monitor shows. It costs the forward pass a little.",
        s => s.ShadingStats, (s, on) => s with { ShadingStats = on });

    public static ViewportToggle Icons { get; } = new(EditorCommands.Icons, "Icons",
        "Show icons for the lights, volumes and cameras, which select them when clicked.",
        s => s.ShowIcons, (s, on) => s with { ShowIcons = on }, "visible");

    public static IReadOnlyList<ViewportToggle> Toggles { get; } = [.. Features, ShadingStats, Icons];

    public static ViewportChoice Shapes { get; } = OfEnum<HelperMode>(EditorCommands.Helpers, "Shapes",
        "Draw the shapes of lights, volumes and cameras: their ranges, cones and bounds, for the selection or for all of them.",
        mode => mode.ToString(), s => s.Helpers, (s, v) => s with { Helpers = v });

    public static ViewportChoice Quality { get; } = OfEnum<ViewportPreset>(EditorCommands.ViewportQuality, "Quality",
        "Draw the viewport at a quality preset in place of the game's, to see what each level costs and looks like. The anti-aliasing and the render scale stay the game's unless they are chosen too, and the global illumination and the reflections are the preset's unless they are.",
        v => EditorShell.ViewportPresetNames[(int)v], s => s.QualityPreset, (s, v) => s with { QualityPreset = v });

    public static ViewportChoice AntiAliasing { get; } = OfEnum<ViewportAa>(EditorCommands.ViewportAntiAliasing, "Anti-Aliasing",
        "Smooth the viewport's edges with a technique in place of the game's. FSR needs a GPU and the library that run it; elsewhere the viewport uses TAA.",
        v => EditorShell.ViewportAaNames[(int)v], s => s.AntiAliasing, (s, v) => s with { AntiAliasing = v });

    public static ViewportChoice GlobalIllumination { get; } = OfEnum<ViewportGi>(EditorCommands.ViewportGiTechnique, "Global Illumination",
        "Light the viewport's indirect light with a technique in place of the game's, at the quality's level. Split Cascades need ray queries; elsewhere the viewport uses Screen Cascades.",
        v => EditorShell.ViewportGiNames[(int)v], s => s.GlobalIllumination, (s, v) => s with { GlobalIllumination = v });

    public static ViewportChoice Reflections { get; } = OfEnum<ViewportReflections>(EditorCommands.ViewportReflections, "Reflections",
        "Draw the viewport's reflections with a technique in place of the game's: the reflection probes alone, the screen-space reflections or the traced ones, both in front of the probes. Ray Traced needs ray queries; elsewhere the viewport uses Screen Space.",
        v => EditorShell.ViewportReflectionsNames[(int)v], s => s.Reflections, (s, v) => s with { Reflections = v });

    public static ViewportChoice ReflectionsLevel { get; } = OfEnum<ViewportLevel>(EditorCommands.ViewportReflectionsLevel, "Reflections Level",
        "Draw the viewport's reflections at a level in place of the game's or the preset's: the probes' slots, faces captured a frame and cube size, and the rays' share of the pixels.",
        v => EditorShell.ViewportLevelNames[(int)v], s => s.ReflectionsLevel, (s, v) => s with { ReflectionsLevel = v });

    public static ViewportChoice RenderScale { get; } = new(EditorCommands.ViewportRenderScale, "Render Scale",
        "Draw the viewport's scene at a share of its size in place of the game's, which TAA or FSR upscale.",
        [.. EditorShell.ViewportRenderScales.Select(s => s.Label)],
        s => EditorShell.ViewportRenderScales.FirstOrDefault(r => Math.Abs(r.Scale - s.RenderScale) < 1e-3f).Label ?? EditorShell.GameQualityLabel,
        (s, label) => EditorShell.ViewportRenderScales.FirstOrDefault(r => r.Label == label) is { Label: not null } choice ? s with { RenderScale = choice.Scale } : s);

    /// <summary>The choices that draw a viewport at a quality in place of the game's (see docs/editor/viewport.md#quality).</summary>
    public static IReadOnlyList<ViewportChoice> QualityChoices { get; } = [Quality, AntiAliasing, GlobalIllumination, Reflections, ReflectionsLevel, RenderScale];

    public static IReadOnlyList<ViewportChoice> Choices { get; } = [Shapes, .. QualityChoices];

    /// <summary>
    /// The debug views (see docs/rendering/post-processing.md#debug-views) by what a person looks for with them, for a
    /// viewport's menu of views. The lit scene is none of them, and every other view is in one group.
    /// </summary>
    public static IReadOnlyList<(string Label, IReadOnlyList<DebugView> Views)> DebugViewGroups { get; } =
    [
        ("Lighting", [DebugView.LightingOnly, DebugView.DirectLight, DebugView.IndirectLight, DebugView.LightComplexity, DebugView.Luminance, DebugView.Emission]),
        ("Shadows", [DebugView.ShadowCascades, DebugView.ShadowMask, DebugView.ShadowVirtual]),
        ("Indirect Light", [DebugView.AmbientOcclusion, DebugView.GiDiffuse, DebugView.GiSpecular, DebugView.GiProbes, DebugView.ReflectionProbes, DebugView.Reflections]),
        ("Surfaces", [DebugView.Albedo, DebugView.Roughness, DebugView.Normals]),
        ("Geometry", [DebugView.Depth, DebugView.Velocity, DebugView.EntityIds, DebugView.Meshlets, DebugView.LodDepth]),
        ("Atmosphere", [DebugView.Fog, DebugView.Clouds]),
        ("Cost", [DebugView.TransparentOverdraw, DebugView.QuadOverdraw]),
    ];

    // A feature is on while the setting that turns it off is false.
    static ViewportToggle Feature(string command, string label, string description, Func<ViewportSettings, bool> off, Func<ViewportSettings, bool, ViewportSettings> setOff) =>
        new(command, label, description, s => !off(s), (s, on) => setOff(s, !on));

    static ViewportChoice OfEnum<T>(string command, string label, string description, Func<T, string> name, Func<ViewportSettings, T> get,
        Func<ViewportSettings, T, ViewportSettings> set) where T : struct, Enum
    {
        var values = Enum.GetValues<T>();
        return new ViewportChoice(command, label, description, [.. values.Select(name)], s => name(get(s)),
            (s, option) => values.Where(v => name(v) == option).Select(v => set(s, v)).DefaultIfEmpty(s).First());
    }
}
