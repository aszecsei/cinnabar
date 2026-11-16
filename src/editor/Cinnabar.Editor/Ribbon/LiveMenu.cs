using Avalonia.Controls;
using Avalonia.Input;
using Cinnabar.Editor.Commands;

namespace Cinnabar.Editor.Ribbon;

/// <summary>
/// A menu for a button, whose items are made once and whose state is read each time it opens: what is checked, what is
/// enabled, and the labels that say a value. So a view that docking makes many times leaves nothing listening to the
/// commands, and the menu still shows the state of the moment. The items must not be added or removed as the menu
/// opens: a <see cref="MenuFlyout"/> takes its size before that, and would show as a sliver.
/// </summary>
sealed class LiveMenu
{
    readonly List<Action> _refresh = [];

    public MenuFlyout Flyout { get; } = new();

    public ItemCollection Items => Flyout.Items;

    public LiveMenu() => Flyout.Opening += (_, _) => Refresh();

    /// <summary>Reads every item's state again, as the menu's opening does.</summary>
    public void Refresh()
    {
        foreach (var refresh in _refresh)
        {
            refresh();
        }
    }

    /// <summary>An item that runs an action, enabled while <paramref name="enabled"/> says so.</summary>
    public MenuItem Item(ItemCollection items, string header, Action click, string? tip = null, Func<bool>? enabled = null)
    {
        var item = new MenuItem { Header = header };
        item.Click += (_, _) => click();
        if (tip != null)
        {
            ToolTip.SetTip(item, tip);
        }
        if (enabled != null)
        {
            _refresh.Add(() => item.IsEnabled = enabled());
        }
        items.Add(item);
        return item;
    }

    /// <summary>An item with a check, which shows while <paramref name="on"/> says so.</summary>
    public MenuItem Check(ItemCollection items, string header, Func<bool> on, Action click, string? tip = null, Func<bool>? enabled = null)
    {
        var item = Item(items, header, click, tip, enabled);
        item.ToggleType = MenuItemToggleType.CheckBox;
        _refresh.Add(() => item.IsChecked = on());
        return item;
    }

    /// <summary>One of a set of items of which one is chosen, marked while <paramref name="on"/> says so.</summary>
    public MenuItem Radio(ItemCollection items, string header, Func<bool> on, Action click, string? tip = null)
    {
        var item = Item(items, header, click, tip);
        item.ToggleType = MenuItemToggleType.Radio;
        _refresh.Add(() => item.IsChecked = on());
        return item;
    }

    /// <summary>A menu under a label, which is read as the menu opens, so that it can say a value.</summary>
    public MenuItem Submenu(ItemCollection items, Func<string> header, string? tip = null)
    {
        var item = new MenuItem { Header = header() };
        if (tip != null)
        {
            ToolTip.SetTip(item, tip);
        }
        _refresh.Add(() => item.Header = header());
        items.Add(item);
        return item;
    }

    /// <summary>What else to read as the menu opens.</summary>
    public void OnOpening(Action refresh) => _refresh.Add(refresh);

    /// <summary>
    /// A command, with its label, icon, check and shortcut, enabled while it can run. <paramref name="before"/> runs
    /// before the command does, as to select what the menu was opened on.
    /// </summary>
    public MenuItem Command(ItemCollection items, Command command, string? shortcut = null, Action? before = null)
    {
        var item = Item(items, command.Label, () =>
        {
            before?.Invoke();
            command.Execute();
        }, command.Description, () => command.CanExecute);
        item.Icon = CommandViews.Icon(command.Icon, 16);
        if (command.IsToggle)
        {
            item.ToggleType = MenuItemToggleType.CheckBox;
            _refresh.Add(() => item.IsChecked = command.IsChecked);
        }
        if (shortcut != null)
        {
            try
            {
                item.InputGesture = KeyGesture.Parse(shortcut);
            }
            catch (ArgumentException)
            {
                // A key binding that is not a gesture has a warning in the console already.
            }
        }
        return item;
    }

    /// <summary>A menu's entries (see <see cref="MenuEntry"/>): its commands, lines, and menus under labels.</summary>
    public void Entries(ItemCollection items, CommandRegistry commands, IEnumerable<MenuEntry> entries, Action? before = null)
    {
        foreach (var entry in entries)
        {
            switch (entry)
            {
                case MenuCommand { Command: var id } when commands.Find(id) is { } command:
                    Command(items, command, before: before);
                    break;
                case MenuSeparator:
                    items.Add(new Separator());
                    break;
                case Submenu submenu:
                    var parent = new MenuItem { Header = submenu.Label, Icon = CommandViews.Icon(submenu.Icon, 16) };
                    Entries(parent.Items, commands, submenu.Entries, before);
                    items.Add(parent);
                    break;
            }
        }
    }
}
