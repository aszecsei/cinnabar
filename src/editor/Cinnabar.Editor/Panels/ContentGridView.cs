using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Cinnabar.Editor.Content;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Ribbon;
using Cinnabar.Editor.Shell;
using Asset = Cinnabar.Editor.Link.Cook.Asset;
using AssetStatus = Cinnabar.Editor.Link.Cook.AssetStatus;

namespace Cinnabar.Editor.Panels;

/// <summary>A row of the content browser's assets, which the view realizes only while it shows.</summary>
sealed record TileRow(Asset[] Items);

/// <summary>
/// The content browser's assets (see docs/editor/shell-and-panels.md#content-browser), as tiles or as a list: a virtualized
/// stack of rows of equal height, as Avalonia has no virtualizing wrap panel. The selection is the model's, and
/// <see cref="ContentGridLayout"/> knows where each asset is, so the keys and the marquee do not depend on what is realized.
/// </summary>
sealed class ContentGridView : Panel
{
    // How close to an edge a marquee scrolls, and how far on each tick of its timer.
    const double MarqueeEdge = 24;
    const double MarqueeSpeed = 12;

    readonly EditorShell _shell;
    readonly ContentBrowserModel _model;
    readonly AssetIndex _index;
    readonly Func<Asset, ContextMenu> _menu;
    readonly ScrollViewer _scroll;
    readonly ItemsControl _rows = new();
    readonly Canvas _overlay = new() { IsHitTestVisible = false };
    readonly Border _band = new() { Classes = { "marquee" }, IsVisible = false };
    readonly DispatcherTimer _marqueeTimer = new() { Interval = TimeSpan.FromMilliseconds(30) };
    // The realized tiles, so a new selection needs no new rows.
    readonly Dictionary<string, Border> _tiles = [];
    IReadOnlyList<Asset> _shown = [];
    ContentGridLayout _layout;
    bool _layoutSet;
    // The press that may start a drag, the asset it is on, and whether its release selects that asset alone: a press on
    // a selected asset may be a drag of the whole selection.
    PointerPressedEventArgs? _press;
    Asset? _pressed;
    bool _selectOnRelease;
    // The marquee: its start in the rows' space, the pointer in this panel's, and what it adds to.
    Point? _marqueeStart;
    Point _marqueePointer;
    List<string> _marqueeBase = [];

    public ContentGridView(EditorShell shell, Func<Asset, ContextMenu> menu)
    {
        _shell = shell;
        _model = shell.Content.Model;
        _index = shell.Assets;
        _menu = menu;
        Focusable = true;
        _rows.ItemsPanel = new FuncTemplate<Panel?>(() => new VirtualizingStackPanel());
        _rows.ItemTemplate = new FuncDataTemplate<TileRow>((row, _) => row == null ? new Control() : RowView(row));
        _scroll = new ScrollViewer
        {
            Content = _rows,
            HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled,
            // The wheel and a click in the empty space need something to hit.
            Background = Brushes.Transparent,
        };
        _overlay.Children.Add(_band);
        Children.Add(_scroll);
        Children.Add(_overlay);
        _scroll.SizeChanged += (_, _) => Show();
        _scroll.AddHandler(PointerPressedEvent, OnBlankPressed);
        _scroll.AddHandler(PointerMovedEvent, OnBlankMoved);
        _scroll.AddHandler(PointerReleasedEvent, OnBlankReleased);
        _marqueeTimer.Tick += (_, _) => MarqueeTick();
        KeyDown += OnKeyDown;
    }

    /// <summary>The menu of the empty space, for the open folder.</summary>
    public ContextMenu? BlankMenu
    {
        get => _scroll.ContextMenu;
        set => _scroll.ContextMenu = value;
    }

    /// <summary>Shows the model's assets, building new rows only when they or their shape changed.</summary>
    public void Show()
    {
        var items = _model.Items;
        var width = _scroll.Bounds.Width;
        var layout = ContentGridLayout.Of(width, _model.ViewMode, _model.TileSize);
        if (_layoutSet && layout == _layout && items.SequenceEqual(_shown))
        {
            ShowSelection();
            return;
        }
        _layout = layout;
        _layoutSet = true;
        _shown = items;
        _tiles.Clear();
        List<TileRow> rows = [];
        for (var i = 0; i < items.Count; i += layout.Columns)
        {
            rows.Add(new TileRow([.. items.Skip(i).Take(layout.Columns)]));
        }
        _rows.ItemsSource = rows;
    }

    /// <summary>Marks the realized tiles of the selected assets.</summary>
    public void ShowSelection()
    {
        foreach (var (guid, tile) in _tiles)
        {
            tile.Classes.Set("selected", _model.Selection.Contains(guid));
        }
    }

    /// <summary>Scrolls so that an asset shows.</summary>
    public void ScrollTo(Asset asset)
    {
        var index = _shown.ToList().FindIndex(a => a.Guid == asset.Guid);
        if (index >= 0)
        {
            ScrollToRow(_layout.RowOf(index));
        }
    }

    void ScrollToRow(int row)
    {
        var top = _layout.Top(row);
        var bottom = top + _layout.RowHeight;
        var offset = _scroll.Offset.Y;
        var height = _scroll.Viewport.Height;
        var moved = top < offset ? top : bottom > offset + height ? bottom - height : offset;
        if (moved != offset)
        {
            _scroll.Offset = new Vector(0, moved);
        }
    }

    Control RowView(TileRow row)
    {
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = ContentGridLayout.Gap, Height = _layout.RowHeight };
        foreach (var asset in row.Items)
        {
            line.Children.Add(_model.ViewMode == ContentViewMode.List ? ListRow(asset) : Tile(asset));
        }
        return line;
    }

    Border Tile(Asset asset)
    {
        var size = _model.TileSize;
        var picture = new Panel { Width = size, Height = size, HorizontalAlignment = HorizontalAlignment.Center };
        if (CommandViews.Icon(KindIcon(asset), Math.Round(size * 0.45)) is { } icon)
        {
            icon.HorizontalAlignment = HorizontalAlignment.Center;
            icon.VerticalAlignment = VerticalAlignment.Center;
            icon.Opacity = 0.7;
            picture.Children.Add(icon);
        }
        if (Marks(asset) is { } marks)
        {
            marks.HorizontalAlignment = HorizontalAlignment.Left;
            marks.VerticalAlignment = VerticalAlignment.Top;
            picture.Children.Add(marks);
        }
        if (HasContents(asset))
        {
            picture.Children.Add(EnterButton(asset));
        }
        var label = new TextBlock
        {
            Text = TileName(asset),
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 2,
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextAlignment = TextAlignment.Center,
            Height = ContentGridLayout.LabelHeight,
            FontSize = 11,
        };
        var content = new StackPanel { Children = { picture, label } };
        return Wire(new Border { Classes = { "asset-tile" }, Width = _layout.TileWidth, Height = _layout.RowHeight - ContentGridLayout.Gap, Padding = new Thickness(ContentGridLayout.Gap, ContentGridLayout.Gap, ContentGridLayout.Gap, 0), Child = content }, asset);
    }

    Border ListRow(Asset asset)
    {
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(6, 2) };
        var arrow = new TextBlock { Text = HasContents(asset) ? "▸" : "", Width = 12, Classes = { "dim" }, Cursor = HasContents(asset) ? new Cursor(StandardCursorType.Hand) : Cursor.Default };
        if (HasContents(asset))
        {
            arrow.PointerPressed += (_, e) =>
            {
                _model.Enter(asset.Guid);
                e.Handled = true;
            };
        }
        line.Children.Add(arrow);
        if (CommandViews.Icon(KindIcon(asset), 14) is { } icon)
        {
            line.Children.Add(icon);
        }
        line.Children.Add(new TextBlock { Text = AssetIndex.DisplayName(asset) });
        if (asset.Behaviour != "")
        {
            line.Children.Add(new Border { Classes = { "badge", "script" }, Margin = new Thickness(0), Child = new TextBlock { Text = FieldValues.Humanize(asset.Behaviour) } });
        }
        if (_model.Filtering)
        {
            var where = AssetIndex.IsSubasset(asset) ? asset.Path : AssetIndex.Parent(asset.Path);
            line.Children.Add(new TextBlock { Text = $"{asset.Root}/{where}", Classes = { "dim" } });
        }
        if (Marks(asset) is { } marks)
        {
            line.Children.Add(marks);
        }
        return Wire(new Border { Classes = { "asset-row" }, Width = _layout.TileWidth, Height = _layout.RowHeight, Child = line }, asset);
    }

    Control EnterButton(Asset asset)
    {
        var button = new Border
        {
            Classes = { "tile-enter" },
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Child = new TextBlock { Text = "›", FontSize = 14, Margin = new Thickness(6, -2, 6, 0) },
            Cursor = new Cursor(StandardCursorType.Hand),
        };
        ToolTip.SetTip(button, "Show what this file makes");
        button.PointerPressed += (_, e) =>
        {
            _model.Enter(asset.Guid);
            e.Handled = true;
        };
        return button;
    }

    // An asset's marks when it failed or has problems.
    Control? Marks(Asset asset)
    {
        if (asset.Errors == 0 && asset.Warnings == 0 && asset.Status != AssetStatus.Failed)
        {
            return null;
        }
        var marks = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        if (asset.Errors > 0 || asset.Status == AssetStatus.Failed)
        {
            marks.Children.Add(new TextBlock { Text = asset.Errors > 0 ? $"✖ {asset.Errors}" : "✖ failed", Foreground = Palette.ErrorBrush });
        }
        if (asset.Warnings > 0)
        {
            marks.Children.Add(new TextBlock { Text = $"⚠ {asset.Warnings}", Classes = { "warning" } });
        }
        return marks;
    }

    // Selecting, dragging, opening and the menu are the same for a tile and a row.
    Border Wire(Border view, Asset asset)
    {
        var problems = _index.ProblemsOf(asset.Guid);
        var tip = $"{asset.Root}/{asset.Path}" + (AssetIndex.IsSubasset(asset) ? $"\n{asset.Subasset}" : "");
        ToolTip.SetTip(view, problems.Count == 0 ? tip : tip + "\n" + string.Join("\n", problems.Select(p => p.Line > 0 ? $"{p.Line}: {p.Text}" : p.Text)));
        view.Background = Brushes.Transparent;
        view.Classes.Set("selected", _model.Selection.Contains(asset.Guid));
        view.AttachedToVisualTree += (_, _) => _tiles[asset.Guid] = view;
        view.DetachedFromVisualTree += (_, _) =>
        {
            if (_tiles.GetValueOrDefault(asset.Guid) == view)
            {
                _tiles.Remove(asset.Guid);
            }
        };
        view.PointerPressed += (_, e) => OnTilePressed(view, asset, e);
        view.PointerMoved += async (_, e) =>
        {
            if (_press is not { } press || _pressed != asset)
            {
                return;
            }
            if (!Gestures.MovedPastAcrossAndDown(e.GetPosition(view) - press.GetPosition(view)))
            {
                return;
            }
            _press = null;
            _selectOnRelease = false;
            // A drag of a selected asset takes the selection, with that asset first.
            var guids = _model.Selection.Contains(asset.Guid) ? [asset.Guid, .. _model.Selection.Where(g => g != asset.Guid)] : new List<string> { asset.Guid };
            var data = new DataTransfer();
            data.Add(DataTransferItem.Create(ContentBrowserView.AssetFormat, string.Join(' ', guids)));
            await DragDrop.DoDragDropAsync(press, data, DragDropEffects.Copy | DragDropEffects.Link | DragDropEffects.Move);
        };
        view.PointerReleased += (_, e) =>
        {
            if (_selectOnRelease && _pressed == asset)
            {
                _model.Press(asset.Guid, false, false);
            }
            _selectOnRelease = false;
            _press = null;
        };
        view.DoubleTapped += (_, e) =>
        {
            _press = null;
            Activate(asset);
            e.Handled = true;
        };
        view.ContextMenu = _menu(asset);
        return view;
    }

    void OnTilePressed(Border view, Asset asset, PointerPressedEventArgs e)
    {
        Focus();
        if (!e.GetCurrentPoint(view).Properties.IsLeftButtonPressed)
        {
            return;
        }
        var add = e.KeyModifiers.HasFlag(KeyModifiers.Control);
        var range = e.KeyModifiers.HasFlag(KeyModifiers.Shift);
        _selectOnRelease = !add && !range && _model.Selection.Contains(asset.Guid) && _model.Selection.Count > 1;
        if (!_selectOnRelease)
        {
            _model.Press(asset.Guid, add, range);
        }
        _press = e;
        _pressed = asset;
        e.Handled = true;
    }

    // A double click, or Enter, on an asset: a file with no editor shows what it makes, and others open.
    void Activate(Asset asset)
    {
        if (HasContents(asset) && !EditorShell.CanOpen(asset))
        {
            _model.Enter(asset.Guid);
        }
        else
        {
            _shell.OpenAsset(asset);
        }
    }

    bool HasContents(Asset asset) => !AssetIndex.IsSubasset(asset) && _index.SubassetsOf(asset.Guid).Any();

    // A sub-asset's name is its path in its file, of which the last part tells it apart in a tile.
    static string TileName(Asset asset) => AssetIndex.Name(AssetIndex.DisplayName(asset));

    static string KindIcon(Asset asset) => ContentBrowserView.KindNoun(asset.Kind).Replace(' ', '-');

    void OnBlankPressed(object? sender, PointerPressedEventArgs e)
    {
        Focus();
        if (!e.GetCurrentPoint(_scroll).Properties.IsLeftButtonPressed)
        {
            return;
        }
        _marqueeStart = e.GetPosition(_rows);
        _marqueePointer = e.GetPosition(this);
        _marqueeBase = e.KeyModifiers.HasFlag(KeyModifiers.Control) ? [.. _model.Selection] : [];
        e.Pointer.Capture(_scroll);
    }

    void OnBlankMoved(object? sender, PointerEventArgs e)
    {
        if (_marqueeStart != null)
        {
            _marqueePointer = e.GetPosition(this);
            _band.IsVisible = true;
            _marqueeTimer.Start();
            ShowMarquee();
        }
    }

    void OnBlankReleased(object? sender, PointerReleasedEventArgs e)
    {
        if (_marqueeStart == null)
        {
            return;
        }
        // A click in the empty space, with no marquee, ends the selection.
        if (!_band.IsVisible && _marqueeBase.Count == 0)
        {
            _model.Select([]);
        }
        _marqueeStart = null;
        _band.IsVisible = false;
        _marqueeTimer.Stop();
        e.Pointer.Capture(null);
    }

    void MarqueeTick()
    {
        if (_marqueeStart == null)
        {
            _marqueeTimer.Stop();
            return;
        }
        var y = _marqueePointer.Y;
        var by = y < MarqueeEdge ? -MarqueeSpeed : y > Bounds.Height - MarqueeEdge ? MarqueeSpeed : 0;
        if (by != 0)
        {
            var max = Math.Max(_scroll.Extent.Height - _scroll.Viewport.Height, 0);
            _scroll.Offset = new Vector(0, Math.Clamp(_scroll.Offset.Y + by, 0, max));
            ShowMarquee();
        }
    }

    void ShowMarquee()
    {
        if (_marqueeStart is not { } start)
        {
            return;
        }
        // The start stays with the rows as they scroll, and the pointer stays with the panel.
        var offset = _scroll.Offset;
        var end = new Point(_marqueePointer.X, _marqueePointer.Y + offset.Y);
        var (left, right) = (Math.Min(start.X, end.X), Math.Max(start.X, end.X));
        var (top, bottom) = (Math.Min(start.Y, end.Y), Math.Max(start.Y, end.Y));
        Canvas.SetLeft(_band, left);
        Canvas.SetTop(_band, top - offset.Y);
        _band.Width = right - left;
        _band.Height = bottom - top;
        var inside = _layout.InRect(start.X, start.Y, end.X, end.Y, _shown.Count).Select(i => _shown[i].Guid);
        _model.Select(_marqueeBase.Concat(inside).Distinct());
    }

    void OnKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Source is TextBox)
        {
            return;
        }
        var range = e.KeyModifiers.HasFlag(KeyModifiers.Shift);
        var page = Math.Max((int)(_scroll.Viewport.Height / Math.Max(_layout.RowHeight, 1)), 1) * _layout.Columns;
        int? by = e.Key switch
        {
            Key.Left => -1,
            Key.Right => 1,
            Key.Up => -_layout.Columns,
            Key.Down => _layout.Columns,
            Key.PageUp => -page,
            Key.PageDown => page,
            Key.Home => -_shown.Count,
            Key.End => _shown.Count,
            _ => null,
        };
        if (by is { } step)
        {
            if (_model.Move(step, range) is { } moved)
            {
                ScrollTo(moved);
            }
            e.Handled = true;
        }
        else if (e.Key == Key.Enter && _model.Selection.Count > 0 && _index.Find(_model.Selection[0]) is { } asset)
        {
            Activate(asset);
            e.Handled = true;
        }
        else if (e.Key == Key.Back && _model.OpenFile != null)
        {
            _model.Leave();
            e.Handled = true;
        }
    }
}
