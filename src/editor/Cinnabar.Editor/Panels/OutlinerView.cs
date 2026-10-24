using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Shell;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// The outliner (see docs/editor.md#outliner): the entity hierarchy as a virtualized list of the visible rows,
/// indented by depth. A tree control with one item per entity would not scale to a large world.
/// </summary>
public sealed class OutlinerView : DockPanel
{
    // The components that the tree itself shows: the hierarchy, and activity by dimming.
    static readonly HashSet<string> Structural = ["Parent", "Previous_Transform", "Inactive", "Disabled"];
    const double Indent = 14;

    readonly WorldModel _world;
    readonly Selection _selection;
    readonly TextBox _filter = new() { PlaceholderText = "Filter by entity or component", Classes = { "outliner-filter" } };
    readonly ListBox _list = new() { Classes = { "outliner" } };
    readonly TextBlock _empty;
    // Rows start expanded. The set holds the ones that the user collapsed.
    readonly HashSet<ulong> _collapsed = [];
    bool _syncing;

    public OutlinerView(WorldModel world, Selection selection)
    {
        _world = world;
        _selection = selection;
        SetDock(_filter, DockSide.Top);
        Children.Add(_filter);
        _empty = new TextBlock
        {
            Text = "The world's entities appear here when the editor link connects to the host.",
            Classes = { "empty" },
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = TextAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            MaxWidth = 240,
            Margin = new Thickness(16),
        };
        Children.Add(new Panel { Children = { _list, _empty } });

        _list.ItemTemplate = new FuncDataTemplate<OutlinerRow>((row, _) => row == null ? new Control() : RowView(row));
        _list.SelectionChanged += (_, _) =>
        {
            if (!_syncing && _list.SelectedItem is OutlinerRow row)
            {
                _selection.Select(row.Node.Handle);
            }
        };
        _filter.TextChanged += (_, _) => Rebuild();

        AttachedToVisualTree += (_, _) =>
        {
            _world.EntitiesChanged += Rebuild;
            _world.TypesChanged += Rebuild;
            _selection.Changed += OnSelectionChanged;
            Rebuild();
        };
        DetachedFromVisualTree += (_, _) =>
        {
            _world.EntitiesChanged -= Rebuild;
            _world.TypesChanged -= Rebuild;
            _selection.Changed -= OnSelectionChanged;
        };
    }

    void Rebuild()
    {
        _empty.IsVisible = !_world.HasWorld;
        var filter = _filter.Text?.Trim() ?? "";
        var rows = new List<OutlinerRow>();
        foreach (var root in _world.Roots)
        {
            Add(rows, root, 0, filter);
        }
        _syncing = true;
        _list.ItemsSource = rows;
        _list.SelectedItem = rows.FirstOrDefault(r => r.Node.Handle == _selection.Entity);
        _syncing = false;
    }

    // Adds a node and its visible descendants, and returns whether the node or one of them matches the filter. With a
    // filter, a match shows with its ancestors, expanded or not.
    bool Add(List<OutlinerRow> rows, EntityNode node, int depth, string filter)
    {
        var summary = string.Join(", ", node.Components.Select(_world.TypeName).Where(n => !Structural.Contains(n)));
        var label = node.ToString();
        var row = new OutlinerRow(node, depth, label, summary, node.Children.Count > 0, !_collapsed.Contains(node.Handle));
        var at = rows.Count;
        rows.Add(row);
        var matches = filter.Length == 0
            || label.Contains(filter, StringComparison.OrdinalIgnoreCase)
            || summary.Contains(filter, StringComparison.OrdinalIgnoreCase);
        var childMatches = false;
        if (row.Expanded || filter.Length > 0)
        {
            foreach (var child in node.Children)
            {
                childMatches |= Add(rows, child, depth + 1, filter);
            }
        }
        if (filter.Length > 0 && !matches && !childMatches)
        {
            rows.RemoveAt(at);
        }
        return matches || childMatches;
    }

    void OnSelectionChanged(ulong old, ulong entity)
    {
        _syncing = true;
        _list.SelectedItem = (_list.ItemsSource as List<OutlinerRow>)?.FirstOrDefault(r => r.Node.Handle == entity);
        if (_list.SelectedItem != null)
        {
            _list.ScrollIntoView(_list.SelectedItem);
        }
        _syncing = false;
    }

    Control RowView(OutlinerRow row)
    {
        var expander = new TextBlock
        {
            Text = row.HasChildren ? (row.Expanded ? "▾" : "▸") : "",
            Width = 14,
            Classes = { "dim" },
            Cursor = row.HasChildren ? new Cursor(StandardCursorType.Hand) : Cursor.Default,
        };
        if (row.HasChildren)
        {
            expander.PointerPressed += (_, e) =>
            {
                if (!_collapsed.Remove(row.Node.Handle))
                {
                    _collapsed.Add(row.Node.Handle);
                }
                e.Handled = true;
                Rebuild();
            };
        }
        return new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(row.Depth * Indent, 0, 0, 0),
            Spacing = 6,
            Opacity = row.Node.Active ? 1 : 0.45,
            Children =
            {
                expander,
                new TextBlock { Text = row.Label },
                new TextBlock { Text = row.Summary, Classes = { "dim" } },
            },
        };
    }
}

public sealed record OutlinerRow(EntityNode Node, int Depth, string Label, string Summary, bool HasChildren, bool Expanded);
