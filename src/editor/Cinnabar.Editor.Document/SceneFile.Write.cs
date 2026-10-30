using System.Globalization;
using System.Text;

namespace Cinnabar.Editor.Document;

/// <summary>The writer of <see cref="SceneFile"/>.</summary>
public static partial class SceneFile
{
    public static string Write(Scene scene)
    {
        var sb = new StringBuilder();
        foreach (var comment in scene.HeaderComments)
        {
            sb.Append(comment).Append('\n');
        }
        sb.Append(CultureInfo.InvariantCulture, $"scene {Version}\n");
        foreach (var e in scene.Entities.OrderBy(e => e.Path ?? [e.Id], PathOrder.Instance))
        {
            sb.Append("\nentity ").Append(e.Path != null ? ScenePath.Format(e.Path) : e.Id.ToString("x16", CultureInfo.InvariantCulture)).Append('\n');
            // A plain entity writes what differs from an entity's defaults, and a prefab's entity what it overrides.
            var plain = e.Path == null && e.Prefab == "";
            if (plain ? e.Name.Length > 0 : e.Keys.HasFlag(SceneKeys.Name))
            {
                sb.Append("name = ").Append(TextQuote.Quote(e.Name)).Append('\n');
            }
            if (e.Path == null ? e.Parent != 0 : e.Keys.HasFlag(SceneKeys.Parent))
            {
                var parent = e.ParentPath is { } path && ScenePath.Id(path) == e.Parent ? SceneValue.EntityRef(path) : SceneValue.EntityRef(e.Parent);
                sb.Append("parent = ").Append(FormatValue(parent)).Append('\n');
            }
            if (e.Prefab != "")
            {
                sb.Append("prefab = $").Append(e.Prefab).Append('\n');
            }
            if (plain ? !e.Active : e.Keys.HasFlag(SceneKeys.Active))
            {
                sb.Append(e.Active ? "active = true\n" : "active = false\n");
            }
            if (e.Removed)
            {
                sb.Append("removed = true\n");
            }
            foreach (var (key, value) in e.UnknownKeys)
            {
                sb.Append(key).Append(" = ").Append(value).Append('\n');
            }
            foreach (var id in e.RemovedComponents)
            {
                sb.Append(CultureInfo.InvariantCulture, $"remove component {id}\n");
            }
            foreach (var script in e.RemovedBehaviours)
            {
                sb.Append("remove behaviour $").Append(script).Append('\n');
            }
            foreach (var c in e.Components.OrderBy(c => c.Id))
            {
                sb.Append(CultureInfo.InvariantCulture, $"component {c.Id} {c.Name}\n");
                WriteFields(sb, c.Fields);
            }
            foreach (var b in e.Behaviours)
            {
                sb.Append("behaviour ").Append(b.Script).Append('\n');
                WriteFields(sb, b.Fields);
            }
        }
        return sb.ToString();
    }

    // Paths in order of their IDs, a path before the longer ones that it starts.
    sealed class PathOrder : IComparer<IReadOnlyList<ulong>>
    {
        public static readonly PathOrder Instance = new();

        public int Compare(IReadOnlyList<ulong>? a, IReadOnlyList<ulong>? b)
        {
            for (var i = 0; i < Math.Min(a!.Count, b!.Count); i++)
            {
                if (a[i] != b[i])
                {
                    return a[i].CompareTo(b[i]);
                }
            }
            return a.Count.CompareTo(b.Count);
        }
    }

    static void WriteFields(StringBuilder sb, List<SceneField> fields)
    {
        foreach (var f in fields)
        {
            sb.Append('\t').Append(f.Name).Append(" = ").Append(FormatValue(f.Value)).Append('\n');
        }
    }

    public static string FormatValue(SceneValue value) => value.Kind switch
    {
        SceneValueKind.Bool => value.Bool ? "true" : "false",
        SceneValueKind.Number when value.Numbers.Count == 1 => FormatNumber(value.Numbers[0]),
        SceneValueKind.Number => "[" + string.Join(", ", value.Numbers.Select(FormatNumber)) + "]",
        SceneValueKind.String => TextQuote.Quote(value.Text),
        SceneValueKind.Name => value.Text,
        SceneValueKind.Asset => value.Asset == "" ? "$0" : $"${value.Asset}",
        _ when value.Path != null => "@" + ScenePath.Format(value.Path),
        _ => value.Entity == 0 ? "@0" : $"@{value.Entity:x16}",
    };

    // A float always has a point or an exponent, so it reads back as a float. A value that an f32 holds exactly, as
    // the editor writes for f32 fields, gets the f32's shortest form, so 0.70710677 is not 0.7071067690849304.
    static string FormatNumber(SceneNumber n)
    {
        if (n.Integer is { } integer)
        {
            return integer.ToString(CultureInfo.InvariantCulture);
        }
        var single = (float)n.Float;
        var text = single == n.Float
            ? single.ToString("R", CultureInfo.InvariantCulture)
            : n.Float.ToString("R", CultureInfo.InvariantCulture);
        return text.AsSpan().IndexOfAny(".Ee") >= 0 || !double.IsFinite(n.Float) ? text : text + ".0";
    }
}
