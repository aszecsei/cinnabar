using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Controls.Templates;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Ribbon;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// A picker of things in folders (see docs/editor/shell-and-panels.md#properties): a box that searches, and under it the
/// folders, closed until clicked, or the matches of the search. A click or Enter picks an item, and Escape closes it.
/// Typing is the fast way, and the folders are for a person who does not know the name yet.
/// </summary>
sealed class CatalogPicker
{
    readonly Func<IReadOnlyList<CatalogItem>> _items;
    readonly Action<CatalogItem> _pick;
    readonly Func<string, string?> _folderIcon;
    // The folders that the user opened, which stay open the next time, by the picker's owner.
    readonly HashSet<string> _expanded;
    readonly TextBox _query = new() { Classes = { "picker-query" } };
    readonly ListBox _rows = new() { Classes = { "picker-rows" }, MaxHeight = 380 };
    readonly TextBlock _note = new() { Classes = { "dim" }, FontSize = 11, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(8, 4), IsVisible = false };
    readonly Flyout _flyout;
    IReadOnlyList<CatalogItem> _all = [];

    /// <summary>What the picker says under its rows, such as why some items are not there. Null for nothing.</summary>
    public Func<string?>? Note { get; init; }

    public CatalogPicker(string watermark, Func<IReadOnlyList<CatalogItem>> items, Action<CatalogItem> pick, HashSet<string> expanded, Func<string, string?> folderIcon)
    {
        _items = items;
        _pick = pick;
        _expanded = expanded;
        _folderIcon = folderIcon;
        _query.PlaceholderText = watermark;
        _rows.ItemTemplate = new FuncDataTemplate<CatalogRow>((row, _) => row == null ? new Control() : Row(row));
        var panel = new DockPanel { Width = 300 };
        DockPanel.SetDock(_query, Avalonia.Controls.Dock.Top);
        DockPanel.SetDock(_note, Avalonia.Controls.Dock.Bottom);
        panel.Children.Add(_query);
        panel.Children.Add(_note);
        panel.Children.Add(_rows);
        _flyout = new Flyout { Content = panel, Placement = PlacementMode.TopEdgeAlignedLeft, FlyoutPresenterClasses = { "picker" } };
        _flyout.Opening += (_, _) =>
        {
            _all = _items();
            _query.Text = "";
            _note.Text = Note?.Invoke();
            _note.IsVisible = !string.IsNullOrEmpty(_note.Text);
            Refresh();
        };
        // The box takes the keys once the flyout shows, so that typing searches at once.
        _flyout.Opened += (_, _) => Dispatcher.UIThread.Post(() => _query.Focus(), DispatcherPriority.Input);
        _query.TextChanged += (_, _) => Refresh();
        _query.KeyDown += OnKey;
        _rows.KeyDown += OnKey;
    }

    /// <summary>A button across its panel that opens the picker.</summary>
    public Button Button(string label)
    {
        var button = new Button
        {
            Content = label,
            Flyout = _flyout,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Center,
            Classes = { "add-component" },
        };
        return button;
    }

    /// <summary>The rows that show for a query: internal to the tests, which have no window to open the flyout in.</summary>
    internal IReadOnlyList<CatalogRow> RowsFor(string query) => Catalog.Rows(_items(), query, _expanded.Contains);

    void Refresh()
    {
        var query = _query.Text ?? "";
        var rows = Catalog.Rows(_all, query, _expanded.Contains);
        _rows.ItemsSource = rows;
        // With a search, Enter takes the best match; without, nothing is chosen until the user moves to it.
        _rows.SelectedIndex = query.Trim().Length > 0 && rows.Count > 0 ? 0 : -1;
    }

    void OnKey(object? sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Escape:
                _flyout.Hide();
                break;
            case Key.Enter:
                if (_rows.SelectedItem is CatalogRow row)
                {
                    Activate(row);
                }
                break;
            case Key.Down:
                _rows.SelectedIndex = Math.Min(_rows.SelectedIndex + 1, _rows.ItemCount - 1);
                _rows.ScrollIntoView(_rows.SelectedIndex);
                break;
            case Key.Up:
                _rows.SelectedIndex = Math.Max(_rows.SelectedIndex - 1, 0);
                _rows.ScrollIntoView(_rows.SelectedIndex);
                break;
            default:
                return;
        }
        e.Handled = true;
    }

    // A folder opens or closes, and an item is picked.
    void Activate(CatalogRow row)
    {
        if (row.Item is { } item)
        {
            _flyout.Hide();
            _pick(item);
            return;
        }
        if (!_expanded.Remove(row.Folder))
        {
            _expanded.Add(row.Folder);
        }
        var index = _rows.SelectedIndex;
        Refresh();
        _rows.SelectedIndex = Math.Min(index, _rows.ItemCount - 1);
    }

    Control Row(CatalogRow row)
    {
        var searching = (_query.Text ?? "").Trim().Length > 0;
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(row.Depth * 14, 0, 0, 0) };
        if (row.IsFolder)
        {
            content.Children.Add(new TextBlock { Text = _expanded.Contains(row.Folder) ? "▾" : "▸", Width = 10, Classes = { "dim" }, VerticalAlignment = VerticalAlignment.Center });
            content.Children.Add(CommandViews.Icon(_folderIcon(row.Folder), 14) ?? new Control { Width = 14 });
            content.Children.Add(new TextBlock { Text = row.Label, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        }
        else
        {
            content.Children.Add(new Control { Width = row.Depth > 0 ? 10 : 0 });
            content.Children.Add(new TextBlock { Text = row.Label, VerticalAlignment = VerticalAlignment.Center });
            // A match of a search says where it is, since its folder does not show.
            var detail = searching ? row.Folder.Replace("/", " › ") : row.Item!.Detail;
            if (!string.IsNullOrEmpty(detail))
            {
                content.Children.Add(new TextBlock { Text = detail, Classes = { "dim" }, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
            }
        }
        var view = new Border { Background = Brushes.Transparent, Child = content };
        if (row.Item?.Detail is { Length: > 0 } tip)
        {
            ToolTip.SetTip(view, tip);
        }
        view.PointerReleased += (_, e) =>
        {
            if (e.InitialPressMouseButton == MouseButton.Left)
            {
                Activate(row);
                e.Handled = true;
            }
        };
        return view;
    }
}
