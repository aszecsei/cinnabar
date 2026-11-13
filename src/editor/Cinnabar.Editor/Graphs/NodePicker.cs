using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Cinnabar.Editor.Maths;

namespace Cinnabar.Editor.Graphs;

/// <summary>A choice in a node picker: what it adds, and the words that find it.</summary>
public sealed record PickerEntry(string Kind, string Label, string Category, string Description);

/// <summary>
/// The menu that adds a node to a graph: a search over what the graph can add, by label, category, kind and description,
/// every word of the query matching. Enter adds the first match. TFrom is what the canvas opened it from, such as the
/// pin that a link was dragged from, which it gives back with the pick.
/// </summary>
sealed class NodePicker<TFrom>
{
    readonly Func<IEnumerable<PickerEntry>> _entries;
    readonly Flyout _flyout;
    readonly TextBox _query = new() { PlaceholderText = "Search nodes", Classes = { "palette-query" } };
    readonly ListBox _results = new() { Classes = { "palette-results" }, MaxHeight = 360, Width = 280 };
    Vec2 _at;
    TFrom _from = default!;

    /// <summary>A kind was picked: its name, where to put it, and what the picker was opened from.</summary>
    public event Action<string, Vec2, TFrom>? Picked;

    public NodePicker(Func<IEnumerable<PickerEntry>> entries)
    {
        _entries = entries;
        var panel = new StackPanel { Children = { _query, _results } };
        _flyout = new Flyout { Content = new Border { Classes = { "palette" }, Child = panel }, Placement = PlacementMode.Pointer };
        _query.TextChanged += (_, _) => Fill();
        _query.KeyDown += (_, e) =>
        {
            switch (e.Key)
            {
                case Key.Enter when _results.ItemCount > 0:
                    Pick((_results.SelectedItem ?? _results.Items[0]) as ListBoxItem);
                    e.Handled = true;
                    break;
                case Key.Down when _results.ItemCount > 0:
                    _results.SelectedIndex = Math.Min(_results.SelectedIndex + 1, _results.ItemCount - 1);
                    e.Handled = true;
                    break;
                case Key.Up when _results.ItemCount > 0:
                    _results.SelectedIndex = Math.Max(_results.SelectedIndex - 1, 0);
                    e.Handled = true;
                    break;
                case Key.Escape:
                    _flyout.Hide();
                    e.Handled = true;
                    break;
            }
        };
        _results.DoubleTapped += (_, _) => Pick(_results.SelectedItem as ListBoxItem);
        _results.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter)
            {
                Pick(_results.SelectedItem as ListBoxItem);
                e.Handled = true;
            }
        };
        _flyout.Opened += (_, _) => _query.Focus();
    }

    public void Open(Control target, Vec2 at, TFrom from)
    {
        _at = at;
        _from = from;
        _query.Text = "";
        Fill();
        _flyout.ShowAt(target, showAtPointer: true);
    }

    void Fill()
    {
        var words = (_query.Text ?? "").Split(' ', StringSplitOptions.RemoveEmptyEntries);
        _results.Items.Clear();
        foreach (var kind in _entries().Where(k => words.All(w => Matches(k, w))))
        {
            var item = new ListBoxItem
            {
                Tag = kind.Kind,
                Content = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 8,
                    Children =
                    {
                        new TextBlock { Text = kind.Label },
                        new TextBlock { Text = kind.Category, Classes = { "dim" } },
                    },
                },
            };
            ToolTip.SetTip(item, kind.Description);
            _results.Items.Add(item);
        }
        _results.SelectedIndex = _results.ItemCount > 0 ? 0 : -1;
    }

    static bool Matches(PickerEntry kind, string word) =>
        kind.Label.Contains(word, StringComparison.OrdinalIgnoreCase) || kind.Category.Contains(word, StringComparison.OrdinalIgnoreCase)
        || kind.Kind.Contains(word, StringComparison.OrdinalIgnoreCase) || kind.Description.Contains(word, StringComparison.OrdinalIgnoreCase);

    void Pick(ListBoxItem? item)
    {
        if (item?.Tag is not string kind)
        {
            return;
        }
        _flyout.Hide();
        Picked?.Invoke(kind, _at, _from);
    }
}
