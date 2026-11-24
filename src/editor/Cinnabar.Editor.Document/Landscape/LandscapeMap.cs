namespace Cinnabar.Editor.Document;

/// <summary>Which of a surface's textures a map is.</summary>
public enum LandscapeMapKind
{
    /// <summary>The <c>height_map</c>, a 16-bit gray PNG cooked as a <c>height</c> texture.</summary>
    Height,
    /// <summary>The <c>hole_mask</c>, an 8-bit gray PNG cooked as a <c>mask</c> texture with box mips.</summary>
    Mask,
    /// <summary>The <c>layer_map</c>, an 8-bit RGBA PNG cooked as a <c>data</c> texture: four layers' weights.</summary>
    Layers,
}

/// <summary>
/// A height map or a hole mask that the landscape tools paint (see docs/editor/landscape.md#height-maps-and-masks): its
/// GUID, its file, its texels, and the revision that the file has. The scene's undo stack holds its strokes, as
/// <see cref="LandscapeOperation"/>s, so it keeps no history of its own. Each edit, undo and redo gives a new
/// <see cref="Revision"/>, and the map is dirty while it is not the one that the file has. The texels change in place,
/// so the revision is the map's snapshot, and its strokes are not <see cref="SnapshotOperation{TSnapshot}"/>s.
/// </summary>
public sealed class LandscapeMap : LiveSnapshotAsset<int>
{
    static int _revisions;

    LandscapeMap(string guid, string path, LandscapeMapKind kind, HeightGrid grid, bool saved)
        : this(guid, path, kind, grid, NextRevision(), saved)
    {
    }

    LandscapeMap(string guid, string path, LandscapeMapKind kind, HeightGrid grid, int revision, bool saved)
        : base(guid, path, revision, saved ? new SavedSnapshot<int>.At(revision) : new SavedSnapshot<int>.NoFile())
    {
        Kind = kind;
        Grid = grid;
    }

    /// <summary>A new map, which has no file until it is saved.</summary>
    public LandscapeMap(string guid, string path, LandscapeMapKind kind, HeightGrid grid) : this(guid, path, kind, grid, saved: false)
    {
    }

    public LandscapeMapKind Kind { get; }

    public HeightGrid Grid { get; }

    /// <summary>Which edit the texels are: every stroke, and so every undo and redo of one, has its own.</summary>
    public int Revision => Current;

    /// <summary>The texels in a rectangle changed: by a stroke's step, an undo or a redo.</summary>
    public event Action<LandscapeMap, TexelRect>? Changed;

    /// <summary>A new revision, for an edit to take.</summary>
    public static int NextRevision() => Interlocked.Increment(ref _revisions);

    /// <summary>Writes tiles and sets the revision that they make, as an undo or a redo does.</summary>
    public void Set(IReadOnlyList<TilePatch> tiles, bool after, int revision)
    {
        var changed = TexelRect.Empty;
        foreach (var tile in tiles)
        {
            Grid.Write(tile.Rect, after ? tile.After : tile.Before);
            changed = changed.Union(tile.Rect);
        }
        Current = revision;
        Changed?.Invoke(this, changed);
    }

    /// <summary>The texels changed in place, as a stroke's step does, and the map is a new revision.</summary>
    public void Touched(TexelRect rect, int revision)
    {
        Current = revision;
        Changed?.Invoke(this, rect);
    }

    /// <summary>
    /// The map as the PNG that the cooker reads: 16-bit gray for a height map, 8-bit gray for a mask, and 8-bit RGBA for
    /// a layer map.
    /// </summary>
    public byte[] EncodePng() => Kind == LandscapeMapKind.Height
        ? Png.Encode(new PngImage(Grid.Width, Grid.Height, 1, 16, Grid.Texels))
        : Png.Encode(new PngImage(Grid.Width, Grid.Height, Grid.Channels, 8, [.. Grid.Texels.Select(t => (ushort)(t >> 8))]));

    /// <summary>The values of a texel of a map of a kind: four for a layer map, one for the others.</summary>
    public static int ChannelsOf(LandscapeMapKind kind) => kind == LandscapeMapKind.Layers ? 4 : 1;

    // The texels are the current revision's: a map saves only its current one.
    protected override byte[] Encode(int snapshot) => EncodePng();

    /// <summary>
    /// A new map's <c>.meta</c>: for a layer map a data texture, its weights as they are, clamped; for a hole mask a
    /// mask, with box mips and clamped, as docs/rendering/surfaces.md#holes asks.
    /// </summary>
    protected override MetaFile.Builder NewMeta() => Kind == LandscapeMapKind.Layers
        ? MetaFile.New(Guid).Set("usage", "data").Set("sampler.wrap", "clamp")
        : MetaFile.New(Guid).Set("usage", "mask").Set("mip_map.kernel", "box").Set("sampler.wrap", "clamp");

    /// <summary>
    /// A map from its file, whatever PNG it is: its first channel, or for a layer map its first four, widened to 16 bits.
    /// Null when it cannot be read.
    /// </summary>
    public static LandscapeMap? Open(string guid, string path, LandscapeMapKind kind)
    {
        byte[] bytes;
        try
        {
            bytes = File.ReadAllBytes(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
        if (Png.Decode(bytes) is not { } image)
        {
            return null;
        }
        var channels = ChannelsOf(kind);
        return new LandscapeMap(guid, path, kind, new HeightGrid(image.Width, image.Height, image.Channels16(channels), channels), saved: true);
    }
}

/// <summary>
/// A stroke on a landscape map, on the scene's undo stack beside the scene's operations: it writes the changed tiles'
/// texels after the stroke, and its inverse writes them as they were. It has nothing for the host's world: the shell
/// sends the texels as a live texture instead.
/// </summary>
public sealed record LandscapeOperation(LandscapeMap Map, IReadOnlyList<TilePatch> Tiles, int BeforeRevision, int AfterRevision) : Operation(0)
{
    public override Operation Apply(Scene scene)
    {
        Map.Set(Tiles, after: true, AfterRevision);
        return new LandscapeOperation(Map, [.. Tiles.Select(t => t with { Before = t.After, After = t.Before })], AfterRevision, BeforeRevision);
    }

    public override Link.Protocol.Operation? ToWire() => null;
}
