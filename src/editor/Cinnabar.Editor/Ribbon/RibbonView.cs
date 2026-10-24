using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Markup.Xaml.Styling;
using Avalonia.Media;
using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Commands.Ribbon;
using Cinnabar.Editor.Shell;
using RibbonComboBox = Cinnabar.Editor.Commands.Ribbon.ComboBox;
using RibbonSplitButton = Cinnabar.Editor.Commands.Ribbon.SplitButton;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.Ribbon;

/// <summary>
/// Shows a <see cref="RibbonLayout"/> (see docs/editor.md#ribbon): the category bands, the tab strip, and the groups
/// of the selected tab. It rebuilds when the editor's context changes, because contextual tabs come and go.
/// </summary>
public sealed class RibbonView : DockPanel
{
    readonly EditorShell _shell;
    readonly CommandViews _views;
    readonly StackPanel _tabStrip = new() { Orientation = Orientation.Horizontal };
    readonly Border _body = new() { Classes = { "ribbon-body" } };
    // Undoes the subscriptions of the current tab's controls, so a rebuild leaves nothing listening.
    readonly List<Action> _unsubscribe = [];
    string? _selectedTab;

    internal RibbonView(EditorShell shell, CommandViews views)
    {
        _shell = shell;
        _views = views;
        Classes.Add("ribbon");
        Resources.MergedDictionaries.Add(new ResourceInclude(new Uri("avares://editor/"))
        {
            Source = new Uri("avares://editor/Ribbon/RibbonResources.axaml"),
        });

        var collapse = new ToggleButton
        {
            Classes = { "ribbon-collapse" },
            Content = CommandViews.Icon("collapse", 12),
            Command = views.Adapter(EditorCommands.CollapseRibbon),
            [ToolTip.TipProperty] = views.Tooltip(shell.Commands.Get(EditorCommands.CollapseRibbon)),
            [AutomationProperties.NameProperty] = shell.Commands.Get(EditorCommands.CollapseRibbon).Label,
        };
        var header = new DockPanel { Classes = { "ribbon-header" } };
        SetDock(collapse, DockSide.Right);
        header.Children.Add(collapse);
        header.Children.Add(_tabStrip);
        SetDock(header, DockSide.Top);
        Children.Add(header);
        Children.Add(_body);

        shell.Context.Changed += Rebuild;
        shell.RibbonCollapsedChanged += () =>
        {
            collapse.IsChecked = shell.RibbonCollapsed;
            _body.IsVisible = !shell.RibbonCollapsed;
        };
        Rebuild();
    }

    void Rebuild()
    {
        foreach (var undo in _unsubscribe)
        {
            undo();
        }
        _unsubscribe.Clear();

        var tabs = _shell.Ribbon.VisibleTabs(_shell.Context).ToList();
        if (tabs.All(t => t.Id != _selectedTab))
        {
            _selectedTab = tabs.FirstOrDefault()?.Id;
        }
        var categories = _shell.Ribbon.Categories.ToDictionary(c => c.Id);
        var anyCategory = tabs.Any(t => t.Category != null);

        _tabStrip.Children.Clear();
        string? previousCategory = null;
        foreach (var tab in tabs)
        {
            var header = new StackPanel();
            if (anyCategory)
            {
                // A category's label shows once, over the first tab of a run of its tabs.
                var category = tab.Category == null ? null : categories[tab.Category];
                header.Children.Add(new Border
                {
                    Classes = { "ribbon-category" },
                    Background = category == null ? Brushes.Transparent : Brush.Parse(category.Color),
                    Child = new TextBlock { Text = category != null && tab.Category != previousCategory ? category.Label : "" },
                });
            }
            previousCategory = tab.Category;
            var button = new Button { Classes = { "ribbon-tab" }, Content = tab.Label };
            if (tab.Id == _selectedTab)
            {
                button.Classes.Add("selected");
            }
            button.Click += (_, _) => Select(tab.Id);
            button.DoubleTapped += (_, _) => _shell.RibbonCollapsed = !_shell.RibbonCollapsed;
            header.Children.Add(button);
            _tabStrip.Children.Add(header);
        }

        var groups = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var group in tabs.FirstOrDefault(t => t.Id == _selectedTab)?.Groups ?? [])
        {
            groups.Children.Add(Group(group));
        }
        _body.Child = new ScrollViewer
        {
            Content = groups,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        _body.IsVisible = !_shell.RibbonCollapsed;
    }

    void Select(string tabId)
    {
        _selectedTab = tabId;
        _shell.RibbonCollapsed = false;
        Rebuild();
    }

    Control Group(RibbonGroup group)
    {
        var items = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        foreach (var item in group.Items)
        {
            items.Children.Add(Item(item));
        }
        var label = new TextBlock { Classes = { "ribbon-group-label" }, Text = group.Label };
        var panel = new DockPanel();
        SetDock(label, DockSide.Bottom);
        panel.Children.Add(label);
        panel.Children.Add(items);
        return new Border { Classes = { "ribbon-group" }, Child = panel };
    }

    Control Item(RibbonItem item) => item switch
    {
        LargeButton large => Button(large.Command, large: true),
        SmallStack stack => Stack(stack),
        RibbonSplitButton split => Split(split),
        Dropdown dropdown => Dropdown(dropdown),
        RibbonComboBox combo => Choice((ChoiceCommand)_shell.Commands.Get(combo.Command)),
        _ => throw new NotSupportedException($"ribbon item {item.GetType().Name}"),
    };

    StackPanel Stack(SmallStack stack)
    {
        var panel = new StackPanel();
        panel.Children.AddRange(stack.Commands.Select(id => Button(id, large: false)));
        return panel;
    }

    Button Button(string id, bool large)
    {
        var command = _shell.Commands.Get(id);
        Button button = command.IsToggle ? new ToggleButton() : new Button();
        button.Classes.Add(large ? "ribbon-large" : "ribbon-small");
        button.Content = Content(command.Label, command.Icon, large);
        button.Command = _views.Adapter(id);
        ToolTip.SetTip(button, _views.Tooltip(command));
        // The content is a panel, so without a name, accessibility tools would read out its type.
        AutomationProperties.SetName(button, command.Label);
        if (button is ToggleButton toggle)
        {
            void Update() => toggle.IsChecked = command.IsChecked;
            Update();
            command.Changed += Update;
            _unsubscribe.Add(() => command.Changed -= Update);
        }
        return button;
    }

    Control Split(RibbonSplitButton split)
    {
        var command = _shell.Commands.Get(split.Command);
        var button = new Avalonia.Controls.SplitButton
        {
            Classes = { "ribbon-large" },
            Content = Content(command.Label, command.Icon, large: true),
            Command = _views.Adapter(split.Command),
            Flyout = Menu(split.Menu),
        };
        ToolTip.SetTip(button, _views.Tooltip(command));
        AutomationProperties.SetName(button, command.Label);
        return button;
    }

    Control Dropdown(Dropdown dropdown) => new DropDownButton
    {
        Classes = { "ribbon-large" },
        Content = Content(dropdown.Label, dropdown.Icon, large: true),
        Flyout = Menu(dropdown.Menu),
        [AutomationProperties.NameProperty] = dropdown.Label,
    };

    MenuFlyout Menu(IReadOnlyList<string> ids)
    {
        var menu = new MenuFlyout();
        foreach (var id in ids)
        {
            menu.Items.Add(_views.MenuItem(id, _unsubscribe));
        }
        return menu;
    }

    Control Choice(ChoiceCommand command)
    {
        var box = new Avalonia.Controls.ComboBox
        {
            ItemsSource = command.Options,
            SelectedItem = command.Selected,
            MinWidth = 90,
        };
        box.SelectionChanged += (_, _) =>
        {
            if (box.SelectedItem is string option)
            {
                command.Select(option);
            }
        };
        void Update()
        {
            box.SelectedItem = command.Selected;
            box.IsEnabled = command.CanExecute;
        }
        Update();
        command.Changed += Update;
        _unsubscribe.Add(() => command.Changed -= Update);
        ToolTip.SetTip(box, _views.Tooltip(command));
        AutomationProperties.SetName(box, command.Label);
        var label = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            Children = { CommandViews.Icon(command.Icon, 16) ?? new Control(), new TextBlock { Text = command.Label } },
        };
        return new StackPanel { Classes = { "ribbon-choice" }, Spacing = 4, Children = { label, box } };
    }

    static Control Content(string label, string? icon, bool large)
    {
        var text = new TextBlock { Text = label };
        if (!large)
        {
            return new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 6,
                Children = { CommandViews.Icon(icon, 16) ?? new Control { Width = 16 }, text },
            };
        }
        text.TextWrapping = TextWrapping.Wrap;
        text.TextAlignment = TextAlignment.Center;
        return new StackPanel
        {
            Spacing = 4,
            Children = { CommandViews.Icon(icon, 28) ?? new Control { Height = 28 }, text },
        };
    }
}
