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

    public ContentDetailsView(EditorShell shell)
    {
        _shell = shell;
        _index = shell.Assets;
        _model = shell.Content.Model;
        Spacing = 2;
        Margin = new Thickness(8, 4);
    }

    public void Show()
    {
        Children.Clear();
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
            Row("Problems", Problems(_shell, problems));
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
            Show();
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
