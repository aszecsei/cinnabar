using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// The undo history (see docs/editor/shell-and-panels.md#panels): the open scene's undo entries, oldest first, after a row for the
/// scene as it opened. Clicking a row undoes or redoes to it. Entries past the current one are dimmed, and the one
/// that the file has is marked.
/// </summary>
public sealed class UndoHistoryView : DockPanel
{
    readonly EditorShell _shell;
    readonly ListBox _list = new() { Classes = { "history" } };
    readonly TextBlock _empty = new()
    {
        Text = "Edits of the open scene appear here.",
        Classes = { "empty" },
        TextWrapping = TextWrapping.Wrap,
        TextAlignment = TextAlignment.Center,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        MaxWidth = 240,
        Margin = new Thickness(16),
    };
    bool _syncing;

    public UndoHistoryView(EditorShell shell)
    {
        _shell = shell;
        Children.Add(new Panel { Children = { _list, _empty } });
        _list.ItemTemplate = new FuncDataTemplate<HistoryRow>((row, _) => row == null ? new Control() : RowView(row));
        _list.SelectionChanged += (_, _) =>
        {
            if (!_syncing && _list.SelectedItem is HistoryRow row)
            {
                _shell.Scene?.MoveTo(row.Position);
            }
        };
        AttachedToVisualTree += (_, _) =>
        {
            _shell.SceneChanged += Rebuild;
            Rebuild();
        };
        DetachedFromVisualTree += (_, _) => _shell.SceneChanged -= Rebuild;
    }

    void Rebuild()
    {
        var scene = _shell.Scene;
        _empty.IsVisible = scene == null;
        var rows = new List<HistoryRow>();
        if (scene != null)
        {
            rows.Add(new HistoryRow(0, $"Open {scene.Title}", scene.Position >= 0, scene.SavedPosition == 0));
            for (var i = 0; i < scene.History.Count; i++)
            {
                rows.Add(new HistoryRow(i + 1, scene.History[i].Label, i < scene.Position, scene.SavedPosition == i + 1));
            }
        }
        _syncing = true;
        _list.ItemsSource = rows;
        _list.SelectedItem = scene == null ? null : rows[scene.Position];
        if (_list.SelectedItem != null)
        {
            _list.ScrollIntoView(_list.SelectedItem);
        }
        _syncing = false;
    }

    static Control RowView(HistoryRow row) => new StackPanel
    {
        Orientation = Orientation.Horizontal,
        Spacing = 6,
        Opacity = row.Applied ? 1 : 0.45,
        Children =
        {
            new TextBlock { Text = row.Label },
            new TextBlock { Text = row.Saved ? "saved" : "", Classes = { "dim" } },
        },
    };
}

/// <summary>A row of the history: the entry that makes <see cref="Position"/> entries applied.</summary>
public sealed record HistoryRow(int Position, string Label, bool Applied, bool Saved);
