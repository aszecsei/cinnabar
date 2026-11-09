using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Shell;
using SceneValue = Cinnabar.Editor.Document.SceneValue;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// The clouds' edits (see docs/editor/shell-and-panels.md#atmosphere): the toggle, the weather presets and the source,
/// and the weather map model (see docs/editor/shell-and-panels.md#weather-map): painting, generating and its PNG.
/// </summary>
public sealed class CloudsTests : IDisposable
{
    readonly TempDirectory _temp = new("clouds");

    // A scene with a sun, and nothing else.
    const string Text = "scene 1\n\nentity 0000000000000001\nname = \"Sun\"\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n" +
        "component 34 Directional_Light\n\tintensity = 3\n";

    const string MapGuid = "57bed8c5e4eac9bb2c03476331afd35b";

    EditorShell NewShell() => TestShell.Open(_temp, "sky.scene", Text);

    static SceneComponent Clouds(SceneEntity volume) => volume.Components.Single(c => c.Id == SceneEdits.CloudsId);

    static SceneValue? Field(SceneComponent component, string name) => component.Fields.Find(f => f.Name == name)?.Value;

    [Fact]
    public void TheCloudsToggleAddsCloudsAndASecondToggleClearsThemKeepingTheCoverage()
    {
        using var shell = NewShell();
        shell.SelectAtmosphere();
        var clouds = shell.Commands.Get(EditorCommands.AtmosphereClouds);
        Assert.False(clouds.IsChecked);

        Assert.True(clouds.Execute());

        Assert.True(clouds.IsChecked);
        Assert.Equal("Add Clouds", shell.Scene!.History[^1].Label);
        Assert.Equal(1, Field(Clouds(shell.AtmosphereVolume!), Atmosphere.CloudDensity)!.Numbers[0].Float);
        Assert.True(shell.Edit("Set Coverage", Atmosphere.Set(shell.AtmosphereVolume!, SceneEdits.CloudsId, Atmosphere.CloudCoverage, SceneEdits.Floats(0.8))));

        Assert.True(clouds.Execute());

        Assert.False(clouds.IsChecked);
        Assert.Equal("Clear Clouds", shell.Scene.History[^1].Label);
        var component = Clouds(shell.AtmosphereVolume!);
        Assert.Equal(0, Field(component, Atmosphere.CloudDensity)!.Numbers[0].Float);
        Assert.Equal(0.8, Field(component, Atmosphere.CloudCoverage)!.Numbers[0].Float, 6);
    }

    [Fact]
    public void AWeatherPresetIsOneUndoEntryThatSetsItsFieldsFromTheScalarsAndKeepsTheMap()
    {
        using var shell = NewShell();
        shell.SelectAtmosphere();
        Assert.True(shell.Edit("Use Map", Atmosphere.UseWeatherMap(shell.AtmosphereVolume!, MapGuid)));
        Assert.Equal("Map", Atmosphere.WeatherSourceOf(shell.AtmosphereVolume!));
        var entries = shell.Scene!.History.Count;

        Assert.True(shell.Commands.Get(EditorCommands.WeatherPreset("Storm")).Execute());

        Assert.Equal(entries + 1, shell.Scene.History.Count);
        Assert.Equal("Set Weather to Storm", shell.Scene.History[^1].Label);
        var volume = shell.AtmosphereVolume!;
        var component = Clouds(volume);
        Assert.Equal(1, Field(component, Atmosphere.CloudDensity)!.Numbers[0].Float);
        Assert.Equal(0.95, Field(component, Atmosphere.CloudCoverage)!.Numbers[0].Float, 6);
        Assert.Equal(0.9, Field(component, Atmosphere.CloudPrecipitation)!.Numbers[0].Float, 6);
        Assert.Equal(1, Field(component, Atmosphere.CloudType)!.Numbers[0].Float);
        Assert.Equal(0, Field(component, Atmosphere.Cirrus)!.Numbers[0].Float);
        Assert.Equal(4500, Field(component, Atmosphere.CloudThickness)!.Numbers[0].Float);
        Assert.Equal("Scalars", Atmosphere.WeatherSourceOf(volume));
        Assert.Equal(MapGuid, Atmosphere.WeatherMapOf(volume));
        Assert.True(Atmosphere.HasClouds(volume));

        // Another preset resets what the first set and leaves what it did not.
        Assert.True(shell.Commands.Get(EditorCommands.WeatherPreset("Clear")).Execute());
        Assert.Equal(0.05, Field(Clouds(shell.AtmosphereVolume!), Atmosphere.CloudCoverage)!.Numbers[0].Float, 6);
        Assert.Equal(MapGuid, Atmosphere.WeatherMapOf(shell.AtmosphereVolume!));

        shell.Scene.Undo();
        shell.Scene.Undo();
        Assert.Equal("Map", Atmosphere.WeatherSourceOf(shell.AtmosphereVolume!));
    }

    [Fact]
    public void ANewWeatherMapOnAVolumeWithoutCloudsKeepsTheMapTheSourceAndTheOriginInOneEntry()
    {
        using var shell = NewShell();
        shell.SelectAtmosphere();
        Assert.DoesNotContain(shell.AtmosphereVolume!.Components, c => c.Id == SceneEdits.CloudsId);
        var entries = shell.Scene!.History.Count;
        long[] origin = [1 << 24, 0, 2 << 24];

        Assert.True(shell.EditAtmosphere("New Weather Map", (_, volume) => Atmosphere.UseWeatherMap(volume, MapGuid, origin)));

        Assert.Equal(entries + 1, shell.Scene.History.Count);
        var volume = shell.AtmosphereVolume!;
        Assert.Equal(MapGuid, Atmosphere.WeatherMapOf(volume));
        Assert.Equal("Map", Atmosphere.WeatherSourceOf(volume));
        Assert.Equal(origin.Length, Field(Clouds(volume), Atmosphere.WeatherOrigin)!.Numbers.Count);
    }

    [Fact]
    public void TheWeatherSourceIsAChoiceAndCenterWeatherSetsTheOriginInRawUnits()
    {
        using var shell = NewShell();
        shell.SelectAtmosphere();
        var source = (ChoiceCommand)shell.Commands.Get(EditorCommands.AtmosphereWeatherSource);
        Assert.Equal("Scalars", source.Selected);

        source.Select("Map");

        Assert.Equal("Map", source.Selected);
        Assert.Equal("Map", Field(Clouds(shell.AtmosphereVolume!), Atmosphere.CloudWeather)!.Text);

        Assert.True(shell.Commands.Get(EditorCommands.AtmosphereCenterWeather).Execute());

        var origin = Field(Clouds(shell.AtmosphereVolume!), Atmosphere.WeatherOrigin)!;
        Assert.Equal(3, origin.Numbers.Count);
        Assert.All(origin.Numbers, n => Assert.True(n.IsInteger));
    }

    [Fact]
    public void TheToggleTargetsTheOverrideBlockOfAnEnvironmentOnAPrefab()
    {
        const string skyPrefab = "33333333333333333333333333333333";
        const ulong instance = 0x5000000000000002;
        const ulong prefabVolume = 0x3000000000000002;
        // A prefab whose root holds a global volume with an Environment, and a scene that instances it. The root's own
        // overrides are the instance block's, so the volume is a child, whose overrides are a block of their own.
        var prefab = "scene 2\n\nentity 3000000000000001\nname = \"Sky Rig\"\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n\n" +
            "entity 3000000000000002\nname = \"Sky\"\nparent = @3000000000000001\ncomponent 2 Local_Transform\n\toffset = [0, 0, 0]\n" +
            "component 42 Volume\n\tshape = Global\ncomponent 49 Environment\n\tmode = Atmosphere\n";
        var scene = "scene 2\n\nentity 5000000000000002\nname = \"Sky\"\nprefab = $" + skyPrefab + "\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n";
        Directory.CreateDirectory(_temp.Path);
        File.WriteAllText(_temp.Combine("sky.prefab"), prefab);
        using var shell = TestShell.Open(_temp, "level.scene", scene);
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [new Importer(AssetKind.Prefab, ".prefab", [])], [], []));
        shell.Assets.Apply(new AssetSnapshot([TestAssets.Make(skyPrefab, AssetKind.Prefab, "sky.prefab")], []));
        var volume = shell.AtmosphereVolume!;
        Assert.Equal(ScenePath.Id([instance, prefabVolume]), volume.Id);

        Assert.True(shell.Commands.Get(EditorCommands.AtmosphereClouds).Execute());

        // The scene's own entities are the instance and an override block for the prefab's volume, which holds the Clouds.
        var block = Assert.Single(shell.Scene!.Scene.Entities, e => e.Kind == BlockKind.Override);
        Assert.Equal([instance, prefabVolume], block.Path);
        Assert.Equal(1, Field(Clouds(block), Atmosphere.CloudDensity)!.Numbers[0].Float);
        Assert.True(Atmosphere.HasClouds(shell.AtmosphereVolume!));
        Assert.True(shell.Commands.Get(EditorCommands.AtmosphereClouds).IsChecked);
    }

    [Fact]
    public void PaintChangesOnlyItsChannelWithinTheRadius()
    {
        var map = new WeatherMap(64, 64);

        map.Paint(WeatherChannel.Precipitation, 32, 32, radius: 8, strength: 1, hardness: 1, value: 1);

        Assert.Equal(1, map.Get(WeatherChannel.Precipitation, 32, 32));
        Assert.Equal(1, map.Get(WeatherChannel.Precipitation, 36, 32));
        Assert.Equal(0, map.Get(WeatherChannel.Precipitation, 32, 44));
        Assert.Equal(0, map.Get(WeatherChannel.Precipitation, 0, 0));
        Assert.Equal(0, map.Get(WeatherChannel.Coverage, 32, 32));
        Assert.Equal(0, map.Get(WeatherChannel.Type, 32, 32));
        Assert.All(Enumerable.Range(0, 64 * 64), i => Assert.Equal(255, map.Rgba[i * 4 + 3]));

        // A soft brush at half strength moves the middle halfway and the edge less.
        var soft = new WeatherMap(64, 64);
        soft.Paint(WeatherChannel.Coverage, 32.5, 32.5, radius: 8, strength: 0.5, hardness: 0, value: 1);
        Assert.Equal(0.5, soft.Get(WeatherChannel.Coverage, 32, 32), 2);
        Assert.InRange(soft.Get(WeatherChannel.Coverage, 38, 32), 0.001, 0.3);
    }

    [Fact]
    public void GenerateIsDeterministicBySeedAndDiffersBySeed()
    {
        var a = new WeatherMap(64, 64);
        var b = new WeatherMap(64, 64);
        var c = new WeatherMap(64, 64);

        a.Generate(new WeatherGeneration(Size: 64, Seed: 7));
        b.Generate(new WeatherGeneration(Size: 64, Seed: 7));
        c.Generate(new WeatherGeneration(Size: 64, Seed: 8));

        Assert.Equal(a.Rgba, b.Rgba);
        Assert.NotEqual(a.Rgba, c.Rgba);
        // The coverage is noise in the middle of its range, not flat.
        var coverage = Enumerable.Range(0, 64 * 64).Select(i => a.Rgba[i * 4]).ToList();
        Assert.True(coverage.Max() - coverage.Min() > 64);
        Assert.All(Enumerable.Range(0, 64 * 64), i => Assert.Equal(255, a.Rgba[i * 4 + 3]));
    }

    [Fact]
    public void APngRoundTrips()
    {
        var map = new WeatherMap(37, 21);
        map.Generate(new WeatherGeneration(Size: 37, Seed: 3));
        map.Paint(WeatherChannel.Type, 10, 10, 5, 1, 1, 0.25);

        var png = map.EncodePng();
        var back = WeatherMap.DecodePng(png);

        Assert.NotNull(back);
        Assert.Equal(37, back.Width);
        Assert.Equal(21, back.Height);
        Assert.Equal(map.Rgba, back.Rgba);
        Assert.Null(WeatherMap.DecodePng([1, 2, 3]));
    }

    [Fact]
    public void TheMetaTextMatchesTheFixture()
    {
        var expected = "# cinnabar asset metadata. Keep this file next to its asset (see docs/content/identity-and-cooking.md#identity).\n" +
            "guid = 57bed8c5e4eac9bb2c03476331afd35b\n" +
            "usage = data\n" +
            "mips = false\n";

        Assert.Equal(expected, WeatherMapFile.MetaText(MapGuid));
        Assert.Equal(32, WeatherMapFile.NewGuid().Length);
        Assert.EndsWith(Path.Combine("textures", "level_weather.png"), WeatherMapFile.PathFor(_temp.Path, _temp.Combine("scenes", "level.scene")));
    }

    public void Dispose() => _temp.Dispose();
}
