using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using static Cinnabar.Editor.Panels.Kit;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.Materials;

/// <summary>
/// A material's parameters and static switches: each one's name, type, default and group, which instances override. A
/// new name renames it in the nodes that read it, and the arrow adds a node that reads it.
/// </summary>
sealed class ParametersPanel : ScrollViewer
{
    // A subclass takes ScrollViewer's template only by its style key.
    protected override Type StyleKeyOverride => typeof(ScrollViewer);

    static readonly string[] TextureDefaults = ["white", "black", "normal"];

    readonly EditorShell _shell;
    readonly MaterialEditor _editor;
    readonly Func<Vec2> _middle;
    readonly StackPanel _content = new() { Margin = new Thickness(8), Spacing = 4 };
    string _shown = "";

    public ParametersPanel(EditorShell shell, MaterialEditor editor, Func<Vec2> middle)
    {
        _shell = shell;
        _editor = editor;
        _middle = middle;
        Content = _content;
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        new ViewSubscriptions(this, attached: Refresh)
            .Add(() => _editor.Changed += Refresh, () => _editor.Changed -= Refresh)
            .Add(() => _shell.Assets.Changed += Rebuild, () => _shell.Assets.Changed -= Rebuild);
    }

    void Rebuild()
    {
        _shown = "";
        Refresh();
    }

    void Refresh()
    {
        var graph = _editor.Document.Graph;
        var shown = string.Join("|", graph.Params) + "||" + string.Join("|", graph.Switches);
        if (shown == _shown)
        {
            return;
        }
        _shown = shown;
        _content.Children.Clear();
        var add = new Button { Content = "Add", Classes = { "field-button" } };
        var menu = new MenuFlyout();
        foreach (var type in MaterialGraph.ParamTypes)
        {
            var item = new MenuItem { Header = type };
            item.Click += (_, _) => _editor.AddParam(type);
            menu.Items.Add(item);
        }
        add.Flyout = menu;
        _content.Children.Add(Header("Parameters", add));
        if (graph.Params.Count == 0)
        {
            _content.Children.Add(Dim("Parameters are values that instances override."));
        }
        foreach (var p in graph.Params)
        {
            _content.Children.Add(ParamView(p));
        }
        _content.Children.Add(Header("Static Switches", SmallButton("Add", "Add a static switch, which picks a branch of a switch node.", () => _editor.AddSwitch())));
        foreach (var s in graph.Switches)
        {
            _content.Children.Add(SwitchView(s));
        }
    }

    static Control Header(string title, Control button)
    {
        var panel = new DockPanel { Margin = new Thickness(0, 6, 0, 0) };
        DockPanel.SetDock(button, DockSide.Right);
        panel.Children.Add(button);
        panel.Children.Add(Heading(title));
        return panel;
    }

    // A parameter's or a switch's name: its own, or one that no other has.
    IValueFormat<string> NameOf(string old) => ValueFormats.Text.Where(
        text => text.Trim() == old || (MaterialFile.IsIdentifier(text.Trim()) && !_editor.Document.Graph.NameTaken(text.Trim())),
        "not a name, or another parameter or switch has it");

    Control ParamView(MaterialParam p)
    {
        var panel = new StackPanel { Spacing = 2 };
        var name = ValueBox(p.Name, NameOf(p.Name), "name", text => _editor.SetParam(p.Name, p with { Name = text.Trim() }));
        var type = Choice(MaterialGraph.ParamTypes, p.Type, t => _editor.SetParam(p.Name, p with { Type = t, Value = DefaultOf(t) }));
        type.Width = 96;
        var node = SmallButton("→", "Add a node that reads it", () =>
        {
            var at = _middle();
            _editor.AddNode("parameter", at.X, at.Y, p.Name);
        });
        var remove = SmallButton("×", "Remove it", () => _editor.RemoveParam(p.Name));
        var top = new DockPanel();
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, Children = { type, node, remove } };
        DockPanel.SetDock(buttons, DockSide.Right);
        top.Children.Add(buttons);
        top.Children.Add(name);
        panel.Children.Add(top);
        panel.Children.Add(Row("Default", ValueEditor(p)));
        panel.Children.Add(Row("Group", ValueBox(p.Group, "none", text => _editor.SetParam(p.Name, p with { Group = text.Trim() }))));
        return new Border { Classes = { "value-box" }, Padding = new Thickness(6), Child = panel };
    }

    Control ValueEditor(MaterialParam p)
    {
        if (p.Type == "texture")
        {
            var assets = new AssetContext(_shell.Assets, "texture", _shell.Content.RevealAsset) { Builtins = TextureDefaults, Clearable = false };
            var texture = new AssetView(assets, new ValueSink(picked => _editor.SetParam(p.Name, p with { Value = TextureStored(picked) })));
            texture.Show(TextureShown(p.Value));
            return texture.Control;
        }
        var count = p.Type switch
        {
            "float" => 1,
            "float2" => 2,
            "float3" => 3,
            _ => 4,
        };
        var box = ValueBox(p.Value, ValueFormats.Numbers(count), DefaultOf(p.Type), n => _editor.SetParam(p.Name, p with { Value = n.Write() }));
        return p.Type == "color" && GraphNumbers.TryParse(p.Value) is { } color ? WithSwatch(Swatch(color.Values), box) : box;
    }

    /// <summary>A texture parameter's value as its asset view shows it: a built-in such as "white" as itself, and a GUID without its "$".</summary>
    internal static string TextureShown(string value) => value.StartsWith('$') ? value[1..] : value;

    /// <summary>The value that a texture parameter's asset view sets: a built-in as itself, and a texture as "$" and its GUID.</summary>
    internal static string TextureStored(string picked) => TextureDefaults.Contains(picked) ? picked : "$" + picked;

    static string DefaultOf(string type) => type switch
    {
        "float" => "0",
        "float2" => "[0, 0]",
        "float3" => "[0, 0, 0]",
        "texture" => "white",
        _ => "[1, 1, 1, 1]",
    };

    Control SwitchView(MaterialSwitch s)
    {
        var name = ValueBox(s.Name, NameOf(s.Name), "name", text => _editor.SetSwitch(s.Name, s with { Name = text.Trim() }));
        var on = new CheckBox { IsChecked = s.Default, Content = "On", FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
        on.IsCheckedChanged += (_, _) => _editor.SetSwitch(s.Name, s with { Default = on.IsChecked == true });
        ToolTip.SetTip(on, "Whether the material itself has it on. Instances can turn it either way, which cooks another permutation.");
        var node = SmallButton("→", "Add a switch node that it picks the branch of", () =>
        {
            var at = _middle();
            var id = _editor.AddNode("switch", at.X, at.Y);
            _editor.SetField(id, "switch", new GraphText(s.Name));
        });
        var remove = SmallButton("×", "Remove it", () => _editor.RemoveSwitch(s.Name));
        var line = new DockPanel();
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Children = { on, node, remove } };
        DockPanel.SetDock(buttons, DockSide.Right);
        line.Children.Add(buttons);
        line.Children.Add(name);
        return new Border { Classes = { "value-box" }, Padding = new Thickness(6), Child = line };
    }
}
