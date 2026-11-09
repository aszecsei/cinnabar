using Avalonia;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The weather map that the Weather Map panel edits (see docs/editor/shell-and-panels.md#weather-map): the atmosphere
/// volume's map as a <see cref="WeatherMap"/>, where its file is, and the strokes since it was read, so a stroke can be
/// undone. It is the shell's, so a panel that docking rebuilds shows the same map and history. A stroke edits the map
/// and, when it ends, writes the PNG, which the daemon cooks and the host streams again: the strokes are asset writes,
/// not undo entries. Generate on a volume without a map writes a new file with its <c>.meta</c>, and then names it in
/// the volume as one undo entry.
/// </summary>
public sealed class WeatherMapSession(EditorShell shell)
{
    /// <summary>How many strokes the history keeps.</summary>
    public const int HistoryLength = 32;

    /// <summary>The sizes that a new map can have, texels on a side.</summary>
    public static readonly IReadOnlyList<int> Sizes = [256, 512, 1024];

    /// <summary>
    /// The map that the strokes edit, with the map before each stroke (the latest last, at most
    /// <see cref="HistoryLength"/>) and the map as it was when the stroke under way began, null between strokes.
    /// </summary>
    public sealed record Loaded(WeatherMap Map, IReadOnlyList<WeatherMap> History, WeatherMap? StrokeStart);

    /// <summary>Where the volume's map stands, as one value; the states that have a map hold it.</summary>
    public abstract record MapState
    {
        /// <summary>No volume, or a volume that names no map.</summary>
        public sealed record None : MapState;

        /// <summary>The volume names a map that the index does not list and the editor did not write.</summary>
        public sealed record Unknown(string Guid) : MapState;

        /// <summary>A map that was read: its GUID, its file and the map with its strokes.</summary>
        public abstract record Mapped(string Guid, string Path, Loaded Data) : MapState;

        /// <summary>The editor wrote the file, and keeps its path until the index lists the GUID.</summary>
        public sealed record Written(string Guid, string Path, Loaded Data) : Mapped(Guid, Path, Data);

        /// <summary>The index lists the map at its file.</summary>
        public sealed record Indexed(string Guid, string Path, Loaded Data) : Mapped(Guid, Path, Data);

        /// <summary>The map's file could not be read as an image.</summary>
        public sealed record Unreadable(string Guid, string Path, string Reason) : MapState;
    }

    MapState _state = new MapState.None();
    // The file that Generate wrote and the index does not list yet, so a Sync that finds the scene naming it, as a redo
    // does after an undo took the name away, reads it again. Sync drops it when the index lists the GUID.
    (string Guid, string Path)? _written;

    public MapState State => _state;

    public WeatherMap? Map => Data?.Map;

    public int Strokes => Data?.History.Count ?? 0;

    public bool IsPainting => Data?.StrokeStart != null;

    Loaded? Data => (_state as MapState.Mapped)?.Data;

    /// <summary>The state or the map changed, so a panel draws again.</summary>
    public event Action? Changed;

    // The one place that changes the state.
    void Transition(MapState next)
    {
        _state = next;
        Changed?.Invoke();
    }

    /// <summary>
    /// Follows the volume's map: the scene's, the index's and the cook link's changes all come here. A map that is
    /// the same stays as it is, with its history; another is read anew.
    /// </summary>
    public void Sync()
    {
        var guid = shell.AtmosphereVolume is { } volume ? Atmosphere.WeatherMapOf(volume) : "";
        var indexed = guid != "" && shell.Assets.Find(guid) is { } asset ? shell.Assets.FullPath(asset) : null;
        if (indexed != null && _written?.Guid == guid)
        {
            _written = null;
        }
        MapState next = guid == "" ? new MapState.None()
            : indexed != null ? Follow(guid, indexed)
            : _written is { } written && written.Guid == guid ? Follow(guid, written.Path)
            : _state is MapState.Unreadable unreadable && unreadable.Guid == guid ? unreadable
            : new MapState.Unknown(guid);
        if (next != _state)
        {
            Transition(next);
        }
    }

    // The map at a path: the one that is read, with its history, when it is the same file, else the file read anew. The
    // index compares paths without regard to case, so this does.
    MapState Follow(string guid, string path)
    {
        if (_state is MapState.Mapped current && string.Equals(current.Path, path, StringComparison.OrdinalIgnoreCase))
        {
            return Mapped(guid, current.Path, current.Data);
        }
        return Load(guid, path);
    }

    // A map that was read is Indexed when the index lists its GUID, else Written.
    MapState Mapped(string guid, string path, Loaded data) =>
        shell.Assets.Find(guid) != null ? new MapState.Indexed(guid, path, data) : new MapState.Written(guid, path, data);

    // Reads the file: the own decoder first, then Avalonia's, for the PNGs it does not read.
    MapState Load(string guid, string path)
    {
        WeatherMap? map;
        try
        {
            map = WeatherMap.DecodePng(File.ReadAllBytes(path)) ?? DecodeWithAvalonia(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return new MapState.Unreadable(guid, path, e.Message);
        }
        return map == null
            ? new MapState.Unreadable(guid, path, "the file is not an image that the editor reads")
            : Mapped(guid, path, new Loaded(map, [], null));
    }

    // A PNG with a palette, 16-bit texels or interlacing, through Avalonia's decoder.
    static WeatherMap? DecodeWithAvalonia(string path)
    {
        try
        {
            using var bitmap = new Bitmap(path);
            var size = bitmap.PixelSize;
            if (size.Width <= 0 || size.Height <= 0)
            {
                return null;
            }
            var map = new WeatherMap(size.Width, size.Height);
            var stride = size.Width * 4;
            var buffer = new byte[stride * size.Height];
            var pinned = System.Runtime.InteropServices.GCHandle.Alloc(buffer, System.Runtime.InteropServices.GCHandleType.Pinned);
            try
            {
                bitmap.CopyPixels(new PixelRect(size), pinned.AddrOfPinnedObject(), buffer.Length, stride);
            }
            finally
            {
                pinned.Free();
            }
            // Avalonia copies Bgra8888 on Windows; the map is RGBA.
            var swap = bitmap.Format == PixelFormat.Bgra8888 || bitmap.Format == null;
            for (var i = 0; i < buffer.Length; i += 4)
            {
                map.Rgba[i] = swap ? buffer[i + 2] : buffer[i];
                map.Rgba[i + 1] = buffer[i + 1];
                map.Rgba[i + 2] = swap ? buffer[i] : buffer[i + 2];
            }
            return map;
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            return null;
        }
    }

    /// <summary>Begins a stroke on the map: what it was is kept, for the history when the stroke ends.</summary>
    public void BeginStroke()
    {
        if (_state is MapState.Mapped { Data: { StrokeStart: null } data } mapped)
        {
            Transition(mapped with { Data = data with { StrokeStart = data.Map.Clone() } });
        }
    }

    /// <summary>Paints the stroke under way at a texel (see <see cref="WeatherMap.Paint"/>).</summary>
    public void Paint(WeatherChannel channel, double x, double y, double radius, double strength, double hardness, double value)
    {
        if (Data is not { StrokeStart: not null } data)
        {
            return;
        }
        data.Map.Paint(channel, x, y, radius, strength, hardness, value);
        Transition(_state);
    }

    /// <summary>Ends the stroke under way: it goes in the history, and the file is written.</summary>
    public void EndStroke()
    {
        if (_state is not MapState.Mapped { Data: { StrokeStart: { } start } data } mapped)
        {
            return;
        }
        var next = mapped with { Data = data with { StrokeStart = null, History = Remember(data.History, start) } };
        Write(next.Path, next.Data.Map);
        Transition(next);
    }

    /// <summary>Undoes the last stroke, or Generate, and writes the file.</summary>
    public bool UndoStroke()
    {
        if (_state is not MapState.Mapped { Data: { StrokeStart: null, History.Count: > 0 } data } mapped)
        {
            return false;
        }
        var next = mapped with { Data = data with { Map = data.History[^1], History = [.. data.History.Take(data.History.Count - 1)] } };
        Write(next.Path, next.Data.Map);
        Transition(next);
        return true;
    }

    /// <summary>Reads the file again, dropping the strokes since, and the history.</summary>
    public void RevertToSaved()
    {
        switch (_state)
        {
            case MapState.Mapped mapped:
                Transition(Load(mapped.Guid, mapped.Path));
                break;
            case MapState.Unreadable unreadable:
                Transition(Load(unreadable.Guid, unreadable.Path));
                break;
        }
    }

    /// <summary>
    /// Fills the map from noise. A volume with a map gets its file written over, with the map before it in the
    /// history; so does one whose map cannot be read, if its file is a PNG, with no history. A volume without a map
    /// gets a new file under the scene's content root, with its <c>.meta</c> first, and then names it in one undo
    /// entry, with the map's origin under the editor's camera unless the volume sets one.
    /// </summary>
    public bool Generate(WeatherGeneration generation)
    {
        if (IsPainting)
        {
            return false;
        }
        var generated = new WeatherMap(generation.Size, generation.Size);
        generated.Generate(generation);
        switch (_state)
        {
            case MapState.Mapped mapped:
                var next = mapped with { Data = new Loaded(generated, Remember(mapped.Data.History, mapped.Data.Map), null) };
                Write(next.Path, generated);
                Transition(next);
                return true;
            case MapState.Unreadable unreadable:
                return Replace(unreadable, generated);
        }
        if (shell.Scene is not { } scene)
        {
            shell.Console.Add(LogLevel.Warning, "weather: open a scene to give its clouds a weather map");
            return false;
        }
        if (!shell.CanEditScene)
        {
            shell.Console.Add(LogLevel.Warning, "weather: stop the game to give its clouds a weather map");
            return false;
        }
        var guid = WeatherMapFile.NewGuid();
        var path = WeatherMapFile.PathFor(ContentRootFor(scene.Path), scene.Path);
        if (File.Exists(path) || File.Exists(path + ".meta"))
        {
            shell.Console.Add(LogLevel.Error, $"weather: {path} exists already; name it in the clouds' weather map to paint it, or move it away");
            return false;
        }
        try
        {
            // A new map's .meta file, with its GUID and its import settings, is the editor's to write, so the scene's
            // reference resolves at the daemon's next pass. The daemon owns it from then on.
            SceneDocument.WriteAtomically(path + ".meta", WeatherMapFile.MetaText(guid));
            WeatherMapFile.WriteAtomically(path, generated.EncodePng());
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            shell.Console.Add(LogLevel.Error, $"weather: cannot write {path}: {e.Message}");
            return false;
        }
        _written = (guid, path);
        Transition(new MapState.Written(guid, path, new Loaded(generated, [], null)));
        var camera = shell.Camera.Position;
        var named = shell.EditAtmosphere("New Weather Map", (_, volume) =>
            Atmosphere.UseWeatherMap(volume, guid, Atmosphere.Setting(volume, SceneEdits.CloudsId, Atmosphere.WeatherOrigin) == null ? camera : null));
        shell.Console.Add(LogLevel.Info, $"weather: wrote {path}");
        if (!shell.Cook.Linked)
        {
            shell.Console.Add(LogLevel.Warning, "weather: the content daemon is not linked, so the map is not cooked until it is");
        }
        return named;
    }

    // A map that cannot be read is the volume's map all the same: a PNG is written over, with no history, and anything
    // else is left for the user to fix.
    bool Replace(MapState.Unreadable unreadable, WeatherMap generated)
    {
        if (!unreadable.Path.EndsWith(".png", StringComparison.OrdinalIgnoreCase))
        {
            shell.Console.Add(LogLevel.Error, $"weather: cannot read {unreadable.Path}: {unreadable.Reason}; fix or replace the file");
            return false;
        }
        if (!Write(unreadable.Path, generated))
        {
            return false;
        }
        if (shell.Assets.Find(unreadable.Guid) == null)
        {
            _written = (unreadable.Guid, unreadable.Path);
        }
        Transition(Mapped(unreadable.Guid, unreadable.Path, new Loaded(generated, [], null)));
        return true;
    }

    /// <summary>
    /// The content root that a scene is in, or the first root, or the scene's own folder when the index has none, as
    /// before the daemon links.
    /// </summary>
    string ContentRootFor(string scenePath)
    {
        var full = Path.GetFullPath(scenePath);
        var root = shell.Assets.Roots.FirstOrDefault(r => full.StartsWith(Path.GetFullPath(r.Dir).TrimEnd('\\', '/') + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            ?? shell.Assets.Roots.FirstOrDefault();
        return root != null ? Path.GetFullPath(root.Dir) : Path.GetDirectoryName(full)!;
    }

    // The history with the map before a stroke added, without the oldest past the limit.
    static List<WeatherMap> Remember(IReadOnlyList<WeatherMap> history, WeatherMap before)
    {
        var next = new List<WeatherMap>(history) { before };
        if (next.Count > HistoryLength)
        {
            next.RemoveAt(0);
        }
        return next;
    }

    // Writes the map over its file. A failure goes to the console; the map stays as painted, so the next write tries again.
    bool Write(string path, WeatherMap map)
    {
        try
        {
            WeatherMapFile.WriteAtomically(path, map.EncodePng());
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            shell.Console.Add(LogLevel.Error, $"weather: cannot write {path}: {e.Message}");
            return false;
        }
    }

    /// <summary>What the panel says over the map: where the file is, or why there is none to paint.</summary>
    public string Status() => _state switch
    {
        MapState.None => "The atmosphere's clouds have no weather map. New Weather Map makes one.",
        MapState.Unknown u => $"The content has no texture {u.Guid}. New Weather Map makes one in its place.",
        MapState.Written w when !shell.Cook.Linked => $"Written to {w.Path}. The content daemon is not linked, so the map is not cooked until it is.",
        MapState.Written w => $"Written to {w.Path}, which the content daemon is cooking.",
        MapState.Indexed i => i.Path,
        MapState.Unreadable u => $"Cannot read {u.Path}: {u.Reason}",
        _ => "",
    };
}
