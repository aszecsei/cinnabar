using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Shell;

static partial class EditorCommands
{
    // The scene's atmosphere (see docs/editor/shell-and-panels.md#atmosphere): its volume, its sky's mode and sun, presets
    // of the time of day, the sky and the fog, and the night's stars and moon. Each edit is one undo entry, and gives
    // the scene an atmosphere first when it has none.
    static void RegisterAtmosphere(EditorShell shell)
    {
        var commands = shell.Commands;
        commands.Register(new Command(AtmosphereSelect, "Atmosphere", shell.SelectAtmosphere)
        {
            Description = "Select the global volume that holds the scene's sky, ambient light and fog, and add one with an atmosphere when the scene has none.",
            Icon = "sky",
            CanExecuteWhen = () => shell.CanEditScene,
        });
        commands.Register(new ChoiceCommand(AtmosphereMode, "Sky", Atmosphere.Modes,
            () => shell.AtmosphereVolume is { } volume ? Atmosphere.ModeOf(volume) : "Flat",
            mode => shell.EditAtmosphere("Set Sky", (_, volume) => Atmosphere.Set(volume, SceneEdits.EnvironmentId, Atmosphere.Mode, SceneValue.Name(mode))))
        {
            Description = "Flat: a background color, and an ambient light from a sky color and a ground color. Atmosphere: a sky that the sun and the moon light through the air, with stars at night. Texture: an hdr image of the sky.",
            CanExecuteWhen = () => shell.CanEditScene,
        });
        commands.Register(new Command(LinkSun, "Link Sun", shell.ToggleSunLink)
        {
            Description = "Take the sky's sun from the selected directional light, or the scene's first: its direction and its light, which the air then tints. Again, the sky has a sun of its own.",
            Icon = "sun",
            IsCheckedWhen = () => shell.AtmosphereSun != null,
            CanExecuteWhen = () => shell.CanEditScene && (shell.AtmosphereSun != null || Atmosphere.DirectionalLights(shell.Scene!.Expanded.Flat).Any()),
        });
        commands.Register(new Command(AimSun, "Aim Sun at Sky", shell.AimSunAtSky)
        {
            Description = "Aim the sun at the texture sky's: where its brightest texels are. A linked sun turns its light, which you can move on from there.",
            Icon = "sun",
            CanExecuteWhen = () => shell.CanEditScene && shell.Host.Linked && shell.AtmosphereVolume is { } volume && Atmosphere.ModeOf(volume) == "Texture",
        });
        foreach (var (name, azimuth, elevation) in Atmosphere.TimesOfDay)
        {
            commands.Register(new Command(TimeOfDay(name), name, () => shell.EditAtmosphere($"Set Time to {name}", (scene, volume) => Atmosphere.Aim(scene, volume, azimuth, elevation)))
            {
                Description = $"Aim the sun as at {name.ToLowerInvariant()}: {elevation} degrees above the horizon, at {azimuth} degrees from +z toward +x. A linked sun turns its light.",
                Icon = "sun",
                CanExecuteWhen = () => shell.CanEditScene,
            });
        }
        foreach (var (name, _) in Atmosphere.Skies)
        {
            commands.Register(new Command(SkyPreset(name), name, () => shell.EditAtmosphere($"Set Air to {name}", (_, volume) => Atmosphere.Sky(volume, name)))
            {
                Description = name == "Clear" ? "Give the atmosphere Earth's clear air." : $"Give the atmosphere {name.ToLowerInvariant()} air.",
                Icon = "sky",
                CanExecuteWhen = () => shell.CanEditScene,
            });
        }
        Night(shell, Stars, "Stars", Atmosphere.StarIntensity, Atmosphere.StarsOn, "Show stars in the atmosphere's sky, which the day's light hides.", "stars");
        Night(shell, Moon, "Moon", Atmosphere.MoonIlluminance, Atmosphere.MoonOn, "Show the moon in the atmosphere's sky, which the sun lights in phases, and which lights the night sky.", "moon");
        commands.Register(new Command(AtmosphereFog, "Fog", () =>
        {
            var foggy = shell.AtmosphereVolume is { } v && Atmosphere.HasFog(v);
            shell.EditAtmosphere(foggy ? "Clear Fog" : "Add Fog", (_, volume) => foggy ? Atmosphere.NoFog(volume) : Atmosphere.Fog(volume, "Light"));
        })
        {
            Description = "Fill the world with the atmosphere's volumetric fog, or clear it and keep its settings.",
            Icon = "fog",
            IsCheckedWhen = () => shell.AtmosphereVolume is { } v && Atmosphere.HasFog(v),
            CanExecuteWhen = () => shell.CanEditScene,
        });
        foreach (var (name, _, _) in Atmosphere.Fogs)
        {
            commands.Register(new Command(FogPreset(name), name, () => shell.EditAtmosphere($"Set Fog to {name}", (_, volume) => Atmosphere.Fog(volume, name)))
            {
                Description = name == "None" ? "Give the atmosphere's fog a density of 0." : $"Give the atmosphere {name.ToLowerInvariant()} fog.",
                Icon = "fog",
                CanExecuteWhen = () => shell.CanEditScene,
            });
        }
    }

    static void Night(EditorShell shell, string id, string label, string field, double on, string description, string icon) =>
        shell.Commands.Register(new Command(id, label, () =>
        {
            var shown = shell.AtmosphereVolume is { } v && Atmosphere.Number(v, field, 0) > 0;
            shell.EditAtmosphere(shown ? $"Hide {label}" : $"Show {label}", (_, volume) => Atmosphere.Set(volume, SceneEdits.EnvironmentId, field, SceneEdits.Floats(shown ? 0 : on)));
        })
        {
            Description = description,
            Icon = icon,
            IsCheckedWhen = () => shell.AtmosphereVolume is { } v && Atmosphere.Number(v, field, 0) > 0,
            CanExecuteWhen = () => shell.CanEditScene,
        });
}
