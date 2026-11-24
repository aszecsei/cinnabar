using System.Globalization;
using Cinnabar.Editor.Maths;

namespace Cinnabar.Editor.Document;

/// <summary>One instance of a foliage set: its position, rotation and scale, relative to its entity.</summary>
public readonly record struct FoliageInstance(Vec3 Position, Quat Rotation, Vec3 Scale);

/// <summary>
/// The text of an <c>.instances</c> file (see docs/content/kinds/instance-sets.md): a header, then a line for each
/// instance of its position, its rotation as a quaternion and its scale, which the cooker cooks to an instance set.
/// </summary>
public static class InstancesFile
{
    /// <summary>The file's extension.</summary>
    public const string Extension = ".instances";

    /// <summary>The set as the file's text.</summary>
    public static string Write(IReadOnlyList<FoliageInstance> instances)
    {
        var text = new System.Text.StringBuilder();
        text.Append("instances 1\n");
        text.Append("# Each line is an instance: its position x y z in meters, its rotation as a quaternion x y z w, and its scale x y z,\n");
        text.Append("# relative to the entity whose Instanced_Mesh_Renderer names the set.\n");
        static string F(double v) => ((float)v).ToString("R", CultureInfo.InvariantCulture);
        foreach (var i in instances)
        {
            text.Append($"i {F(i.Position.X)} {F(i.Position.Y)} {F(i.Position.Z)} {F(i.Rotation.X)} {F(i.Rotation.Y)} {F(i.Rotation.Z)} {F(i.Rotation.W)} {F(i.Scale.X)} {F(i.Scale.Y)} {F(i.Scale.Z)}\n");
        }
        return text.ToString();
    }

    /// <summary>The instances of a file's text, or null with the first problem's line and message.</summary>
    public static (IReadOnlyList<FoliageInstance>? Instances, (int Line, string Message)? Problem) Parse(string text)
    {
        var instances = new List<FoliageInstance>();
        var header = false;
        var lines = text.Split('\n');
        for (var n = 0; n < lines.Length; n++)
        {
            var line = lines[n];
            var hash = line.IndexOf('#');
            var words = (hash >= 0 ? line[..hash] : line).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (words.Length == 0)
            {
                continue;
            }
            if (!header)
            {
                if (words is not ["instances", "1"])
                {
                    return (null, (n + 1, "an instances file starts with \"instances 1\""));
                }
                header = true;
                continue;
            }
            if (words.Length != 11 || words[0] != "i")
            {
                return (null, (n + 1, "an instance is i and ten numbers: its position, its rotation and its scale"));
            }
            var v = new double[10];
            for (var k = 0; k < 10; k++)
            {
                if (!double.TryParse(words[k + 1], NumberStyles.Float, CultureInfo.InvariantCulture, out v[k]) || !double.IsFinite(v[k]))
                {
                    return (null, (n + 1, $"{words[k + 1]} is not a number"));
                }
            }
            instances.Add(new FoliageInstance(new Vec3(v[0], v[1], v[2]), new Quat(v[3], v[4], v[5], v[6]), new Vec3(v[7], v[8], v[9])));
        }
        return header ? (instances, null) : (null, (1, "an instances file starts with \"instances 1\""));
    }
}

/// <summary>
/// A foliage set that the landscape tools scatter (see docs/editor/landscape.md#foliage): an <c>.instances</c> file, its
/// GUID, and its instances, a snapshot that each edit replaces. The scene's undo stack holds its strokes, as
/// <see cref="FoliageOperation"/>s. It is dirty while its instances are not the snapshot that the file has.
/// </summary>
public sealed class FoliageSet(string guid, string path, IReadOnlyList<FoliageInstance> instances, SavedSnapshot<IReadOnlyList<FoliageInstance>> saved)
    : LiveSnapshotAsset<IReadOnlyList<FoliageInstance>>(guid, path, instances, saved)
{
    /// <summary>A new set, which has no file until it is saved.</summary>
    public FoliageSet(string guid, string path) : this(guid, path, [], new SavedSnapshot<IReadOnlyList<FoliageInstance>>.NoFile())
    {
    }

    public IReadOnlyList<FoliageInstance> Instances => Current;

    /// <summary>The instances changed: by a stroke's step, an undo or a redo.</summary>
    public event Action<FoliageSet>? Changed;

    /// <summary>Sets the instances to a snapshot.</summary>
    public void Set(IReadOnlyList<FoliageInstance> instances)
    {
        Current = instances;
        Changed?.Invoke(this);
    }

    protected override byte[] Encode(IReadOnlyList<FoliageInstance> snapshot) => Utf8Text.Encode(InstancesFile.Write(snapshot));

    /// <summary>A set from its file, or null with the reason when it cannot be read.</summary>
    public static (FoliageSet? Set, string? Problem) Open(string guid, string path)
    {
        string text;
        try
        {
            text = File.ReadAllText(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return (null, e.Message);
        }
        var (instances, problem) = InstancesFile.Parse(text);
        if (instances == null)
        {
            return (null, $"line {problem!.Value.Line}: {problem.Value.Message}");
        }
        return (new FoliageSet(guid, path, instances, new SavedSnapshot<IReadOnlyList<FoliageInstance>>.At(instances)), null);
    }
}

/// <summary>
/// A stroke on a foliage set, on the scene's undo stack: it sets the set's instances to the snapshot after the stroke,
/// and its inverse to the one before. The shell sends the set to the host as a live instance set.
/// </summary>
public sealed record FoliageOperation(FoliageSet Set, IReadOnlyList<FoliageInstance> Before, IReadOnlyList<FoliageInstance> After)
    : SnapshotOperation<IReadOnlyList<FoliageInstance>>(Before, After)
{
    protected override void Restore(IReadOnlyList<FoliageInstance> snapshot) => Set.Set(snapshot);
}
