using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// The editor's small controls, which the properties panel's field editors and the material editor's panels share: a
/// box, a choice, a button, a row of a name and a control.
/// </summary>
static class Kit
{
    /// <summary>
    /// A box that edits text: Enter or leaving it commits, and Escape puts the text back. With
    /// <paramref name="multiline"/>, Enter starts a line and Ctrl+Enter commits.
    /// </summary>
    public static Control ValueBox(string text, string watermark, Action<string> commit, bool multiline = false)
    {
        var box = new TextBox
        {
            Text = text,
            PlaceholderText = watermark,
            Classes = { "value-edit" },
            AcceptsReturn = multiline,
            TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap,
            MinHeight = multiline ? 60 : 20,
        };
        var committed = text;
        void Commit()
        {
            if (box.Text != committed)
            {
                committed = box.Text ?? "";
                commit(committed);
            }
        }
        box.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter && (!multiline || e.KeyModifiers == KeyModifiers.Control))
            {
                Commit();
                e.Handled = true;
            }
            else if (e.Key == Key.Escape)
            {
                box.Text = committed;
                e.Handled = true;
            }
        };
        box.LostFocus += (_, _) => Commit();
        return new Border { Classes = { "value-box", "editable" }, Child = box };
    }

    public static ComboBox Choice(IEnumerable<string> options, string? selected, Action<string> pick)
    {
        var list = options.ToList();
        var combo = new ComboBox
        {
            ItemsSource = list,
            SelectedItem = selected != null && list.Contains(selected) ? selected : null,
            Classes = { "value-choice" },
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        combo.SelectionChanged += (_, _) =>
        {
            if (combo.SelectedItem is string s && s != selected)
            {
                pick(s);
            }
        };
        return combo;
    }

    /// <summary>A button of a word or a sign. With <paramref name="handled"/>, the click goes no farther up, as to a header that it sits in.</summary>
    public static Button SmallButton(string text, string tip, Action click, bool handled = false)
    {
        var button = new Button { Content = text, Classes = { "field-button" }, VerticalAlignment = VerticalAlignment.Center };
        ToolTip.SetTip(button, tip);
        button.Click += (_, e) =>
        {
            click();
            if (handled)
            {
                e.Handled = true;
            }
        };
        return button;
    }

    /// <summary>
    /// A button across the panel that opens a menu. It is disabled when the menu has no items, unless the menu fills
    /// itself as it opens.
    /// </summary>
    public static Button AddButton(string label, MenuFlyout menu, bool disabledWhenEmpty = true)
    {
        var button = new Button
        {
            Content = label,
            Flyout = menu,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Center,
            Classes = { "add-component" },
        };
        if (disabledWhenEmpty)
        {
            button.IsEnabled = menu.Items.Count > 0;
        }
        return button;
    }

    public static TextBlock Heading(string text) => new()
    {
        Text = text,
        FontSize = 12,
        FontWeight = FontWeight.SemiBold,
        Margin = new Thickness(0, 6, 0, 2),
    };

    public static TextBlock Dim(string text) => new() { Text = text, Classes = { "empty" }, TextWrapping = TextWrapping.Wrap };

    /// <summary>A row of a name and a control, as the properties panel's fields are.</summary>
    public static Grid Row(string name, Control value, params Control[] after)
    {
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("90,*,Auto"), ColumnSpacing = 6, Margin = new Thickness(0, 1) };
        var label = new TextBlock { Text = name, Classes = { "field-name" }, VerticalAlignment = VerticalAlignment.Center, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis };
        ToolTip.SetTip(label, name);
        grid.Children.Add(label);
        Grid.SetColumn(value, 1);
        grid.Children.Add(value);
        if (after.Length > 0)
        {
            var buttons = new StackPanel { Orientation = Orientation.Horizontal };
            foreach (var a in after)
            {
                buttons.Children.Add(a);
            }
            Grid.SetColumn(buttons, 2);
            grid.Children.Add(buttons);
        }
        return grid;
    }

    /// <summary>Numbers as a value box takes them, with a count that they must have, or any count up to four for 0.</summary>
    public static GraphNumbers? Numbers(string text, int count = 0) =>
        GraphNumbers.TryParse(text) is { } n && (count == 0 || n.Values.Count == count) ? n : null;

    /// <summary>The color of a linear color's first three numbers, as the screen shows it.</summary>
    public static Color SrgbColor(IReadOnlyList<double> linear)
    {
        static byte Encode(double v) => (byte)Math.Round(Model.LinearColor.ToSrgb(v) * 255);
        return Color.FromRgb(Encode(linear[0]), Encode(linear[1]), Encode(linear[2]));
    }

    /// <summary>The rounded outline of a swatch, to give a size and a color.</summary>
    public static Border SwatchFrame() => new()
    {
        CornerRadius = new CornerRadius(3),
        BorderBrush = new SolidColorBrush(Palette.SwatchBorder),
        BorderThickness = new Thickness(1),
    };

    /// <summary>A swatch of a linear color, as the screen shows it.</summary>
    public static Border Swatch(IReadOnlyList<double> rgba)
    {
        var swatch = SwatchFrame();
        swatch.Width = 18;
        swatch.Height = 18;
        swatch.Background = new SolidColorBrush(rgba.Count >= 3 ? SrgbColor(rgba) : Colors.Transparent);
        swatch.VerticalAlignment = VerticalAlignment.Center;
        return swatch;
    }
}
