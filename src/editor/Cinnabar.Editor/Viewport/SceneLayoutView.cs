using Avalonia.Controls;
using Avalonia.Media;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Viewport;

/// <summary>
/// The Scene document's view: the scene views that the shell's layout shows (see docs/editor/viewport.md#views), each a
/// <see cref="ViewportView"/>. Single is the first alone. Quad is two by two, with splitters between the views: Perspective
/// at the top left, Top at the top right, Front at the bottom left and Side at the bottom right. A new layout keeps the
/// first view as it is, so its target stays, and adds or drops the others.
/// </summary>
public sealed class SceneLayoutView : Grid
{
    const double SplitterSize = 4;

    readonly EditorShell _shell;
    // The first view stays in the tree across layouts, so that changing the layout does not close and open it.
    readonly ViewportView _first;

    public SceneLayoutView(EditorShell shell)
    {
        _shell = shell;
        _first = new ViewportView(shell, shell.Viewports[0]);
        Background = Brushes.Black;
        AttachedToVisualTree += (_, _) =>
        {
            _shell.SceneLayoutChanged += Arrange;
            Arrange();
        };
        DetachedFromVisualTree += (_, _) => _shell.SceneLayoutChanged -= Arrange;
        Arrange();
    }

    void Arrange()
    {
        var quad = _shell.SceneLayout == SceneLayout.Quad;
        // The other views and the splitters leave the tree, which hides the views' sessions and closes them in the game.
        for (var i = Children.Count - 1; i >= 0; i--)
        {
            if (Children[i] != _first)
            {
                Children.RemoveAt(i);
            }
        }
        ColumnDefinitions.Clear();
        RowDefinitions.Clear();
        ColumnDefinitions.Add(new ColumnDefinition(GridLength.Star));
        RowDefinitions.Add(new RowDefinition(GridLength.Star));
        if (quad)
        {
            ColumnDefinitions.Add(new ColumnDefinition(new GridLength(SplitterSize)));
            ColumnDefinitions.Add(new ColumnDefinition(GridLength.Star));
            RowDefinitions.Add(new RowDefinition(new GridLength(SplitterSize)));
            RowDefinitions.Add(new RowDefinition(GridLength.Star));
        }
        SetColumn(_first, 0);
        SetRow(_first, 0);
        if (!Children.Contains(_first))
        {
            Children.Add(_first);
        }
        if (!quad)
        {
            return;
        }
        foreach (var viewport in _shell.SceneLayoutViews.Skip(1))
        {
            var view = new ViewportView(_shell, viewport);
            SetColumn(view, viewport.Index % 2 * 2);
            SetRow(view, viewport.Index / 2 * 2);
            Children.Add(view);
        }
        var across = new GridSplitter { ResizeDirection = GridResizeDirection.Columns };
        SetColumn(across, 1);
        SetRowSpan(across, RowDefinitions.Count);
        Children.Add(across);
        var down = new GridSplitter { ResizeDirection = GridResizeDirection.Rows };
        SetRow(down, 1);
        SetColumnSpan(down, ColumnDefinitions.Count);
        Children.Add(down);
    }
}
