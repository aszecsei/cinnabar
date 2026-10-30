using System.Globalization;
using System.Text;

namespace Cinnabar.Editor.Document;

/// <summary>A material, or a material function, which has only nodes.</summary>
public enum MaterialFileKind
{
    Material,
    Function,
}

/// <summary>
/// A value in a node's block (see docs/content/kinds/materials.md#material-graphs), as the file writes it: numbers, a quoted
/// string, a bare word, an asset's GUID after <c>$</c>, or a link to another node's output, <c>@node.output</c>.
/// </summary>
public abstract record GraphValue
{
    public abstract string Write();

    /// <summary>Reads a value, or returns null for text that is not one.</summary>
    public static GraphValue? Parse(string text)
    {
        text = text.Trim();
        if (text.Length == 0)
        {
            return null;
        }
        switch (text[0])
        {
            case '"':
                return TextQuote.Unquote(text) is { } unquoted ? new GraphText(unquoted) : null;
            case '$':
                return text.Length == 33 && text[1..].All(Uri.IsHexDigit) ? new GraphAsset(text[1..].ToLowerInvariant()) : null;
            case '@':
                var dot = text.IndexOf('.');
                return dot > 1 && int.TryParse(text[1..dot], NumberStyles.None, CultureInfo.InvariantCulture, out var node) && dot + 1 < text.Length
                    ? new GraphLink(node, text[(dot + 1)..]) : null;
        }
        if (GraphNumbers.TryParse(text) is { } numbers)
        {
            return numbers;
        }
        return MaterialFile.IsIdentifier(text) ? new GraphWord(text) : null;
    }
}

public sealed record GraphLink(int Node, string Output) : GraphValue
{
    public override string Write() => $"@{Node}.{Output}";
}

public sealed record GraphText(string Text) : GraphValue
{
    public override string Write() => TextQuote.Quote(Text);
}

public sealed record GraphWord(string Word) : GraphValue
{
    public override string Write() => Word;
}

public sealed record GraphAsset(string Guid) : GraphValue
{
    public override string Write() => "$" + Guid;
}

/// <summary>A number or up to four, as a value of a node's block writes them: <c>0.5</c> or <c>[1, 0, 0, 1]</c>.</summary>
public sealed record GraphNumbers : GraphValue
{
    public GraphNumbers(params double[] values) => Values = values;

    public IReadOnlyList<double> Values { get; }

    public override string Write() =>
        Values.Count == 1 ? Format(Values[0]) : $"[{string.Join(", ", Values.Select(Format))}]";

    /// <summary>A number as the files write it: as short as reads back the same, with no exponent for ordinary values.</summary>
    public static string Format(double value) => value.ToString("R", CultureInfo.InvariantCulture);

    public static GraphNumbers? TryParse(string text)
    {
        text = text.Trim();
        var inner = text;
        if (text.StartsWith('['))
        {
            if (!text.EndsWith(']'))
            {
                return null;
            }
            inner = text[1..^1];
        }
        var parts = inner.Split(',');
        if (parts.Length is < 1 or > 4)
        {
            return null;
        }
        var values = new double[parts.Length];
        for (var i = 0; i < parts.Length; i++)
        {
            if (!double.TryParse(parts[i].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out values[i]))
            {
                return null;
            }
        }
        return new GraphNumbers(values);
    }

    public bool Equals(GraphNumbers? other) => other != null && Values.SequenceEqual(other.Values);

    public override int GetHashCode() => Values.Aggregate(0, (h, v) => HashCode.Combine(h, v));
}

/// <summary>A node of a graph: its ID in the graph, its kind, its place in the editor, and its inputs and properties.</summary>
public sealed class GraphNode(int id, string kind)
{
    public int Id { get; } = id;
    public string Kind { get; } = kind;
    public double X { get; set; }
    public double Y { get; set; }

    /// <summary>The inputs and properties that the file sets, in its order. One that it does not set has its default.</summary>
    public List<(string Name, GraphValue Value)> Fields { get; } = [];

    public GraphValue? Get(string name) => Fields.FindIndex(f => f.Name == name) is var i and >= 0 ? Fields[i].Value : null;

    /// <summary>Sets a field, or with null removes it, so it has its default.</summary>
    public void Set(string name, GraphValue? value)
    {
        var i = Fields.FindIndex(f => f.Name == name);
        if (value == null)
        {
            if (i >= 0)
            {
                Fields.RemoveAt(i);
            }
        }
        else if (i >= 0)
        {
            Fields[i] = (name, value);
        }
        else
        {
            Fields.Add((name, value));
        }
    }

    public GraphNode Clone()
    {
        var copy = new GraphNode(Id, Kind) { X = X, Y = Y };
        copy.Fields.AddRange(Fields);
        return copy;
    }
}

/// <summary>A material's parameter: its name, its type as the file writes it, its default as the file writes it, and its group.</summary>
public sealed record MaterialParam(string Name, string Type, string Value, string Group = "");

public sealed record MaterialSwitch(string Name, bool Default);

/// <summary>
/// A <c>.material</c> or a <c>.material_function</c> file (see docs/content/kinds/materials.md#material-graphs): a material's
/// settings, parameters and static switches, and the graph's nodes. A material whose evaluate is HLSL after a
/// <c>---</c> line has <see cref="Hlsl"/>, and no nodes.
/// </summary>
public sealed class MaterialGraph
{
    public static readonly string[] ParamTypes = ["float", "float2", "float3", "float4", "color", "texture"];
    public static readonly string[] Blends = ["opaque", "masked", "transparent", "additive"];
    /// <summary>A transparent material's: moment-based order-independent transparency, or sorted back to front.</summary>
    public static readonly string[] Transparencies = ["moments", "sorted"];

    public MaterialFileKind Kind { get; init; }

    /// <summary>The comment lines between the version line and the first setting, which the editor keeps.</summary>
    public List<string> Comments { get; } = [];

    public string Shading { get; set; } = "lit";
    public string Blend { get; set; } = "opaque";
    public double Cutoff { get; set; } = 0.5;
    public string Transparency { get; set; } = "moments";
    public bool TwoSided { get; set; }
    public bool CastShadows { get; set; } = true;
    public List<MaterialParam> Params { get; } = [];
    public List<MaterialSwitch> Switches { get; } = [];
    public List<GraphNode> Nodes { get; } = [];

    /// <summary>The HLSL after the <c>---</c> line, with that line, or null for a graph.</summary>
    public string? Hlsl { get; set; }

    /// <summary>Whether the material draws after the opaque surfaces, blended over them.</summary>
    public bool IsTransparent => Blend is "transparent" or "additive";

    public GraphNode? Find(int id) => Nodes.Find(n => n.Id == id);

    /// <summary>An ID that no node has.</summary>
    public int NextId() => Nodes.Count == 0 ? 1 : Nodes.Max(n => n.Id) + 1;

    /// <summary>Whether a name is taken by a parameter or a static switch, which share one set of names.</summary>
    public bool NameTaken(string name) => Params.Any(p => p.Name == name) || Switches.Any(s => s.Name == name);

    /// <summary>Removes a node and every link to it.</summary>
    public void Remove(int id)
    {
        Nodes.RemoveAll(n => n.Id == id);
        foreach (var node in Nodes)
        {
            node.Fields.RemoveAll(f => f.Value is GraphLink link && link.Node == id);
        }
    }

    public MaterialGraph Clone()
    {
        var copy = new MaterialGraph
        {
            Kind = Kind,
            Shading = Shading,
            Blend = Blend,
            Cutoff = Cutoff,
            Transparency = Transparency,
            TwoSided = TwoSided,
            CastShadows = CastShadows,
            Hlsl = Hlsl,
        };
        copy.Comments.AddRange(Comments);
        copy.Params.AddRange(Params);
        copy.Switches.AddRange(Switches);
        copy.Nodes.AddRange(Nodes.Select(n => n.Clone()));
        return copy;
    }
}

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
