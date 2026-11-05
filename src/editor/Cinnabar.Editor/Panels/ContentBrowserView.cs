using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
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
using AssetTemplate = Cinnabar.Editor.Link.Cook.AssetTemplate;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// The content browser (see docs/editor/shell-and-panels.md#content-browser): the content roots' folders on the left, as a virtualized
/// list of the visible rows, the assets in the middle, as tiles or a list, and the selected asset's details on the right.
/// Everything comes from the cook daemon's index, and what shows is the shell's <see cref="ContentBrowserModel"/>, as a view
/// lasts only until docking rebuilds it. The menus, the keys and dragging onto a folder do the asset operations, which the
/// daemon does.
/// </summary>
public sealed class ContentBrowserView : DockPanel
{
    /// <summary>Dragged assets, by their GUIDs, separated by spaces.</summary>
    public static readonly DataFormat<string> AssetFormat = DataFormat.CreateStringApplicationFormat("cinnabar-asset");

    const double Indent = 14;

    readonly EditorShell _shell;
    readonly AssetIndex _index;
    readonly ContentBrowserModel _model;
    readonly TextBox _search = new() { PlaceholderText = "Search by name, or kind:script, kind:scene", Width = 260, Classes = { "outliner-filter" } };
    readonly StackPanel _location = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0), Spacing = 4 };
    readonly TextBlock _status = new() { Classes = { "dim" }, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0) };
    readonly Border _general = new() { Classes = { "problems" }, Margin = new Thickness(4, 0, 4, 4) };
    readonly ContentFilterBar _filter;
    readonly ListBox _folders = new() { Classes = { "outliner" } };
    readonly ListBox _tags = new() { Classes = { "outliner" } };
    readonly TextBlock _noTags = new()
    {
        Text = "Tag an asset in its details to see its tags here. A / nests them, as env/stone.",
        Classes = { "empty" },
        TextWrapping = TextWrapping.Wrap,
        TextAlignment = TextAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        Margin = new Thickness(12),
        IsHitTestVisible = false,
    };
    readonly ToggleButton _showFolders = new() { Content = "Folders", Classes = { "kind-chip" } };
    readonly ToggleButton _showTags = new() { Content = "Tags", Classes = { "kind-chip" } };
    readonly ContentGridView _grid;
    readonly ContentDetailsView _details;
    readonly TextBlock _empty = new()
    {
        Classes = { "empty" },
        TextWrapping = TextWrapping.Wrap,
        TextAlignment = TextAlignment.Center,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        Margin = new Thickness(16),
        IsHitTestVisible = false,
    };
    bool _rebuildPosted;
    bool _syncing;

    public ContentBrowserView(EditorShell shell)
    {
        _shell = shell;
        _index = shell.Assets;
        _model = shell.Content.Model;
        _filter = new ContentFilterBar(_model);
        _grid = new ContentGridView(shell, AssetMenu);
        _details = new ContentDetailsView(shell);

        var bar = new DockPanel { Margin = new Thickness(0, 0, 0, 2) };
        SetDock(_search, DockSide.Right);
        SetDock(_status, DockSide.Right);
        bar.Children.Add(_search);
        bar.Children.Add(_status);
        bar.Children.Add(_location);
        SetDock(bar, DockSide.Top);
        Children.Add(bar);
        SetDock(_filter, DockSide.Top);
        Children.Add(_filter);
        SetDock(_general, DockSide.Top);
        Children.Add(_general);

        // The panel docks at the bottom by default, where it is wide and short, so the details are a column.
        var details = new DockPanel();
        SetDock(_details.DraftBar, DockSide.Top);
        details.Children.Add(_details.DraftBar);
        details.Children.Add(new ScrollViewer { Content = _details, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled });
        var assets = new Panel { Children = { _grid, _empty } };
        _grid.BlankMenu = FolderMenu(null);
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("220,4,*,4,320") };
        Grid.SetColumn(assets, 2);
        Grid.SetColumn(details, 4);
        var left = new DockPanel();
        var pane = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(4, 0), Children = { _showFolders, _showTags } };
        SetDock(pane, DockSide.Top);
        left.Children.Add(pane);
        left.Children.Add(new Panel { Children = { _folders, _tags, _noTags } });
        _showFolders.Click += (_, _) => _model.ShowingTags = false;
        _showTags.Click += (_, _) => _model.ShowingTags = true;
        grid.Children.Add(left);
        grid.Children.Add(Splitter(1));
        grid.Children.Add(assets);
        grid.Children.Add(Splitter(3));
        grid.Children.Add(details);
        Children.Add(grid);

        _folders.ItemTemplate = new FuncDataTemplate<FolderRow>((row, _) => row == null ? new Control() : FolderView(row));
        _tags.ItemTemplate = new FuncDataTemplate<TagRow>((row, _) => row == null ? new Control() : TagView(row));
        _folders.SelectionChanged += (_, _) =>
        {
            if (!_syncing && _folders.SelectedItem is FolderRow row)
            {
                _model.Open(new ContentFolder(row.Root, row.Path));
            }
        };
        BrowserKey(Key.F2, KeyModifiers.None, () => RunOnSelection(EditorCommands.RenameAsset));
        BrowserKey(Key.D, KeyModifiers.Control, () => RunOnSelection(EditorCommands.DuplicateAsset));
        BrowserKey(Key.Delete, KeyModifiers.None, () => RunOnSelection(EditorCommands.DeleteAsset));
        BrowserKey(Key.A, KeyModifiers.Control, _model.SelectAll);
        _search.TextChanged += (_, _) =>
        {
            if (!_syncing)
            {
                _model.Search = _search.Text ?? "";
            }
        };

        new ViewSubscriptions(this, attached: Rebuild)
            .Add(() => _model.Changed += PostRebuild, () => _model.Changed -= PostRebuild)
            .Add(() => _model.ContextChanged += OnContextChanged, () => _model.ContextChanged -= OnContextChanged)
            .Add(() => _model.Revealed += OnRevealed, () => _model.Revealed -= OnRevealed)
            .Add(() => _shell.Content.Draft.Changed += _details.Show, () => _shell.Content.Draft.Changed -= _details.Show)
            .Add(() => _shell.Cook.StateChanged += ShowStatus, () => _shell.Cook.StateChanged -= ShowStatus)
            .Add(() => _shell.Cook.Cooked += OnCooked, () => _shell.Cook.Cooked -= OnCooked)
            .Add(() => _shell.Cook.ProgressChanged += ShowStatus, () => _shell.Cook.ProgressChanged -= ShowStatus);
    }

    // A key that means one thing here and another on the entities, which comes first while the browser has the focus, as
    // it is nearer than the window's. It does nothing for lack of a selection, not the entities' command, and leaves a
    // text box its keys.
    void BrowserKey(Key key, KeyModifiers modifiers, Action run) =>
        KeyBindings.Add(new KeyBinding
        {
            Gesture = new KeyGesture(key, modifiers),
            Command = new RelayCommand(run, () => TopLevel.GetTopLevel(this)?.FocusManager?.GetFocusedElement() is not TextBox),
        });

    void RunOnSelection(string id)
    {
        var command = _shell.Commands.Get(id);
        if (_model.Selection.Count > 0 && command.CanExecute)
        {
            command.Execute();
        }
    }

    void OnContextChanged()
    {
        _grid.ShowSelection();
        _details.Show();
    }

    void OnRevealed(Asset asset)
    {
        Rebuild();
        _grid.ScrollTo(asset);
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
        ShowFolders();
        ShowTags();
        ShowLocation();
        ShowAssets();
        _filter.Show();
        ShowStatus();
        ShowGeneralProblems();
        // A view of an index that the daemon no longer keeps up to date.
        Opacity = _index.Linked ? 1 : 0.6;
    }

    void ShowTags()
    {
        var rows = _model.TagRows();
        var showing = _model.ShowingTags;
        _showFolders.IsChecked = !showing;
        _showTags.IsChecked = showing;
        _folders.IsVisible = !showing;
        _tags.IsVisible = showing && rows.Count > 0;
        _noTags.IsVisible = showing && rows.Count == 0;
        _syncing = true;
        _tags.ItemsSource = rows;
        _tags.SelectedItem = null;
        _syncing = false;
    }

    // A tag's row: a click filters by it, an asset dropped on it gets it, and its menu renames or deletes it.
    Control TagView(TagRow row)
    {
        var expander = new TextBlock
        {
            Text = row.HasChildren ? (row.Expanded ? "\u25be" : "\u25b8") : "",
            Width = 14,
            Classes = { "dim" },
            Cursor = row.HasChildren ? new Cursor(StandardCursorType.Hand) : Cursor.Default,
        };
        if (row.HasChildren)
        {
            expander.PointerPressed += (_, e) =>
            {
                _model.ToggleTagExpanded(row.Tag);
                e.Handled = true;
            };
        }
        var name = new TextBlock { Text = row.Name };
        if (row.Filtering)
        {
            name.FontWeight = FontWeight.Bold;
            name.Foreground = new SolidColorBrush(Palette.Accent);
        }
        var view = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 4,
            Margin = new Thickness(row.Depth * Indent, 0, 0, 0),
            Background = Brushes.Transparent,
            Children =
            {
                expander,
                name,
                new TextBlock { Text = row.Count.ToString(), Classes = { "dim" } },
            },
        };
        ToolTip.SetTip(view, row.Tag);
        view.PointerPressed += (_, e) =>
        {
            if (e.GetCurrentPoint(view).Properties.IsLeftButtonPressed)
            {
                _model.ToggleTag(row.Tag);
                e.Handled = true;
            }
        };
        DragDrop.SetAllowDrop(view, true);
        view.AddHandler(DragDrop.DragOverEvent, (_, e) =>
        {
            e.DragEffects = DroppedAll(e) is { Count: > 0 } ? DragDropEffects.Link : DragDropEffects.None;
            e.Handled = true;
        });
        view.AddHandler(DragDrop.DropEvent, (_, e) =>
        {
            if (DroppedAll(e) is { Count: > 0 } guids)
            {
                _shell.Content.Tags.Add(guids, row.Tag);
            }
            e.Handled = true;
        });
        view.ContextMenu = new ContextMenu
        {
            Items =
            {
                new MenuItem { Header = "Rename", Command = new RelayCommand(() => _shell.Content.RequestRenameTag(row.Tag)) },
                new MenuItem { Header = "Delete", Command = new RelayCommand(() => _shell.Content.RequestDeleteTag(row.Tag)) },
            },
        };
        return view;
    }

    void ShowFolders()
    {
        var rows = _model.FolderRows();
        _syncing = true;
        _folders.ItemsSource = rows;
        _folders.SelectedItem = rows.FirstOrDefault(r => _model.Folder is { } f && r.Root == f.Root && r.Path == f.Path);
        _syncing = false;
    }

    // The path over the assets, each part a link, or how many assets a filter leaves.
    void ShowLocation()
    {
        _location.Children.Clear();
        if (_model.Filtering)
        {
            var count = _model.Items.Count;
            var scope = _model.OpenFile != null ? " in this file" : _model.InThisFolder ? " in this folder" : "";
            _location.Children.Add(new TextBlock { Text = $"{count} {(count == 1 ? "asset matches" : "assets match")}{scope}", VerticalAlignment = VerticalAlignment.Center });
            _location.Children.Add(Link("Clear", _model.ClearFilter));
            return;
        }
        var crumbs = _model.Crumbs();
        for (var i = 0; i < crumbs.Count; i++)
        {
            if (i > 0)
            {
                _location.Children.Add(new TextBlock { Text = "›", Classes = { "dim" }, VerticalAlignment = VerticalAlignment.Center });
            }
            var crumb = crumbs[i];
            if (i == crumbs.Count - 1)
            {
                _location.Children.Add(new TextBlock { Text = crumb.Name, VerticalAlignment = VerticalAlignment.Center });
            }
            else if (crumb.Folder is { } folder)
            {
                _location.Children.Add(Link(crumb.Name, () => _model.Open(folder)));
            }
        }
    }

    static TextBlock Link(string text, Action click)
    {
        var link = new TextBlock { Text = text, Classes = { "link" }, Cursor = new Cursor(StandardCursorType.Hand), VerticalAlignment = VerticalAlignment.Center };
        link.PointerPressed += (_, e) =>
        {
            click();
            e.Handled = true;
        };
        return link;
    }

    void ShowAssets()
    {
        var assets = _model.Items;
        _empty.Text = _index.Roots.Count == 0
            ? "The content roots appear here once the cook daemon runs."
            : _model.Filtering ? "No asset matches the filter." : "This folder has no assets.";
        _empty.IsVisible = assets.Count == 0;
        _syncing = true;
        if ((_search.Text ?? "") != _model.Search)
        {
            _search.Text = _model.Search;
        }
        _syncing = false;
        _grid.Show();
        _details.Show();
    }

    void ShowStatus()
    {
        var cook = _shell.Cook;
        var last = cook.LastCook;
        var failed = last is { Failed: > 0 } ? $"{last.Failed} {Plural(last.Failed, "asset")} failed to cook" : "";
        _status.Text = cook.State switch
        {
            // A stage's step is its meshes and textures; another's is the assets of its kind.
            CookState.Linked when cook.Progress is { } progress =>
                $"Cooking {(progress.Name != "" ? progress.Name[(progress.Name.LastIndexOf('/') + 1)..] : KindNoun(progress.Kind) + "s")} {progress.Done}/{progress.Total}",
            CookState.Linked when last is { Cooked.Length: > 0 } =>
                $"Cooked {string.Join(", ", last.Cooked.Select(c => $"{c.Count} {Plural(c.Count, KindNoun(c.Kind))}"))} in {last.Milliseconds:0} ms"
                + (failed == "" ? "" : $", {failed}"),
            CookState.Linked when failed != "" => failed,
            CookState.Linked => "Up to date",
            CookState.Starting => "Starting the cook daemon",
            CookState.Exited => $"The cook daemon exited with code {cook.ExitCode}",
            _ => "The cook daemon is stopped",
        };
    }

    static string Plural(uint count, string noun) => count == 1 ? noun : noun + "s";

    /// <summary>A kind's name in messages, which is also its icon's.</summary>
    internal static string KindNoun(AssetKind kind) => kind switch
    {
        AssetKind.Scene => "scene",
        AssetKind.Shader => "shader",
        AssetKind.Texture => "texture",
        AssetKind.Model => "model",
        AssetKind.Mesh => "mesh",
        AssetKind.ShadingModel => "shading model",
        AssetKind.Material => "material",
        AssetKind.MaterialInstance => "material instance",
        AssetKind.MaterialFunction => "material function",
        AssetKind.Prefab => "prefab",
        AssetKind.Effect => "effect",
        AssetKind.Stage => "stage",
        AssetKind.InstanceSet => "instance set",
        AssetKind.Skin => "skin",
        AssetKind.Animation => "animation",
        AssetKind.AnimationGraph => "animation graph",
        AssetKind.Audio => "audio",
        _ => "script",
    };

    // Problems that belong to no asset, such as a broken definition file, show over the browser.
    void ShowGeneralProblems()
    {
        var problems = _index.ProblemsOf("");
        _general.IsVisible = problems.Count > 0;
        _general.Child = new StackPanel { Children = { ContentDetailsView.Problems(_shell, problems) } };
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
                _model.ToggleFolder(row.Root, row.Path);
                e.Handled = true;
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
            if (row.HasChildren)
            {
                _model.ToggleFolder(row.Root, row.Path);
            }
            e.Handled = true;
        };
        // Assets dragged onto a folder move into it.
        var folder = new ContentFolder(row.Root, row.Path);
        DragDrop.SetAllowDrop(view, true);
        view.AddHandler(DragDrop.DragOverEvent, (_, e) =>
        {
            e.DragEffects = DroppedAll(e) is { Count: > 0 } guids && _shell.Content.CanMoveAssets(guids, folder) ? DragDropEffects.Move : DragDropEffects.None;
            e.Handled = true;
        });
        view.AddHandler(DragDrop.DropEvent, (_, e) =>
        {
            if (DroppedAll(e) is { Count: > 0 } guids && _shell.Content.CanMoveAssets(guids, folder))
            {
                _ = _shell.Content.MoveAssets(guids, folder);
            }
            e.Handled = true;
        });
        view.ContextMenu = FolderMenu(row);
        return view;
    }

    // The menu of a folder, or of the assets' empty space for the open folder: new assets, and for a folder that is not
    // a root, rename and delete.
    ContextMenu FolderMenu(FolderRow? row)
    {
        var menu = new ContextMenu();
        // A folder's menu acts on that folder, so it opens it first.
        void Open()
        {
            if (row != null)
            {
                _model.Open(new ContentFolder(row.Root, row.Path));
            }
        }
        menu.Opening += (_, _) =>
        {
            menu.Items.Clear();
            var linked = _shell.Content.CanChangeContent && (row != null || _model.Folder != null);
            foreach (var (label, template) in new (string, AssetTemplate?)[]
                {
                    ("New Script", AssetTemplate.Script), ("New Behaviour", AssetTemplate.Behaviour), ("New Scene", AssetTemplate.Scene),
                    ("New Material", AssetTemplate.Material), ("New Material Function", AssetTemplate.MaterialFunction), ("New Mesh", AssetTemplate.Mesh),
                    ("New Prefab", AssetTemplate.Prefab), ("New Effect", AssetTemplate.Effect),
                    ("New Animation Graph", AssetTemplate.AnimationGraph),
                    ("New Folder", null),
                })
            {
                menu.Items.Add(new MenuItem
                {
                    Header = label,
                    IsEnabled = linked,
                    Command = new RelayCommand(() =>
                    {
                        Open();
                        _shell.Content.RequestNewAsset(template);
                    }),
                });
            }
            if (row == null)
            {
                return;
            }
            var folder = new ContentFolder(row.Root, row.Path);
            menu.Items.Add(new Separator());
            if (_index.FindRoot(row.Root) is { } root)
            {
                var dir = Path.GetFullPath(Path.Combine(root.Dir, row.Path));
                menu.Items.Add(new MenuItem { Header = "Show in Explorer", Command = new RelayCommand(() => _shell.ShowInExplorer(dir)) });
            }
            if (row.Path != "")
            {
                menu.Items.Add(new MenuItem { Header = "Rename", IsEnabled = _shell.Content.CanChangeContent, Command = new RelayCommand(() => _shell.Content.RequestRename(ContentItem.Of(folder))) });
                menu.Items.Add(new MenuItem { Header = "Delete", IsEnabled = _shell.Content.CanChangeContent, Command = new RelayCommand(() => _shell.Content.RequestDelete([ContentItem.Of(folder)])) });
            }
        };
        // Avalonia shows no menu without items, so it starts with one.
        menu.Items.Add(new MenuItem { Header = "New Script" });
        return menu;
    }

    ContextMenu AssetMenu(Asset asset)
    {
        var path = _index.FullPath(asset);
        var menu = new ContextMenu();
        // A right click on an asset that is not selected selects it alone, so the operations act on what the menu is for.
        menu.Opening += (_, _) =>
        {
            if (!_model.Selection.Contains(asset.Guid))
            {
                _model.Press(asset.Guid, false, false);
            }
        };
        if (EditorShell.CanOpen(asset))
        {
            menu.Items.Add(new MenuItem { Header = _shell.OpenLabel(asset), Command = new RelayCommand(() => _shell.OpenAsset(asset)) });
        }
        if (!AssetIndex.IsSubasset(asset) && _index.SubassetsOf(asset.Guid).Any())
        {
            menu.Items.Add(new MenuItem { Header = "Show Contents", Command = new RelayCommand(() => _model.Enter(asset.Guid)) });
        }
        if (path != null)
        {
            menu.Items.Add(new MenuItem { Header = "Show in Explorer", Command = new RelayCommand(() => _shell.ShowInExplorer(path)) });
        }
        menu.Items.Add(new Separator());
        foreach (var id in new[] { EditorCommands.RenameAsset, EditorCommands.DuplicateAsset, EditorCommands.DeleteAsset, EditorCommands.Reimport })
        {
            var command = _shell.Commands.Get(id);
            var item = new MenuItem { Header = command.Label.Replace(" Asset", ""), Command = new RelayCommand(() => command.Execute()) };
            item.InputGesture = id switch
            {
                EditorCommands.RenameAsset => new KeyGesture(Key.F2),
                EditorCommands.DuplicateAsset => new KeyGesture(Key.D, KeyModifiers.Control),
                EditorCommands.DeleteAsset => new KeyGesture(Key.Delete),
                _ => null,
            };
            menu.Opening += (_, _) => item.IsEnabled = command.CanExecute;
            menu.Items.Add(item);
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

    /// <summary>The GUID of a dragged asset, the first of several, or null.</summary>
    public static string? Dropped(DragEventArgs e) => DroppedAll(e) is [var first, ..] ? first : null;

    /// <summary>The GUIDs of the dragged assets, or null.</summary>
    public static IReadOnlyList<string>? DroppedAll(DragEventArgs e) =>
        e.DataTransfer.TryGetValue(AssetFormat)?.Split(' ', StringSplitOptions.RemoveEmptyEntries);
}
