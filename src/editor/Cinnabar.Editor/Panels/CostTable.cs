using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Model;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// A table of the profiler's costs of one kind (see docs/editor/shell-and-panels.md#profiler): a virtualized list under
/// headers that sort it. Selecting a row highlights its name in the timeline.
/// </summary>
public sealed class CostTable : DockPanel
{
    const string Columns = "*,64,84,84,64";

    static readonly (CostColumn Column, string Label, HorizontalAlignment Align)[] Headers =
    [
        (CostColumn.Name, "Name", HorizontalAlignment.Left),
        (CostColumn.Calls, "Calls", HorizontalAlignment.Right),
        (CostColumn.Average, "Average", HorizontalAlignment.Right),
        (CostColumn.Max, "Most", HorizontalAlignment.Right),
        (CostColumn.Percent, "% frame", HorizontalAlignment.Right),
    ];

    readonly ProfilerModel _model;
    readonly ProfileCostKind _kind;
    readonly ListBox _list;
    readonly Button[] _buttons;
    readonly TextBlock _empty;
    bool _syncing;

    public CostTable(ProfilerModel model, ProfileCostKind kind, string empty)
    {
        _model = model;
        _kind = kind;
        var header = new Grid { ColumnDefinitions = new ColumnDefinitions(Columns), Margin = new Thickness(4, 2, 18, 2) };
        _buttons = new Button[Headers.Length];
        for (var i = 0; i < Headers.Length; i++)
        {
            var (column, label, align) = Headers[i];
            var button = new Button
            {
                Content = label,
                Padding = new Thickness(4, 1),
                Background = Brushes.Transparent,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = align,
            };
            button.Click += (_, _) => _model.SortBy(_kind, column);
            Grid.SetColumn(button, i);
            header.Children.Add(button);
            _buttons[i] = button;
        }
        SetDock(header, DockSide.Top);
        Children.Add(header);

        _empty = new TextBlock
        {
            Text = empty,
            Classes = { "empty" },
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = TextAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(16),
        };
        _list = new ListBox
        {
            ItemTemplate = new FuncDataTemplate<CostRow>((row, _) => Row(row)),
        };
        _list.SelectionChanged += (_, _) =>
        {
            if (!_syncing)
            {
                _model.SetHighlight((_list.SelectedItem as CostRow)?.Name);
            }
        };
        var body = new Panel { Children = { _list, _empty } };
        Children.Add(body);
        new ViewSubscriptions(this, attached: Show)
            .Add(() => _model.SummaryChanged += Show, () => _model.SummaryChanged -= Show);
    }

    static Control Row(CostRow? row)
    {
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions(Columns) };
        if (row == null)
        {
            return grid;
        }
        void Cell(int column, string text, bool dim = false)
        {
            var block = new TextBlock
            {
                Text = text,
                HorizontalAlignment = column == 0 ? HorizontalAlignment.Left : HorizontalAlignment.Right,
                TextTrimming = TextTrimming.CharacterEllipsis,
                Margin = new Thickness(4, 0),
            };
            if (dim)
            {
                block.Classes.Add("dim");
            }
            Grid.SetColumn(block, column);
            grid.Children.Add(block);
        }
        var name = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(4, 0) };
        name.Children.Add(new TextBlock { Text = row.Name, TextTrimming = TextTrimming.CharacterEllipsis });
        if (row.Detail != "")
        {
            name.Children.Add(new TextBlock { Text = row.Detail, Classes = { "dim" } });
        }
        grid.Children.Add(name);
        Cell(1, row.Calls >= 10 ? $"{row.Calls:0}" : $"{row.Calls:0.#}", dim: true);
        Cell(2, $"{row.AverageMs:0.000} ms");
        Cell(3, $"{row.MaxMs:0.000} ms", dim: true);
        Cell(4, $"{row.Percent:0.0}%");
        ToolTip.SetTip(grid, $"{row.Name} {row.Detail}".Trim());
        return grid;
    }

    void Show()
    {
        var rows = _model.Rows(_kind);
        var (sorted, descending) = _model.SortOf(_kind);
        for (var i = 0; i < Headers.Length; i++)
        {
            _buttons[i].Content = Headers[i].Column == sorted ? $"{Headers[i].Label} {(descending ? "▾" : "▴")}" : Headers[i].Label;
        }
        _empty.IsVisible = rows.Count == 0;
        // The rows are rebuilt four times a second, so the selection is found again by name.
        var selected = (_list.SelectedItem as CostRow)?.Name ?? _model.Highlight;
        _syncing = true;
        _list.ItemsSource = rows;
        _list.SelectedItem = rows.FirstOrDefault(r => r.Name == selected);
        _syncing = false;
    }
}
