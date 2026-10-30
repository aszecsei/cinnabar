using System.Globalization;

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
