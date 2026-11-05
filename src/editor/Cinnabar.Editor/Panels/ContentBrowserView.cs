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
using AssetTemplate = Cinnabar.Editor.Link.Cook.AssetTemplate;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// The content browser (see docs/editor/shell-and-panels.md#content-browser): the content roots' folders on the left, as a virtualized
/// list of the visible rows, the selected folder's assets in the middle, or every asset that a search matches, and the
/// selected asset's details on the right. Everything comes from the cook daemon's index. A double click opens a scene in
/// the editor and a script in the script editor, and a script that defines a behaviour drags onto an entity. The menus,
/// the keys and dragging onto a folder do the asset operations, which the daemon does.
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
    readonly TextBlock _location = new() { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0), TextTrimming = TextTrimming.CharacterEllipsis };
    readonly TextBlock _status = new() { Classes = { "dim" }, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0) };
    readonly Border _general = new() { Classes = { "problems" }, Margin = new Thickness(4, 0, 4, 4) };
    readonly ListBox _folders = new() { Classes = { "outliner" } };
    readonly ListBox _assets = new() { Classes = { "outliner" }, SelectionMode = SelectionMode.Multiple };
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
    // The first selected asset's details show.
    string? Selected => _model.Selection.Count > 0 ? _model.Selection[0] : null;
    bool _rebuildPosted;
    bool _syncing;
    PointerPressedEventArgs? _press;
    Asset? _pressed;

    public ContentBrowserView(EditorShell shell)
    {
        _shell = shell;
        _index = shell.Assets;
        _model = shell.Content.Model;

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
        _assets.ContextMenu = FolderMenu(null);
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
                _model.Open(new ContentFolder(row.Root, row.Path));
            }
        };
        _assets.SelectionChanged += (_, _) =>
        {
            if (!_syncing)
            {
                _model.Select(_assets.SelectedItems?.OfType<Asset>().Select(a => a.Guid) ?? []);
            }
        };
        KeyDown += OnKeyDown;
        _search.TextChanged += (_, _) =>
        {
            if (!_syncing)
            {
                _model.Search = _search.Text ?? "";
            }
        };

        new ViewSubscriptions(this, attached: Rebuild)
            .Add(() => _model.Changed += PostRebuild, () => _model.Changed -= PostRebuild)
            .Add(() => _model.ContextChanged += ShowDetails, () => _model.ContextChanged -= ShowDetails)
            .Add(() => _model.Revealed += OnRevealed, () => _model.Revealed -= OnRevealed)
            .Add(() => _shell.Cook.StateChanged += ShowStatus, () => _shell.Cook.StateChanged -= ShowStatus)
            .Add(() => _shell.Cook.Cooked += OnCooked, () => _shell.Cook.Cooked -= OnCooked)
            .Add(() => _shell.Cook.ProgressChanged += ShowStatus, () => _shell.Cook.ProgressChanged -= ShowStatus);
    }

    // F2, Ctrl+D and Delete act on the selected assets while the browser has focus, and not while a box has it.
    void OnKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Source is TextBox)
        {
            return;
        }
        var command = (e.Key, e.KeyModifiers) switch
        {
            (Key.F2, KeyModifiers.None) => EditorCommands.RenameAsset,
            (Key.D, KeyModifiers.Control) => EditorCommands.DuplicateAsset,
            (Key.Delete, KeyModifiers.None) => EditorCommands.DeleteAsset,
            _ => null,
        };
        if (command != null && _model.Selection.Count > 0)
        {
            _shell.Commands.Get(command).Execute();
            e.Handled = true;
        }
    }

    void OnRevealed(Asset asset)
    {
        Rebuild();
        _assets.ScrollIntoView(asset);
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
        ShowAssets();
        ShowStatus();
        ShowGeneralProblems();
        // A view of an index that the daemon no longer keeps up to date.
        Opacity = _index.Linked ? 1 : 0.6;
    }

    void ShowFolders()
    {
        var rows = _model.FolderRows();
        _syncing = true;
        _folders.ItemsSource = rows;
        _folders.SelectedItem = rows.FirstOrDefault(r => _model.Folder is { } f && r.Root == f.Root && r.Path == f.Path);
        _syncing = false;
    }

    void ShowAssets()
    {
        var assets = _model.Items;
        var query = _model.Search.Trim();
        if (_model.Searching)
        {
            _location.Text = $"{assets.Count} {(assets.Count == 1 ? "asset matches" : "assets match")} \"{query}\"";
        }
        else if (_model.Folder is { } folder)
        {
            _location.Text = folder.Path == "" ? folder.Root : $"{folder.Root} › {folder.Path.Replace("/", " › ")}";
        }
        else
        {
            _location.Text = "";
        }
        _empty.Text = _index.Roots.Count == 0
            ? "The content roots appear here once the cook daemon runs."
            : query.Length > 0 ? "No asset matches the search." : "This folder has no assets.";
        _empty.IsVisible = assets.Count == 0;
        _syncing = true;
        if ((_search.Text ?? "") != _model.Search)
        {
            _search.Text = _model.Search;
        }
        _assets.ItemsSource = assets;
        // The list keeps what it had selected across a new list where it can, which may be an asset that is no
        // longer selected, so its selection is rebuilt from the model's, not added to.
        _assets.SelectedItems?.Clear();
        foreach (var asset in assets.Where(a => _model.Selection.Contains(a.Guid)))
        {
            _assets.SelectedItems?.Add(asset);
        }
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

    // A kind's name in messages, which is also its icon's.
    static string KindNoun(AssetKind kind) => kind switch
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
        _general.Child = new StackPanel { Children = { Problems(problems) } };
    }

    void ShowDetails()
    {
        _details.Children.Clear();
        if (Selected is not { } guid || _index.Find(guid) is not { } asset)
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
        foreach (var info in _index.SettingsOf(asset.Kind))
        {
            Row(FieldValues.Humanize(info.Key), SettingEditor(asset, info));
        }
        // Settings that the importer does not know, which it warns of.
        var unknown = asset.Settings.Where(s => !_index.SettingsOf(asset.Kind).Any(i => i.Key == s.Key)).ToList();
        if (unknown.Count > 0)
        {
            Row("Settings", new SelectableTextBlock { Text = string.Join(", ", unknown.Select(s => $"{s.Key} = {s.Value}")) });
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

    // An import setting's editor: a check box for a setting of true or false, and a list of its values otherwise. A
    // change goes to the daemon, which writes the .meta file and cooks the asset again.
    Control SettingEditor(Asset asset, Link.Cook.SettingInfo info)
    {
        var value = asset.Settings.FirstOrDefault(s => s.Key == info.Key)?.Value ?? info.Default;
        Control editor;
        if (info.Values is ["true", "false"] or ["false", "true"])
        {
            var check = new CheckBox { IsChecked = value == "true", Padding = new Thickness(4, 0), MinHeight = 0 };
            check.IsCheckedChanged += (_, _) => _ = SetSetting(asset.Guid, info.Key, check.IsChecked == true ? "true" : "false");
            editor = check;
        }
        else
        {
            var list = new ComboBox { ItemsSource = info.Values, SelectedItem = value, MinHeight = 0 };
            list.SelectionChanged += (_, _) =>
            {
                if (list.SelectedItem is string chosen && chosen != value)
                {
                    _ = SetSetting(asset.Guid, info.Key, chosen);
                }
            };
            editor = list;
        }
        editor.IsEnabled = _shell.Content.CanChangeContent;
        ToolTip.SetTip(editor, info.Description);
        return editor;
    }

    async Task SetSetting(string guid, string key, string value)
    {
        if (!await _shell.Content.SetImportSetting(guid, key, value))
        {
            // The editor shows the asset's settings as they are.
            ShowDetails();
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
                _shell.Content.RevealAsset(asset.Guid);
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
                Foreground = p.Error ? Palette.ErrorBrush : Palette.WarningBrush,
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

    // The menu of a folder, or of the asset list for the open folder: new assets, and for a folder that is not a root,
    // rename and delete.
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

    Control AssetView(Asset asset)
    {
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        var searching = _model.Searching;
        var subasset = AssetIndex.IsSubasset(asset);
        // A file with sub-assets expands in place to show them, indented under it. Search lists them as they are.
        var hasSubassets = !subasset && _index.SubassetsOf(asset.Guid).Any();
        var expander = new TextBlock
        {
            Text = hasSubassets && !searching ? (_model.IsFileExpanded(asset.Guid) ? "▾" : "▸") : "",
            Width = 12,
            Margin = new Thickness(subasset && !searching ? 18 : 0, 0, 0, 0),
            Classes = { "dim" },
            Cursor = hasSubassets ? new Cursor(StandardCursorType.Hand) : Cursor.Default,
        };
        if (hasSubassets && !searching)
        {
            expander.PointerPressed += (_, e) =>
            {
                _model.ToggleFile(asset.Guid);
                e.Handled = true;
            };
        }
        line.Children.Add(expander);
        if (CommandViews.Icon(KindNoun(asset.Kind).Replace(' ', '-'), 14) is { } icon)
        {
            line.Children.Add(icon);
        }
        line.Children.Add(new TextBlock { Text = AssetIndex.DisplayName(asset) });
        if (asset.Behaviour != "")
        {
            line.Children.Add(new Border { Classes = { "badge", "script" }, Margin = new Thickness(0), Child = new TextBlock { Text = FieldValues.Humanize(asset.Behaviour) } });
        }
        if (searching)
        {
            var where = subasset ? asset.Path : AssetIndex.Parent(asset.Path);
            line.Children.Add(new TextBlock { Text = $"{asset.Root}/{where}", Classes = { "dim" } });
        }
        if (asset.Errors > 0 || asset.Status == AssetStatus.Failed)
        {
            line.Children.Add(new TextBlock { Text = asset.Errors > 0 ? $"✖ {asset.Errors}" : "✖ failed", Foreground = Palette.ErrorBrush });
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
            if (!Gestures.MovedPastAcrossAndDown(moved))
            {
                return;
            }
            _press = null;
            // A drag of a selected asset takes the selection, with that asset first.
            var guids = _model.Selection.Contains(asset.Guid) ? [asset.Guid, .. _model.Selection.Where(g => g != asset.Guid)] : new List<string> { asset.Guid };
            var data = new DataTransfer();
            data.Add(DataTransferItem.Create(AssetFormat, string.Join(' ', guids)));
            await DragDrop.DoDragDropAsync(press, data, DragDropEffects.Copy | DragDropEffects.Link | DragDropEffects.Move);
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
        // A right click on an asset that is not selected selects it alone, so the operations act on what the menu is for.
        menu.Opening += (_, _) =>
        {
            if (!_model.Selection.Contains(asset.Guid))
            {
                _assets.SelectedItem = _assets.ItemsSource?.OfType<Asset>().FirstOrDefault(a => a.Guid == asset.Guid);
            }
        };
        if (EditorShell.CanOpen(asset))
        {
            menu.Items.Add(new MenuItem { Header = _shell.OpenLabel(asset), Command = new RelayCommand(() => _shell.OpenAsset(asset)) });
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
