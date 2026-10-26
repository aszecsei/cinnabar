using Cinnabar.Editor.Link.Cook;

namespace Cinnabar.Editor.Document;

/// <summary>An input or an output of a node in a graph: its name, its type, and an input's default or the name of what the shaders give.</summary>
public sealed record GraphPin(string Name, PinType Type, IReadOnlyList<float> Default, string DefaultLabel = "");

/// <summary>
/// What the editor knows to show a graph's nodes (see docs/editor/material-editor.md#material-editor): the kinds of node and the
/// shading models, which the cook daemon sends, and the material functions, which the editor reads from their files.
/// A node's inputs and outputs come from its kind, or for some kinds from the material's parameters, the shading model
/// or the function that it calls.
/// </summary>
public sealed class MaterialCatalog(IReadOnlyList<NodeInfo> nodes, IReadOnlyList<ShadingModelInfo> shadingModels, Func<string, MaterialGraph?> function)
{
    public IReadOnlyList<NodeInfo> Nodes { get; } = nodes;

    public IReadOnlyList<ShadingModelInfo> ShadingModels { get; } = shadingModels;

    public NodeInfo? Kind(string name) => Nodes.FirstOrDefault(n => n.Kind == name);

    public ShadingModelInfo? ShadingModel(string name) => ShadingModels.FirstOrDefault(s => s.Name == name);

    /// <summary>A material function's graph, by its GUID, or null when it cannot be read.</summary>
    public MaterialGraph? Function(string guid) => function(guid);

    /// <summary>The kinds of node that a graph of a kind can have, in the catalog's order.</summary>
    public IEnumerable<NodeInfo> KindsFor(MaterialFileKind kind) =>
        Nodes.Where(n => n.Scope == NodeScope.Both || n.Scope == (kind == MaterialFileKind.Function ? NodeScope.Function : NodeScope.Material));

    public (IReadOnlyList<GraphPin> Inputs, IReadOnlyList<GraphPin> Outputs) PinsOf(MaterialGraph graph, GraphNode node)
    {
        var kind = Kind(node.Kind);
        if (kind == null)
        {
            return ([], []);
        }
        var inputs = kind.Inputs.Select(Pin).ToList();
        var outputs = kind.Outputs.Select(Pin).ToList();
        switch (kind.PinsFrom)
        {
            case NodePinsFrom.ShadingModel:
                inputs.AddRange(ShadingModel(graph.Shading)?.Inputs.Select(Pin) ?? []);
                break;
            case NodePinsFrom.Function:
                if (node.Get("function") is GraphAsset asset && Function(asset.Guid) is { } f)
                {
                    foreach (var n in f.Nodes)
                    {
                        var name = (n.Get("name") as GraphText)?.Text ?? (n.Kind == "function_input" ? "input" : "output");
                        if (n.Kind == "function_input")
                        {
                            var d = (n.Get("default") as GraphNumbers)?.Values.Select(v => (float)v).ToArray() ?? [0, 0, 0, 0];
                            inputs.Add(new GraphPin(name, TypeNamed(Word(n, "type", "float3")), d));
                        }
                        else if (n.Kind == "function_output")
                        {
                            outputs.Add(new GraphPin(name, TypeNamed(Word(n, "type", "float3")), [0, 0, 0, 0]));
                        }
                    }
                }
                break;
        }
        // Outputs whose type a property or a parameter gives.
        for (var i = 0; i < outputs.Count; i++)
        {
            var type = node.Kind switch
            {
                "parameter" => graph.Params.Find(p => p.Name == (node.Get("name") as GraphText)?.Text) is { } p ? ParamType(p.Type) : PinType.Any,
                "custom" or "function_input" => TypeNamed(Word(node, "type", "float3")),
                _ => outputs[i].Type,
            };
            outputs[i] = outputs[i] with { Type = type };
        }
        return (inputs, outputs);
    }

    static GraphPin Pin(NodePin p) => new(p.Name, p.Type, p.Default, p.DefaultLabel);

    /// <summary>What an unlinked input without a value of its own gives, as the file would write it, or the name of what the shaders give.</summary>
    public static string DefaultText(GraphPin pin)
    {
        if (pin.DefaultLabel != "")
        {
            return pin.DefaultLabel;
        }
        var count = pin.Type switch
        {
            PinType.Float2 => 2,
            PinType.Float3 => 3,
            PinType.Float4 => 4,
            _ => 1,
        };
        var values = Enumerable.Range(0, count).Select(i => i < pin.Default.Count ? (double)pin.Default[i] : 0).ToArray();
        return new GraphNumbers(values).Write();
    }

    static string Word(GraphNode node, string name, string fallback) => node.Get(name) switch
    {
        GraphWord w => w.Word,
        GraphNumbers n => n.Write(),
        _ => fallback,
    };

    public static PinType ParamType(string type) => type switch
    {
        "float" => PinType.Float,
        "float2" => PinType.Float2,
        "float3" => PinType.Float3,
        "texture" => PinType.Texture,
        _ => PinType.Float4,
    };

    public static PinType TypeNamed(string type) => type switch
    {
        "float" => PinType.Float,
        "float2" => PinType.Float2,
        "float3" => PinType.Float3,
        "float4" => PinType.Float4,
        "texture" => PinType.Texture,
        _ => PinType.Any,
    };
}
