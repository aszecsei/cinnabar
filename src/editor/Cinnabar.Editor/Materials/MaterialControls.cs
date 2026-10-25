using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Materials;

/// <summary>The material editor's small controls, which look like the properties panel's field editors.</summary>
static class MaterialControls
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

    public static Button SmallButton(string text, string tip, Action click)
    {
        var button = new Button { Content = text, Classes = { "field-button" }, VerticalAlignment = VerticalAlignment.Center };
        ToolTip.SetTip(button, tip);
        button.Click += (_, _) => click();
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

    /// <summary>A swatch of a linear color, as the screen shows it.</summary>
    public static Border Swatch(IReadOnlyList<double> rgba)
    {
        static byte Encode(double linear) => (byte)Math.Round(Model.LinearColor.ToSrgb(linear) * 255);
        var color = rgba.Count >= 3 ? Color.FromRgb(Encode(rgba[0]), Encode(rgba[1]), Encode(rgba[2])) : Colors.Transparent;
        return new Border
        {
            Width = 18,
            Height = 18,
            CornerRadius = new CornerRadius(3),
            BorderBrush = new SolidColorBrush(Color.Parse("#55555C")),
            BorderThickness = new Thickness(1),
            Background = new SolidColorBrush(color),
            VerticalAlignment = VerticalAlignment.Center,
        };
    }
}
