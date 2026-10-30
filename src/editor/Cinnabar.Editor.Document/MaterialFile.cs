using System.Globalization;
using System.Text;

namespace Cinnabar.Editor.Document;

/// <summary>A line of a material file that does not parse, with its number from 1. A problem is an error unless it says otherwise.</summary>
public sealed record MaterialProblem(int Line, string Message, bool IsError = true);

/// <summary>
/// The material file format's reader and writer, as the cooker reads it (tools/cook/materials.odin and graphs.odin).
/// The two must agree. The writer puts each node on lines of its own, and gives each node's first line, so the editor
/// can find a node from the line of a problem.
/// </summary>
public static class MaterialFile
{
    public const string MaterialHeader = "material 1";
    public const string FunctionHeader = "material_function 1";

    public static MaterialFileKind KindOf(string path) =>
        path.EndsWith(".material_function", StringComparison.OrdinalIgnoreCase) ? MaterialFileKind.Function : MaterialFileKind.Material;

    /// <summary>Whether a material's text defines evaluate in HLSL, after a <c>---</c> line, rather than with nodes.</summary>
    public static bool IsHlsl(string text) => text.Split('\n').Any(l => l.Trim() == "---");

    public static (MaterialGraph? Graph, IReadOnlyList<MaterialProblem> Problems) Parse(string text, MaterialFileKind kind)
    {
        var problems = new List<MaterialProblem>();
        var graph = new MaterialGraph { Kind = kind };
        var lines = text.Replace("\r\n", "\n").Split('\n');
        var header = kind == MaterialFileKind.Function ? FunctionHeader : MaterialHeader;
        var number = 0;
        while (number < lines.Length && lines[number].Trim() == "")
        {
            number++;
        }
        if (number == lines.Length || lines[number].Trim() != header)
        {
            return (null, [new MaterialProblem(number + 1, $"the file starts with `{header}`")]);
        }
        number++;
        var leading = true;
        GraphNode? node = null;
        var param = -1;
        for (; number < lines.Length; number++)
        {
            var raw = lines[number];
            var line = raw.Trim();
            var lineNumber = number + 1;
            if (line == "" || line.StartsWith('#'))
            {
                if (leading && line.StartsWith('#'))
                {
                    graph.Comments.Add(line);
                }
                continue;
            }
            leading = false;
            if (line == "---" && kind == MaterialFileKind.Material)
            {
                graph.Hlsl = string.Join("\n", lines[number..]);
                break;
            }
            var indented = raw[0] is ' ' or '\t';
            if (indented)
            {
                var (key, value) = Split(line);
                if (node != null && GraphValue.Parse(value) is { } v && IsIdentifier(key))
                {
                    if (key == "position" && v is GraphNumbers { Values.Count: 2 } p)
                    {
                        (node.X, node.Y) = (p.Values[0], p.Values[1]);
                    }
                    else
                    {
                        node.Set(key, v);
                    }
                }
                else if (param >= 0 && key == "group" && GraphValue.Parse(value) is GraphText group)
                {
                    graph.Params[param] = graph.Params[param] with { Group = group.Text };
                }
                else
                {
                    problems.Add(new MaterialProblem(lineNumber, $"{line} is not a line of a node or a parameter"));
                }
                continue;
            }
            node = null;
            param = -1;
            var space = line.IndexOf(' ');
            var word = space < 0 ? line : line[..space];
            var rest = space < 0 ? "" : line[(space + 1)..];
            switch (word)
            {
                case "node":
                    var parts = rest.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                    if (parts.Length == 2 && int.TryParse(parts[0], NumberStyles.None, CultureInfo.InvariantCulture, out var id) && id > 0 && graph.Find(id) == null)
                    {
                        node = new GraphNode(id, parts[1]);
                        graph.Nodes.Add(node);
                    }
                    else
                    {
                        problems.Add(new MaterialProblem(lineNumber, "a node is `node <id> <kind>`, with an ID that no other node has"));
                    }
                    break;
                case "param" when kind == MaterialFileKind.Material:
                    var (head, value) = Split(rest);
                    var fields = head.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                    if (fields.Length == 2 && IsIdentifier(fields[0]) && MaterialGraph.ParamTypes.Contains(fields[1]) && value != "")
                    {
                        graph.Params.Add(new MaterialParam(fields[0], fields[1], value));
                        param = graph.Params.Count - 1;
                    }
                    else
                    {
                        problems.Add(new MaterialProblem(lineNumber, "a parameter is `param <name> <type> = <default>`"));
                    }
                    break;
                case "switch" when kind == MaterialFileKind.Material:
                    var (name, on) = Split(rest);
                    if (IsIdentifier(name) && on is "true" or "false")
                    {
                        graph.Switches.Add(new MaterialSwitch(name, on == "true"));
                    }
                    else
                    {
                        problems.Add(new MaterialProblem(lineNumber, "a switch is `switch <name> = true` or `false`"));
                    }
                    break;
                default:
                    if (kind == MaterialFileKind.Function || !Setting(graph, line))
                    {
                        problems.Add(new MaterialProblem(lineNumber, $"{line} is not a line of a {(kind == MaterialFileKind.Function ? "material function" : "material")}"));
                    }
                    break;
            }
        }
        return (problems.Count == 0 ? graph : null, problems);
    }

    static bool Setting(MaterialGraph graph, string line)
    {
        var (key, value) = Split(line);
        switch (key)
        {
            case "shading" when IsIdentifier(value):
                graph.Shading = value;
                return true;
            case "blend" when MaterialGraph.Blends.Contains(value):
                graph.Blend = value;
                return true;
            case "cutoff" when double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var cutoff):
                graph.Cutoff = cutoff;
                return true;
            case "transparency" when MaterialGraph.Transparencies.Contains(value):
                graph.Transparency = value;
                return true;
            case "two_sided" when value is "true" or "false":
                graph.TwoSided = value == "true";
                return true;
            case "cast_shadows" when value is "true" or "false":
                graph.CastShadows = value == "true";
                return true;
        }
        return false;
    }

    static (string Key, string Value) Split(string text)
    {
        var equals = text.IndexOf('=');
        return equals < 0 ? (text.Trim(), "") : (text[..equals].Trim(), text[(equals + 1)..].Trim());
    }

    /// <summary>Writes a graph as the file has it. <paramref name="nodeLines"/>, if given, gets each node's first line, from 1.</summary>
    public static string Write(MaterialGraph graph, Dictionary<int, int>? nodeLines = null)
    {
        var lines = new List<string> { graph.Kind == MaterialFileKind.Function ? FunctionHeader : MaterialHeader };
        lines.AddRange(graph.Comments);
        if (graph.Kind == MaterialFileKind.Material)
        {
            lines.Add($"shading = {graph.Shading}");
            if (graph.Blend != "opaque")
            {
                lines.Add($"blend = {graph.Blend}");
            }
            if (graph.Blend == "masked")
            {
                lines.Add($"cutoff = {GraphNumbers.Format(graph.Cutoff)}");
            }
            if (graph.Blend == "transparent" && graph.Transparency != "moments")
            {
                lines.Add($"transparency = {graph.Transparency}");
            }
            if (graph.TwoSided)
            {
                lines.Add("two_sided = true");
            }
            // Transparent surfaces cast no shadows, so the cooker takes no setting for them.
            if (!graph.CastShadows && !graph.IsTransparent)
            {
                lines.Add("cast_shadows = false");
            }
            foreach (var p in graph.Params)
            {
                lines.Add($"param {p.Name} {p.Type} = {p.Value}");
                if (p.Group != "")
                {
                    lines.Add($"\tgroup = {TextQuote.Quote(p.Group)}");
                }
            }
            foreach (var s in graph.Switches)
            {
                lines.Add($"switch {s.Name} = {(s.Default ? "true" : "false")}");
            }
        }
        if (graph.Hlsl != null)
        {
            lines.Add(graph.Hlsl.TrimEnd('\n'));
            return string.Join("\n", lines) + "\n";
        }
        // A blank line parts the declarations from the nodes.
        if (graph.Nodes.Count > 0)
        {
            lines.Add("");
        }
        foreach (var node in graph.Nodes)
        {
            nodeLines?.Add(node.Id, lines.Count + 1);
            lines.Add($"node {node.Id} {node.Kind}");
            lines.Add($"\tposition = [{GraphNumbers.Format(Math.Round(node.X))}, {GraphNumbers.Format(Math.Round(node.Y))}]");
            foreach (var (name, value) in node.Fields)
            {
                lines.Add($"\t{name} = {value.Write()}");
            }
        }
        return string.Join("\n", lines) + "\n";
    }

    public static bool IsIdentifier(string name) =>
        name.Length > 0 && !char.IsAsciiDigit(name[0]) && name.All(c => c == '_' || char.IsAsciiLetterOrDigit(c));
}
