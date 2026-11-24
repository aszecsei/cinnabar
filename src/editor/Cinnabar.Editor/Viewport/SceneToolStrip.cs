using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Ribbon;
using Cinnabar.Editor.Shell;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.Viewport;

/// <summary>
/// Buttons for commands outside the ribbon: a tool strip's and a tool shelf's. A button follows its command while it is
/// in the visual tree, and lets go when it leaves, since docking makes a view more than once.
/// </summary>
static class ToolButton
{
    /// <summary>
    /// A button that runs a command: a toggle for a toggle command, checked while the command is. With
    /// <paramref name="label"/> it shows the command's icon and label, and without, its icon alone, with the label in
    /// the tooltip. It never takes the focus, so the viewport keeps its keys.
    /// </summary>
    public static Button Create(EditorShell shell, string id, bool label, string classes, string? text = null)
    {
        var command = shell.Commands.Get(id);
        Button button = command.IsToggle ? new ToggleButton() : new Button();
        button.Classes.Add(classes);
        button.Focusable = false;
        var icon = CommandViews.Icon(command.Icon, 16);
        var name = text ?? command.Label;
        if (label)
        {
            button.Content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 6,
                Children = { icon ?? new Control { Width = 16 }, new TextBlock { Text = name, VerticalAlignment = VerticalAlignment.Center, TextTrimming = Avalonia.Media.TextTrimming.CharacterEllipsis } },
            };
        }
        else
        {
            button.Content = icon ?? (object)name;
        }
        var shortcut = shell.KeyBindings.Describe(id);
        var title = shortcut == null ? command.Label : $"{command.Label} ({shortcut})";
        ToolTip.SetTip(button, command.Description is { } description ? $"{title}\n{description}" : title);
        Avalonia.Automation.AutomationProperties.SetName(button, command.Label);
        void Update()
        {
            button.IsEnabled = command.CanExecute;
            if (button is ToggleButton toggle)
            {
                toggle.IsChecked = command.IsChecked;
            }
        }
        button.Click += (_, _) =>
        {
            command.Execute();
            // A toggle checks itself on a click, whatever the command then is.
            Update();
        };
        button.AttachedToVisualTree += (_, _) =>
        {
            command.Changed += Update;
            Update();
        };
        button.DetachedFromVisualTree += (_, _) => command.Changed -= Update;
        Update();
        return button;
    }

    /// <summary>A choice command as a row of its label and a box of its options.</summary>
    public static Control Choice(EditorShell shell, string id)
    {
        var command = (ChoiceCommand)shell.Commands.Get(id);
        var box = new ComboBox { Classes = { "shelf-choice" }, ItemsSource = command.Options, SelectedItem = command.Selected, Focusable = false, HorizontalAlignment = HorizontalAlignment.Stretch };
        var showing = false;
        box.SelectionChanged += (_, _) =>
        {
            if (!showing && box.SelectedItem is string option)
            {
                command.Select(option);
            }
        };
        void Update()
        {
            showing = true;
            box.SelectedItem = command.Selected;
            showing = false;
            box.IsEnabled = command.CanExecute;
        }
        box.AttachedToVisualTree += (_, _) =>
        {
            command.Changed += Update;
            Update();
        };
        box.DetachedFromVisualTree += (_, _) => command.Changed -= Update;
        var name = new TextBlock { Text = command.Label, Classes = { "field-name" }, VerticalAlignment = VerticalAlignment.Center };
        ToolTip.SetTip(name, command.Description);
        ToolTip.SetTip(box, command.Description);
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("72,*"), ColumnSpacing = 6 };
        Grid.SetColumn(box, 1);
        row.Children.Add(name);
        row.Children.Add(box);
        return row;
    }
}

/// <summary>
/// The Scene's tool strip, down its left edge (see docs/editor/viewport.md#tool-strip): what is the same in every scene
/// view, once. From the top: the mode, Object or Mesh; the tools; the tools that make, measure and paint; the gizmo's
/// space and snapping; in mesh mode, the kind of element; and at the bottom, Add, the menu of the kinds of entity.
/// </summary>
public sealed class SceneToolStrip : Border
{
    readonly EditorShell _shell;
    readonly StackPanel _elements = new() { Spacing = 2, IsVisible = false };
    readonly ToggleButton _object;

    public SceneToolStrip(EditorShell shell)
    {
        _shell = shell;
        Classes.Add("tool-strip");
        var tools = new StackPanel { Spacing = 2 };
        Button Tool(string id) => ToolButton.Create(shell, id, label: false, "tool-strip-button");

        // Object mode is what the editor is in while it is in no other, so its button leaves mesh mode.
        var objectMode = shell.Commands.Get(EditorCommands.ObjectMode);
        _object = new ToggleButton { Content = CommandViews.Icon("volume", 16), Classes = { "tool-strip-button" }, Focusable = false };
        ToolTip.SetTip(_object, "Object Mode\nSelect and move entities. Tab in the viewport leaves mesh mode.");
        _object.Click += (_, _) =>
        {
            objectMode.Execute();
            ShowMode();
        };
        tools.Children.Add(_object);
        tools.Children.Add(Tool(EditorCommands.EditMesh));
        tools.Children.Add(Gap());
        tools.Children.Add(Tool(EditorCommands.SelectTool));
        tools.Children.Add(Tool(EditorCommands.MoveTool));
        tools.Children.Add(Tool(EditorCommands.RotateTool));
        tools.Children.Add(Tool(EditorCommands.ScaleTool));
        tools.Children.Add(Gap());
        tools.Children.Add(Tool(EditorCommands.MeshBlock));
        tools.Children.Add(Tool(EditorCommands.NavPathTool));
        tools.Children.Add(Tool(EditorCommands.LandscapeTool));
        tools.Children.Add(Gap());
        tools.Children.Add(Tool(EditorCommands.LocalSpace));
        tools.Children.Add(Tool(EditorCommands.Snap));
        // The element kinds, while mesh mode is on.
        _elements.Children.Add(Gap());
        _elements.Children.Add(Tool(EditorCommands.MeshVertices));
        _elements.Children.Add(Tool(EditorCommands.MeshEdges));
        _elements.Children.Add(Tool(EditorCommands.MeshFaces));
        tools.Children.Add(_elements);

        // The Add menu, which reads as it opens whether the scene can take each kind.
        var addMenu = new LiveMenu();
        addMenu.Flyout.Placement = PlacementMode.RightEdgeAlignedBottom;
        MenuBuilder.Build(addMenu.Items, DefaultRibbon.AddMenu(), shell.Commands, shell.KeyBindings, addMenu);
        var add = new Button { Content = CommandViews.Icon("add", 16), Classes = { "tool-strip-button" }, Focusable = false, Flyout = addMenu.Flyout };
        ToolTip.SetTip(add, "Add\nAdd an entity of a common kind, ready to use: a light, a camera, a volume, a sound.");

        var panel = new DockPanel();
        DockPanel.SetDock(add, DockSide.Bottom);
        panel.Children.Add(add);
        panel.Children.Add(new ScrollViewer { Content = tools, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled });
        Child = panel;

        AttachedToVisualTree += (_, _) =>
        {
            _shell.Mesh.MeshModeChanged += ShowMode;
            ShowMode();
        };
        DetachedFromVisualTree += (_, _) => _shell.Mesh.MeshModeChanged -= ShowMode;
        ShowMode();
    }

    void ShowMode()
    {
        _elements.IsVisible = _shell.Mesh.InMeshMode;
        _object.IsChecked = !_shell.Mesh.InMeshMode;
    }

    static Border Gap() => new() { Classes = { "tool-strip-gap" } };
}
