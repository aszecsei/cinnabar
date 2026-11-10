using Avalonia.Controls;
using Avalonia.Media;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Viewport;

/// <summary>
/// The Scene document's view: the scene views that are in it (<see cref="EditorShell.SceneViews"/>), each a
/// <see cref="ViewportView"/>, placed by <see cref="SceneGrid"/> with splitters between them (see
/// docs/editor/viewport.md#views). A change of the views keeps every view that stays in the tree, so its target stays,
/// and moves it to its new cells; the views that leave are removed, and the ones that enter are added. The splitters'
/// positions are not kept: a new arrangement starts with equal tracks.
/// </summary>
public class SceneLayoutView : Grid
{
    const double SplitterSize = 4;

    readonly EditorShell _shell;
    readonly Dictionary<int, ViewportView> _views = [];
    readonly List<Control> _splitters = [];

    public SceneLayoutView(EditorShell shell)
    {
        _shell = shell;
        Background = Brushes.Black;
        AttachedToVisualTree += (_, _) =>
        {
            _shell.SceneViewsChanged += Arrange;
            Arrange();
        };
        DetachedFromVisualTree += (_, _) => _shell.SceneViewsChanged -= Arrange;
        Arrange();
    }

    /// <summary>A splitter that resizes the columns, or the rows. Tests have no platform for the real one.</summary>
    protected virtual Control CreateSplitter(bool vertical) =>
        new GridSplitter { ResizeDirection = vertical ? GridResizeDirection.Columns : GridResizeDirection.Rows };

    // Public to the tests, which have no visual tree to raise the shell's event on attach.
    internal void Arrange()
    {
        var grid = SceneGrid.Arrange(_shell.SceneViews);
        var wanted = grid.Cells.Select(c => c.View).ToHashSet();
        // The views that leave the Scene leave the tree, which hides their sessions and closes them in the game, and so do
        // the old splitters. A view that stays is not touched but for its cell.
        Children.RemoveAll(_splitters);
        _splitters.Clear();
        foreach (var gone in _views.Keys.Where(i => !wanted.Contains(i)).ToList())
        {
            Children.Remove(_views[gone]);
            _views.Remove(gone);
        }
        ColumnDefinitions.Clear();
        RowDefinitions.Clear();
        for (var column = 0; column < grid.Columns; column++)
        {
            ColumnDefinitions.Add(new ColumnDefinition(column % 2 == 0 ? GridLength.Star : new GridLength(SplitterSize)));
        }
        for (var row = 0; row < grid.Rows; row++)
        {
            RowDefinitions.Add(new RowDefinition(row % 2 == 0 ? GridLength.Star : new GridLength(SplitterSize)));
        }
        foreach (var cell in grid.Cells)
        {
            if (!_views.TryGetValue(cell.View, out var view))
            {
                _views[cell.View] = view = new ViewportView(_shell, _shell.Viewports[cell.View]);
            }
            SetRow(view, cell.Row);
            SetColumn(view, cell.Column);
            SetRowSpan(view, cell.RowSpan);
            SetColumnSpan(view, cell.ColumnSpan);
            if (!Children.Contains(view))
            {
                Children.Add(view);
            }
        }
        foreach (var splitter in grid.Splitters)
        {
            var control = CreateSplitter(splitter.Vertical);
            _splitters.Add(control);
            SetRow(control, splitter.Row);
            SetColumn(control, splitter.Column);
            SetRowSpan(control, splitter.RowSpan);
            SetColumnSpan(control, splitter.ColumnSpan);
            Children.Add(control);
        }
    }
}
