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
using AssetIndex = Cinnabar.Editor.Content.AssetIndex;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.Materials;

/// <summary>
/// The material editor's details: the selected node's properties and the values of its inputs that no link gives, with
/// its problems. Without a selected node, the material's problems that are on no node.
/// </summary>
sealed class NodeDetails : ScrollViewer
{
    readonly EditorShell _shell;
    readonly MaterialEditor _editor;
    readonly StackPanel _content = new() { Margin = new Thickness(8), Spacing = 2 };
    string _shown = "";

    public NodeDetails(EditorShell shell, MaterialEditor editor)
    {
        _shell = shell;
        _editor = editor;
        Content = _content;
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        new ViewSubscriptions(this, attached: Refresh)
            .Add(() => _editor.SelectionChanged += Refresh, () => _editor.SelectionChanged -= Refresh)
            .Add(() => _editor.Changed += Refresh, () => _editor.Changed -= Refresh)
            .Add(() => _editor.ProblemsChanged += Refresh, () => _editor.ProblemsChanged -= Refresh);
    }

    // The panel builds again only when what it shows changed, so a box keeps its focus while a drag moves the node.
    void Refresh()
    {
        var node = _editor.SelectedNode;
        var graph = _editor.Document.Graph;
        var shown = node == null
            ? "none|" + string.Join("|", _editor.Problems.Select(p => p.Text))
            : $"{node.Id}|{node.Kind}|{string.Join(",", node.Fields.Select(f => f.Name + "=" + f.Value.Write()))}|{graph.Shading}"
                + $"|{string.Join(",", graph.Params.Select(p => p.Name + p.Type))}|{string.Join(",", graph.Switches.Select(s => s.Name))}"
                + $"|{string.Join("|", _editor.Problems.Where(p => p.Node == node.Id).Select(p => p.Text))}";
        if (shown == _shown)
        {
            return;
        }
        _shown = shown;
        _content.Children.Clear();
        if (node == null)
        {
            _content.Children.Add(Dim("Select a node to see its properties and the values of its inputs."));
            var general = _editor.Problems.Where(p => p.Node == null).ToList();
            if (general.Count > 0)
            {
                _content.Children.Add(Heading("Problems"));
                AddProblems(general);
            }
            return;
        }
        var kind = _editor.Catalog.Kind(node.Kind);
        _content.Children.Add(new TextBlock { Text = _editor.Label(node.Id), FontSize = 15, FontWeight = FontWeight.SemiBold });
        if (kind != null)
        {
            _content.Children.Add(Dim(kind.Description));
        }
        if (kind is { Properties.Length: > 0 })
        {
            _content.Children.Add(Heading("Properties"));
            foreach (var p in kind.Properties)
            {
                _content.Children.Add(Row(MaterialEditor.Humanize(p.Name), PropertyEditor(node, p)));
            }
        }
        var (inputs, _) = _editor.Catalog.PinsOf(graph, node);
        if (inputs.Count > 0)
        {
            _content.Children.Add(Heading("Inputs"));
            foreach (var pin in inputs)
            {
                _content.Children.Add(InputRow(node, pin));
            }
        }
        var problems = _editor.Problems.Where(p => p.Node == node.Id).ToList();
        if (problems.Count > 0)
        {
            _content.Children.Add(Heading("Problems"));
            AddProblems(problems);
        }
    }

    void AddProblems(IEnumerable<GraphProblem> problems)
    {
        foreach (var p in problems)
        {
            _content.Children.Add(new SelectableTextBlock
            {
                Text = p.Text,
                Classes = { p.Error ? "error" : "warning" },
                TextWrapping = TextWrapping.Wrap,
                FontSize = 12,
            });
        }
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
                var box = ValueBox(numbers?.Write() ?? "", property.Default, text =>
                {
                    if (text.Trim() == "")
                    {
                        Set(null);
                    }
                    else if (Numbers(text, count) is { } n)
                    {
                        Set(n);
                    }
                    else
                    {
                        _shell.Console.Add(Model.LogLevel.Warning, $"material: {property.Name} takes {count} numbers, such as {property.Default}");
                        _shown = "";
                        Refresh();
                    }
                });
                if (property.Kind != PropertyKind.Color || numbers == null)
                {
                    return box;
                }
                var line = new DockPanel();
                var swatch = Swatch(numbers.Values);
                swatch.Margin = new Thickness(0, 0, 6, 0);
                DockPanel.SetDock(swatch, DockSide.Left);
                line.Children.Add(swatch);
                line.Children.Add(box);
                return line;
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
                var functions = _shell.Assets.Assets.Values.Where(a => a.Kind == AssetKind.MaterialFunction && a.Guid != _editor.Guid)
                    .OrderBy(a => a.Path, StringComparer.OrdinalIgnoreCase).ToList();
                var names = functions.Select(f => AssetIndex.DisplayName(f)).ToList();
                var selected = value is GraphAsset asset ? functions.FindIndex(f => f.Guid == asset.Guid) : -1;
                return Choice(names, selected >= 0 ? names[selected] : null, name => Set(new GraphAsset(functions[names.IndexOf(name)].Guid)));
        }
        return Dim("");
    }

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
        var box = ValueBox(value?.Write() ?? "", watermark, text =>
        {
            if (text.Trim() == "")
            {
                _editor.SetField(node.Id, pin.Name, null);
            }
            else if (Numbers(text) is { } n)
            {
                _editor.SetField(node.Id, pin.Name, n);
            }
            else
            {
                _shell.Console.Add(Model.LogLevel.Warning, $"material: {pin.Name} takes a number or up to four, such as 0.5 or [1, 0, 0]");
                _shown = "";
                Refresh();
            }
        });
        ToolTip.SetTip(box, "A number, which fills every component, or up to four, such as [1, 0.5, 0]. Empty gives the default.");
        return value != null ? Row(name, box, SmallButton("↺", "Reset to the default", () => _editor.SetField(node.Id, pin.Name, null))) : Row(name, box);
    }
}
