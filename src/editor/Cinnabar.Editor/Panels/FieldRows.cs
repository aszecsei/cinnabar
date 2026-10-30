using Avalonia.Controls;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// A grid of rows that each hold a name, a value and optionally a control after them, as the properties panel lays out
/// its fields.
/// </summary>
sealed class FieldRows(string columns = "Auto,*")
{
    int _row;

    public Grid Grid { get; } = new() { ColumnDefinitions = new ColumnDefinitions(columns), Classes = { "fields" } };

    /// <summary>Adds a row, and returns its index.</summary>
    public int Add(Control name, Control value, Control? after = null)
    {
        var row = _row++;
        Grid.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
        Grid.SetRow(name, row);
        Grid.SetRow(value, row);
        Grid.SetColumn(value, 1);
        Grid.Children.Add(name);
        Grid.Children.Add(value);
        if (after != null)
        {
            Grid.SetRow(after, row);
            Grid.SetColumn(after, 2);
            Grid.Children.Add(after);
        }
        return row;
    }
}
