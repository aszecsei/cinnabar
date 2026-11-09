using Avalonia.Controls;
using Avalonia.Media;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Viewport;

/// <summary>
/// The viewport panel: the viewports that the shell's arrangement shows, each a <see cref="ViewportView"/>, with
/// splitters between them (see docs/editor/viewport.md#several-viewports). A new arrangement lays them out again.
/// </summary>
public sealed class ViewportsView : Grid
{
    const double SplitterSize = 4;

    readonly EditorShell _shell;

    public ViewportsView(EditorShell shell)
    {
        _shell = shell;
        Background = Brushes.Black;
        AttachedToVisualTree += (_, _) =>
        {
            _shell.ArrangementChanged += Arrange;
            Arrange();
        };
        DetachedFromVisualTree += (_, _) => _shell.ArrangementChanged -= Arrange;
    }

    // Each open viewport gets a cell, in the order of their numbers: across for two side by side, down for two stacked,
    // and across then down for four.
    void Arrange()
    {
        Children.Clear();
        ColumnDefinitions.Clear();
        RowDefinitions.Clear();
        var arrangement = _shell.Arrangement;
        var columns = arrangement is ViewportArrangement.SideBySide or ViewportArrangement.Quad ? 2 : 1;
        var rows = arrangement is ViewportArrangement.Stacked or ViewportArrangement.Quad ? 2 : 1;
        ColumnDefinitions.Add(new ColumnDefinition(GridLength.Star));
        if (columns == 2)
        {
            ColumnDefinitions.Add(new ColumnDefinition(new GridLength(SplitterSize)));
            ColumnDefinitions.Add(new ColumnDefinition(GridLength.Star));
        }
        RowDefinitions.Add(new RowDefinition(GridLength.Star));
        if (rows == 2)
        {
            RowDefinitions.Add(new RowDefinition(new GridLength(SplitterSize)));
            RowDefinitions.Add(new RowDefinition(GridLength.Star));
        }
        foreach (var viewport in _shell.OpenViewports)
        {
            var view = new ViewportView(_shell, viewport);
            SetColumn(view, viewport.Index % columns * 2);
            SetRow(view, viewport.Index / columns * 2);
            Children.Add(view);
        }
        if (columns == 2)
        {
            var splitter = new GridSplitter { ResizeDirection = GridResizeDirection.Columns };
            SetColumn(splitter, 1);
            SetRowSpan(splitter, RowDefinitions.Count);
            Children.Add(splitter);
        }
        if (rows == 2)
        {
            var splitter = new GridSplitter { ResizeDirection = GridResizeDirection.Rows };
            SetRow(splitter, 1);
            SetColumnSpan(splitter, ColumnDefinitions.Count);
            Children.Add(splitter);
        }
    }
}
