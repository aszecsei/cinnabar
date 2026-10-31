using Cinnabar.Editor.Commands;

namespace Cinnabar.Editor.Shell;

static partial class EditorCommands
{
    // The panels, the layout, the ribbon and the viewport's scale.
    static void RegisterWindow(EditorShell shell)
    {
        var commands = shell.Commands;
        foreach (var panel in shell.Layout.Panels)
        {
            commands.Register(new Command(Panel(panel.Id), panel.Title, () => shell.Layout.Toggle(panel.Id))
            {
                Description = $"Show or hide the {panel.Title.ToLowerInvariant()} panel.",
                Icon = panel.Icon,
                IsCheckedWhen = () => shell.Layout.IsOpen(panel.Id),
            });
        }
        commands.Register(new Command(ResetLayout, "Reset Layout", shell.Layout.Reset)
        {
            Description = "Put every panel back where it starts.",
            Icon = "reset",
        });
        commands.Register(new Command(Stats, "Viewport Stats", () => shell.Viewport.ShowStats = !shell.Viewport.ShowStats)
        {
            Description = "Show the frame rates and the adapter over the viewport.",
            Icon = "stats",
            IsCheckedWhen = () => shell.Viewport.ShowStats,
        });
        commands.Register(new Command(CollapseRibbon, "Collapse Ribbon", () => shell.RibbonCollapsed = !shell.RibbonCollapsed)
        {
            Description = "Show only the ribbon's tabs. Double-clicking a tab does the same.",
            Icon = "collapse",
            Shortcut = "Ctrl+F1",
            IsCheckedWhen = () => shell.RibbonCollapsed,
        });
        commands.Register(ChoiceCommand.ForEnum<Viewport.ViewportScale>(ViewportScale, "Scale", () => shell.Viewport.Scale, scale => shell.Viewport.Scale = scale,
            scale => scale == Viewport.ViewportScale.Fit ? "Fit" : "100%",
            description: "Fit the frame to the viewport, or show one frame pixel per screen pixel.",
            icon: "scale"));
    }

    // The viewport's rendering (see docs/editor/viewport.md#viewport): what it shows in place of the lit scene, the features
    // that it turns off, the exposure offset, and the helpers. Each toggle is checked while its feature is on.
    static void RegisterRendering(EditorShell shell)
    {
        var commands = shell.Commands;
        commands.Register(ChoiceCommand.ForEnum<Link.Protocol.DebugView>(DebugView, "View", () => shell.ViewportSettings.DebugView,
            view => shell.ViewportSettings = shell.ViewportSettings with { DebugView = view }, EditorShell.DebugViewName,
            description: "Show the lit scene, or a debug view of what makes it: the lighting, the albedo, the normals, the light complexity and more.",
            icon: "viewport"));
        Feature(shell, TemporalAa, "Temporal AA", "Smooth edges with temporal AA in the viewport.", s => s.NoTemporalAa, (s, v) => s with { NoTemporalAa = v });
        Feature(shell, Bloom, "Bloom", "Draw bloom in the viewport.", s => s.NoBloom, (s, v) => s with { NoBloom = v });
        Feature(shell, ToneMapping, "Tone Mapping", "Tone map and grade the viewport; off, a plain roll-off to white.", s => s.NoToneMapping, (s, v) => s with { NoToneMapping = v });
        Feature(shell, Fog, "Fog", "Draw the volumes' fog in the viewport.", s => s.NoFog, (s, v) => s with { NoFog = v });
        Feature(shell, AmbientOcclusion, "Ambient Occlusion", "Darken the indirect light where surfaces meet.", s => s.NoAmbientOcclusion, (s, v) => s with { NoAmbientOcclusion = v });
        Feature(shell, GlobalIllumination, "Global Illumination", "Light the viewport with the light that bounces; off, with the environment's ambient light.", s => s.NoGi, (s, v) => s with { NoGi = v });
        Feature(shell, Shadows, "Shadows", "Draw the lights' shadows in the viewport.", s => s.NoShadows, (s, v) => s with { NoShadows = v });
        Feature(shell, PostEffects, "Post Effects", "Run the game's post effects in the viewport.", s => s.NoPostEffects, (s, v) => s with { NoPostEffects = v });
        Feature(shell, OcclusionCulling, "Occlusion Culling", "Leave out what other surfaces hide, by last frame's depth and this one's; off, only what is outside the view.", s => s.NoOcclusionCulling, (s, v) => s with { NoOcclusionCulling = v });
        Feature(shell, MeshletHierarchy, "Meshlet Hierarchy", "Walk each mesh's hierarchy of meshlets to find the ones that its level of detail may draw; off, every meshlet of every level is tested. Both draw the same meshlets.", s => s.NoMeshletHierarchy, (s, v) => s with { NoMeshletHierarchy = v });
        commands.Register(Command.Toggle(Icons, "Icons", () => shell.ViewportSettings.ShowIcons, on => shell.ViewportSettings = shell.ViewportSettings with { ShowIcons = on },
            "Show icons for the lights, volumes and cameras, which select them when clicked.", "visible"));
        commands.Register(ChoiceCommand.ForEnum<Link.Protocol.HelperMode>(Helpers, "Shapes", () => shell.ViewportSettings.Helpers,
            mode => shell.ViewportSettings = shell.ViewportSettings with { Helpers = mode },
            description: "Draw the shapes of lights, volumes and cameras: their ranges, cones and bounds, for the selection or for all of them.",
            icon: "frame"));
        commands.Register(ChoiceCommand.ForEnum<Link.Protocol.ViewportPreset>(ViewportQuality, "Quality", () => shell.ViewportSettings.QualityPreset,
            preset => shell.ViewportSettings = shell.ViewportSettings with { QualityPreset = preset }, preset => EditorShell.ViewportPresetNames[(int)preset],
            description: "Draw the viewport at a quality preset in place of the game's, to see what each level costs and looks like. The anti-aliasing and the render scale stay the game's unless they are chosen too.",
            icon: "viewport"));
        commands.Register(ChoiceCommand.ForEnum<Link.Protocol.ViewportAa>(ViewportAntiAliasing, "Anti-Aliasing", () => shell.ViewportSettings.AntiAliasing,
            aa => shell.ViewportSettings = shell.ViewportSettings with { AntiAliasing = aa }, aa => EditorShell.ViewportAaNames[(int)aa],
            description: "Smooth the viewport's edges with a technique in place of the game's. FSR needs a GPU and the library that run it; elsewhere the viewport uses TAA.",
            icon: "viewport"));
        commands.Register(new ChoiceCommand(ViewportRenderScale, "Render Scale", [.. EditorShell.ViewportRenderScales.Select(s => s.Label)],
            () => shell.ViewportRenderScale, shell.SetViewportRenderScale)
        {
            Description = "Draw the viewport's scene at a share of its size in place of the game's, which TAA or FSR upscale.",
            Icon = "viewport",
        });
        commands.Register(new Command(ExposureUp, "Brighter", () => shell.ChangeExposure(1))
        {
            Description = "Add half a stop to the viewport's exposure.",
        });
        commands.Register(new Command(ExposureDown, "Darker", () => shell.ChangeExposure(-1))
        {
            Description = "Take half a stop from the viewport's exposure.",
        });
        commands.Register(new Command(ExposureReset, "Reset Exposure", () => shell.ChangeExposure(0))
        {
            Description = "Show the exposure that the volumes give, with no offset.",
            CanExecuteWhen = () => shell.ViewportSettings.ExposureOffset != 0,
        });
    }

    static void Feature(EditorShell shell, string id, string label, string description, Func<Link.Protocol.ViewportSettings, bool> off,
        Func<Link.Protocol.ViewportSettings, bool, Link.Protocol.ViewportSettings> set) =>
        shell.Commands.Register(Command.Toggle(id, label, () => !off(shell.ViewportSettings), on => shell.ViewportSettings = set(shell.ViewportSettings, !on), description));
}
