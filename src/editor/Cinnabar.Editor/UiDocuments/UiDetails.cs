using System.Globalization;
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

namespace Cinnabar.Editor.UiDocuments;

/// <summary>
/// The UI editor's properties (see docs/editor/ui-editor.md#properties): the selected element's id, styles and states to
/// preview, and each attribute that means something on it, by its kind, from the cook daemon's table. What it sets
/// itself has a clear button; what it takes from its styles or its parent shows dim, with where from, until it is set.
/// With a style selected, the style's attributes.
/// </summary>
sealed class UiDetails : ScrollViewer
{
    // The attributes' groups, as docs/content/kinds/ui-documents.md#attributes has them.
    static readonly (string Name, string[] Attributes)[] Groups =
    [
        ("Layout", ["width", "height", "min_width", "max_width", "min_height", "max_height", "padding", "gap", "direction", "align", "cross", "anchor", "offset", "visible", "clip", "overflow", "scroll_bar"]),
        ("Paint", ["fill", "radius", "border", "opacity", "image", "tint", "slice"]),
        ("Text", ["text", "placeholder", "font", "size", "color", "text_align", "line_height", "wrap", "max_length"]),
        ("Interaction", ["focusable", "disabled", "click", "changed", "submit", "nav_up", "nav_down", "nav_left", "nav_right", "cancel", "focus", "modal"]),
    ];

    // The words that an enum's kind takes, as format.ui_parse_value reads them.
    static readonly Dictionary<string, string[]> Words = new()
    {
        ["boolean"] = ["true", "false"],
        ["direction"] = ["column", "row", "stack"],
        ["align"] = ["start", "center", "end", "space_between"],
        ["cross"] = ["start", "center", "end", "stretch"],
        ["anchor"] = ["top_left", "top", "top_right", "left", "center", "right", "bottom_left", "bottom", "bottom_right", "fill"],
        ["text_align"] = ["start", "center", "end"],
        ["overflow"] = ["visible", "scroll"],
    };

    const string Unset = "—";

    readonly EditorShell _shell;
    readonly UiEditor _editor;
    readonly StackPanel _panel = new() { Margin = new Thickness(8), Spacing = 2 };
    string _shown = "";

    // A subclass takes ScrollViewer's template only by its style key.
    protected override Type StyleKeyOverride => typeof(ScrollViewer);

    public UiDetails(EditorShell shell, UiEditor editor)
    {
        _shell = shell;
        _editor = editor;
        Content = _panel;
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        new ViewSubscriptions(this, attached: Refresh)
            .Add(() => _editor.Changed += Refresh, () => _editor.Changed -= Refresh)
            .Add(() => _editor.SelectionChanged += Refresh, () => _editor.SelectionChanged -= Refresh)
            .Add(() => _editor.ProblemsChanged += Rebuild, () => _editor.ProblemsChanged -= Rebuild)
            .Add(() => _shell.Assets.Changed += Rebuild, () => _shell.Assets.Changed -= Rebuild);
    }

    void Rebuild()
    {
        _shown = "";
        Refresh();
    }

    void Refresh()
    {
        // A drag or a picker's session keeps its controls, so the one being used is not built again under it.
        if (_editor.Document.InTransaction)
        {
            return;
        }
        var shown = $"{_editor.File.Text.GetHashCode()}:{_editor.SelectedNode}:{_editor.SelectedStyle}:{string.Join(',', _editor.States)}:{_editor.Problems.Count}";
        if (shown == _shown)
        {
            return;
        }
        _shown = shown;
        _panel.Children.Clear();
        if (_editor.SelectedStyle is { } style && _editor.File.Style(style) is { } s)
        {
            ShowStyle(s);
        }
        else if (_editor.Selected is { } node)
        {
            ShowNode(node);
        }
        else
        {
            _panel.Children.Add(Dim("Select an element on the canvas or in the tree, or a style."));
        }
    }

    IEnumerable<UiAttributeInfo> Attributes => _shell.Assets.UiAttributes;

    void ShowNode(UiNode node)
    {
        _panel.Children.Add(Heading(UiCascade.Label(node)));
        if (node.ButtonText)
        {
            _panel.Children.Add(Dim("A button's text is a text of its own, which takes the text style."));
        }
        else
        {
            _panel.Children.Add(Row("id", ValueBox(node.Id, "none", id =>
            {
                if (!_editor.SetId(node.Index, id))
                {
                    Rebuild();
                }
            })));
            if (node.Kind is not ("ui" or "template"))
            {
                var names = node.Element.Get("style") ?? "";
                var menu = new MenuFlyout();
                foreach (var st in _editor.File.Styles.Where(x => x.State == "" && x.Name != node.Kind))
                {
                    var item = new MenuItem { Header = st.Name };
                    item.Click += (_, _) => _editor.SetStyles(node.Index, names.Split(' ', StringSplitOptions.RemoveEmptyEntries).Append(st.Name));
                    menu.Items.Add(item);
                }
                var add = new Button { Content = "+", Flyout = menu, Classes = { "field-button" }, IsEnabled = menu.Items.Count > 0 };
                ToolTip.SetTip(add, "Add a style to the element's");
                _panel.Children.Add(Row("style", ValueBox(names, "none", list => _editor.SetStyles(node.Index, list.Split(' ', StringSplitOptions.RemoveEmptyEntries))), add));
            }
            var takes = _editor.File.StylesOf(node);
            if (takes.Count > 0)
            {
                _panel.Children.Add(Dim($"Takes {string.Join(", ", takes.Select(t => t.Name))}"));
            }
        }
        if (node.Kind != "template")
        {
            _panel.Children.Add(States());
        }
        foreach (var p in _editor.Problems.Where(p => p.Node == node.Index))
        {
            _panel.Children.Add(ProblemText(p));
        }
        if (node.Kind == "template")
        {
            _panel.Children.Add(Dim("A template takes only an id. Its element is what scripts copy with Ui.add."));
            return;
        }
        var values = _editor.Values(node.Index);
        var attributes = Attributes.Where(a => a.Elements.Contains(node.Kind)).ToList();
        if (attributes.Count == 0)
        {
            _panel.Children.Add(Dim("The attributes come from the cook daemon, once it links."));
        }
        ShowGroups(attributes, name => values.GetValueOrDefault(name), (name, value) => _editor.SetAttribute(node.Index, name, value), node.Index, null);
    }

    // The states that the canvas shows the selected element in, in place of the player's.
    Control States()
    {
        var row = new WrapPanel();
        foreach (var state in UiFile.States)
        {
            var toggle = new ToggleButton { Content = state, IsChecked = _editor.States.Contains(state), Classes = { "viewport-tool" }, FontSize = 11, Margin = new Thickness(0, 0, 2, 2), Focusable = false };
            toggle.IsCheckedChanged += (_, _) => _editor.SetState(state, toggle.IsChecked == true);
            row.Children.Add(toggle);
        }
        ToolTip.SetTip(row, "Show the element in a state on the canvas, with its styles' variants for it");
        return Row("preview", row);
    }

    void ShowStyle(UiStyle style)
    {
        _panel.Children.Add(Heading($"<style> {style.Name}"));
        if (style.State == "")
        {
            _panel.Children.Add(Row("name", ValueBox(style.Name, "", name =>
            {
                if (!_editor.RenameStyle(style.Name, name))
                {
                    Rebuild();
                }
            })));
        }
        var takers = _editor.TakersOf(style.Name).Select(UiCascade.Label).ToList();
        _panel.Children.Add(Dim(takers.Count == 0 ? "No element takes it." : $"Taken by {string.Join(", ", takers)}"));
        foreach (var p in _editor.Problems.Where(p => p.Style == style.Name))
        {
            _panel.Children.Add(ProblemText(p));
        }
        var own = style.Element.Attributes.Where(a => !UiCascade.NotValues.Contains(a.Name)).ToDictionary(a => a.Name, a => new UiValue(a.Value, UiSource.Own, ""));
        ShowGroups([.. Attributes], name => own.GetValueOrDefault(name), (name, value) => _editor.SetStyleAttribute(style.Name, name, value), null, style.Name);
    }

    void ShowGroups(IReadOnlyList<UiAttributeInfo> attributes, Func<string, UiValue?> value, Action<string, string?> set, int? node, string? style)
    {
        foreach (var (group, names) in Groups)
        {
            var rows = attributes.Where(a => names.Contains(a.Name)).OrderBy(a => Array.IndexOf(names, a.Name)).ToList();
            if (rows.Count == 0)
            {
                continue;
            }
            _panel.Children.Add(Heading(group));
            foreach (var a in rows)
            {
                _panel.Children.Add(AttributeRow(a, value(a.Name), v => set(a.Name, v), node, style));
            }
        }
    }

    Control AttributeRow(UiAttributeInfo info, UiValue? value, Action<string?> set, int? node, string? style)
    {
        var own = value is { Source: UiSource.Own };
        var shown = value?.Value ?? "";
        var editor = Editor(info, own ? shown : "", own ? "" : shown, set, node, style);
        Control[] after = own
            ? [SmallButton("×", $"Take {info.Name} out", () => set(null))]
            : [];
        var grid = Row(info.Name, editor, after);
        if (!own && value != null)
        {
            var from = value.Source == UiSource.Inherited ? $"from {value.From}" : $"from {value.From}";
            ToolTip.SetTip(editor, $"{shown}, {from}");
            var stack = new StackPanel();
            stack.Children.Add(grid);
            stack.Children.Add(new TextBlock { Text = $"{shown}  {from}", FontSize = 10, Classes = { "empty" }, Margin = new Thickness(96, -1, 0, 2), TextTrimming = TextTrimming.CharacterEllipsis });
            return stack;
        }
        return grid;
    }

    // An attribute's editor by its kind. A value that it does not have yet shows as its placeholder.
    Control Editor(UiAttributeInfo info, string value, string placeholder, Action<string?> set, int? node, string? style)
    {
        void Commit(string text) => set(text.Trim() == "" && info.Kind != "text" ? null : text);
        if (Words.TryGetValue(info.Kind, out var words))
        {
            return Choice([Unset, .. words], value == "" ? Unset : value, pick => set(pick == Unset ? null : pick));
        }
        switch (info.Kind)
        {
            case "color" or "paint":
                return ColorEditor(info, value, placeholder, Commit, node, style);
            case "guid":
                return AssetEditor(info.Name == "font" ? AssetKind.Font : AssetKind.Texture, value, set);
            case "length":
                var length = new DockPanel();
                var menu = new MenuFlyout();
                foreach (var word in new[] { "fit", "fill", "50%", "100%" })
                {
                    var item = new MenuItem { Header = word };
                    item.Click += (_, _) => set(word);
                    menu.Items.Add(item);
                }
                var pick = new Button { Content = "▾", Flyout = menu, Classes = { "field-button" } };
                ToolTip.SetTip(pick, "Pixels at a UI scale of 1, a percent of the parent's content, fit, or fill with a weight such as fill 2");
                DockPanel.SetDock(pick, Avalonia.Controls.Dock.Right);
                length.Children.Add(pick);
                length.Children.Add(ValueBox(value, placeholder, Commit));
                return length;
            default:
                return ValueBox(value, placeholder == "" ? Hint(info) : placeholder, Commit, multiline: info.Kind == "text" && value.Length > 40);
        }
    }

    static string Hint(UiAttributeInfo info) => info.Kind switch
    {
        "edges" => "top right bottom left",
        "corners" => "top left, top right, bottom right, bottom left",
        "offset" => "x y",
        "border" => "width #color",
        "number" or "count" => info.Max > 0 ? $"{info.Min.ToString(CultureInfo.InvariantCulture)} to {info.Max.ToString(CultureInfo.InvariantCulture)}" : "",
        "event" => "a name: on_<name> gets it",
        "id" => "an element's id",
        _ => "",
    };

    // A font or a texture, by its GUID after $, from the assets of its kind.
    Control AssetEditor(AssetKind kind, string value, Action<string?> set)
    {
        var assets = _shell.Assets.Assets.Values.Where(a => a.Kind == kind).OrderBy(a => a.Path).ToList();
        var names = new List<string> { Unset };
        var guids = new List<string?> { null };
        foreach (var a in assets)
        {
            names.Add(a.Subasset != "" ? $"{Path.GetFileName(a.Path)} {a.Subasset}" : Path.GetFileName(a.Path));
            guids.Add("$" + a.Guid);
        }
        if (value != "" && !guids.Contains(value))
        {
            names.Add($"missing {value}");
            guids.Add(value);
        }
        var selected = value == "" ? Unset : names[guids.IndexOf(value)];
        return Choice(names, selected, pick => set(guids[names.IndexOf(pick)]));
    }

    // A color: its text, and a swatch that opens a picker of hue, saturation, value and alpha, whose session is one
    // undo entry. A gradient's text is edited as text.
    Control ColorEditor(UiAttributeInfo info, string value, string placeholder, Action<string> commit, int? node, string? style)
    {
        var shown = value != "" ? value : placeholder;
        var swatch = SwatchFrame();
        swatch.Width = 18;
        swatch.Height = 18;
        swatch.Background = UiColors.Parse(shown) is { } c ? new SolidColorBrush(c) : Brushes.Transparent;
        var button = new Button { Content = swatch, Padding = new Thickness(0), Background = Brushes.Transparent, BorderThickness = new Thickness(0), VerticalAlignment = VerticalAlignment.Center };
        ToolTip.SetTip(button, info.Kind == "paint" ? "A color, or linear(<degrees>, <color>, <color>) as text" : "A color: #rgb, #rgba, #rrggbb, #rrggbbaa or none");
        var picker = new UiColorPicker(UiColors.Parse(shown) ?? Colors.White, color => _editor.Scrub(node, style, info.Name, UiColors.Format(color)));
        var flyout = new Flyout { Content = picker };
        flyout.Opened += (_, _) => _editor.BeginScrub($"Set {info.Name}");
        flyout.Closed += (_, _) => _editor.EndScrub();
        button.Flyout = flyout;
        var panel = new DockPanel();
        DockPanel.SetDock(button, Avalonia.Controls.Dock.Left);
        panel.Children.Add(button);
        var box = ValueBox(value, placeholder, commit);
        box.Margin = new Thickness(4, 0, 0, 0);
        panel.Children.Add(box);
        return panel;
    }

    static SelectableTextBlock ProblemText(UiProblem p) => new()
    {
        Text = p.Line > 0 ? $"{p.Line}:{p.Column}: {p.Text}" : p.Text,
        Classes = { p.Error ? "error" : "warning" },
        TextWrapping = TextWrapping.Wrap,
        FontSize = 12,
    };
}

/// <summary>A UI document's colors as the cooker reads them: #rgb, #rgba, #rrggbb, #rrggbbaa, or none.</summary>
static class UiColors
{
    public static Color? Parse(string text)
    {
        text = text.Trim();
        if (text == "none")
        {
            return Colors.Transparent;
        }
        if (text.StartsWith("linear(", StringComparison.Ordinal))
        {
            var parts = text.TrimEnd(')').Split(',');
            return parts.Length == 3 ? Parse(parts[1]) : null;
        }
        if (text.Length < 4 || text[0] != '#' || !text[1..].All(Uri.IsHexDigit))
        {
            return null;
        }
        var hex = text[1..];
        byte At(int i, int width) => width == 1 ? (byte)(Convert.ToByte(hex[i].ToString(), 16) * 17) : Convert.ToByte(hex.Substring(i * 2, 2), 16);
        return hex.Length switch
        {
            3 => Color.FromRgb(At(0, 1), At(1, 1), At(2, 1)),
            4 => Color.FromArgb(At(3, 1), At(0, 1), At(1, 1), At(2, 1)),
            6 => Color.FromRgb(At(0, 2), At(1, 2), At(2, 2)),
            8 => Color.FromArgb(At(3, 2), At(0, 2), At(1, 2), At(2, 2)),
            _ => null,
        };
    }

    public static string Format(Color c) => c.A == 255 ? $"#{c.R:x2}{c.G:x2}{c.B:x2}" : $"#{c.R:x2}{c.G:x2}{c.B:x2}{c.A:x2}";
}

/// <summary>Sliders of hue, saturation, value and alpha over the encoded color, as a designer picks it.</summary>
sealed class UiColorPicker : StackPanel
{
    public UiColorPicker(Color start, Action<Color> changed)
    {
        Width = 220;
        Spacing = 4;
        var (h, s, v) = Model.LinearColor.Hsv(start.R / 255.0, start.G / 255.0, start.B / 255.0);
        var hue = Slider("Hue", h, 0, 1);
        var saturation = Slider("Saturation", s, 0, 1);
        var value = Slider("Value", v, 0, 1);
        var alpha = Slider("Alpha", start.A / 255.0, 0, 1);
        var preview = new Border { Height = 20, CornerRadius = new CornerRadius(3), Background = new SolidColorBrush(start) };
        Children.Add(preview);
        void Changed()
        {
            var rgb = Model.LinearColor.FromHsv(hue.Value, saturation.Value, value.Value);
            var color = Color.FromArgb((byte)Math.Round(alpha.Value * 255), (byte)Math.Round(rgb[0] * 255), (byte)Math.Round(rgb[1] * 255), (byte)Math.Round(rgb[2] * 255));
            preview.Background = new SolidColorBrush(color);
            changed(color);
        }
        foreach (var slider in new[] { hue, saturation, value, alpha })
        {
            slider.ValueChanged += (_, _) => Changed();
        }

        Slider Slider(string name, double at, double min, double max)
        {
            var slider = new Slider { Minimum = min, Maximum = max, Value = at, SmallChange = 0.01 };
            Children.Add(new TextBlock { Text = name, FontSize = 11, Classes = { "field-name" } });
            Children.Add(slider);
            return slider;
        }
    }
}
