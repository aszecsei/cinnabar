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
sealed record TileRow(ContentTile[] Items);

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
    IReadOnlyList<ContentTile> _shown = [];
    ContentGridLayout _layout;
    bool _layoutSet;
    // The press that may start a drag, the asset it is on, and whether its release selects that asset alone: a press on
    // a selected asset may be a drag of the whole selection.
    PointerPressedEventArgs? _press;
    ContentTile? _pressed;
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
        var items = _model.Tiles;
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
    public void ScrollTo(string key)
    {
        var index = _shown.ToList().FindIndex(t => t.Key == key);
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
        foreach (var tile in row.Items)
        {
            line.Children.Add(_model.ViewMode == ContentViewMode.List ? ListRow(tile) : Tile(tile));
        }
        return line;
    }

    Border Tile(ContentTile item)
    {
        var size = _model.TileSize;
        var picture = new Panel { Width = size, Height = size, HorizontalAlignment = HorizontalAlignment.Center };
        if (CommandViews.Icon(KindIcon(item), Math.Round(size * 0.45)) is { } icon)
        {
            icon.HorizontalAlignment = HorizontalAlignment.Center;
            icon.VerticalAlignment = VerticalAlignment.Center;
            icon.Opacity = 0.7;
            picture.Children.Add(icon);
        }
        if (ThumbnailPath(item) is { } thumbnail)
        {
            ShowThumbnail(picture, thumbnail);
        }
        if (item.Asset is { } asset && Marks(asset) is { } marks)
        {
            marks.HorizontalAlignment = HorizontalAlignment.Left;
            marks.VerticalAlignment = VerticalAlignment.Top;
            picture.Children.Add(marks);
        }
        if (HasContents(item))
        {
            picture.Children.Add(EnterButton(item));
        }
        var label = new TextBlock
        {
            Text = AssetIndex.Name(item.Name),
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 2,
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextAlignment = TextAlignment.Center,
            Height = ContentGridLayout.LabelHeight,
            FontSize = 11,
        };
        var content = new StackPanel { Children = { picture, label } };
        return Wire(new Border { Classes = { "asset-tile" }, Width = _layout.TileWidth, Height = _layout.RowHeight - ContentGridLayout.Gap, Padding = new Thickness(ContentGridLayout.Gap, ContentGridLayout.Gap, ContentGridLayout.Gap, 0), Child = content }, item);
    }

    Border ListRow(ContentTile item)
    {
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(6, 2) };
        var arrow = new TextBlock { Text = HasContents(item) ? "\u25b8" : "", Width = 12, Classes = { "dim" }, Cursor = HasContents(item) ? new Cursor(StandardCursorType.Hand) : Cursor.Default };
        if (HasContents(item))
        {
            arrow.PointerPressed += (_, e) =>
            {
                Enter(item);
                e.Handled = true;
            };
        }
        line.Children.Add(arrow);
        if (CommandViews.Icon(KindIcon(item), 14) is { } icon)
        {
            line.Children.Add(icon);
        }
        line.Children.Add(new TextBlock { Text = item.Name });
        if (item.Asset is { } asset)
        {
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
        }
        return Wire(new Border { Classes = { "asset-row" }, Width = _layout.TileWidth, Height = _layout.RowHeight, Child = line }, item);
    }

    // The picture of a tile: an asset's own, or for a file with none, such as a stage or a model, what it makes: its
    // prefab, or its first mesh.
    string? ThumbnailPath(ContentTile item)
    {
        if (item.Asset is not { } asset)
        {
            return null;
        }
        if (asset.ThumbnailReady)
        {
            return asset.Thumbnail;
        }
        if (AssetIndex.IsSubasset(asset) || asset.Thumbnail != "")
        {
            return null;
        }
        var made = _index.SubassetsOf(asset.Guid).ToList();
        return (made.Find(a => a.Kind == Link.Cook.AssetKind.Prefab && a.ThumbnailReady) ?? made.Find(a => a.Kind == Link.Cook.AssetKind.Mesh && a.ThumbnailReady))?.Thumbnail;
    }

    // Shows a thumbnail over a tile's icon once it is decoded, for as long as the tile is realized, which is what keeps it
    // in the cache. The icon shows until then, and instead when it cannot be read.
    static void ShowThumbnail(Panel picture, string path)
    {
        var image = new Image { Stretch = Stretch.Uniform, IsHitTestVisible = false };
        Avalonia.Media.RenderOptions.SetBitmapInterpolationMode(image, Avalonia.Media.Imaging.BitmapInterpolationMode.HighQuality);
        picture.Children.Add(image);
        var attached = false;
        image.AttachedToVisualTree += async (_, _) =>
        {
            attached = true;
            var bitmap = await ThumbnailCache.Shared.Acquire(path);
            if (!attached)
            {
                ThumbnailCache.Shared.Release(path);
            }
            else if (bitmap != null)
            {
                image.Source = bitmap;
                if (picture.Children.Count > 0 && picture.Children[0] is PathIcon icon)
                {
                    icon.IsVisible = false;
                }
            }
            else
            {
                ThumbnailCache.Shared.Release(path);
            }
        };
        image.DetachedFromVisualTree += (_, _) =>
        {
            attached = false;
            if (image.Source != null)
            {
                image.Source = null;
                ThumbnailCache.Shared.Release(path);
            }
        };
    }

    void Enter(ContentTile item)
    {
        if (item.Part is { } part)
        {
            _model.EnterNode(part.Id);
        }
        else if (item.Asset is { } asset)
        {
            _model.Enter(asset.Guid);
        }
    }

    Control EnterButton(ContentTile item)
    {
        var button = new Border
        {
            Classes = { "tile-enter" },
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Child = new TextBlock { Text = "›", FontSize = 14, Margin = new Thickness(6, -2, 6, 0) },
            Cursor = new Cursor(StandardCursorType.Hand),
        };
        ToolTip.SetTip(button, item.Part != null || item.Asset?.Kind == Link.Cook.AssetKind.Prefab ? "Show what is in it, to take a part of it" : "Show what this file makes");
        button.PointerPressed += (_, e) =>
        {
            Enter(item);
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
    Border Wire(Border view, ContentTile item)
    {
        var key = item.Key;
        if (item.Asset is { } shown)
        {
            var problems = _index.ProblemsOf(shown.Guid);
            var tip = $"{shown.Root}/{shown.Path}" + (AssetIndex.IsSubasset(shown) ? $"\n{shown.Subasset}" : "");
            ToolTip.SetTip(view, problems.Count == 0 ? tip : tip + "\n" + string.Join("\n", problems.Select(p => p.Line > 0 ? $"{p.Line}: {p.Text}" : p.Text)));
        }
        else
        {
            ToolTip.SetTip(view, $"{item.Name}\nDrag it into the scene to take this part of the prefab. Alt makes plain entities of it.");
        }
        view.Classes.Set("selected", _model.Selection.Contains(key));
        view.AttachedToVisualTree += (_, _) => _tiles[key] = view;
        view.DetachedFromVisualTree += (_, _) =>
        {
            if (_tiles.GetValueOrDefault(key) == view)
            {
                _tiles.Remove(key);
            }
        };
        view.PointerPressed += (_, e) => OnTilePressed(view, item, e);
        view.PointerMoved += async (_, e) =>
        {
            if (_press is not { } press || _pressed != item)
            {
                return;
            }
            if (!Gestures.MovedPastAcrossAndDown(e.GetPosition(view) - press.GetPosition(view)))
            {
                return;
            }
            _press = null;
            _selectOnRelease = false;
            // A drag of a selected tile takes the selection, with that tile first. Assets and parts go to different places,
            // so a part's drag holds only parts, and an asset's only assets.
            var isPart = item.Part != null;
            var keys = (_model.Selection.Contains(key) ? [key, .. _model.Selection.Where(g => g != key)] : new List<string> { key })
                .Where(k => k.Contains(':') == isPart);
            var data = new DataTransfer();
            data.Add(DataTransferItem.Create(isPart ? ContentBrowserView.PartFormat : ContentBrowserView.AssetFormat, string.Join(' ', keys)));
            await DragDrop.DoDragDropAsync(press, data, DragDropEffects.Copy | DragDropEffects.Link | DragDropEffects.Move);
        };
        view.PointerReleased += (_, e) =>
        {
            if (_selectOnRelease && _pressed == item)
            {
                _model.Press(key, false, false);
            }
            _selectOnRelease = false;
            _press = null;
        };
        view.DoubleTapped += (_, e) =>
        {
            _press = null;
            Activate(item);
            e.Handled = true;
        };
        view.ContextMenu = item.Asset is { } menuAsset ? _menu(menuAsset) : PartMenu(item);
        return view;
    }

    ContextMenu? PartMenu(ContentTile item)
    {
        if (!HasContents(item))
        {
            return null;
        }
        return new ContextMenu { Items = { new MenuItem { Header = "Show Contents", Command = new CommunityToolkit.Mvvm.Input.RelayCommand(() => Enter(item)) } } };
    }

    void OnTilePressed(Border view, ContentTile item, PointerPressedEventArgs e)
    {
        Focus();
        if (!e.GetCurrentPoint(view).Properties.IsLeftButtonPressed)
        {
            return;
        }
        var add = e.KeyModifiers.HasFlag(KeyModifiers.Control);
        var range = e.KeyModifiers.HasFlag(KeyModifiers.Shift);
        _selectOnRelease = !add && !range && _model.Selection.Contains(item.Key) && _model.Selection.Count > 1;
        if (!_selectOnRelease)
        {
            _model.Press(item.Key, add, range);
        }
        _press = e;
        _pressed = item;
        e.Handled = true;
    }

    // A double click, or Enter, on a tile: a part shows what is under it, a file with no editor what it makes, and others
    // open. A generated prefab has no text worth opening, so it shows what is in it too.
    void Activate(ContentTile item)
    {
        if (item.Part != null)
        {
            if (HasContents(item))
            {
                Enter(item);
            }
        }
        else if (item.Asset is { } asset)
        {
            if (HasContents(item) && (!EditorShell.CanOpen(asset) || (asset.Kind == Link.Cook.AssetKind.Prefab && asset.Generated != "")))
            {
                _model.Enter(asset.Guid);
            }
            else
            {
                _shell.OpenAsset(asset);
            }
        }
    }

    bool HasContents(ContentTile item) => item.Part is { } part
        ? part.ChildCount > 0
        : item.Asset is { } asset && (asset.Kind == Link.Cook.AssetKind.Prefab || (!AssetIndex.IsSubasset(asset) && _index.SubassetsOf(asset.Guid).Any()));

    static string KindIcon(ContentTile item) => item.Part is { } part
        ? part.HasMesh ? "mesh" : "prefab"
        : ContentBrowserView.KindNoun(item.Asset!.Kind).Replace(' ', '-');

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
        var inside = _layout.InRect(start.X, start.Y, end.X, end.Y, _shown.Count).Select(i => _shown[i].Key);
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
                ScrollTo(moved.Key);
            }
            e.Handled = true;
        }
        else if (e.Key == Key.Enter && _model.Selection.Count > 0 && _shown.FirstOrDefault(t => t.Key == _model.Selection[0]) is { } selected)
        {
            Activate(selected);
            e.Handled = true;
        }
        else if (e.Key == Key.Back && (_model.OpenFile != null || _model.OpenPrefab != null))
        {
            _model.Leave();
            e.Handled = true;
        }
    }
}
