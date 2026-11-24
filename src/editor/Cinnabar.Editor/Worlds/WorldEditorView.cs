using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Content;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Ribbon;
using Cinnabar.Editor.Shell;
using static Cinnabar.Editor.Panels.Kit;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.Worlds;

/// <summary>
/// The World editor (see docs/editor/world-view.md#the-world-editor): a table of the world's scenes in the file's order,
/// each with its bounds and distances and its state in Play, with its problems, and the preview bar. Docking can rebuild
/// the view at any time, so its state is in its <see cref="WorldEditor"/> and the shell.
/// </summary>
public sealed class WorldEditorView : DockPanel
{
    const string Columns = "200,Auto,180,180,70,70,70,Auto";

    readonly EditorShell _shell;
    readonly WorldEditor _editor;
    readonly StackPanel _preview = new() { Orientation = Orientation.Horizontal, Spacing = 4, Margin = new Thickness(8, 4) };
    readonly StackPanel _rows = new() { Margin = new Thickness(8), Spacing = 4, HorizontalAlignment = HorizontalAlignment.Left };
    readonly TextBlock _status = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
    string _shown = "";
    string _shownPreview = "";

    public WorldEditorView(EditorShell shell, WorldEditor editor)
    {
        _shell = shell;
        _editor = editor;
        var toolbar = new DockPanel { Margin = new Thickness(8, 4) };
        var save = new Button { Content = CommandViews.Icon("save", 16), Classes = { "viewport-tool" }, Focusable = false, Margin = new Thickness(0, 0, 8, 0) };
        ToolTip.SetTip(save, "Save (Ctrl+S)");
        save.Click += (_, _) => shell.SaveGraph(editor);
        DockPanel.SetDock(save, DockSide.Left);
        toolbar.Children.Add(save);
        var text = SmallButton("Open in Script Editor", "Edit the world's text. Save first: this editor does not read the file again.", () => shell.OpenScript(editor.Document.Path));
        DockPanel.SetDock(text, DockSide.Left);
        toolbar.Children.Add(text);
        DockPanel.SetDock(_status, DockSide.Right);
        toolbar.Children.Add(_status);
        toolbar.Children.Add(new Panel());
        var top = new StackPanel { Children = { toolbar, _preview } };
        var border = new Border { Child = top, BorderBrush = new SolidColorBrush(Color.Parse("#333337")), BorderThickness = new Thickness(0, 0, 0, 1) };
        SetDock(border, DockSide.Top);
        Children.Add(border);
        Children.Add(new ScrollViewer { Content = _rows, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto });

        new ViewSubscriptions(this, attached: Refresh)
            .Add(() => _editor.Changed += Refresh, () => _editor.Changed -= Refresh)
            .Add(() => _editor.ProblemsChanged += Refresh, () => _editor.ProblemsChanged -= Refresh)
            .Add(() => _shell.Cook.StateChanged += Refresh, () => _shell.Cook.StateChanged -= Refresh)
            .Add(() => _shell.WorldStateChanged += Refresh, () => _shell.WorldStateChanged -= Refresh)
            .Add(() => _shell.SceneChanged += Refresh, () => _shell.SceneChanged -= Refresh)
            .Add(() => _shell.ModeChanged += Refresh, () => _shell.ModeChanged -= Refresh);
    }

    void Refresh()
    {
        var state = _editor.Checks.State;
        CookStatus.Show(_status, state, CookStatus.Describe(state, _editor.Problems.Count(p => p.Error), _shell.Cook.Linked),
            _editor.Document.IsDirty ? "not saved" : null);
        RefreshPreview();
        var scenes = _editor.Scenes;
        var shown = string.Join("|", scenes.Select(s => $"{s.Guid} {s.Persistent} {WorldFile.Format(s.Min ?? [])} {WorldFile.Format(s.Max ?? [])} {s.LoadDistance} {s.UnloadDistance} {_editor.PlayState(s)}"))
            + "#" + string.Join("|", _editor.Problems.Select(p => p.Line + p.Text));
        if (shown == _shown)
        {
            return;
        }
        _shown = shown;
        _rows.Children.Clear();
        var header = new Grid { ColumnDefinitions = new ColumnDefinitions(Columns), ColumnSpacing = 6 };
        string[] names = ["Scene", "Persistent", "Min", "Max", "Load", "Unload", "Play"];
        for (var i = 0; i < names.Length; i++)
        {
            var heading = Heading(names[i]);
            Grid.SetColumn(heading, i);
            header.Children.Add(heading);
        }
        _rows.Children.Add(header);
        if (scenes.Count == 0)
        {
            _rows.Children.Add(Dim("The world has no scenes. Add one: the game streams them in and out as the camera moves."));
        }
        foreach (var scene in scenes)
        {
            _rows.Children.Add(SceneRow(scene));
        }
        var known = scenes.Select(s => s.Guid).ToHashSet();
        var add = new MenuFlyout();
        foreach (var asset in _shell.Assets.Assets.Values.Where(a => a.Kind == AssetKind.Scene && !known.Contains(a.Guid)).OrderBy(AssetIndex.DisplayName, StringComparer.OrdinalIgnoreCase))
        {
            var item = new MenuItem { Header = AssetIndex.DisplayName(asset) };
            var guid = asset.Guid;
            item.Click += (_, _) => _editor.AddScene(guid);
            add.Items.Add(item);
        }
        var button = AddButton("Add Scene", add);
        button.HorizontalAlignment = HorizontalAlignment.Left;
        _rows.Children.Add(button);
        foreach (var p in _editor.Problems.Where(p => p.Line == 0 || _editor.SceneAt(p.Line) == null))
        {
            _rows.Children.Add(ProblemText(p, LinePlace(p.Line)));
        }
    }

    Control SceneRow(WorldScene scene)
    {
        var guid = scene.Guid;
        var persistent = scene.Persistent;
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions(Columns), ColumnSpacing = 6 };
        void Put(Control control, int column)
        {
            Grid.SetColumn(control, column);
            grid.Children.Add(control);
        }
        var name = _shell.Assets.Find(guid) is { } asset ? AssetIndex.DisplayName(asset) : guid;
        Put(new TextBlock { Text = name, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis }, 0);
        var check = new CheckBox { IsChecked = persistent, VerticalAlignment = VerticalAlignment.Center };
        check.IsCheckedChanged += (_, _) => _editor.SetPersistent(guid, check.IsChecked == true);
        Put(check, 1);
        if (!persistent)
        {
            var (min, max) = (scene.Min, scene.Max);
            Put(ValueBox(min == null ? "" : WorldFile.Format(min), Vector, "[0, 0, 0]", v => _editor.SetBounds(guid, v, max ?? v)), 2);
            Put(ValueBox(max == null ? "" : WorldFile.Format(max), Vector, "[0, 0, 0]", v => _editor.SetBounds(guid, min ?? v, v)), 3);
            var (load, unload) = (scene.LoadDistance, scene.UnloadDistance);
            Put(ValueBox(load is { } l ? WorldFile.Format(l) : "", ValueFormats.Number(), "25", v => _editor.SetDistances(guid, v, unload)), 4);
            // Empty is the default, which follows the load distance.
            Put(ValueBox(unload is { } u ? WorldFile.Format(u) : "", ValueFormats.OptionalNumber(), "auto", v => _editor.SetDistances(guid, load ?? 25, v)), 5);
        }
        var play = new TextBlock { Text = _editor.PlayState(scene), VerticalAlignment = VerticalAlignment.Center };
        Put(play, 6);
        Put(SmallButton("×", "Remove the scene from the world", () => _editor.RemoveScene(guid)), 7);
        var column = new StackPanel { Spacing = 2, Children = { grid } };
        foreach (var problem in _editor.ProblemsOf(scene))
        {
            column.Children.Add(ProblemText(problem));
        }
        return column;
    }

    // A bound: three numbers, with or without the brackets.
    static readonly IValueFormat<double[]> Vector = ValueFormats.Of(ParseVector, WorldFile.Format, "three numbers, such as [0, 0, 0]");

    static double? ParseNumber(string text) =>
        double.TryParse(text.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var number) && double.IsFinite(number) ? number : null;

    // Three numbers, with or without the brackets.
    static double[]? ParseVector(string text)
    {
        var parts = text.Trim().TrimStart('[').TrimEnd(']').Split(',', StringSplitOptions.TrimEntries);
        var numbers = parts.Select(ParseNumber).ToArray();
        return numbers.Length == 3 && numbers.All(n => n != null) ? [.. numbers.Select(n => n!.Value)] : null;
    }

    // The preview bar: where the preview is, its buttons, and the scenes that it loads.
    void RefreshPreview()
    {
        var names = _shell.PreviewedScenes.Select(g => _shell.Assets.Find(g) is { } asset ? AssetIndex.DisplayName(asset) : g).ToList();
        var shown = $"{_shell.Preview.GetType().Name}|{_shell.IsEditing}|{_shell.ActiveViewport.HasCamera}|{string.Join(",", names)}";
        if (shown == _shownPreview)
        {
            return;
        }
        _shownPreview = shown;
        _preview.Children.Clear();
        _preview.Children.Add(new TextBlock { Text = "Preview", FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        _preview.Children.Add(CommandButton(EditorCommands.WorldPreviewOff, "Off"));
        _preview.Children.Add(CommandButton(EditorCommands.WorldPreviewCamera, "Camera"));
        _preview.Children.Add(CommandButton(EditorCommands.WorldPinPreview, "Pin Here"));
        _preview.Children.Add(CommandButton(EditorCommands.WorldOpenPreviewed, "Open Previewed Scenes"));
        _preview.Children.Add(new TextBlock
        {
            Text = !_shell.IsEditing ? "the game's own scenes show in Play" : names.Count == 0 ? "no scene loads" : "loads " + string.Join(", ", names),
            Classes = { "empty" },
            VerticalAlignment = VerticalAlignment.Center,
        });
    }

    // A button for a command, which marks the command that is on.
    Button CommandButton(string id, string label)
    {
        var command = _shell.Commands.Get(id);
        var button = SmallButton(command.IsChecked ? $"● {label}" : label, command.Description ?? label, () => command.Execute());
        button.IsEnabled = command.CanExecute;
        return button;
    }
}
