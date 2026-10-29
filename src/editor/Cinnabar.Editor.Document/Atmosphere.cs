namespace Cinnabar.Editor.Document;

/// <summary>
/// The scene's atmosphere (see docs/editor/shell-and-panels.md#atmosphere): the global volume whose Environment gives
/// the sky, the sun and the ambient light, and whose Fog gives the fog (see docs/rendering/sky.md#sky). Each edit gives
/// operations, which the caller applies as one undo entry. Setting a volume's setting overrides it, as the properties
/// panel's edits do. The field names and the defaults are the engine's, in lib/engine/render/settings.odin.
/// </summary>
public static class Atmosphere
{
    public const string Mode = "mode";
    public const string Sun = "sun";
    public const string SunAzimuth = "sun_azimuth";
    public const string SunElevation = "sun_elevation";
    public const string StarIntensity = "night.star_intensity";
    public const string MoonIlluminance = "night.moon_illuminance";

    /// <summary>The Environment's modes, as the engine's Sky_Mode names them.</summary>
    public static readonly IReadOnlyList<string> Modes = ["Flat", "Atmosphere", "Texture"];

    /// <summary>The star intensity and the moon's illuminance that the Stars and Moon toggles turn on.</summary>
    public const double StarsOn = 1;
    public const double MoonOn = 0.05;

    // The engine's default elevation, for a sun that the scene does not aim.
    const double DefaultElevation = 45;

    /// <summary>Times of day: the sun's azimuth from +z toward +x and its elevation, in degrees.</summary>
    public static readonly IReadOnlyList<(string Name, double Azimuth, double Elevation)> TimesOfDay =
    [
        ("Dawn", 90, 2),
        ("Morning", 120, 25),
        ("Noon", 180, 65),
        ("Afternoon", 240, 35),
        ("Dusk", 270, 2),
        ("Night", 270, -20),
    ];

    /// <summary>Skies: the atmosphere's settings that differ from Earth's clear air, which Clear resets.</summary>
    public static readonly IReadOnlyList<(string Name, (string Field, double[] Value)[] Settings)> Skies =
    [
        ("Clear", []),
        ("Hazy", [("atmosphere.mie_scattering", [12]), ("atmosphere.mie_height", [1.6])]),
        ("Dusty", [("atmosphere.mie_scattering", [40]), ("atmosphere.mie_absorption", [30]), ("atmosphere.mie_height", [2.5]), ("atmosphere.ground_albedo", [0.45, 0.35, 0.25])]),
        ("Alien", [("atmosphere.rayleigh_scattering", [33.1, 13.558, 5.802]), ("atmosphere.mie_scattering", [8])]),
    ];

    /// <summary>The sky presets' fields, all of which a preset resets before it sets its own.</summary>
    static readonly string[] SkyFields =
        ["atmosphere.rayleigh_scattering", "atmosphere.mie_scattering", "atmosphere.mie_absorption", "atmosphere.mie_height", "atmosphere.ground_albedo"];

    /// <summary>Fogs: the Fog's density and height falloff. None has a density of 0.</summary>
    public static readonly IReadOnlyList<(string Name, double Density, double Falloff)> Fogs =
    [
        ("None", 0, 0),
        ("Light", 0.005, 0.2),
        ("Medium", 0.02, 0.15),
        ("Heavy", 0.08, 0.05),
    ];

    /// <summary>
    /// The global volume that holds the atmosphere: of the global volumes, one with an Environment, the highest
    /// priority first, or without any, one without. Null when the scene has no global volume.
    /// </summary>
    public static SceneEntity? Find(Scene scene) =>
        scene.Entities.Where(IsGlobalVolume)
            .OrderByDescending(e => e.Components.Any(c => c.Id == SceneEdits.EnvironmentId))
            .ThenByDescending(Priority)
            .FirstOrDefault();

    // A volume without a shape is Global, the engine's first.
    static bool IsGlobalVolume(SceneEntity e) =>
        e.Components.Find(c => c.Id == SceneEdits.VolumeId) is { } volume
        && volume.Fields.Find(f => f.Name == "shape")?.Value is null or { Kind: SceneValueKind.Name, Text: "Global" };

    static double Priority(SceneEntity e) =>
        e.Components.Find(c => c.Id == SceneEdits.VolumeId)?.Fields.Find(f => f.Name == "priority")?.Value is { Kind: SceneValueKind.Number } v ? v.Numbers[0].Float : 0;

    /// <summary>The scene's directional lights, which can be the sky's sun.</summary>
    public static IEnumerable<SceneEntity> DirectionalLights(Scene scene) =>
        scene.Entities.Where(e => e.Components.Any(c => c.Id == SceneEdits.DirectionalLightId));

    /// <summary>
    /// The operations that give the scene an atmosphere, and the volume that holds it: a global volume's Environment
    /// in Atmosphere mode, with the scene's first directional light as its sun. A global volume without an Environment
    /// gets one; otherwise a new one, named Atmosphere, at the origin.
    /// </summary>
    public static (Operation[] Operations, SceneEntity Volume) Create(Scene scene)
    {
        var environment = new SceneComponent(SceneEdits.EnvironmentId, "Environment", [new SceneField(Mode, SceneValue.Name("Atmosphere"))]);
        if (DirectionalLights(scene).FirstOrDefault() is { } sun)
        {
            environment.Fields.Add(new SceneField(Sun, SceneValue.EntityRef(sun.Id)));
        }
        if (Find(scene) is { } existing)
        {
            return existing.Components.Any(c => c.Id == SceneEdits.EnvironmentId) ? ([], existing) : ([new AddComponent(existing.Id, environment)], existing);
        }
        var create = SceneEdits.NewEntity(scene, [0, 0, 0]);
        create.Created.Name = "Atmosphere";
        create.Created.Components.Add(new SceneComponent(SceneEdits.VolumeId, "Volume", [new SceneField("shape", SceneValue.Name("Global"))]));
        create.Created.Components.Add(environment);
        return ([create], create.Created);
    }

    /// <summary>A setting of a component of the volume as the scene sets it, or null when it does not override it.</summary>
    public static SceneValue? Setting(SceneEntity volume, ulong component, string field)
    {
        var fields = volume.Components.Find(c => c.Id == component)?.Fields;
        if (fields == null || fields.Find(f => f.Name == field + SceneEdits.OverrideSuffix)?.Value is { Kind: SceneValueKind.Bool, Bool: false })
        {
            return null;
        }
        return fields.Find(f => f.Name == field)?.Value;
    }

    /// <summary>A number setting of the Environment, or its default when the scene does not override it.</summary>
    public static double Number(SceneEntity volume, string field, double fallback) =>
        Setting(volume, SceneEdits.EnvironmentId, field) is { Kind: SceneValueKind.Number } v ? v.Numbers[0].Float : fallback;

    /// <summary>The Environment's mode, Flat by default.</summary>
    public static string ModeOf(SceneEntity volume) =>
        Setting(volume, SceneEdits.EnvironmentId, Mode) is { Kind: SceneValueKind.Name } v && Modes.Contains(v.Text) ? v.Text : "Flat";

    /// <summary>The directional light that is the sky's sun, or null when the sky's sun is its own.</summary>
    public static SceneEntity? SunOf(Scene scene, SceneEntity volume) =>
        Setting(volume, SceneEdits.EnvironmentId, Sun) is { Kind: SceneValueKind.Entity, Entity: not 0 } v
        && scene.Find(v.Entity) is { } light && light.Components.Any(c => c.Id == SceneEdits.DirectionalLightId)
            ? light
            : null;

    /// <summary>Overrides a setting of a component of the volume with a value, as the properties panel does.</summary>
    public static Operation[] Set(SceneEntity volume, ulong component, string field, SceneValue value) =>
        [new SetField(volume.Id, component, field, value), new SetField(volume.Id, component, field + SceneEdits.OverrideSuffix, null)];

    /// <summary>Resets a setting of a component of the volume to its default, not overridden.</summary>
    public static Operation[] Reset(SceneEntity volume, ulong component, string field) =>
        [new SetField(volume.Id, component, field + SceneEdits.OverrideSuffix, null), new SetField(volume.Id, component, field, null)];

    /// <summary>Links the sky's sun to a directional light, or with 0, unlinks it.</summary>
    public static Operation[] Link(SceneEntity volume, ulong light) =>
        light == 0 ? Reset(volume, SceneEdits.EnvironmentId, Sun) : Set(volume, SceneEdits.EnvironmentId, Sun, SceneValue.EntityRef(light));

    /// <summary>The sun's azimuth and elevation: its light's when it has one, else the Environment's own.</summary>
    public static (double Azimuth, double Elevation) SunAngles(Scene scene, SceneEntity volume)
    {
        if (SunOf(scene, volume) is { } light)
        {
            return SunAnglesOf((SceneEdits.WorldPose(scene, light) ?? Pose.Identity).Rotation);
        }
        return (Number(volume, SunAzimuth, 0), Number(volume, SunElevation, DefaultElevation));
    }

    /// <summary>
    /// Points the sun at an azimuth and an elevation: its light's rotation when it has one, else the Environment's
    /// own angles. A light under a parent turns its Local_Transform, so its world rotation is the one asked for.
    /// </summary>
    public static Operation[] Aim(Scene scene, SceneEntity volume, double azimuth, double elevation)
    {
        if (SunOf(scene, volume) is not { } light)
        {
            return
            [
                .. Set(volume, SceneEdits.EnvironmentId, SunAzimuth, SceneEdits.Floats(Wrap(azimuth))),
                .. Set(volume, SceneEdits.EnvironmentId, SunElevation, SceneEdits.Floats(Math.Clamp(elevation, -90, 90))),
            ];
        }
        var rotation = SunRotation(azimuth, elevation);
        if (light.Parent != 0 && light.Components.Any(c => c.Id == SceneEdits.LocalTransformId) && scene.Find(light.Parent) is { } parent)
        {
            var parentRotation = (SceneEdits.WorldPose(scene, parent) ?? Pose.Identity).Rotation;
            return [new SetField(light.Id, SceneEdits.LocalTransformId, "rotation", Rotation((parentRotation.Conjugate * rotation).Normalized()))];
        }
        return [new SetField(light.Id, SceneEdits.TransformId, "rotation", Rotation(rotation))];
    }

    static SceneValue Rotation(Quat q) => SceneEdits.Floats(q.X, q.Y, q.Z, q.W);

    /// <summary>
    /// The rotation of a directional light whose light comes from an azimuth and an elevation: its +z, where the light
    /// travels, points away from them, as the engine's sky_direction has the sun.
    /// </summary>
    public static Quat SunRotation(double azimuth, double elevation)
    {
        var yaw = (azimuth + 180) * Math.PI / 180;
        var pitch = Math.Clamp(elevation, -90, 90) * Math.PI / 180;
        var turn = new Quat(0, Math.Sin(yaw / 2), 0, Math.Cos(yaw / 2));
        var tilt = new Quat(Math.Sin(pitch / 2), 0, 0, Math.Cos(pitch / 2));
        return (turn * tilt).Normalized();
    }

    /// <summary>The azimuth, from 0 to 360, and the elevation of the sun of a directional light with a rotation.</summary>
    public static (double Azimuth, double Elevation) SunAnglesOf(Quat rotation)
    {
        var travels = rotation.Rotate([0, 0, 1]);
        return AnglesToward([-travels[0], -travels[1], -travels[2]]);
    }

    /// <summary>
    /// The azimuth, from 0 to 360, and the elevation of a unit direction toward the sun, such as where a texture sky's
    /// sun is.
    /// </summary>
    public static (double Azimuth, double Elevation) AnglesToward(double[] toward)
    {
        var elevation = Math.Asin(Math.Clamp(toward[1], -1, 1)) * 180 / Math.PI;
        // Straight up or down, the azimuth is any, so it stays 0.
        var azimuth = Math.Abs(toward[1]) > 0.999999 ? 0 : Math.Atan2(toward[0], toward[2]) * 180 / Math.PI;
        return (Wrap(azimuth), elevation);
    }

    static double Wrap(double degrees) => ((degrees % 360) + 360) % 360;

    /// <summary>Sets the atmosphere's settings to a sky's, after resetting every setting that a sky sets.</summary>
    public static Operation[] Sky(SceneEntity volume, string name)
    {
        var sky = Skies.First(s => s.Name == name);
        return
        [
            .. SkyFields.SelectMany(f => Reset(volume, SceneEdits.EnvironmentId, f)),
            .. sky.Settings.SelectMany(s => Set(volume, SceneEdits.EnvironmentId, s.Field, SceneEdits.Floats(s.Value))),
        ];
    }

    /// <summary>Gives the volume a fog's density and falloff, with a Fog if it has none.</summary>
    public static Operation[] Fog(SceneEntity volume, string name)
    {
        var fog = Fogs.First(f => f.Name == name);
        if (!volume.Components.Any(c => c.Id == SceneEdits.FogId))
        {
            return [new AddComponent(volume.Id, new SceneComponent(SceneEdits.FogId, "Fog",
                [new SceneField("density", SceneEdits.Floats(fog.Density)), new SceneField("height_falloff", SceneEdits.Floats(fog.Falloff))]))];
        }
        return
        [
            .. Set(volume, SceneEdits.FogId, "density", SceneEdits.Floats(fog.Density)),
            .. Set(volume, SceneEdits.FogId, "height_falloff", SceneEdits.Floats(fog.Falloff)),
        ];
    }

    /// <summary>Whether the volume's fog shows: its Fog sets a density above 0, which is 0 by default.</summary>
    public static bool HasFog(SceneEntity volume) =>
        Setting(volume, SceneEdits.FogId, "density") is { Kind: SceneValueKind.Number } d && d.Numbers[0].Float > 0;

    /// <summary>The volume without its fog: its Fog's density set to 0, which keeps its other settings.</summary>
    public static Operation[] NoFog(SceneEntity volume) =>
        volume.Components.Any(c => c.Id == SceneEdits.FogId) ? Set(volume, SceneEdits.FogId, "density", SceneEdits.Floats(0)) : [];
}
