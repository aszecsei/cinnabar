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
/// The landscape tools (see docs/editor/landscape.md): the PNGs they read and write, the brushes and their strokes'
/// undo, the editor's pick of a terrain, and the Landscape tool in the shell, with the live textures that the game hears.
/// </summary>
public sealed class LandscapeTests : IDisposable
{
    readonly TempDirectory _temp = new("landscape");
    readonly List<ILinkMessage> _sent = [];

    public void Dispose() => _temp.Dispose();

    [Fact]
    public void PngsOf16BitGrayRoundTripAndEightBitTexelsWiden()
    {
        var gray16 = new PngImage(3, 2, 1, 16, [0, 1, 256, 32768, 65534, 65535]);
        var decoded = Png.Decode(Png.Encode(gray16));
        Assert.NotNull(decoded);
        Assert.Equal(16, decoded.Depth);
        Assert.Equal(gray16.Samples, decoded.Samples);

        var rgb8 = new PngImage(2, 1, 3, 8, [10, 20, 30, 255, 0, 0]);
        var widened = Png.Decode(Png.Encode(rgb8))!.FirstChannel16();
        Assert.Equal([(ushort)(10 * 257), (ushort)65535], widened);
        Assert.Null(Png.Decode([1, 2, 3]));
    }

    [Fact]
    public void TheWeatherMapStillReadsAndWritesItsPng()
    {
        var map = new WeatherMap(4, 2);
        map.Set(WeatherChannel.Coverage, 1, 1, 0.5);
        var back = WeatherMap.DecodePng(map.EncodePng());
        Assert.NotNull(back);
        Assert.Equal(map.Rgba, back.Rgba);
        Assert.Null(WeatherMap.DecodePng(Png.Encode(new PngImage(1, 1, 1, 16, [5]))));
    }

    static HeightGrid Flat(ushort value = 32768) => new(64, 64, value);

    static BrushDab Dab(double x, double y, double radius = 8, double strength = 1, double falloff = 0.5) => new(x, y, radius, radius, strength, falloff);

    [Fact]
    public void RaiseAndLowerChangeOnlyTheTexelsInsideTheBrushSymmetrically()
    {
        var grid = Flat();
        var stroke = new LandscapeStroke(grid, LandscapeBrush.Raise, Dab(32, 32));
        var rect = stroke.Apply(Dab(32, 32));
        Assert.True(grid[31, 31] > 32768);
        Assert.Equal(grid[31, 31], grid[32, 32]);
        Assert.Equal(grid[28, 31], grid[35, 31]);
        Assert.Equal(32768, grid[20, 32]);
        Assert.True(rect.X <= 24 && rect.Right >= 40);

        var lower = new LandscapeStroke(grid, LandscapeBrush.Lower, Dab(32, 32));
        lower.Apply(Dab(32, 32));
        Assert.Equal(32768, grid[32, 32]);
    }

    [Fact]
    public void SmoothFlattenAndNoiseDoWhatTheySay()
    {
        var grid = Flat(0);
        for (var y = 0; y < 64; y++)
        {
            for (var x = 0; x < 64; x++)
            {
                grid[x, y] = (ushort)((x + y) % 2 == 0 ? 40000 : 20000);
            }
        }
        double Spread(HeightGrid g) => Enumerable.Range(28, 8).SelectMany(y => Enumerable.Range(28, 8).Select(x => (double)g[x, y])).Max()
            - Enumerable.Range(28, 8).SelectMany(y => Enumerable.Range(28, 8).Select(x => (double)g[x, y])).Min();
        var before = Spread(grid);
        new LandscapeStroke(grid, LandscapeBrush.Smooth, Dab(32, 32)).Apply(Dab(32, 32));
        Assert.True(Spread(grid) < before / 2);

        var hill = Flat(10000);
        hill[10, 10] = 60000;
        var flatten = new LandscapeStroke(hill, LandscapeBrush.Flatten, Dab(40.5, 40.5));
        for (var i = 0; i < 20; i++)
        {
            flatten.Apply(Dab(12, 12));
        }
        Assert.InRange(hill[10, 10], 9990, 10010);

        var noisy = Flat();
        new LandscapeStroke(noisy, LandscapeBrush.Noise, Dab(32, 32)).Apply(Dab(32, 32));
        var again = Flat();
        new LandscapeStroke(again, LandscapeBrush.Noise, Dab(32, 32)).Apply(Dab(32, 32));
        Assert.Equal(noisy.Texels, again.Texels);
        Assert.Contains(noisy.Texels, t => t != 32768);
    }

    [Fact]
    public void ARampSlopesFromWhereTheStrokeStartedAndIsDrawnAgainAtEachStep()
    {
        var grid = Flat(0);
        for (var x = 48; x < 64; x++)
        {
            for (var y = 0; y < 64; y++)
            {
                grid[x, y] = 60000;
            }
        }
        var ramp = new LandscapeStroke(grid, LandscapeBrush.Ramp, Dab(8, 32, 4, 1, 0));
        ramp.Apply(Dab(30, 32, 4, 1, 0));
        // Drawn again to the far side: the first end's step is gone.
        ramp.Apply(Dab(56, 32, 4, 1, 0));
        var row = Enumerable.Range(8, 48).Select(x => (int)grid[x, 32]).ToList();
        Assert.True(row.Zip(row.Skip(1)).All(p => p.Second >= p.First), "it rises along the ramp");
        Assert.InRange(grid[31, 32], 20000, 40000);
        Assert.Equal(0, grid[31, 40]);
    }

    [Fact]
    public void PaintRaisesALayerAndTheWeightsStillAddUpToOne()
    {
        var grid = HeightGrid.Of(16, 16, 65535, 0, 0, 0);
        var stroke = new LandscapeStroke(grid, LandscapeBrush.Paint, Dab(8, 8, 4), layer: 2);
        // Each dab moves it a quarter of the way: eight make it 1 - 0.75^8, about 0.9.
        for (var i = 0; i < 8; i++)
        {
            stroke.Apply(Dab(8, 8, 4));
        }
        Assert.True(grid[8, 8, 2] > 50000, $"the third layer is most of the middle: {grid[8, 8, 2]}");
        Assert.InRange(grid[8, 8, 0] + grid[8, 8, 1] + grid[8, 8, 2] + grid[8, 8, 3], 65533, 65537);
        Assert.Equal(65535, grid[0, 0, 0]);
        Assert.Equal(0, grid[0, 0, 2]);
        var patch = Assert.Single(stroke.Patches());
        // The tile is the whole 16 by 16 grid, four values a texel.
        Assert.Equal(16 * 16 * 4, patch.After.Length);
        stroke.Restore();
        Assert.All(Enumerable.Range(0, 256), i => Assert.Equal(65535, grid.Texels[i * 4]));
    }

    [Fact]
    public void ALayerMapRoundTripsAsAnRgbaPng()
    {
        var grid = HeightGrid.Of(2, 1, 65535, 0, 0, 0);
        grid[1, 0, 0] = 0;
        grid[1, 0, 3] = 65535;
        var map = new LandscapeMap("00000000000000000000000000000002", _temp.Combine("l.png"), LandscapeMapKind.Layers, grid);
        var png = Png.Decode(map.EncodePng())!;
        Assert.Equal((4, 8), (png.Channels, png.Depth));
        Assert.Equal([(ushort)255, 0, 0, 0, 0, 0, 0, 255], png.Samples);
        Assert.Equal([(ushort)65535, 0, 0, 0, 0, 0, 0, 65535], png.Channels16(4));
    }

    [Fact]
    public void AStrokesPatchesAreItsChangedTilesAndItsRestorePutsThemBack()
    {
        var grid = Flat();
        var original = (ushort[])grid.Texels.Clone();
        var stroke = new LandscapeStroke(grid, LandscapeBrush.Hole, Dab(10, 10, 3));
        stroke.Apply(Dab(10, 10, 3));
        Assert.Equal(0, grid[10, 10]);
        var patches = stroke.Patches();
        var patch = Assert.Single(patches);
        Assert.Equal(new TexelRect(0, 0, HeightGrid.Tile, HeightGrid.Tile), patch.Rect);
        stroke.Restore();
        Assert.Equal(original, grid.Texels);
    }

    [Fact]
    public void AnOperationAndItsInverseAreBitExactAndSetTheRevision()
    {
        var grid = Flat();
        var map = new LandscapeMap("00000000000000000000000000000001", _temp.Combine("h.png"), LandscapeMapKind.Height, grid);
        var start = map.Revision;
        var stroke = new LandscapeStroke(grid, LandscapeBrush.Raise, Dab(32, 32));
        var revision = LandscapeMap.NextRevision();
        map.Touched(stroke.Apply(Dab(32, 32)), revision);
        var after = (ushort[])grid.Texels.Clone();
        var op = new LandscapeOperation(map, stroke.Patches(), start, revision);
        var changes = new List<TexelRect>();
        map.Changed += (_, rect) => changes.Add(rect);

        var inverse = op.Apply(new Scene());
        Assert.Equal(after, grid.Texels);
        inverse.Apply(new Scene());
        Assert.All(grid.Texels, t => Assert.Equal(32768, t));
        Assert.Equal(start, map.Revision);
        op.Apply(new Scene());
        Assert.Equal(after, grid.Texels);
        Assert.Equal(revision, map.Revision);
        Assert.Equal(3, changes.Count);
    }

    [Fact]
    public void APickHitsTheHeightMapAndPassesThroughAHole()
    {
        var surface = new LandscapeSurface(1, 16, 16, 1, 0, 4, "a", "b");
        var height = new HeightGrid(16, 16, 32768);
        var hit = LandscapePick.Ray(surface, height, null, new Vec3(-2, 10, 3), new Vec3(0, -1, 0));
        Assert.NotNull(hit);
        Assert.Equal(2, hit.Value.Local.Y, 3);
        Assert.Equal(8, hit.Value.Distance, 3);
        Assert.Equal((-2 + 8) / 16.0, hit.Value.U, 6);

        var mask = new HeightGrid(16, 16, 65535);
        mask[6, 11] = 0;
        Assert.Null(LandscapePick.Ray(surface, height, mask, new Vec3(-1.5, 10, 3.5), new Vec3(0, -1, 0)));
        Assert.Null(LandscapePick.Ray(surface, height, null, new Vec3(20, 10, 0), new Vec3(0, -1, 0)));
        // A slanted ray hits where it crosses the height.
        var slanted = LandscapePick.Ray(surface, height, null, new Vec3(-6, 6, 0), new Vec3(1, -1, 0).Normalized());
        Assert.NotNull(slanted);
        Assert.Equal(-2, slanted.Value.Local.X, 2);
    }

    const string HeightGuid = "9a1b2c3d4e5f60718293a4b5c6d7e8f9";
    const string MaterialGuid = "0f1e2d3c4b5a69788796a5b4c3d2e1f0";

    static ulong Handle(uint index) => 1UL << 32 | index;

    EditorShell NewShell()
    {
        Directory.CreateDirectory(_temp.Path);
        File.WriteAllBytes(_temp.Combine("terrain_height.png"), Png.Encode(new PngImage(16, 16, 1, 16, [.. Enumerable.Repeat((ushort)32768, 256)])));
        var text = "scene 1\n\nentity 0000000000000001\nname = \"Terrain\"\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n" +
            $"component 51 Surface_Renderer\n\tsize = [16, 16]\n\tmaterial = ${MaterialGuid}\n\tcell = 1\n\theight_range = [0, 4]\n\theight_map = ${HeightGuid}\n";
        var shell = TestShell.Open(_temp, "main.scene", text);
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [new Importer(AssetKind.Texture, ".png", [])], [], []));
        shell.Assets.Apply(new AssetSnapshot([TestAssets.Make(HeightGuid, AssetKind.Texture, "terrain_height.png")], []));
        shell.Host.LinkForTests(_sent.Add);
        shell.OnGameMessage(new Wire.EntitySnapshot([new Wire.EntityInfo(Handle(0), "Terrain", 1, 1, 0, true, [1, 51])]));
        shell.Viewports[0].Session.Show(new PixelSize(1600, 900));
        // 20 m over the terrain's middle, looking down.
        shell.Camera.Place([0, (long)(20 * Pose.Unit), 0], 0, -EditorCamera.MaxPitch);
        if (shell.Camera.Forward.Y > 0)
        {
            shell.Camera.Place([0, (long)(20 * Pose.Unit), 0], 0, EditorCamera.MaxPitch);
        }
        shell.Selection.Select(Handle(0));
        return shell;
    }

    static readonly Vec2 Middle = new(800, 450);

    [Fact]
    public void SelectingATerrainSetsItsContextAndTheToolPaintsOnlyThen()
    {
        using var shell = NewShell();
        Assert.True(shell.Context.IsActive(LandscapeSession.TerrainContext));
        Assert.False(shell.Landscape.BeginStroke(Middle), "the tool is not the Landscape tool");
        shell.Commands.Get(EditorCommands.LandscapeTool).Execute();
        Assert.Equal(Tool.Landscape, shell.Tool);
        shell.Selection.Select(0);
        Assert.False(shell.Context.IsActive(LandscapeSession.TerrainContext));
        Assert.False(shell.Landscape.BeginStroke(Middle));
    }

    [Fact]
    public void AStrokeShowsAtOnceUndoesAsOneEntryAndSavesThePng()
    {
        using var shell = NewShell();
        shell.SetTool(Tool.Landscape);
        _sent.Clear();
        Assert.True(shell.Landscape.BeginStroke(Middle));
        var whole = Assert.Single(_sent.OfType<Wire.LiveTexture>());
        Assert.Equal(Convert.FromHexString(HeightGuid), whole.Guid);
        Assert.Equal(Wire.LiveTextureUsage.Height, whole.Usage);
        Assert.NotEmpty(_sent.OfType<Wire.LiveTextureRegion>());
        shell.Landscape.DragStroke(new Vec2(850, 450));
        shell.Landscape.EndStroke();
        var map = Assert.Single(shell.Landscape.Maps);
        var raised = map.Grid[8, 8];
        Assert.True(raised > 32768);
        Assert.True(map.IsDirty);
        Assert.True(shell.Scene!.CanUndo);

        _sent.Clear();
        shell.Scene.Undo();
        Assert.Equal(32768, map.Grid[8, 8]);
        Assert.NotEmpty(_sent.OfType<Wire.LiveTextureRegion>());
        Assert.False(map.IsDirty, "undo back to the file's texels");
        shell.Scene.Redo();
        Assert.Equal(raised, map.Grid[8, 8]);

        Assert.True(shell.SaveScene());
        Assert.False(map.IsDirty);
        var saved = Png.Decode(File.ReadAllBytes(_temp.Combine("terrain_height.png")));
        Assert.NotNull(saved);
        Assert.Equal(16, saved.Depth);
        Assert.Equal(raised, saved.Samples[8 * 16 + 8]);
    }

    [Fact]
    public void EscapeCancelsAStrokeAndPutsTheTexelsBack()
    {
        using var shell = NewShell();
        shell.SetTool(Tool.Landscape);
        Assert.True(shell.Landscape.BeginStroke(Middle));
        shell.Landscape.CancelStroke();
        var map = Assert.Single(shell.Landscape.Maps);
        Assert.All(map.Grid.Texels, t => Assert.Equal(32768, t));
        Assert.False(shell.Scene!.CanUndo);
        Assert.False(map.IsDirty);
    }

    [Fact]
    public void ALostCaptureCancelsAStrokeAndAnEndedStrokeDoesNothing()
    {
        using var shell = NewShell();
        shell.SetTool(Tool.Landscape);
        var drag = TestShell.Press(shell, Middle);
        Assert.NotNull(drag);
        drag.Move(new Vec2(850, 450), default);
        drag.Lost();
        Assert.False(shell.Landscape.IsStroking);
        var map = Assert.Single(shell.Landscape.Maps);
        Assert.All(map.Grid.Texels, t => Assert.Equal(32768, t));
        Assert.False(shell.Scene!.CanUndo);

        // A change of tool ends the stroke; its drag then leaves the next stroke alone.
        var stale = TestShell.Press(shell, Middle)!;
        shell.SetTool(Tool.Move);
        shell.SetTool(Tool.Landscape);
        var next = TestShell.Press(shell, Middle)!;
        stale.End(default);
        stale.Cancel();
        Assert.True(shell.Landscape.IsStroking);
        Assert.False(shell.Scene.CanUndo);
        next.End(default);
        Assert.Equal("Sculpt (Raise)", Assert.Single(shell.Scene.History).Label);
    }

    [Fact]
    public void AStrokeKeepsTheBrushThatItBeganWith()
    {
        using var shell = NewShell();
        shell.SetTool(Tool.Landscape);
        Assert.True(shell.Landscape.BeginStroke(Middle));
        shell.Landscape.SetBrush(LandscapeBrush.Hole);
        shell.Landscape.DragStroke(new Vec2(850, 450));
        shell.Landscape.EndStroke();
        Assert.Equal("Sculpt (Raise)", Assert.Single(shell.Scene!.History).Label);
        Assert.DoesNotContain(shell.Landscape.Maps, m => m.Kind == LandscapeMapKind.Mask);
    }

    [Theory]
    [InlineData(LandscapeBrush.Raise, LandscapeSession.BrushTarget.Height)]
    [InlineData(LandscapeBrush.Ramp, LandscapeSession.BrushTarget.Height)]
    [InlineData(LandscapeBrush.Noise, LandscapeSession.BrushTarget.Height)]
    [InlineData(LandscapeBrush.Hole, LandscapeSession.BrushTarget.Mask)]
    [InlineData(LandscapeBrush.Fill, LandscapeSession.BrushTarget.Mask)]
    [InlineData(LandscapeBrush.Paint, LandscapeSession.BrushTarget.Layers)]
    [InlineData(LandscapeBrush.Scatter, LandscapeSession.BrushTarget.Foliage)]
    [InlineData(LandscapeBrush.Erase, LandscapeSession.BrushTarget.Foliage)]
    public void EachBrushPaintsOneTarget(LandscapeBrush brush, LandscapeSession.BrushTarget target) =>
        Assert.Equal(target, LandscapeSession.TargetOf(brush));

    [Fact]
    public void AHoleOnASurfaceWithoutAMaskMakesOneOfItsCellsAndNamesIt()
    {
        using var shell = NewShell();
        shell.SetTool(Tool.Landscape);
        shell.Landscape.SetBrush(LandscapeBrush.Hole);
        shell.Landscape.SetRadius(1);
        _sent.Clear();
        Assert.True(shell.Landscape.BeginStroke(Middle));
        shell.Landscape.EndStroke();
        var mask = Assert.Single(shell.Landscape.Maps, m => m.Kind == LandscapeMapKind.Mask);
        Assert.Equal((16, 16), (mask.Grid.Width, mask.Grid.Height));
        Assert.Equal(0, mask.Grid[8, 8]);
        Assert.Equal(65535, mask.Grid[0, 0]);
        Assert.Contains(_sent.OfType<Wire.LiveTexture>(), t => t.Usage == Wire.LiveTextureUsage.Mask);
        var named = LandscapeSurface.Of(shell.Scene!.Scene.Find(1)!)!.HoleMask;
        Assert.Equal(mask.Guid, named);

        Assert.True(shell.SaveScene());
        Assert.True(File.Exists(mask.Path));
        Assert.Contains("usage = mask", File.ReadAllText(mask.Path + ".meta"));
        Assert.Contains("kernel = box", File.ReadAllText(mask.Path + ".meta"));
        var png = Png.Decode(File.ReadAllBytes(mask.Path))!;
        Assert.Equal(8, png.Depth);
        Assert.Equal(0, png.Samples[8 * 16 + 8]);

        // Undo takes the mask out of the surface with the hole.
        shell.Scene.Undo();
        Assert.Equal("", LandscapeSurface.Of(shell.Scene.Scene.Find(1)!)!.HoleMask);
    }

    [Fact]
    public void PaintOnASurfaceWithoutALayerMapMakesOneTheHeightMapsSizeAndNamesIt()
    {
        using var shell = NewShell();
        shell.SetTool(Tool.Landscape);
        shell.Landscape.SetBrush(LandscapeBrush.Paint);
        shell.Landscape.SetLayer(1);
        _sent.Clear();
        Assert.True(shell.Landscape.BeginStroke(Middle));
        shell.Landscape.EndStroke();
        var layers = Assert.Single(shell.Landscape.Maps, m => m.Kind == LandscapeMapKind.Layers);
        Assert.Equal((16, 16, 4), (layers.Grid.Width, layers.Grid.Height, layers.Grid.Channels));
        Assert.True(layers.Grid[8, 8, 1] > 0);
        Assert.Equal(65535, layers.Grid[0, 0, 0]);
        var live = Assert.Single(_sent.OfType<Wire.LiveTexture>(), t => t.Usage == Wire.LiveTextureUsage.Layers);
        Assert.Equal(16 * 16 * 4, live.Texels.Length);
        Assert.Equal(layers.Guid, LandscapeSurface.Of(shell.Scene!.Scene.Find(1)!)!.LayerMap);

        Assert.True(shell.SaveScene());
        Assert.Contains("usage = data", File.ReadAllText(layers.Path + ".meta"));
        Assert.Equal(4, Png.Decode(File.ReadAllBytes(layers.Path))!.Channels);
        shell.Scene.Undo();
        Assert.Equal("", LandscapeSurface.Of(shell.Scene.Scene.Find(1)!)!.LayerMap);
    }

    [Fact]
    public void ACookedSavedMapIsLetGoOfAndANewGameStateGetsTheLiveOnesAgain()
    {
        using var shell = NewShell();
        shell.SetTool(Tool.Landscape);
        Assert.True(shell.Landscape.BeginStroke(Middle));
        shell.Landscape.EndStroke();
        var map = Assert.Single(shell.Landscape.Maps);
        Assert.True(map.IsLive);
        Assert.True(shell.SaveScene());
        _sent.Clear();
        shell.Landscape.ReleaseCooked();
        Assert.Single(_sent.OfType<Wire.ReleaseLiveTexture>());
        Assert.False(map.IsLive);

        Assert.True(shell.Landscape.BeginStroke(Middle));
        shell.Landscape.EndStroke();
        _sent.Clear();
        shell.Landscape.SendLiveMaps();
        Assert.Single(_sent.OfType<Wire.LiveTexture>());
    }
}
