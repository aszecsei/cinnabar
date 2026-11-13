using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Ribbon;
using Cinnabar.Editor.Shell;
using static Cinnabar.Editor.Panels.Kit;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.Decisions;

/// <summary>
/// The blackboard editor (see docs/editor/decision-editor.md#blackboards): a table of the keys in their slots' order,
/// each its name, its type, an enum's names and its default, with its problems. Renaming a key that decisions read asks
/// first, since it changes them too. Docking can rebuild the view at any time, so its state is in its
/// <see cref="BlackboardEditor"/>.
/// </summary>
public sealed class BlackboardEditorView : DockPanel
{
    readonly EditorShell _shell;
    readonly BlackboardEditor _editor;
    readonly StackPanel _rows = new() { Margin = new Thickness(8), Spacing = 4, MaxWidth = 760, HorizontalAlignment = HorizontalAlignment.Left };
    readonly TextBlock _status = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
    string _shown = "";

    public BlackboardEditorView(EditorShell shell, BlackboardEditor editor)
    {
        _shell = shell;
        _editor = editor;
        var toolbar = new DockPanel { Margin = new Thickness(8, 4) };
        var save = new Button { Content = CommandViews.Icon("save", 16), Classes = { "viewport-tool" }, Focusable = false, Margin = new Thickness(0, 0, 8, 0) };
        ToolTip.SetTip(save, "Save (Ctrl+S)");
        save.Click += (_, _) => shell.SaveGraph(editor);
        DockPanel.SetDock(save, DockSide.Left);
        toolbar.Children.Add(save);
        var text = SmallButton("Open in Script Editor", "Edit the blackboard's text. Save first: this editor does not read the file again.", () => shell.OpenScript(editor.Document.Path));
        DockPanel.SetDock(text, DockSide.Left);
        toolbar.Children.Add(text);
        DockPanel.SetDock(_status, DockSide.Right);
        toolbar.Children.Add(_status);
        toolbar.Children.Add(new Panel());
        var top = new Border { Child = toolbar, BorderBrush = new SolidColorBrush(Color.Parse("#333337")), BorderThickness = new Thickness(0, 0, 0, 1) };
        SetDock(top, DockSide.Top);
        Children.Add(top);
        Children.Add(new ScrollViewer { Content = _rows, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled });

        new ViewSubscriptions(this, attached: Refresh)
            .Add(() => _editor.Changed += Refresh, () => _editor.Changed -= Refresh)
            .Add(() => _editor.ProblemsChanged += Refresh, () => _editor.ProblemsChanged -= Refresh)
            .Add(() => _shell.Cook.StateChanged += Refresh, () => _shell.Cook.StateChanged -= Refresh);
    }

    void Rebuild()
    {
        _shown = "";
        Refresh();
    }

    void Refresh()
    {
        var errors = _editor.Problems.Count(p => p.Error);
        var status = !_shell.Cook.Linked ? "waiting for the cook daemon" : errors == 0 ? "cooks" : errors == 1 ? "1 error" : $"{errors} errors";
        _status.Text = _editor.Document.IsDirty ? $"{status}  ·  not saved" : status;
        var shown = string.Join("|", _editor.Keys.Select(k => $"{k.Type} {k.Name} {string.Join(",", k.Values)} {k.Default}"))
            + "#" + string.Join("|", _editor.Problems.Select(p => p.Line + p.Text));
        if (shown == _shown)
        {
            return;
        }
        _shown = shown;
        _rows.Children.Clear();
        var header = new Grid { ColumnDefinitions = new ColumnDefinitions("160,100,*,Auto"), ColumnSpacing = 6 };
        header.Children.Add(Heading("Key"));
        var typeHeading = Heading("Type");
        Grid.SetColumn(typeHeading, 1);
        header.Children.Add(typeHeading);
        var defaultHeading = Heading("Default");
        Grid.SetColumn(defaultHeading, 2);
        header.Children.Add(defaultHeading);
        _rows.Children.Add(header);
        var keys = _editor.Keys;
        if (keys.Count == 0)
        {
            _rows.Children.Add(Dim("The blackboard has no keys. Add one: a decision reads and writes them, and an agent's scripts and actions do too."));
        }
        for (var i = 0; i < keys.Count; i++)
        {
            _rows.Children.Add(KeyRow(keys[i], first: i == 0, last: i == keys.Count - 1));
        }
        var add = new MenuFlyout();
        foreach (var type in BlackboardFile.Types)
        {
            var item = new MenuItem { Header = type };
            item.Click += (_, _) => _editor.AddKey(type);
            add.Items.Add(item);
        }
        var button = AddButton("Add Key", add);
        button.HorizontalAlignment = HorizontalAlignment.Left;
        _rows.Children.Add(button);
        foreach (var p in _editor.Problems.Where(p => _editor.Keys.All(k => !_editor.ProblemsOf(k).Contains(p))))
        {
            var text = AnimationGraphs.AnimationGraphPanel.ProblemText(p);
            text.Text = p.Line > 0 ? $"Line {p.Line}: {p.Text}" : p.Text;
            _rows.Children.Add(text);
        }
    }

    Control KeyRow(BlackboardKey key, bool first, bool last)
    {
        var (name, type, values, @default) = (key.Name, key.Type, key.Values, key.Default);
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("160,100,*,Auto"), ColumnSpacing = 6 };
        grid.Children.Add(ValueBox(name, "name", text => _ = Rename(name, text.Trim())));
        var choice = Choice(BlackboardFile.Types, type, t => _editor.SetKey(name, t, t == "enum" ? ["a", "b"] : [], null));
        Grid.SetColumn(choice, 1);
        grid.Children.Add(choice);
        var value = new StackPanel { Spacing = 2 };
        if (type == "enum")
        {
            value.Children.Add(ValueBox(string.Join(", ", values), "names, such as calm, alert", text =>
            {
                var names = text.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
                _editor.SetKey(name, type, names, @default != null && names.Contains(@default) ? @default : null);
            }));
            value.Children.Add(Choice(["", .. values], @default ?? "", d => _editor.SetKey(name, type, values, d)));
        }
        else if (type == "bool")
        {
            value.Children.Add(Choice(["false", "true"], @default ?? "false", d => _editor.SetKey(name, type, values, d == "false" ? null : d)));
        }
        else if (type == "entity")
        {
            value.Children.Add(Dim("none: a script or an action sets it"));
        }
        else
        {
            var watermark = type is "position" or "vector" ? "[0, 0, 0]" : "0";
            value.Children.Add(ValueBox(@default ?? "", watermark, d => _editor.SetKey(name, type, values, d)));
        }
        foreach (var problem in _editor.ProblemsOf(key))
        {
            value.Children.Add(AnimationGraphs.AnimationGraphPanel.ProblemText(problem));
        }
        Grid.SetColumn(value, 2);
        grid.Children.Add(value);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Top };
        var up = SmallButton("↑", "Move it up a slot", () => _editor.MoveKey(name, -1));
        up.IsEnabled = !first;
        var down = SmallButton("↓", "Move it down a slot", () => _editor.MoveKey(name, 1));
        down.IsEnabled = !last;
        buttons.Children.Add(up);
        buttons.Children.Add(down);
        buttons.Children.Add(SmallButton("×", "Remove it", () => _editor.RemoveKey(name)));
        Grid.SetColumn(buttons, 3);
        grid.Children.Add(buttons);
        return grid;
    }

    // A rename of a key that decisions read changes them too, each in its editor, so it asks first.
    async Task Rename(string name, string newName)
    {
        if (newName == name)
        {
            return;
        }
        if (!_editor.CanRename(name, newName))
        {
            _shell.Console.Add(Model.LogLevel.Warning, $"blackboard: {newName} is not a name for a key, or another key has it");
            Rebuild();
            return;
        }
        var decisions = _editor.DecisionsReading(name);
        if (decisions.Count > 0 && TopLevel.GetTopLevel(this) is Window window)
        {
            var files = string.Join(", ", decisions.Select(d => Content.AssetIndex.DisplayName(d)));
            var message = $"Renaming {name} to {newName} also renames it in {files}, which open in the decision editor, unsaved, for you to look over and save.";
            if (await Dialogs.Ask(window, "Rename Key", message, "Rename", "Cancel") != "Rename")
            {
                Rebuild();
                return;
            }
        }
        _editor.RenameKey(name, newName);
    }
}
