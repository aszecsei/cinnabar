using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using static Cinnabar.Editor.Panels.Kit;

namespace Cinnabar.Editor.UiDocuments;

/// <summary>
/// The UI editor's styles (see docs/editor/ui-editor.md#styles): each style with its variants under it, and how many
/// elements take it. A click selects a style, whose attributes the properties then show; the buttons add a style, a
/// variant of the selected one for a state, and delete it.
/// </summary>
sealed class UiStylesPanel : DockPanel
{
    static readonly IBrush SelectedBrush = new SolidColorBrush(Color.FromArgb(0x50, Palette.Accent.R, Palette.Accent.G, Palette.Accent.B));

    readonly UiEditor _editor;
    readonly StackPanel _rows = new();
    string _shown = "";

    public UiStylesPanel(UiEditor editor)
    {
        _editor = editor;
        var buttons = new WrapPanel { Margin = new Thickness(6, 4) };
        buttons.Children.Add(new TextBlock { Text = "Styles", FontWeight = FontWeight.SemiBold, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(2, 0, 8, 0) });
        var name = new TextBox { PlaceholderText = "new style", Width = 90, Classes = { "value-edit" } };
        name.KeyDown += (_, e) =>
        {
            if (e.Key == Avalonia.Input.Key.Enter && name.Text is { Length: > 0 } text && _editor.AddStyle(text.Trim()))
            {
                name.Text = "";
                e.Handled = true;
            }
        };
        ToolTip.SetTip(name, "Enter adds a style by this name, or a variant as button:hover");
        buttons.Children.Add(name);
        var variants = new MenuFlyout();
        variants.Opening += (_, _) =>
        {
            variants.Items.Clear();
            if (_editor.SelectedStyle is not { } selected || _editor.File.Style(selected) is not { } style)
            {
                return;
            }
            foreach (var state in UiFile.States.Where(s => _editor.File.Style($"{style.Base}:{s}") == null))
            {
                var item = new MenuItem { Header = $"{style.Base}:{state}" };
                item.Click += (_, _) => _editor.AddStyle($"{style.Base}:{state}");
                variants.Items.Add(item);
            }
        };
        var variant = new Button { Content = "Variant", Flyout = variants, Classes = { "field-button" }, Margin = new Thickness(4, 0, 0, 0) };
        ToolTip.SetTip(variant, "Add a variant of the selected style for a state: hover, focus, press or disabled");
        buttons.Children.Add(variant);
        buttons.Children.Add(SmallButton("Delete", "Delete the selected style", () =>
        {
            if (_editor.SelectedStyle is { } s)
            {
                _editor.DeleteStyle(s);
            }
        }));
        SetDock(buttons, Avalonia.Controls.Dock.Top);
        Children.Add(buttons);
        Children.Add(new ScrollViewer { Content = _rows, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled });
        new ViewSubscriptions(this, attached: Refresh)
            .Add(() => _editor.Changed += Refresh, () => _editor.Changed -= Refresh)
            .Add(() => _editor.SelectionChanged += Refresh, () => _editor.SelectionChanged -= Refresh)
            .Add(() => _editor.ProblemsChanged += Rebuild, () => _editor.ProblemsChanged -= Rebuild);
    }

    void Rebuild()
    {
        _shown = "";
        Refresh();
    }

    void Refresh()
    {
        var shown = $"{_editor.File.Text.GetHashCode()}:{_editor.SelectedStyle}:{_editor.Problems.Count}";
        if (shown == _shown)
        {
            return;
        }
        _shown = shown;
        _rows.Children.Clear();
        var styles = _editor.File.Styles;
        if (styles.Count == 0)
        {
            _rows.Children.Add(Dim("No styles. An element takes the style named for its kind, such as button, and those that it names."));
        }
        foreach (var style in styles.Where(s => s.State == "" || styles.All(b => b.Name != s.Base)))
        {
            _rows.Children.Add(Row(style, 0));
            foreach (var state in UiFile.States)
            {
                if (style.State == "" && _editor.File.Style($"{style.Name}:{state}") is { } v)
                {
                    _rows.Children.Add(Row(v, 1));
                }
            }
        }
    }

    Control Row(UiStyle style, int depth)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        content.Children.Add(new TextBlock { Text = depth == 0 ? style.Name : $":{style.State}", FontSize = 12 });
        if (depth == 0)
        {
            var count = _editor.TakersOf(style.Name).Count();
            content.Children.Add(new TextBlock { Text = count == 1 ? "1 element" : $"{count} elements", FontSize = 11, Classes = { "empty" } });
        }
        var problems = _editor.Problems.Where(p => p.Style == style.Name).ToList();
        if (problems.Count > 0)
        {
            var mark = new TextBlock { Text = "●", FontSize = 10, Foreground = problems.Any(p => p.Error) ? Palette.ErrorBrush : Palette.WarningBrush };
            ToolTip.SetTip(mark, string.Join("\n", problems.Select(p => p.Text)));
            content.Children.Add(mark);
        }
        var view = new Border
        {
            Child = content,
            Padding = new Thickness(8 + depth * 14, 2, 4, 2),
            Background = style.Name == _editor.SelectedStyle ? SelectedBrush : Brushes.Transparent,
        };
        view.PointerPressed += (_, _) => _editor.SelectStyle(style.Name);
        return view;
    }
}

/// <summary>
/// The values that the canvas gives the document's bindings (see docs/editor/ui-editor.md#bindings): each {name} in its
/// text, with a box for the value. The file does not keep them.
/// </summary>
sealed class UiBindingsPanel : ScrollViewer
{
    readonly UiEditor _editor;
    readonly StackPanel _panel = new() { Margin = new Thickness(8), Spacing = 2 };
    string _shown = "";

    // A subclass takes ScrollViewer's template only by its style key.
    protected override Type StyleKeyOverride => typeof(ScrollViewer);

    public UiBindingsPanel(UiEditor editor)
    {
        _editor = editor;
        Content = _panel;
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        new ViewSubscriptions(this, attached: Refresh).Add(() => _editor.Changed += Refresh, () => _editor.Changed -= Refresh);
    }

    void Refresh()
    {
        var names = _editor.BindingNames;
        var shown = string.Join(',', names);
        if (shown == _shown)
        {
            return;
        }
        _shown = shown;
        _panel.Children.Clear();
        _panel.Children.Add(Heading("Bindings"));
        if (names.Count == 0)
        {
            _panel.Children.Add(Dim("The text binds no {name}."));
        }
        foreach (var name in names)
        {
            _panel.Children.Add(Kit.Row(name, ValueBox(_editor.BindingValues.GetValueOrDefault(name, ""), "a value to preview", value => _editor.SetBinding(name, value))));
        }
    }
}
