using Avalonia.Controls;
using Cinnabar.Editor.Commands;

namespace Cinnabar.Editor.Ribbon;

/// <summary>
/// A menu for a button, whose items are made once and whose state is read each time it opens: what is checked, what is
/// enabled, and the labels that say a value. So a view that docking makes many times leaves nothing listening to the
/// commands, and the menu still shows the state of the moment. The items must not be added or removed as the menu
/// opens: a <see cref="MenuFlyout"/> takes its size before that, and would show as a sliver. What is read as the menu
/// opens is read in the order that it was added, so a menu that acts on a target adds what makes it current first.
/// </summary>
sealed class LiveMenu : IMenuBinding
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

    /// <summary>A command's item reads its state as the menu opens (see <see cref="MenuBuilder"/>).</summary>
    void IMenuBinding.Bind(Command command, Action read)
    {
        read();
        _refresh.Add(read);
    }
}
