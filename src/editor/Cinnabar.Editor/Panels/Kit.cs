using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// The editor's small controls, which the properties panel's field editors and the material editor's panels share: a
/// box, a choice, a button, a row of a name and a control.
/// </summary>
static class Kit
{
    /// <summary>
    /// A box that edits text: Enter or leaving it commits, and Escape puts the text back. With
    /// <paramref name="multiline"/>, Enter starts a line and Ctrl+Enter commits. The setter takes every text.
    /// </summary>
    public static Control ValueBox(string text, string watermark, Action<string> commit, bool multiline = false) =>
        ValueBox(text, ValueFormats.Text, watermark, commit, multiline);

    /// <summary>
    /// A box that edits a value of a <paramref name="format"/>, which starts as the document's
    /// <paramref name="text"/>. A text that does not parse puts the value back and shows the problem as the box's tip.
    /// </summary>
    public static Control ValueBox<T>(string text, IValueFormat<T> format, string watermark, Action<T> set, bool multiline = false) =>
        ValueBox(text, format, watermark, value =>
        {
            set(value);
            return true;
        }, "", multiline);

    /// <summary>
    /// A box whose setter can refuse a value, as one that would rename a parameter to a name that another has. A
    /// refusal puts the value back and shows <paramref name="refused"/> as the box's tip.
    /// </summary>
    public static Control ValueBox<T>(string text, IValueFormat<T> format, string watermark, Func<T, bool> set, string refused, bool multiline = false)
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
        CommitBox.Attach(box, typed =>
            !format.TryParse(typed, out var value, out var problem) ? Verdict.Refused(problem)
            : set(value) ? Verdict.Took
            : Verdict.Refused(refused), multiline);
        return new Border { Classes = { "value-box", "editable" }, Child = box };
    }

    /// <summary>
    /// A box over a <paramref name="value"/> that other controls change too, as a toolbar's is: a refusal, Escape and
    /// the loss of the focus put back the value as it is then, and the box shows it again when it shows again.
    /// </summary>
    public static Control ValueBox<T>(Func<T> value, IValueFormat<T> format, string watermark, Action<T> set)
    {
        var box = new TextBox { Text = format.Format(value()), PlaceholderText = watermark, Classes = { "value-edit" }, MinHeight = 20 };
        CommitBox.Attach(box, typed =>
        {
            if (!format.TryParse(typed, out var parsed, out var problem))
            {
                return Verdict.Refused(problem);
            }
            set(parsed);
            return Verdict.Took;
        }, () => format.Format(value()));
        var border = new Border { Classes = { "value-box", "editable" }, Child = box };
        border.PropertyChanged += (_, e) =>
        {
            if (e.Property == Visual.IsVisibleProperty && border.IsVisible && !box.IsFocused)
            {
                box.Text = format.Format(value());
            }
        };
        return border;
    }

    /// <summary>
    /// Makes a box commit its text on Enter and when it loses the focus, and put the text back on Escape, as
    /// <see cref="CommitBox"/> does. It commits a text once: a box that commits on Enter and then loses the focus, as it
    /// does when its view builds again without it, does not commit again. So the commit must not compare with a value
    /// that it captured, which is old by then.
    /// </summary>
    public static void CommitOnEnterOrBlur(TextBox box, Action<string> commit) =>
        CommitBox.Attach(box, text =>
        {
            commit(text);
            return Verdict.Took;
        });

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
        // The option that the box last picked or started with, so that going back to the first option picks it again.
        var current = selected;
        combo.SelectionChanged += (_, _) =>
        {
            if (combo.SelectedItem is string s && s != current)
            {
                current = s;
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

    /// <summary>A swatch, and the box that edits its color beside it.</summary>
    public static DockPanel WithSwatch(Control swatch, Control box)
    {
        var line = new DockPanel();
        swatch.Margin = new Thickness(0, 0, 6, 0);
        DockPanel.SetDock(swatch, Avalonia.Controls.Dock.Left);
        line.Children.Add(swatch);
        line.Children.Add(box);
        return line;
    }

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
