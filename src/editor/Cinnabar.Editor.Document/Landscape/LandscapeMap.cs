namespace Cinnabar.Editor.Document;

/// <summary>Which of a surface's textures a map is.</summary>
public enum LandscapeMapKind
{
    /// <summary>The <c>height_map</c>, a 16-bit gray PNG cooked as a <c>height</c> texture.</summary>
    Height,
    /// <summary>The <c>hole_mask</c>, an 8-bit gray PNG cooked as a <c>mask</c> texture with box mips.</summary>
    Mask,
}

/// <summary>
/// A height map or a hole mask that the landscape tools paint (see docs/editor/landscape.md#height-maps-and-masks): its
/// GUID, its file, its texels, and the revision that the file has. The scene's undo stack holds its strokes, as
/// <see cref="LandscapeOperation"/>s, so it keeps no history of its own. Each edit, undo and redo gives a new
/// <see cref="Revision"/>, and the map is dirty while it is not the one that the file has.
/// </summary>
public sealed class LandscapeMap(string guid, string path, LandscapeMapKind kind, HeightGrid grid)
{
    static int _revisions;

    /// <summary>The asset's GUID, as 32 lowercase hex digits.</summary>
    public string Guid { get; } = guid;

    /// <summary>The PNG's full path.</summary>
    public string Path { get; } = System.IO.Path.GetFullPath(path);

    public LandscapeMapKind Kind { get; } = kind;

    public HeightGrid Grid { get; } = grid;

    /// <summary>Which edit the texels are: every stroke, and so every undo and redo of one, has its own.</summary>
    public int Revision { get; private set; } = NextRevision();

    /// <summary>The revision that the file has, or null for a map with no file yet.</summary>
    public int? SavedRevision { get; private set; } = null;

    public bool IsDirty => Revision != SavedRevision;

    /// <summary>
    /// The host draws the map from the editor's texels: it was sent as a live texture and not let go of. A map that is
    /// saved and cooked is let go of until the next edit.
    /// </summary>
    public bool IsLive { get; set; }

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
        Revision = revision;
        Changed?.Invoke(this, changed);
    }

    /// <summary>The texels changed in place, as a stroke's step does, and the map is a new revision.</summary>
    public void Touched(TexelRect rect, int revision)
    {
        Revision = revision;
        Changed?.Invoke(this, rect);
    }

    /// <summary>The map as the PNG that the cooker reads: 16-bit gray for a height map, 8-bit gray for a mask.</summary>
    public byte[] EncodePng() => Kind == LandscapeMapKind.Height
        ? Png.Encode(new PngImage(Grid.Width, Grid.Height, 1, 16, Grid.Texels))
        : Png.Encode(new PngImage(Grid.Width, Grid.Height, 1, 8, [.. Grid.Texels.Select(t => (ushort)(t >> 8))]));

    /// <summary>Writes the map to its file, through a temporary file, and the file has this revision.</summary>
    public void Save()
    {
        WeatherMapFile.WriteAtomically(Path, EncodePng());
        SavedRevision = Revision;
    }

    /// <summary>A map from its file, whatever PNG it is: its first channel, widened to 16 bits. Null when it cannot be read.</summary>
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
        var map = new LandscapeMap(guid, path, kind, new HeightGrid(image.Width, image.Height, image.FirstChannel16()));
        map.SavedRevision = map.Revision;
        return map;
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
