using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Shell;
using SceneValue = Cinnabar.Editor.Document.SceneValue;

namespace Cinnabar.Editor.Tests;

/// <summary>The atmosphere's edits (see docs/editor/shell-and-panels.md#atmosphere): its volume, its sun and its presets.</summary>
public sealed class AtmosphereTests : IDisposable
{
    readonly TempDirectory _temp = new("atmosphere");

    // A scene with a sun, a light whose +z points down and toward -z, and nothing else.
    const string Text = "scene 1\n\nentity 0000000000000001\nname = \"Sun\"\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n" +
        "component 34 Directional_Light\n\tintensity = 3\n";

    EditorShell NewShell()
    {
        return TestShell.Open(_temp, "sky.scene", Text);
    }

    static SceneComponent Environment(EditorShell shell) =>
        shell.AtmosphereVolume!.Components.Single(c => c.Id == SceneEdits.EnvironmentId);

    static SceneValue? Field(SceneComponent component, string name) => component.Fields.Find(f => f.Name == name)?.Value;

    [Theory]
    [InlineData(0, 45)]
    [InlineData(90, 10)]
    [InlineData(200, -20)]
    [InlineData(315, 80)]
    public void TheSunsAnglesComeBackFromItsRotation(double azimuth, double elevation)
    {
        var (a, e) = Atmosphere.SunAnglesOf(Atmosphere.SunRotation(azimuth, elevation));

        Assert.Equal(azimuth, a, 6);
        Assert.Equal(elevation, e, 6);
    }

    // A texture sky's sun comes as the direction toward it, which the engine's sky_direction makes from the angles.
    [Theory]
    [InlineData(0, 0, 1, 0, 0)]
    [InlineData(1, 0, 0, 90, 0)]
    [InlineData(0, 1, 0, 0, 90)]
    [InlineData(-0.5, 0.5, -0.5, 225, 35.26439)]
    public void TheSunsAnglesComeFromTheDirectionTowardIt(double x, double y, double z, double azimuth, double elevation)
    {
        var length = Math.Sqrt(x * x + y * y + z * z);
        var (a, e) = Atmosphere.AnglesToward([x / length, y / length, z / length]);

        Assert.Equal(azimuth, a, 4);
        Assert.Equal(elevation, e, 4);
    }

    [Fact]
    public void ASunLightShinesAwayFromItsAngles()
    {
        // Straight overhead, the light travels down its +z.
        var down = Atmosphere.SunRotation(0, 90).Rotate([0, 0, 1]);

        Assert.Equal(-1, down[1], 6);
    }

    [Fact]
    public void TheAtmosphereIsCreatedOnceAsOneUndoEntryWithTheSceneSun()
    {
        using var shell = NewShell();

        Assert.Null(shell.AtmosphereVolume);
        Assert.True(shell.Commands.Get(EditorCommands.AtmosphereSelect).Execute());

        var volume = shell.AtmosphereVolume!;
        Assert.Equal("Atmosphere", volume.Name);
        Assert.Equal("Atmosphere", Atmosphere.ModeOf(volume));
        Assert.Equal(1ul, shell.AtmosphereSun!.Id);
        Assert.Equal("Create Atmosphere", Assert.Single(shell.Scene!.History).Label);

        // Again, it finds the one that it made.
        Assert.True(shell.Commands.Get(EditorCommands.AtmosphereSelect).Execute());
        Assert.Single(shell.Scene.History);
    }

    [Fact]
    public void AnEditWithoutAnAtmosphereMakesOneInTheSameUndoEntry()
    {
        using var shell = NewShell();

        Assert.True(shell.Commands.Get(EditorCommands.Stars).Execute());

        Assert.Equal("Show Stars", Assert.Single(shell.Scene!.History).Label);
        Assert.Equal(Atmosphere.StarsOn, Field(Environment(shell), Atmosphere.StarIntensity)!.Numbers[0].Float);
        Assert.True(shell.Commands.Get(EditorCommands.Stars).IsChecked);
        shell.Scene.Undo();
        Assert.Null(shell.AtmosphereVolume);
    }

    [Fact]
    public void TheTimeOfDayTurnsALinkedSunsLight()
    {
        using var shell = NewShell();
        shell.SelectAtmosphere();

        Assert.True(shell.Commands.Get(EditorCommands.TimeOfDay("Night")).Execute());

        var (azimuth, elevation) = Atmosphere.SunAngles(shell.Scene!.Expanded.Flat, shell.AtmosphereVolume!);
        Assert.Equal(270, azimuth, 3);
        Assert.Equal(-20, elevation, 3);
        Assert.Null(Field(Environment(shell), Atmosphere.SunElevation));
        Assert.Equal("Set Time to Night", shell.Scene.History[^1].Label);
    }

    [Fact]
    public void AnUnlinkedSunSetsTheSkysOwnAnglesAndOverridesThem()
    {
        using var shell = NewShell();
        shell.SelectAtmosphere();
        Assert.True(shell.Commands.Get(EditorCommands.LinkSun).IsChecked);
        Assert.True(shell.Commands.Get(EditorCommands.LinkSun).Execute());
        Assert.Null(shell.AtmosphereSun);

        Assert.True(shell.Commands.Get(EditorCommands.TimeOfDay("Dawn")).Execute());

        var environment = Environment(shell);
        Assert.Equal(90, Field(environment, Atmosphere.SunAzimuth)!.Numbers[0].Float);
        Assert.Equal(2, Field(environment, Atmosphere.SunElevation)!.Numbers[0].Float);
        Assert.Null(Field(environment, Atmosphere.SunElevation + SceneEdits.OverrideSuffix));
        // The light did not turn.
        Assert.Equal([0.0, 0, 0, 1], shell.Scene!.Scene.Find(1)!.Components[0].Fields.Single(f => f.Name == "rotation").Value.Numbers.Select(n => n.Float));
    }

    [Fact]
    public void TheModeIsAChoiceOfTheEnvironment()
    {
        using var shell = NewShell();
        var mode = (ChoiceCommand)shell.Commands.Get(EditorCommands.AtmosphereMode);
        Assert.Equal("Flat", mode.Selected);
        shell.SelectAtmosphere();
        Assert.Equal("Atmosphere", mode.Selected);

        mode.Select("Flat");

        Assert.Equal("Flat", mode.Selected);
        Assert.Equal("Flat", Field(Environment(shell), Atmosphere.Mode)!.Text);
    }

    [Fact]
    public void TheFogToggleAddsAFogAndClearsItKeepingItsSettings()
    {
        using var shell = NewShell();
        shell.SelectAtmosphere();
        var fog = shell.Commands.Get(EditorCommands.AtmosphereFog);
        Assert.False(fog.IsChecked);

        Assert.True(fog.Execute());
        Assert.True(fog.IsChecked);
        Assert.True(shell.Commands.Get(EditorCommands.FogPreset("Heavy")).Execute());
        Assert.True(fog.Execute());

        Assert.False(fog.IsChecked);
        var component = shell.AtmosphereVolume!.Components.Single(c => c.Id == SceneEdits.FogId);
        Assert.Equal(0, Field(component, "density")!.Numbers[0].Float);
        Assert.Equal(0.05, Field(component, "height_falloff")!.Numbers[0].Float, 6);
    }

    [Fact]
    public void ASkyPresetResetsTheOthersSettings()
    {
        using var shell = NewShell();
        shell.SelectAtmosphere();

        Assert.True(shell.Commands.Get(EditorCommands.SkyPreset("Dusty")).Execute());
        Assert.NotNull(Field(Environment(shell), "atmosphere.ground_albedo"));
        Assert.True(shell.Commands.Get(EditorCommands.SkyPreset("Hazy")).Execute());

        var environment = Environment(shell);
        Assert.Null(Field(environment, "atmosphere.ground_albedo"));
        Assert.Equal(12, Field(environment, "atmosphere.mie_scattering")!.Numbers[0].Float);
    }

    public void Dispose() => _temp.Dispose();
}
