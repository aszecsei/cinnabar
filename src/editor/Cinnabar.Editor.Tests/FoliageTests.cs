using Avalonia;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using Wire = Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// The landscape tools' foliage (see docs/editor/landscape.md#foliage): the <c>.instances</c> text, and the Scatter
/// and Erase brushes on a terrain's foliage layer in the shell, with the live instance sets that the game hears.
/// </summary>
public sealed class FoliageTests : IDisposable
{
    readonly TempDirectory _temp = new("foliage");
    readonly List<ILinkMessage> _sent = [];

    public void Dispose() => _temp.Dispose();

    [Fact]
    public void AnInstancesFileRoundTripsAndReportsItsProblemsLines()
    {
        var instances = new[]
        {
            new FoliageInstance(new Vec3(1.5, 0, -2), new Quat(0, 0.3826834, 0, 0.9238795), new Vec3(1, 1, 1)),
            new FoliageInstance(new Vec3(0.1, 2.25, 3), Quat.Identity, new Vec3(0.8, 0.8, 0.8)),
        };
        var text = InstancesFile.Write(instances);
        Assert.StartsWith("instances 1\n", text);
        var (back, problem) = InstancesFile.Parse(text);
        Assert.Null(problem);
        Assert.Equal(2, back!.Count);
        Assert.Equal((float)instances[1].Position.Y, (float)back[1].Position.Y);
        Assert.Equal((float)instances[0].Rotation.Y, (float)back[0].Rotation.Y);

        Assert.Equal(3, InstancesFile.Parse("instances 1\n\ni 1 2 3\n").Problem!.Value.Line);
        Assert.Equal(1, InstancesFile.Parse("instance 2\n").Problem!.Value.Line);
        Assert.Equal(2, InstancesFile.Parse("instances 1\ni 1 2 x 0 0 0 1 1 1 1\n").Problem!.Value.Line);
        Assert.Empty(InstancesFile.Parse("# none\ninstances 1\n").Instances!);
    }

    const string HeightGuid = "9a1b2c3d4e5f60718293a4b5c6d7e8f9";
    const string MeshGuid = "1f2e3d4c5b6a79880796a5b4c3d2e1f0";

    static ulong Handle(uint index) => 1UL << 32 | index;

    // A 16 m terrain at half its 4 m height, and a foliage layer under it, 2 m to the side, without an instance set.
    EditorShell NewShell(uint select = 0)
    {
        Directory.CreateDirectory(_temp.Path);
        File.WriteAllBytes(_temp.Combine("terrain_height.png"), Png.Encode(new PngImage(16, 16, 1, 16, [.. Enumerable.Repeat((ushort)32768, 256)])));
        var text = "scene 1\n\nentity 0000000000000001\nname = \"Terrain\"\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n" +
            $"component 51 Surface_Renderer\n\tsize = [16, 16]\n\tcell = 1\n\theight_range = [0, 4]\n\theight_map = ${HeightGuid}\n\n" +
            "entity 0000000000000002\nname = \"Grass\"\nparent = @0000000000000001\ncomponent 1 Transform\n\tposition = [33554432, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n" +
            $"component 53 Instanced_Mesh_Renderer\n\tmesh = ${MeshGuid}\n";
        var shell = TestShell.Open(_temp, "main.scene", text);
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [new Importer(AssetKind.Texture, ".png", []), new Importer(AssetKind.InstanceSet, ".instances", [])], [], []));
        shell.Assets.Apply(new AssetSnapshot([TestAssets.Make(HeightGuid, AssetKind.Texture, "terrain_height.png")], []));
        shell.Host.LinkForTests(_sent.Add);
        shell.OnGameMessage(new Wire.EntitySnapshot(
        [
            new Wire.EntityInfo(Handle(0), "Terrain", 1, 1, 0, true, [1, 51]),
            new Wire.EntityInfo(Handle(1), "Grass", 2, 1, Handle(0), true, [1, 53]),
        ]));
        shell.Viewports[0].Session.Show(new PixelSize(1600, 900));
        shell.Camera.Place([0, (long)(20 * Pose.Unit), 0], 0, -EditorCamera.MaxPitch);
        if (shell.Camera.Forward.Y > 0)
        {
            shell.Camera.Place([0, (long)(20 * Pose.Unit), 0], 0, EditorCamera.MaxPitch);
        }
        shell.Selection.Select(Handle(select));
        shell.SetTool(Tool.Landscape);
        shell.Landscape.SetBrush(LandscapeBrush.Scatter);
        shell.Landscape.SetRadius(4);
        shell.Landscape.SetStrength(1);
        shell.Landscape.SetDensity(50);
        return shell;
    }

    static readonly Vec2 Middle = new(800, 450);

    [Fact]
    public void ScatterMakesTheLayersSetAndPutsInstancesOnTheTerrainInsideTheBrush()
    {
        using var shell = NewShell();
        _sent.Clear();
        Assert.True(shell.Landscape.BeginStroke(Middle));
        shell.Landscape.EndStroke();
        var set = Assert.Single(shell.Landscape.Sets);
        // 50 on 100 m² over a 4 m circle is about 25, which the spacing may leave a few short of.
        Assert.InRange(set.Instances.Count, 10, 26);
        // The camera looks down at 89 degrees, so the brush is a little off the terrain's middle.
        var surface = shell.Landscape.Surface!;
        var hit = shell.Landscape.Pick(surface, Pose.Identity, Middle)!.Value;
        foreach (var i in set.Instances)
        {
            // The layer is 2 m along x from the terrain, so its instances are 2 m back in its space, at the terrain's height.
            var (dx, dz) = (i.Position.X + 2 - hit.Local.X, i.Position.Z - hit.Local.Z);
            Assert.InRange(Math.Sqrt(dx * dx + dz * dz), 0, 4.01);
            Assert.Equal(2, i.Position.Y, 2);
            Assert.InRange(i.Scale.X, LandscapeSession.ScaleMin, LandscapeSession.ScaleMax);
        }
        var live = _sent.OfType<Wire.LiveInstances>().Last();
        Assert.Equal(set.Instances.Count * 3, live.Positions.Length);
        var grass = shell.Scene!.Scene.Find(2)!;
        var named = grass.Components.First(c => c.Id == LandscapeSession.InstancedMeshRendererId).Fields.Single(f => f.Name == "instances").Value.Asset;
        Assert.Equal(set.Guid, named);

        // A second stroke there adds none: the circle has its density.
        var count = set.Instances.Count;
        Assert.True(shell.Landscape.BeginStroke(Middle));
        shell.Landscape.EndStroke();
        Assert.InRange(set.Instances.Count, count, count + 3);

        Assert.True(shell.SaveScene());
        var (saved, problem) = InstancesFile.Parse(File.ReadAllText(set.Path));
        Assert.Null(problem);
        Assert.Equal(set.Instances.Count, saved!.Count);
        Assert.Contains($"guid = {set.Guid}", File.ReadAllText(set.Path + ".meta"));
        Assert.EndsWith(".instances", set.Path);
    }

    [Fact]
    public void EraseTakesTheInstancesAwayAndUndoPutsThemBack()
    {
        using var shell = NewShell(select: 1);
        Assert.True(shell.Context.IsActive(LandscapeSession.TerrainContext), "a selected foliage layer selects its terrain");
        Assert.True(shell.Landscape.BeginStroke(Middle));
        shell.Landscape.EndStroke();
        var set = Assert.Single(shell.Landscape.Sets);
        var scattered = set.Instances;
        Assert.NotEmpty(scattered);

        shell.Landscape.SetBrush(LandscapeBrush.Erase);
        Assert.True(shell.Landscape.BeginStroke(Middle));
        shell.Landscape.EndStroke();
        Assert.Empty(set.Instances);
        shell.Scene!.Undo();
        Assert.Equal(scattered, set.Instances);
        shell.Scene.Undo();
        Assert.Empty(set.Instances);
    }

    [Fact]
    public void EscapeCancelsAScatterAndForgetsTheSetItMade()
    {
        using var shell = NewShell();
        Assert.True(shell.Landscape.BeginStroke(Middle));
        shell.Landscape.CancelStroke();
        Assert.Empty(shell.Landscape.Sets);
        Assert.Single(_sent.OfType<Wire.ReleaseLiveInstances>());
        Assert.False(shell.Scene!.CanUndo);
    }
}
