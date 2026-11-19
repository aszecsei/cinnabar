using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// The Sublevels panel (see docs/editor/shell-and-panels.md#sublevels): the base and the project's sublevels, each with
/// how many entities of the open scenes it has, whether it starts active, which writes <c>project.settings</c>, and
/// whether Edit loads it. Assign puts the selection in a row's sublevel. A sublevel that the open scenes use and the
/// project does not declare shows with a warning, and Declare declares it.
/// </summary>
public sealed class SublevelsView : DockPanel
{
    readonly EditorShell _shell;
    readonly StackPanel _rows = new() { Spacing = 2, Margin = new Thickness(6) };
    readonly TextBox _name = new() { PlaceholderText = "New sublevel", MinWidth = 120 };

    internal ViewSubscriptions Subscriptions { get; }

    /// <summary>The rows as the panel last built them: the base first, then each known sublevel.</summary>
    internal IReadOnlyList<SublevelRow> Rows { get; private set; } = [];

    public SublevelsView(EditorShell shell)
    {
        _shell = shell;
        var add = new Button { Content = "Add", VerticalAlignment = VerticalAlignment.Center };
        add.Click += (_, _) => AddTyped();
        _name.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter)
            {
                AddTyped();
                e.Handled = true;
            }
        };
        var footer = new DockPanel { Margin = new Thickness(6), Children = { add, _name } };
        DockPanel.SetDock(add, Avalonia.Controls.Dock.Right);
        DockPanel.SetDock(footer, Avalonia.Controls.Dock.Bottom);
        Children.Add(footer);
        Children.Add(new ScrollViewer { Content = _rows });
        Subscriptions = new ViewSubscriptions(this, attached: Rebuild)
            .Add(() => _shell.SublevelsChanged += Rebuild, () => _shell.SublevelsChanged -= Rebuild)
            .Add(() => _shell.SceneChanged += Rebuild, () => _shell.SceneChanged -= Rebuild)
            .Add(() => _shell.Selection.Changed += OnSelectionChanged, () => _shell.Selection.Changed -= OnSelectionChanged);
    }

    // Assign needs a selection.
    void OnSelectionChanged(IReadOnlyList<ulong> old, IReadOnlyList<ulong> entities) => Rebuild();

    void AddTyped()
    {
        var name = _name.Text?.Trim() ?? "";
        if (name.Length > 0 && _shell.DeclareSublevel(name, active: false))
        {
            _name.Text = "";
        }
    }

    internal void Rebuild()
    {
        var declared = _shell.DeclaredSublevels;
        var rows = new List<SublevelRow> { new("", Declared: true, Active: true, _shell.SublevelCount(""), Loaded: true) };
        rows.AddRange(_shell.KnownSublevels().Select(name =>
        {
            var declaration = declared.FirstOrDefault(s => s.Name == name);
            return new SublevelRow(name, declaration.Name != null, declaration.Active, _shell.SublevelCount(name), _shell.IsSublevelChosen(name));
        }));
        Rows = rows;
        _rows.Children.Clear();
        _rows.Children.Add(Header());
        foreach (var row in rows)
        {
            _rows.Children.Add(RowView(row));
        }
        if (rows.Count == 1)
        {
            _rows.Children.Add(new TextBlock
            {
                Text = "The project declares no sublevels. Add one below to make a variant of a room, such as night.",
                Classes = { "empty" },
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 8),
            });
        }
    }

    static Grid Columns(params Control[] cells)
    {
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto,Auto,Auto,Auto,Auto"), MinHeight = 26 };
        for (var i = 0; i < cells.Length; i++)
        {
            Grid.SetColumn(cells[i], i);
            cells[i].VerticalAlignment = VerticalAlignment.Center;
            cells[i].Margin = new Thickness(i == 0 ? 0 : 8, 0, 0, 0);
            grid.Children.Add(cells[i]);
        }
        return grid;
    }

    static Grid Header() => Columns(
        Dim("Sublevel"), Dim("Entities"), Dim("Starts active"), Dim("Load in Edit"), new Control(), new Control());

    static TextBlock Dim(string text) => new() { Text = text, Classes = { "dim" }, FontSize = 11 };

    Control RowView(SublevelRow row)
    {
        var isBase = row.Name == "";
        var name = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        name.Children.Add(new TextBlock { Text = isBase ? "Base" : row.Name, FontStyle = isBase ? FontStyle.Italic : FontStyle.Normal });
        if (!row.Declared)
        {
            var warning = new TextBlock { Text = "not declared", Classes = { "warning" } };
            ToolTip.SetTip(warning, "Entities of the open scenes are in this sublevel, but project.settings does not declare it, so the scenes do not cook. Declare it.");
            name.Children.Add(warning);
        }
        var count = new TextBlock { Text = row.Count.ToString("N0"), HorizontalAlignment = HorizontalAlignment.Right, MinWidth = 40, TextAlignment = TextAlignment.Right };

        Control active = new Control();
        Control loaded = new Control();
        Control remove = new Control();
        if (!isBase && row.Declared)
        {
            var box = new CheckBox { IsChecked = row.Active, HorizontalAlignment = HorizontalAlignment.Center };
            ToolTip.SetTip(box, "Whether the game starts with this sublevel active, and Play with it loaded. Writes project.settings.");
            box.IsCheckedChanged += (_, _) => _shell.DeclareSublevel(row.Name, box.IsChecked == true);
            active = box;
            var cross = new Button { Content = "×", Classes = { "field-button" } };
            ToolTip.SetTip(cross, "Remove the declaration from project.settings");
            cross.Click += (_, _) => _shell.RemoveSublevel(row.Name);
            remove = cross;
        }
        else if (!isBase)
        {
            var declare = new Button { Content = "Declare", Padding = new Thickness(6, 0) };
            declare.Click += (_, _) => _shell.DeclareSublevel(row.Name, active: false);
            active = declare;
        }
        if (!isBase)
        {
            var box = new CheckBox { IsChecked = row.Loaded, IsEnabled = _shell.IsEditing, HorizontalAlignment = HorizontalAlignment.Center };
            ToolTip.SetTip(box, _shell.IsEditing
                ? "Whether Edit loads this sublevel's parts of the open scenes. Play starts with the active set."
                : "Play has the project's active set. Stop brings back the editor's choice.");
            box.IsCheckedChanged += (_, _) => _shell.SetSublevelLoaded(row.Name, box.IsChecked == true);
            loaded = box;
        }
        var assign = new Button { Content = "Assign", Padding = new Thickness(6, 0), IsEnabled = _shell.IsEditing && _shell.Selection.Entities.Count > 0 };
        ToolTip.SetTip(assign, isBase ? "Put the selected roots in the base" : $"Put the selected roots in {row.Name}");
        assign.Click += (_, _) => _shell.AssignSublevel(row.Name);
        var grid = Columns(name, count, active, loaded, assign, remove);
        grid.Opacity = isBase || row.Loaded || !_shell.IsEditing ? 1 : 0.6;
        return grid;
    }
}

/// <summary>A row of the Sublevels panel: "" is the base.</summary>
public sealed record SublevelRow(string Name, bool Declared, bool Active, int Count, bool Loaded);
