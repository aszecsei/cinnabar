using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Cinnabar.Editor.Content;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Shell;
using Asset = Cinnabar.Editor.Link.Cook.Asset;
using AssetStatus = Cinnabar.Editor.Link.Cook.AssetStatus;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.Panels;

/// <summary>The details of the asset that was selected first: where it is, its import settings, what it depends on and what uses it, and its problems.</summary>
sealed class ContentDetailsView : StackPanel
{
    readonly EditorShell _shell;
    readonly AssetIndex _index;
    readonly ContentBrowserModel _model;
    readonly Button _apply;

    public ContentDetailsView(EditorShell shell)
    {
        _shell = shell;
        _index = shell.Assets;
        _model = shell.Content.Model;
        Spacing = 2;
        Margin = new Thickness(8, 4);
        var apply = new Button { Content = "Apply" };
        var revert = new Button { Content = "Revert" };
        ToolTip.SetTip(apply, "Write the .meta files and cook the assets again.");
        apply.Click += (_, _) => _ = _shell.Content.ApplyDraft();
        revert.Click += (_, _) => _shell.Content.Draft.Revert();
        _apply = apply;
        DraftBar = new StackPanel
        {
            Orientation = Avalonia.Layout.Orientation.Horizontal,
            Spacing = 4,
            Margin = new Thickness(8, 4, 8, 0),
            IsVisible = false,
            Children = { apply, revert },
        };
    }

    /// <summary>Apply and Revert, which stay in sight over the settings while the draft has changes.</summary>
    public Control DraftBar { get; }

    public void Show()
    {
        Children.Clear();
        DraftBar.IsVisible = _shell.Content.Draft.Dirty;
        _apply.IsEnabled = _shell.Content.CanChangeContent;
        if (_model.Selection.Count > 0 && ContentBrowserModel.ParsePartKey(_model.Selection[0]) is var (prefab, id))
        {
            ShowPart(prefab, id);
            return;
        }
        if (_model.Selection.Count == 0 || _index.Find(_model.Selection[0]) is not { } asset)
        {
            return;
        }
        var guid = asset.Guid;
        void Row(string label, Control value)
        {
            var row = new DockPanel();
            var name = new TextBlock { Text = label, Width = 96, Classes = { "dim" } };
            DockPanel.SetDock(name, DockSide.Left);
            row.Children.Add(name);
            row.Children.Add(value);
            Children.Add(row);
        }
        Row("Path", new SelectableTextBlock { Text = $"{asset.Root}/{asset.Path}", TextWrapping = TextWrapping.Wrap });
        Row("GUID", new SelectableTextBlock { Text = asset.Guid, FontFamily = new FontFamily("Consolas"), FontSize = 11 });
        Row("Status", new TextBlock { Text = asset.Status == AssetStatus.Failed ? "Failed: it keeps its last good blob" : "Cooked" });
        if (asset.Behaviour != "")
        {
            Row("Behaviour", new TextBlock { Text = FieldValues.Humanize(asset.Behaviour) });
        }
        Row("Tags", TagsEditor());
        ShowSettings(asset, Row);
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
            Row("Problems", Problems(_shell, problems));
        }
    }

    // A part of a prefab: what it is in, and what it draws, as links, which is how to reach its mesh and its materials.
    void ShowPart(string prefab, ulong id)
    {
        if (_shell.PrefabTreeOf(prefab) is not { } tree || tree.Find(id) is not { } node)
        {
            return;
        }
        void Row(string label, Control value)
        {
            var row = new DockPanel();
            var name = new TextBlock { Text = label, Width = 96, Classes = { "dim" } };
            DockPanel.SetDock(name, DockSide.Left);
            row.Children.Add(name);
            row.Children.Add(value);
            Children.Add(row);
        }
        Row("Part", new SelectableTextBlock { Text = node.Name, TextWrapping = TextWrapping.Wrap });
        Row("Of", Links(new[] { prefab }.Select(_index.Find).OfType<Asset>()));
        Row("ID", new SelectableTextBlock { Text = $"{node.Id:x16}", FontFamily = new FontFamily("Consolas"), FontSize = 11 });
        Row("Under it", new TextBlock { Text = tree.Nodes.Count(n => IsUnder(tree, n, id)).ToString() });
        if (node.Mesh != "")
        {
            Row("Mesh", Links(new[] { node.Mesh }.Select(_index.Find).OfType<Asset>()));
        }
        if (node.Materials.Count > 0)
        {
            Row("Materials", Links(node.Materials.Select(_index.Find).OfType<Asset>()));
        }
    }

    static bool IsUnder(Document.PrefabTree tree, Document.PrefabNode node, ulong above)
    {
        for (var n = node; n.Parent != 0 && tree.Find(n.Parent) is { } parent; n = parent)
        {
            if (parent.Id == above)
            {
                return true;
            }
        }
        return false;
    }

    // The selected assets' tags as chips: dim when only some have the tag, which a click gives to all, with a cross that
    // takes it from all. A box adds a tag, offering those that exist.
    Control TagsEditor()
    {
        var tags = _shell.Content.Tags;
        var selection = _model.Selection.ToList();
        var panel = new WrapPanel();
        foreach (var tag in selection.SelectMany(tags.Of).Distinct().Order(StringComparer.OrdinalIgnoreCase))
        {
            var everyOne = selection.All(g => tags.Of(g).Contains(tag));
            var name = new TextBlock { Text = tag, Opacity = everyOne ? 1 : 0.55, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center };
            var cross = new TextBlock { Text = " \u00d7", Cursor = new Cursor(StandardCursorType.Hand), VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center };
            ToolTip.SetTip(cross, $"Take {tag} from the selected assets");
            cross.PointerPressed += (_, e) =>
            {
                tags.Remove(selection, tag);
                e.Handled = true;
            };
            if (!everyOne)
            {
                ToolTip.SetTip(name, $"Only some of the selected assets have {tag}. A click gives it to all of them.");
                name.Cursor = new Cursor(StandardCursorType.Hand);
                name.PointerPressed += (_, e) =>
                {
                    tags.Add(selection, tag);
                    e.Handled = true;
                };
            }
            panel.Children.Add(new Border { Classes = { "badge", "tag" }, Child = new StackPanel { Orientation = Avalonia.Layout.Orientation.Horizontal, Children = { name, cross } } });
        }
        var box = new AutoCompleteBox
        {
            PlaceholderText = "Add a tag, as env/stone",
            ItemsSource = tags.All(),
            FilterMode = AutoCompleteFilterMode.ContainsOrdinal,
            MinimumPrefixLength = 1,
            MinWidth = 160,
        };
        box.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter && !string.IsNullOrWhiteSpace(box.Text))
            {
                if (ProjectTags.Normalize(box.Text) is { } tag)
                {
                    tags.Add(selection, tag);
                }
                else
                {
                    ToolTip.SetTip(box, "A tag can have letters, digits, _ and -, with / between its parts.");
                    ToolTip.SetIsOpen(box, true);
                }
                e.Handled = true;
            }
        };
        return new StackPanel { Spacing = 2, Children = { panel, box } };
    }

    // A sub-asset's settings are its file's, so it links there. The selected files' settings are the draft's.
    void ShowSettings(Asset asset, Action<string, Control> row)
    {
        var draft = _shell.Content.Draft;
        if (AssetIndex.IsSubasset(asset) && _index.Find(asset.Parent) is { } file)
        {
            var note = new WrapPanel();
            note.Children.Add(new TextBlock { Text = "On ", Classes = { "dim" } });
            note.Children.Add(Links([file]));
            row("Settings", note);
        }
        var rows = draft.Rows();
        if (rows.Count > 0 && draft.Assets.Count > 1)
        {
            row("Settings", new TextBlock { Text = $"Of the {draft.Assets.Count} selected files", Classes = { "dim" } });
        }
        foreach (var setting in rows)
        {
            row(setting.Changed ? "\u2022 " + FieldValues.Humanize(setting.Info.Key) : FieldValues.Humanize(setting.Info.Key), SettingEditor(setting));
        }
    }

    // An import setting's editor: a check box for a setting of true or false, and a list of its values otherwise, each
    // showing no value while the files differ. A change goes to the draft.
    Control SettingEditor(ImportSettingRow setting)
    {
        var info = setting.Info;
        var draft = _shell.Content.Draft;
        Control editor;
        if (info.Values is ["true", "false"] or ["false", "true"])
        {
            var check = new CheckBox { IsChecked = setting.Value == null ? null : setting.Value == "true", Padding = new Thickness(4, 0), MinHeight = 0 };
            check.Click += (_, _) => draft.Set(info.Key, check.IsChecked == true ? "true" : "false");
            editor = check;
        }
        else
        {
            var list = new ComboBox { ItemsSource = info.Values, SelectedItem = setting.Value, MinHeight = 0, PlaceholderText = "\u2014" };
            list.SelectionChanged += (_, _) =>
            {
                if (list.SelectedItem is string chosen && chosen != setting.Value)
                {
                    draft.Set(info.Key, chosen);
                }
            };
            editor = list;
        }
        editor.IsEnabled = _shell.Content.CanChangeContent;
        ToolTip.SetTip(editor, info.Description);
        return editor;
    }

    // Assets as links that select them in their folders.
    Control Links(IEnumerable<Asset> assets)
    {
        var panel = new WrapPanel();
        foreach (var asset in assets)
        {
            var link = new TextBlock { Text = AssetIndex.Name(AssetIndex.DisplayName(asset)), Classes = { "link" }, Margin = new Thickness(0, 0, 10, 0), Cursor = new Cursor(StandardCursorType.Hand) };
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

    /// <summary>Each problem as its place and text. A click opens its file in the script editor, at its line.</summary>
    public static Control Problems(EditorShell shell, IReadOnlyList<Link.Cook.Problem> problems)
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
                    shell.OpenScript(p.File, p.Line);
                    e.Handled = true;
                };
            }
            list.Children.Add(text);
        }
        return list;
    }
}
