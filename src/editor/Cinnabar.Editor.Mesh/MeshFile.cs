using System.Collections.Immutable;
using System.Globalization;
using System.Text;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Mesh;

/// <summary>An error or a warning in a mesh file, at a line from 1, or 0 for the whole file.</summary>
public sealed record MeshFileProblem(int Line, string Message, bool IsError)
{
    public override string ToString() => Line > 0 ? $"{Line}: {Message}" : Message;
}

/// <summary>
/// Reads and writes mesh files (see docs/content/kinds/meshes.md#mesh-files). The cooker and the game read the same
/// format with <c>asset_format.mesh_text_parse</c>, and the two must agree. Writing puts the vertices first, then the
/// faces in order, each with its map line, then the sharp edges, so an edit changes the lines of the face it touches.
/// </summary>
public static class MeshFile
{
    public const int Version = 1;
    public const string Extension = ".mesh";

    /// <summary>Parses a file. The mesh is null when a problem is an error.</summary>
    public static (MeshData? Mesh, IReadOnlyList<MeshFileProblem> Problems) Parse(string text)
    {
        var parser = new Parser();
        var mesh = parser.Run(text);
        return (parser.Problems.Any(p => p.IsError) ? null : mesh, parser.Problems);
    }

    public static string Write(MeshData mesh)
    {
        var sb = new StringBuilder();
        foreach (var comment in mesh.HeaderComments)
        {
            sb.Append(comment).Append('\n');
        }
        sb.Append(CultureInfo.InvariantCulture, $"mesh {Version}\n");
        for (var slot = 0; slot < mesh.Materials.Length; slot++)
        {
            if (mesh.Materials[slot].Length > 0)
            {
                sb.Append(CultureInfo.InvariantCulture, $"material {slot} ${mesh.Materials[slot]}\n");
            }
        }
        foreach (var v in mesh.Vertices)
        {
            sb.Append('v');
            WriteNumbers(sb, v.X, v.Y, v.Z);
            sb.Append('\n');
        }
        foreach (var f in mesh.Faces)
        {
            sb.Append(CultureInfo.InvariantCulture, $"f {f.Slot}");
            foreach (var c in f.Corners)
            {
                sb.Append(CultureInfo.InvariantCulture, $" {c}");
            }
            sb.Append("\nmap");
            var m = f.Mapping;
            WriteNumbers(sb, m.UAxis.X, m.UAxis.Y, m.UAxis.Z, m.VAxis.X, m.VAxis.Y, m.VAxis.Z, m.ScaleU, m.ScaleV, m.ShiftU, m.ShiftV, m.Rotation);
            sb.Append('\n');
        }
        foreach (var e in mesh.SharpEdges)
        {
            sb.Append(CultureInfo.InvariantCulture, $"e {e.A} {e.B} sharp\n");
        }
        return sb.ToString();
    }

    static void WriteNumbers(StringBuilder sb, params double[] values)
    {
        foreach (var v in values)
        {
            sb.Append(' ').Append(FormatNumber(v));
        }
    }

    /// <summary>
    /// The shortest decimal that reads back as the same f32, without an exponent, as <c>format.mesh_text_write</c>
    /// writes it: the file holds f32-exact values, and the mesh's doubles round to them on save.
    /// </summary>
    public static string FormatNumber(double value)
    {
        var single = (float)value;
        if (single == 0)
        {
            return float.IsNegative(single) ? "-0" : "0";
        }
        var text = single.ToString("R", CultureInfo.InvariantCulture);
        if (text.IndexOfAny(['E', 'e']) < 0)
        {
            return text;
        }
        // "R" picks an exponent for small and large values; the decimal form has at most 28 places, and keeps every
        // digit that the shortest form had.
        return ((decimal)single).ToString(CultureInfo.InvariantCulture);
    }

    sealed class Parser
    {
        public List<MeshFileProblem> Problems { get; } = [];

        int _line;
        readonly List<string> _comments = [];
        readonly string[] _materials = Enumerable.Repeat("", MeshData.MaxSlots).ToArray();
        readonly List<Vec3> _vertices = [];
        readonly List<(int Slot, ImmutableArray<int> Corners, Mapping? Mapping, int Line)> _faces = [];
        readonly List<MeshEdge> _sharp = [];

        public MeshData Run(string text)
        {
            var header = false;
            foreach (var raw in text.Split('\n'))
            {
                _line++;
                var trimmed = raw.Trim();
                if (trimmed.Length == 0 || trimmed[0] == '#')
                {
                    if (!header && trimmed.Length > 0)
                    {
                        _comments.Add(trimmed);
                    }
                    continue;
                }
                if (!header)
                {
                    header = true;
                    if (trimmed != $"mesh {Version}")
                    {
                        Error($"a mesh file starts with `mesh {Version}`");
                        break;
                    }
                    continue;
                }
                var space = trimmed.IndexOf(' ');
                var word = space < 0 ? trimmed : trimmed[..space];
                var fields = space < 0 ? [] : trimmed[(space + 1)..].Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
                switch (word)
                {
                    case "material":
                        ParseMaterial(fields);
                        break;
                    case "v":
                        ParseVertex(fields);
                        break;
                    case "f":
                        ParseFace(fields);
                        break;
                    case "map":
                        ParseMap(fields);
                        break;
                    case "e":
                        ParseEdge(fields);
                        break;
                    default:
                        Warning($"the line \"{word}\" is unknown, so it is ignored");
                        break;
                }
            }
            if (!header)
            {
                Error($"a mesh file starts with `mesh {Version}`");
            }
            var vertices = _vertices.ToImmutableArray();
            var faces = new List<MeshFace>();
            foreach (var (slot, corners, mapping, line) in _faces)
            {
                _line = line;
                if (corners.FirstOrDefault(c => c >= vertices.Length, -1) is var c and >= 0)
                {
                    Error($"the face uses vertex {c}, and the file has {vertices.Length}");
                }
                faces.Add(new MeshFace(slot, corners, mapping ?? Mapping.WorldAligned(MeshData.FaceNormal(vertices, corners))));
            }
            _line = 0;
            foreach (var e in _sharp.Where(e => e.A >= vertices.Length || e.B >= vertices.Length))
            {
                Error($"the sharp edge {e.A} {e.B} uses a vertex the file does not have");
            }
            return new MeshData(_materials, vertices, faces, _sharp, _comments);
        }

        void Error(string message) => Problems.Add(new MeshFileProblem(_line, message, true));

        void Warning(string message) => Problems.Add(new MeshFileProblem(_line, message, false));

        void ParseMaterial(string[] fields)
        {
            if (fields.Length != 2)
            {
                Error("a material line is `material <slot> $<guid>`");
                return;
            }
            if (!int.TryParse(fields[0], NumberStyles.None, CultureInfo.InvariantCulture, out var slot) || slot >= MeshData.MaxSlots)
            {
                Error($"a material slot is 0 to {MeshData.MaxSlots - 1}, not \"{fields[0]}\"");
                return;
            }
            if (ParseAsset(fields[1]) is not { } guid)
            {
                Error($"a material is 32 hex digits after $, or $0 for none, not \"{fields[1]}\"");
                return;
            }
            _materials[slot] = guid;
        }

        static string? ParseAsset(string text)
        {
            if (text == "$0")
            {
                return "";
            }
            if (text.Length != 33 || text[0] != '$' || !text.Skip(1).All(Uri.IsHexDigit))
            {
                return null;
            }
            return text[1..].ToLowerInvariant();
        }

        void ParseVertex(string[] fields)
        {
            if (ParseNumbers(fields, 3) is not { } v)
            {
                Error("a vertex is `v <x> <y> <z>` in meters");
                return;
            }
            _vertices.Add(new Vec3(v[0], v[1], v[2]));
        }

        void ParseFace(string[] fields)
        {
            if (fields.Length < 4)
            {
                Error("a face is `f <slot> <v0> <v1> <v2> ...`, with three or more vertices");
                return;
            }
            if (!int.TryParse(fields[0], NumberStyles.None, CultureInfo.InvariantCulture, out var slot) || slot >= MeshData.MaxSlots)
            {
                Error($"a face's material slot is 0 to {MeshData.MaxSlots - 1}, not \"{fields[0]}\"");
                return;
            }
            var corners = new int[fields.Length - 1];
            for (var i = 1; i < fields.Length; i++)
            {
                if (!int.TryParse(fields[i], NumberStyles.None, CultureInfo.InvariantCulture, out corners[i - 1]))
                {
                    Error($"a face's vertex is an index from 0, not \"{fields[i]}\"");
                    return;
                }
            }
            _faces.Add((slot, [.. corners], null, _line));
        }

        void ParseMap(string[] fields)
        {
            if (_faces.Count == 0 || _faces[^1].Mapping != null)
            {
                Error("a map line follows the face it maps");
                return;
            }
            if (ParseNumbers(fields, 11) is not { } v)
            {
                Error("a map is `map <ux uy uz> <vx vy vz> <su sv> <tu tv> <rotation>`, 11 numbers");
                return;
            }
            if (v[6] == 0 || v[7] == 0)
            {
                Error("a map's scale is meters per repeat, and cannot be 0");
                return;
            }
            var face = _faces[^1];
            _faces[^1] = face with { Mapping = new Mapping(new Vec3(v[0], v[1], v[2]), new Vec3(v[3], v[4], v[5]), v[6], v[7], v[8], v[9], v[10]) };
        }

        void ParseEdge(string[] fields)
        {
            if (fields.Length != 3 || fields[2] != "sharp")
            {
                Error("an edge is `e <a> <b> sharp`");
                return;
            }
            if (!int.TryParse(fields[0], NumberStyles.None, CultureInfo.InvariantCulture, out var a)
                || !int.TryParse(fields[1], NumberStyles.None, CultureInfo.InvariantCulture, out var b) || a == b)
            {
                Error($"an edge joins two different vertices by index, not \"{fields[0]}\" and \"{fields[1]}\"");
                return;
            }
            _sharp.Add(new MeshEdge(a, b));
        }

        /// <summary>Exactly count finite numbers, or null.</summary>
        static double[]? ParseNumbers(string[] fields, int count)
        {
            if (fields.Length != count)
            {
                return null;
            }
            var values = new double[count];
            for (var i = 0; i < count; i++)
            {
                if (!double.TryParse(fields[i], NumberStyles.Float, CultureInfo.InvariantCulture, out values[i]) || !double.IsFinite(values[i]))
                {
                    return null;
                }
            }
            return values;
        }
    }
}
