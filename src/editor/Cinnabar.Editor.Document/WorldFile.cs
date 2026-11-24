using System.Globalization;

namespace Cinnabar.Editor.Document;

/// <summary>
/// A scene of a world: its <c>scene $&lt;guid&gt;</c> line and the setting lines after it. Its settings are read from
/// those lines each time, so the scene has no state of its own that an edit could leave behind.
/// </summary>
public sealed class WorldScene : FieldBlock
{
    internal WorldScene(string guid) => Guid = guid;

    /// <summary>The scene asset's GUID, as 32 lowercase hex digits.</summary>
    public string Guid { get; }

    public bool Persistent => Get("persistent") == "true";

    /// <summary>The corner of the bounds with the lowest coordinates in meters, or null when the line is missing or is not three numbers.</summary>
    public double[]? Min => Vector("min");

    /// <summary>The corner of the bounds with the highest coordinates in meters, or null when the line is missing or is not three numbers.</summary>
    public double[]? Max => Vector("max");

    public double? LoadDistance => Number("load_distance");

    /// <summary>The unload distance in meters, or null when the line is missing, so the cooker uses the load distance times <see cref="WorldFile.DefaultUnloadFactor"/>.</summary>
    public double? UnloadDistance => Number("unload_distance");

    /// <summary><see cref="Min"/> as World_Position units, as the cooker makes them, or null when it has none or it is out of range.</summary>
    public long[]? RawMin => WorldFile.Raw(Min);

    /// <summary><see cref="Max"/> as World_Position units, as the cooker makes them, or null when it has none or it is out of range.</summary>
    public long[]? RawMax => WorldFile.Raw(Max);

    double? Number(string name) =>
        Get(name) is { } value && double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var number) ? number : null;

    double[]? Vector(string name)
    {
        if (Get(name)?.Trim() is not { } value)
        {
            return null;
        }
        if (!value.StartsWith('[') || !value.EndsWith(']'))
        {
            return null;
        }
        var parts = value[1..^1].Split(',', StringSplitOptions.TrimEntries);
        var numbers = new double[3];
        if (parts.Length != 3 || parts.Where((p, i) => !double.TryParse(p, NumberStyles.Float, CultureInfo.InvariantCulture, out numbers[i])).Any())
        {
            return null;
        }
        return numbers;
    }
}

/// <summary>
/// A world's text (see docs/content/kinds/worlds.md) as whole lines: a file writes back as it was, and an edit changes
/// only its own lines. It reads the scenes as the cooker does, and a line that the cooker would refuse is kept as it
/// is, so a world with problems still opens.
/// </summary>
public sealed class WorldFile : BlockListFile, ITextFile<WorldFile>
{
    public const string Header = "a world starts with `world 1`";

    /// <summary>The unload distance of a scene that has no <c>unload_distance</c>, as a factor of its load distance (<c>DEFAULT_UNLOAD_FACTOR</c> of the format).</summary>
    public const double DefaultUnloadFactor = 1.25;

    // World_Position units per meter: 2^24.
    const double UnitsPerMeter = 16777216;
    const double PositionLimit = (double)((1L << 62) - 1);

    WorldFile()
    {
    }

    /// <summary>The scenes in the file's order.</summary>
    public IEnumerable<WorldScene> Scenes => _blocks.OfType<WorldScene>();

    public WorldScene? Find(string guid) => Scenes.FirstOrDefault(s => s.Guid == guid.ToLowerInvariant());

    /// <summary>
    /// Reads a file's text. The file is null, with a problem at a line, when its first line that is not a comment is not
    /// <c>world 1</c>, which is the only thing that it refuses.
    /// </summary>
    public static (WorldFile? File, MaterialProblem? Problem) Parse(string text)
    {
        var file = new WorldFile();
        var header = false;
        var number = 0;
        WorldScene? scene = null;
        // The blank and comment lines after the scene's last line: they join the scene only if a setting follows them.
        var pending = new List<TextLine>();
        foreach (var line in TextLine.Split(text))
        {
            number++;
            file.FinalEnding = line.Ending;
            if (!header)
            {
                if (!line.IsBlank)
                {
                    if (line.Code.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries) is not ["world", "1"])
                    {
                        return (null, new MaterialProblem(number, Header));
                    }
                    header = true;
                }
                file.AppendOther(line);
            }
            else if (line.IsBlank)
            {
                if (scene == null)
                {
                    file.AppendOther(line);
                }
                else
                {
                    pending.Add(line);
                }
            }
            else if (ReadScene(line.Code) is { } guid)
            {
                file.AppendOther(pending);
                pending.Clear();
                scene = new WorldScene(guid);
                scene.Lines.Add(line);
                file._blocks.Add(scene);
            }
            else if (scene == null)
            {
                file.AppendOther(line);
            }
            else
            {
                scene.Lines.AddRange(pending);
                pending.Clear();
                scene.Lines.Add(line);
            }
        }
        file.AppendOther(pending);
        return header ? (file, null) : (null, new MaterialProblem(1, Header));
    }

    // The GUID of a scene's line, `scene $<32 hex digits>`, or null for another line.
    static string? ReadScene(string code)
    {
        var parts = code.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        return parts is ["scene", ['$', ..] word] && word.Length == 33 && word.Skip(1).All(Uri.IsHexDigit) ? word[1..].ToLowerInvariant() : null;
    }

    /// <summary>
    /// A coordinate in meters as World_Position units: scaled by 2^24 and rounded to the nearest unit, halves away from
    /// zero, as <c>world_raw_from_meters</c> does. Null for a coordinate that a World_Position cannot hold.
    /// </summary>
    public static long? Raw(double meters)
    {
        var scaled = Math.Round(meters * UnitsPerMeter, MidpointRounding.AwayFromZero);
        return Math.Abs(scaled) <= PositionLimit ? (long)scaled : null;
    }

    internal static long[]? Raw(double[]? meters)
    {
        if (meters == null)
        {
            return null;
        }
        var raw = new long[3];
        for (var i = 0; i < 3; i++)
        {
            if (Raw(meters[i]) is not { } units)
            {
                return null;
            }
            raw[i] = units;
        }
        return raw;
    }

    /// <summary>A number of meters as the file writes it: the shortest text that reads back as the same number.</summary>
    public static string Format(double number) => number.ToString("R", CultureInfo.InvariantCulture);

    /// <summary>Three numbers of meters as the file writes them, such as <c>[0, 1.5, -2]</c>.</summary>
    public static string Format(double[] vector) => $"[{string.Join(", ", vector.Select(Format))}]";

    /// <summary>Adds a scene that is not persistent, after the last scene.</summary>
    public WorldScene AddScene(string guid, double[] min, double[] max, double loadDistance)
    {
        var scene = new WorldScene(guid.ToLowerInvariant());
        scene.Lines.Add(new TextLine($"scene ${scene.Guid}", ""));
        InsertInGroup(scene, Scenes.LastOrDefault(), null);
        SetBounds(scene, min, max);
        SetDistances(scene, loadDistance, null);
        return scene;
    }

    public void SetBounds(WorldScene scene, double[] min, double[] max)
    {
        scene.Set("min", Format(min));
        scene.Set("max", Format(max));
    }

    /// <summary>Sets the distances in meters. A null unload distance removes its line, so the cooker uses the load distance times <see cref="DefaultUnloadFactor"/>.</summary>
    public void SetDistances(WorldScene scene, double loadDistance, double? unloadDistance)
    {
        scene.Set("load_distance", Format(loadDistance));
        if (unloadDistance is { } unload)
        {
            scene.Set("unload_distance", Format(unload));
        }
        else
        {
            scene.Set("unload_distance", null);
        }
    }

    /// <summary>
    /// Makes a scene persistent or not. Only its <c>persistent</c> line changes: a persistent scene keeps its bounds and
    /// distances, which the cooker ignores, so the scene has them again when it stops being persistent.
    /// </summary>
    public void SetPersistent(WorldScene scene, bool persistent)
    {
        if (persistent)
        {
            scene.Set("persistent", "true");
        }
        else
        {
            scene.Set("persistent", null);
        }
    }

    /// <summary>The scene that has a line, from 1, or null for a line of no scene.</summary>
    public WorldScene? SceneAt(int line) => BlockAt(line) as WorldScene;
}

/// <summary>What the game's streaming policy loads (see docs/world/streaming.md#the-policy), worked out as the game does.</summary>
public static class WorldStreaming
{
    /// <summary>
    /// The distance in meters from a position to a scene's bounds, 0 inside them, as <c>scene_distance</c> of
    /// <c>lib/engine/streaming</c> measures it: the position's nearest point in the bounds, per axis in World_Position
    /// units, and the difference in meters. Infinity for a scene without bounds.
    /// </summary>
    public static double Distance(WorldScene scene, long[] position)
    {
        if (scene.RawMin is not { } min || scene.RawMax is not { } max)
        {
            return double.PositiveInfinity;
        }
        var sum = 0.0;
        for (var axis = 0; axis < 3; axis++)
        {
            var closest = Math.Min(Math.Max(position[axis], min[axis]), max[axis]);
            var meters = (position[axis] - closest) * (1 / 16777216.0);
            sum += meters * meters;
        }
        return Math.Sqrt(sum);
    }

    /// <summary>
    /// Whether the policy loads a scene that is not loaded from a position: a persistent scene always, and another
    /// within its load distance, which the format keeps as an f32. The unload distance has no part in it.
    /// </summary>
    public static bool WouldLoad(WorldScene scene, long[] position) =>
        scene.Persistent || (scene.LoadDistance is { } load && Distance(scene, position) <= (float)load);
}

/// <summary>An open world and its edits.</summary>
public sealed class WorldDocument : TextGraphDocument<WorldFile>
{
    WorldDocument(string path, string guid, WorldFile file, string text) : base(path, guid, file, text)
    {
    }

    /// <summary>Reads a file. The document is null, with a problem, when it cannot be read or does not start as a world does.</summary>
    public static (WorldDocument? Document, MaterialProblem? Problem) Open(string path, string guid) =>
        Open(path, (full, file, text) => new WorldDocument(full, guid, file, text));
}
