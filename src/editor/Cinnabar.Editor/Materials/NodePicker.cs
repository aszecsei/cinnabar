using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Materials;

/// <summary>
/// The menu that adds a node: a search over the kinds of node that the graph can have, by label, category and
/// description, every word of the query matching. Enter adds the first match.
/// </summary>
sealed class NodePicker
{
    readonly MaterialEditor _editor;
    readonly Flyout _flyout;
    readonly TextBox _query = new() { PlaceholderText = "Search nodes", Classes = { "palette-query" } };
    readonly ListBox _results = new() { Classes = { "palette-results" }, MaxHeight = 360, Width = 280 };
    Vec2 _at;
    (int Node, string Pin, bool FromOutput)? _from;

    /// <summary>A kind was picked: its name, where to put it, and the pin that a link was dragged from, if any.</summary>
    public event Action<string, Vec2, (int Node, string Pin, bool FromOutput)?>? Picked;

    public NodePicker(MaterialEditor editor)
    {
        _editor = editor;
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

    public void Open(Control target, Vec2 at, (int Node, string Pin, bool FromOutput)? from)
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
        foreach (var kind in _editor.Catalog.KindsFor(_editor.Document.Kind).Where(k => k.Kind != "output" && words.All(w => Matches(k, w))))
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

    static bool Matches(NodeInfo kind, string word) =>
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
