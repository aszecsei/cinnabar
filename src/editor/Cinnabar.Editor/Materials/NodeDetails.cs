using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using static Cinnabar.Editor.Panels.Kit;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.Materials;

/// <summary>
/// The material editor's details: the selected node's properties and the values of its inputs that no link gives, with
/// its problems. Without a selected node, the material's problems that are on no node.
/// </summary>
sealed class NodeDetails : DetailsPanel
{
    readonly EditorShell _shell;
    readonly MaterialEditor _editor;

    public NodeDetails(EditorShell shell, MaterialEditor editor)
    {
        _shell = shell;
        _editor = editor;
        Subscriptions
            .Add(() => _editor.SelectionChanged += Refresh, () => _editor.SelectionChanged -= Refresh)
            .Add(() => _editor.Changed += Refresh, () => _editor.Changed -= Refresh)
            .Add(() => _editor.ProblemsChanged += Refresh, () => _editor.ProblemsChanged -= Refresh)
            // A function node names its function from the content, which a cook changes.
            .Add(() => _shell.Assets.Changed += Rebuild, () => _shell.Assets.Changed -= Rebuild);
    }

    protected override string ShownKey()
    {
        var node = _editor.SelectedNode;
        var graph = _editor.Document.Graph;
        return node == null
            ? "none|" + string.Join("|", _editor.Problems.Select(p => p.Text))
            : $"{node.Id}|{node.Kind}|{string.Join(",", node.Fields.Select(f => f.Name + "=" + f.Value.Write()))}|{graph.Shading}"
                + $"|{string.Join(",", graph.Params.Select(p => p.Name + p.Type))}|{string.Join(",", graph.Switches.Select(s => s.Name))}"
                + $"|{string.Join("|", _editor.Problems.Where(p => p.Node == node.Id).Select(p => p.Text))}";
    }

    protected override void Fill()
    {
        var node = _editor.SelectedNode;
        var graph = _editor.Document.Graph;
        if (node == null)
        {
            Rows.Add(Dim("Select a node to see its properties and the values of its inputs."));
            AddProblems(_editor.Problems.Where(p => p.Node == null));
            return;
        }
        var kind = _editor.Catalog.Kind(node.Kind);
        Rows.Add(new TextBlock { Text = _editor.Label(node.Id), FontSize = 15, FontWeight = FontWeight.SemiBold });
        if (kind != null)
        {
            Rows.Add(Dim(kind.Description));
        }
        if (kind is { Properties.Length: > 0 })
        {
            Rows.Add(Heading("Properties"));
            foreach (var p in kind.Properties)
            {
                Rows.Add(Row(MaterialEditor.Humanize(p.Name), PropertyEditor(node, p)));
            }
        }
        var (inputs, _) = _editor.Catalog.PinsOf(graph, node);
        if (inputs.Count > 0)
        {
            Rows.Add(Heading("Inputs"));
            foreach (var pin in inputs)
            {
                Rows.Add(InputRow(node, pin));
            }
        }
        AddProblems(_editor.Problems.Where(p => p.Node == node.Id));
    }

    Control PropertyEditor(GraphNode node, NodeProperty property)
    {
        var value = node.Get(property.Name);
        var graph = _editor.Document.Graph;
        void Set(GraphValue? v) => _editor.SetField(node.Id, property.Name, v);
        switch (property.Kind)
        {
            case PropertyKind.Number or PropertyKind.Vector2 or PropertyKind.Vector3 or PropertyKind.Vector4 or PropertyKind.Color:
                var count = property.Kind switch
                {
                    PropertyKind.Number => 1,
                    PropertyKind.Vector2 => 2,
                    PropertyKind.Vector3 => 3,
                    _ => 4,
                };
                var numbers = value as GraphNumbers ?? GraphNumbers.TryParse(property.Default);
                // Empty is the default.
                var box = ValueBox(numbers?.Write() ?? "", ValueFormats.Optional(ValueFormats.Numbers(count)), property.Default, Set);
                return property.Kind == PropertyKind.Color && numbers != null ? WithSwatch(Swatch(numbers.Values), box) : box;
            case PropertyKind.Text:
                return ValueBox((value as GraphText)?.Text ?? TextQuote.Unquote(property.Default) ?? "", "", text => Set(new GraphText(text)));
            case PropertyKind.Code:
                var code = ValueBox((value as GraphText)?.Text ?? TextQuote.Unquote(property.Default) ?? "", "HLSL", text => Set(new GraphText(text)), multiline: true);
                ToolTip.SetTip(code, "An expression of a, b, c and d, or a body that returns. Ctrl+Enter applies it.");
                return code;
            case PropertyKind.Choice:
                var current = value switch
                {
                    GraphWord w => w.Word,
                    GraphNumbers n => n.Write(),
                    _ => property.Default,
                };
                return Choice(property.Choices, current, choice => Set(GraphValue.Parse(choice)));
            case PropertyKind.Parameter:
                return Choice(graph.Params.Select(p => p.Name), (value as GraphText)?.Text, name => Set(new GraphText(name)));
            case PropertyKind.Switch:
                return Choice(graph.Switches.Select(s => s.Name), (value as GraphText)?.Text, name => Set(new GraphText(name)));
            case PropertyKind.Function:
                var function = new AssetView(FunctionAssets(), new ValueSink(guid => Set(FunctionStored(guid))));
                function.Show(FunctionShown(value));
                return function.Control;
        }
        return Dim("");
    }

    // The material functions that a function node can call: any but the one being edited.
    AssetContext FunctionAssets() =>
        new(_shell.Assets, "material_function", _shell.Content.RevealAsset) { Exclude = a => a.Guid == _editor.Guid };

    /// <summary>A function node's function as its asset view shows it: the GUID, "" for none, or text that is not one, which shows as missing.</summary>
    internal static string FunctionShown(GraphValue? value) => value switch
    {
        null => "",
        GraphAsset asset => asset.Guid,
        _ => value.Write(),
    };

    /// <summary>The value that a function node's asset view sets: the function's asset, or none.</summary>
    internal static GraphAsset? FunctionStored(string guid) => guid == "" ? null : new GraphAsset(guid);

    Control InputRow(GraphNode node, GraphPin pin)
    {
        var name = MaterialEditor.Humanize(pin.Name);
        if (node.Get(pin.Name) is GraphLink link)
        {
            var from = new TextBlock { Text = $"← {_editor.Label(link.Node)} · {link.Output}", Classes = { "link" }, VerticalAlignment = VerticalAlignment.Center, FontSize = 12 };
            from.PointerPressed += (_, _) => _editor.Select([link.Node]);
            return Row(name, from, SmallButton("×", "Remove the link", () => _editor.SetField(node.Id, pin.Name, null)));
        }
        if (pin.Type == PinType.Texture)
        {
            return Row(name, Dim("Link a texture parameter"));
        }
        var watermark = MaterialCatalog.DefaultText(pin);
        var value = node.Get(pin.Name) as GraphNumbers;
        var box = ValueBox(value?.Write() ?? "", ValueFormats.Optional(ValueFormats.Numbers()), watermark, n => _editor.SetField(node.Id, pin.Name, n));
        ToolTip.SetTip(box, "A number, which fills every component, or up to four, such as [1, 0.5, 0]. Empty gives the default.");
        return value != null ? Row(name, box, SmallButton("↺", "Reset to the default", () => _editor.SetField(node.Id, pin.Name, null))) : Row(name, box);
    }
}
