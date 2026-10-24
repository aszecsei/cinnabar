using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Input;
using Avalonia.Input.Platform;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Cinnabar.Editor.Content;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Ribbon;
using Cinnabar.Editor.Shell;
using CommunityToolkit.Mvvm.Input;
using Asset = Cinnabar.Editor.Link.Cook.Asset;
using AssetKind = Cinnabar.Editor.Link.Cook.AssetKind;
using AssetStatus = Cinnabar.Editor.Link.Cook.AssetStatus;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// The content browser (see docs/editor.md#content-browser): the content roots' folders on the left, as a virtualized
/// list of the visible rows, the selected folder's assets in the middle, or every asset that a search matches, and the
/// selected asset's details on the right. Everything comes from the cook daemon's index. A double click opens a scene in
/// the editor and a script in the script editor, and a script that defines a behaviour drags onto an entity.
/// </summary>
public sealed class ContentBrowserView : DockPanel
{
    /// <summary>A dragged asset, by its GUID.</summary>
    public static readonly DataFormat<string> AssetFormat = DataFormat.CreateStringApplicationFormat("cinnabar-asset");

    const double Indent = 14;
    // A press must move this far, in pixels, before it starts a drag.
    const double DragThreshold = 4;

    readonly EditorShell _shell;
    readonly AssetIndex _index;
    readonly TextBox _search = new() { PlaceholderText = "Search by name, or kind:script, kind:scene", Width = 260, Classes = { "outliner-filter" } };
    readonly TextBlock _location = new() { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0), TextTrimming = TextTrimming.CharacterEllipsis };
    readonly TextBlock _status = new() { Classes = { "dim" }, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0) };
    readonly Border _general = new() { Classes = { "problems" }, Margin = new Thickness(4, 0, 4, 4) };
    readonly ListBox _folders = new() { Classes = { "outliner" } };
    readonly ListBox _assets = new() { Classes = { "outliner" } };
    readonly StackPanel _details = new() { Spacing = 2, Margin = new Thickness(8, 4) };
    readonly TextBlock _empty = new()
    {
        Classes = { "empty" },
        TextWrapping = TextWrapping.Wrap,
        TextAlignment = TextAlignment.Center,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        Margin = new Thickness(16),
    };
    // Roots start expanded, and other folders collapsed. The set holds the expanded ones, as "root/path".
    readonly HashSet<string> _expanded = [];
    readonly HashSet<string> _seenRoots = [];
    (string Root, string Path)? _folder;
    string? _selected;
    bool _rebuildPosted;
    bool _syncing;
    PointerPressedEventArgs? _press;
    Asset? _pressed;

    public ContentBrowserView(EditorShell shell)
    {
        _shell = shell;
        _index = shell.Assets;

        var bar = new DockPanel { Margin = new Thickness(0, 0, 0, 2) };
        SetDock(_search, DockSide.Right);
        SetDock(_status, DockSide.Right);
        bar.Children.Add(_search);
        bar.Children.Add(_status);
        bar.Children.Add(_location);
        SetDock(bar, DockSide.Top);
        Children.Add(bar);
        SetDock(_general, DockSide.Top);
        Children.Add(_general);

        // The panel docks at the bottom by default, where it is wide and short, so the details are a column.
        var details = new ScrollViewer { Content = _details, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
        var assets = new Panel { Children = { _assets, _empty } };
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("220,4,*,4,320") };
        Grid.SetColumn(assets, 2);
        Grid.SetColumn(details, 4);
        grid.Children.Add(_folders);
        grid.Children.Add(Splitter(1));
        grid.Children.Add(assets);
        grid.Children.Add(Splitter(3));
        grid.Children.Add(details);
        Children.Add(grid);

        _folders.ItemTemplate = new FuncDataTemplate<FolderRow>((row, _) => row == null ? new Control() : FolderView(row));
        _assets.ItemTemplate = new FuncDataTemplate<Asset>((asset, _) => asset == null ? new Control() : AssetView(asset));
        _folders.SelectionChanged += (_, _) =>
        {
            if (!_syncing && _folders.SelectedItem is FolderRow row)
            {
                _folder = (row.Root, row.Path);
                _search.Text = "";
                ShowAssets();
            }
        };
        _assets.SelectionChanged += (_, _) =>
        {
            if (!_syncing)
            {
                _selected = (_assets.SelectedItem as Asset)?.Guid;
                ShowDetails();
            }
        };
        _search.TextChanged += (_, _) => ShowAssets();

        AttachedToVisualTree += (_, _) =>
        {
            _index.Changed += PostRebuild;
            _shell.Cook.StateChanged += ShowStatus;
            _shell.Cook.Cooked += OnCooked;
            Rebuild();
        };
        DetachedFromVisualTree += (_, _) =>
        {
            _index.Changed -= PostRebuild;
            _shell.Cook.StateChanged -= ShowStatus;
            _shell.Cook.Cooked -= OnCooked;
        };
    }

    static GridSplitter Splitter(int column)
    {
        var splitter = new GridSplitter { ResizeDirection = GridResizeDirection.Columns, Background = Brushes.Transparent };
        Grid.SetColumn(splitter, column);
        return splitter;
    }

    void OnCooked(Link.Cook.CookFinished finished) => ShowStatus();

    // A cook sends a message for each change, so the view builds once after them.
    void PostRebuild()
    {
        if (_rebuildPosted)
        {
            return;
        }
        _rebuildPosted = true;
        Dispatcher.UIThread.Post(() =>
        {
            _rebuildPosted = false;
            Rebuild();
        }, DispatcherPriority.Background);
    }

    void Rebuild()
    {
        foreach (var root in _index.Roots.Where(r => _seenRoots.Add(r.Name)))
        {
            _expanded.Add(root.Name + "/");
        }
        if (_folder is not { } folder || _index.FindRoot(folder.Root) == null || (folder.Path != "" && !_index.Folders.Contains(new(folder.Root, folder.Path))))
        {
            _folder = _index.Roots.Count > 0 ? (_index.Roots[0].Name, "") : null;
        }
        ShowFolders();
        ShowAssets();
        ShowStatus();
        ShowGeneralProblems();
        // A view of an index that the daemon no longer keeps up to date.
        Opacity = _index.Linked ? 1 : 0.6;
    }

    void ShowFolders()
    {
        var rows = new List<FolderRow>();
        void Add(string root, string path, string name, int depth)
        {
            var children = _index.ChildFolders(root, path).ToList();
            var expanded = _expanded.Contains($"{root}/{path}");
            rows.Add(new FolderRow(root, path, name, depth, children.Count > 0, expanded));
            if (expanded)
            {
                foreach (var child in children)
                {
                    Add(root, path == "" ? child : $"{path}/{child}", child, depth + 1);
                }
            }
        }
        foreach (var root in _index.Roots)
        {
            Add(root.Name, "", root.Name, 0);
        }
        _syncing = true;
        _folders.ItemsSource = rows;
        _folders.SelectedItem = rows.FirstOrDefault(r => _folder is { } f && r.Root == f.Root && r.Path == f.Path);
        _syncing = false;
    }

    void ShowAssets()
    {
        var query = _search.Text?.Trim() ?? "";
        List<Asset> assets;
        if (query.Length > 0)
        {
            assets = [.. _index.Search(query)];
            _location.Text = $"{assets.Count} {(assets.Count == 1 ? "asset matches" : "assets match")} \"{query}\"";
        }
        else if (_folder is { } folder)
        {
            assets = [.. _index.AssetsIn(folder.Root, folder.Path)];
            _location.Text = folder.Path == "" ? folder.Root : $"{folder.Root} › {folder.Path.Replace("/", " › ")}";
        }
        else
        {
            assets = [];
            _location.Text = "";
        }
        _empty.Text = _index.Roots.Count == 0
            ? "The content roots appear here once the cook daemon runs."
            : query.Length > 0 ? "No asset matches the search." : "This folder has no assets.";
        _empty.IsVisible = assets.Count == 0;
        _syncing = true;
        _assets.ItemsSource = assets;
        _assets.SelectedItem = assets.FirstOrDefault(a => a.Guid == _selected);
        _syncing = false;
        ShowDetails();
    }

    void ShowStatus()
    {
        var cook = _shell.Cook;
        var last = cook.LastCook;
        var failed = last is { Failed: > 0 } ? $"{last.Failed} {Plural(last.Failed, "asset")} failed to cook" : "";
        _status.Text = cook.State switch
        {
            CookState.Linked when last is { Scripts: > 0 } or { Scenes: > 0 } =>
                $"Cooked {last.Scripts} {Plural(last.Scripts, "script")} and {last.Scenes} {Plural(last.Scenes, "scene")} in {last.Milliseconds:0} ms"
                + (failed == "" ? "" : $", {failed}"),
            CookState.Linked when failed != "" => failed,
            CookState.Linked => "Up to date",
            CookState.Starting => "Starting the cook daemon",
            CookState.Exited => $"The cook daemon exited with code {cook.ExitCode}",
            _ => "The cook daemon is stopped",
        };
    }

    static string Plural(uint count, string noun) => count == 1 ? noun : noun + "s";

    // Problems that belong to no asset, such as a broken definition file, show over the browser.
    void ShowGeneralProblems()
    {
        var problems = _index.ProblemsOf("");
        _general.IsVisible = problems.Count > 0;
        _general.Child = new StackPanel { Children = { Problems(problems) } };
    }

    void ShowDetails()
    {
        _details.Children.Clear();
        if (_selected is not { } guid || _index.Find(guid) is not { } asset)
        {
            return;
        }
        void Row(string label, Control value)
        {
            var row = new DockPanel();
            var name = new TextBlock { Text = label, Width = 96, Classes = { "dim" } };
            SetDock(name, DockSide.Left);
            row.Children.Add(name);
            row.Children.Add(value);
            _details.Children.Add(row);
        }
        Row("Path", new SelectableTextBlock { Text = $"{asset.Root}/{asset.Path}", TextWrapping = TextWrapping.Wrap });
        Row("GUID", new SelectableTextBlock { Text = asset.Guid, FontFamily = new FontFamily("Consolas"), FontSize = 11 });
        Row("Status", new TextBlock { Text = asset.Status == AssetStatus.Failed ? "Failed: it keeps its last good blob" : "Cooked" });
        if (asset.Behaviour != "")
        {
            Row("Behaviour", new TextBlock { Text = FieldValues.Humanize(asset.Behaviour) });
        }
        if (asset.Settings.Length > 0)
        {
            Row("Settings", new SelectableTextBlock { Text = string.Join(", ", asset.Settings.Select(s => $"{s.Key} = {s.Value}")) });
        }
        if (asset.Dependencies.Length > 0)
        {
            Row("Depends on", Links(asset.Dependencies.Select(_index.Find).OfType<Asset>()));
        }
        if (_index.Dependents(guid).ToList() is { Count: > 0 } dependents)
        {
            Row("Used by", Links(dependents));
        }
        if (_index.ProblemsOf(guid) is { Count: > 0 } problems)
        {
            Row("Problems", Problems(problems));
        }
    }

    // Assets as links that select them in their folders.
    Control Links(IEnumerable<Asset> assets)
    {
        var panel = new WrapPanel();
        foreach (var asset in assets)
        {
            var link = new TextBlock { Text = AssetIndex.Name(asset.Path), Classes = { "link" }, Margin = new Thickness(0, 0, 10, 0), Cursor = new Cursor(StandardCursorType.Hand) };
            ToolTip.SetTip(link, $"{asset.Root}/{asset.Path}");
            link.PointerPressed += (_, e) =>
            {
                Reveal(asset);
                e.Handled = true;
            };
            panel.Children.Add(link);
        }
        return panel;
    }

    // Each problem as its place and text. A click opens its file in the script editor, at its line.
    Control Problems(IReadOnlyList<Link.Cook.Problem> problems)
    {
        var list = new StackPanel();
        foreach (var p in problems)
        {
            var place = p.File == "" ? "" : p.Line > 0 ? $"{Path.GetFileName(p.File)}:{p.Line}: " : $"{Path.GetFileName(p.File)}: ";
            var text = new TextBlock
            {
                Text = place + p.Text,
                Classes = { p.Error ? "error" : "warning" },
                Foreground = p.Error ? Brush.Parse("#F0605A") : Brush.Parse("#E8B04A"),
                TextWrapping = TextWrapping.Wrap,
            };
            if (p.File != "")
            {
                text.Cursor = new Cursor(StandardCursorType.Hand);
                ToolTip.SetTip(text, $"Open {p.File}");
                text.PointerPressed += (_, e) =>
                {
                    _shell.OpenScript(p.File, p.Line);
                    e.Handled = true;
                };
            }
            list.Children.Add(text);
        }
        return list;
    }

    // Selects an asset in its folder, and clears the search.
    void Reveal(Asset asset)
    {
        var folder = AssetIndex.Parent(asset.Path);
        for (var path = folder; path != ""; path = AssetIndex.Parent(path))
        {
            _expanded.Add($"{asset.Root}/{path}");
        }
        _folder = (asset.Root, folder);
        _selected = asset.Guid;
        _search.Text = "";
        ShowFolders();
        ShowAssets();
        _assets.ScrollIntoView(asset);
    }

    Control FolderView(FolderRow row)
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
                var key = $"{row.Root}/{row.Path}";
                if (!_expanded.Remove(key))
                {
                    _expanded.Add(key);
                }
                e.Handled = true;
                ShowFolders();
            };
        }
        var icon = CommandViews.Icon("folder", 14);
        var view = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 4,
            Margin = new Thickness(row.Depth * Indent, 0, 0, 0),
            Background = Brushes.Transparent,
            Children = { expander, new TextBlock { Text = row.Name, FontWeight = row.Depth == 0 ? FontWeight.SemiBold : FontWeight.Normal } },
        };
        if (icon != null)
        {
            view.Children.Insert(1, icon);
        }
        view.DoubleTapped += (_, e) =>
        {
            var key = $"{row.Root}/{row.Path}";
            if (row.HasChildren && !_expanded.Remove(key))
            {
                _expanded.Add(key);
            }
            e.Handled = true;
            ShowFolders();
        };
        return view;
    }

    Control AssetView(Asset asset)
    {
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        if (CommandViews.Icon(asset.Kind == AssetKind.Scene ? "scene" : "script", 14) is { } icon)
        {
            line.Children.Add(icon);
        }
        line.Children.Add(new TextBlock { Text = AssetIndex.Name(asset.Path) });
        if (asset.Behaviour != "")
        {
            line.Children.Add(new Border { Classes = { "badge", "script" }, Margin = new Thickness(0), Child = new TextBlock { Text = FieldValues.Humanize(asset.Behaviour) } });
        }
        if (!string.IsNullOrEmpty(_search.Text?.Trim()))
        {
            line.Children.Add(new TextBlock { Text = $"{asset.Root}/{AssetIndex.Parent(asset.Path)}", Classes = { "dim" } });
        }
        if (asset.Errors > 0 || asset.Status == AssetStatus.Failed)
        {
            line.Children.Add(new TextBlock { Text = asset.Errors > 0 ? $"✖ {asset.Errors}" : "✖ failed", Foreground = Brush.Parse("#F0605A") });
        }
        if (asset.Warnings > 0)
        {
            line.Children.Add(new TextBlock { Text = $"⚠ {asset.Warnings}", Classes = { "warning" } });
        }
        if (_index.ProblemsOf(asset.Guid) is { Count: > 0 } problems)
        {
            ToolTip.SetTip(line, string.Join("\n", problems.Select(p => p.Line > 0 ? $"{p.Line}: {p.Text}" : p.Text)));
        }
        var view = new Border { Background = Brushes.Transparent, Child = line };
        view.PointerPressed += (_, e) =>
        {
            if (e.GetCurrentPoint(view).Properties.IsLeftButtonPressed)
            {
                _press = e;
                _pressed = asset;
            }
        };
        view.PointerMoved += async (_, e) =>
        {
            if (_press is not { } press || _pressed != asset)
            {
                return;
            }
            var moved = e.GetPosition(view) - press.GetPosition(view);
            if (Math.Abs(moved.X) + Math.Abs(moved.Y) < DragThreshold)
            {
                return;
            }
            _press = null;
            var data = new DataTransfer();
            data.Add(DataTransferItem.Create(AssetFormat, asset.Guid));
            await DragDrop.DoDragDropAsync(press, data, DragDropEffects.Link);
        };
        view.PointerReleased += (_, _) => _press = null;
        view.DoubleTapped += (_, e) =>
        {
            _press = null;
            _shell.OpenAsset(asset);
            e.Handled = true;
        };
        view.ContextMenu = AssetMenu(asset);
        return view;
    }

    ContextMenu AssetMenu(Asset asset)
    {
        var path = _index.FullPath(asset);
        var menu = new ContextMenu();
        menu.Items.Add(new MenuItem { Header = asset.Kind == AssetKind.Scene ? "Open Scene" : "Open in Script Editor", Command = new RelayCommand(() => _shell.OpenAsset(asset)) });
        if (path != null)
        {
            menu.Items.Add(new MenuItem { Header = "Show in Explorer", Command = new RelayCommand(() => _shell.ShowInExplorer(path)) });
        }
        menu.Items.Add(new Separator());
        menu.Items.Add(new MenuItem { Header = "Copy GUID", Command = new RelayCommand(() => Copy(asset.Guid)) });
        if (path != null)
        {
            menu.Items.Add(new MenuItem { Header = "Copy Path", Command = new RelayCommand(() => Copy(path)) });
        }
        return menu;
    }

    void Copy(string text)
    {
        if (TopLevel.GetTopLevel(this)?.Clipboard is { } clipboard)
        {
            _ = clipboard.SetTextAsync(text);
        }
    }

    /// <summary>The GUID of a dragged asset, or null.</summary>
    public static string? Dropped(DragEventArgs e) => e.DataTransfer.TryGetValue(AssetFormat);
}

public sealed record FolderRow(string Root, string Path, string Name, int Depth, bool HasChildren, bool Expanded);
