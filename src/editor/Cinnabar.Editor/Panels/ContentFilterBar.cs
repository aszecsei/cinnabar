using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Cinnabar.Editor.Content;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// What narrows and shapes the content browser's assets: a chip for each kind that the filter's other parts leave, with
/// its count, whether a filter stays in the open folder, the grid or the list, and the tiles' size.
/// </summary>
sealed class ContentFilterBar : DockPanel
{
    readonly ContentBrowserModel _model;
    readonly WrapPanel _kinds = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
    readonly CheckBox _inFolder = new() { Content = "In this folder", MinHeight = 0, Padding = new Thickness(4, 0), Margin = new Thickness(8, 0), VerticalAlignment = VerticalAlignment.Center };
    readonly ToggleButton _grid = new() { Content = "Grid", Classes = { "kind-chip" } };
    readonly ToggleButton _list = new() { Content = "List", Classes = { "kind-chip" } };
    readonly Slider _size = new()
    {
        Minimum = ContentBrowserModel.MinTileSize,
        Maximum = ContentBrowserModel.MaxTileSize,
        Width = 90,
        // The slider's height would make the row taller than its chips.
        Margin = new Thickness(8, -6),
        VerticalAlignment = VerticalAlignment.Center,
        Classes = { "value-slider" },
    };
    bool _syncing;

    public ContentFilterBar(ContentBrowserModel model)
    {
        _model = model;
        Margin = new Thickness(4, 0, 4, 2);
        ToolTip.SetTip(_inFolder, "Look only in the open folder and the folders under it, not in every folder.");
        ToolTip.SetTip(_size, "The size of the tiles.");
        var view = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, Children = { _inFolder, _size, _grid, _list } };
        SetDock(view, Avalonia.Controls.Dock.Right);
        Children.Add(view);
        Children.Add(_kinds);
        _inFolder.IsCheckedChanged += (_, _) =>
        {
            if (!_syncing)
            {
                _model.InThisFolder = _inFolder.IsChecked == true;
            }
        };
        _grid.Click += (_, _) => _model.ViewMode = ContentViewMode.Grid;
        _list.Click += (_, _) => _model.ViewMode = ContentViewMode.List;
        _size.ValueChanged += (_, _) =>
        {
            if (!_syncing)
            {
                _model.TileSize = _size.Value;
            }
        };
    }

    public void Show()
    {
        _syncing = true;
        _kinds.Children.Clear();
        foreach (var (kind, count) in _model.KindCounts())
        {
            var chip = new ToggleButton { Content = $"{kind} {count}", IsChecked = _model.Kinds.Contains(kind), Classes = { "kind-chip" } };
            chip.Click += (_, _) => _model.ToggleKind(kind);
            _kinds.Children.Add(chip);
        }
        // A kind that the filter turned on and that nothing has now stays visible, or it could not be turned off.
        foreach (var kind in _model.Kinds.Except(_model.KindCounts().Select(k => k.Kind)))
        {
            var chip = new ToggleButton { Content = $"{kind} 0", IsChecked = true, Classes = { "kind-chip" } };
            chip.Click += (_, _) => _model.ToggleKind(kind);
            _kinds.Children.Add(chip);
        }
        _inFolder.IsVisible = _model.Filtering && _model.OpenFile == null;
        _inFolder.IsChecked = _model.InThisFolder;
        _grid.IsChecked = _model.ViewMode == ContentViewMode.Grid;
        _list.IsChecked = _model.ViewMode == ContentViewMode.List;
        _size.IsVisible = _model.ViewMode == ContentViewMode.Grid;
        _size.Value = _model.TileSize;
        _syncing = false;
    }
}
