using Avalonia.Controls;
using Cinnabar.Editor.Commands;

namespace Cinnabar.Editor.Ribbon;

/// <summary>
/// How a menu's items keep their commands' state: what is enabled and what is checked. <c>read</c> sets an item's state
/// from its command, and the binding says when it runs.
/// </summary>
interface IMenuBinding
{
    void Bind(Command command, Action read);
}

/// <summary>The ways that a menu's items keep their state, besides <see cref="LiveMenu"/>, which reads it as it opens.</summary>
static class MenuBinding
{
    /// <summary>
    /// Each item listens to its command: for a menu that is made once and lives as long as its view, as the ribbon's.
    /// <paramref name="unsubscribe"/> collects what stops the listening.
    /// </summary>
    public static IMenuBinding Subscribed(List<Action> unsubscribe) => new SubscribedBinding(unsubscribe);

    /// <summary>Each item reads its command once: for a menu that is filled again each time it opens.</summary>
    public static IMenuBinding Snapshot { get; } = new SnapshotBinding();

    sealed class SubscribedBinding(List<Action> unsubscribe) : IMenuBinding
    {
        public void Bind(Command command, Action read)
        {
            read();
            command.Changed += read;
            unsubscribe.Add(() => command.Changed -= read);
        }
    }

    sealed class SnapshotBinding : IMenuBinding
    {
        public void Bind(Command command, Action read) => read();
    }
}

/// <summary>
/// Builds a menu's items from its entries (see <see cref="MenuEntry"/>): the one walker of every menu of commands. A
/// command shows with its label, icon, shortcut, check and description, a choice command as a radio item for each of its
/// options, a separator as a line, and a menu under a label with its own entries. An entry whose command the registry no
/// longer has, as a game's command after a reload, is left out.
/// </summary>
static class MenuBuilder
{
    /// <summary>
    /// Adds the entries' items to <paramref name="items"/>. A command's <see cref="MenuCommand.Focus"/>, or else
    /// <paramref name="focus"/>, runs before the command does, as to select what the menu was opened on.
    /// </summary>
    public static void Build(ItemCollection items, IEnumerable<MenuEntry> entries, CommandRegistry commands, KeyBindings keys,
        IMenuBinding binding, Action? focus = null)
    {
        foreach (var entry in entries)
        {
            switch (entry)
            {
                case MenuCommand { Command: var id } named when commands.Find(id) is ChoiceCommand choice:
                    AddOptions(items, choice, named.Focus ?? focus, binding);
                    break;
                case MenuCommand { Command: var id } named when commands.Find(id) is { } command:
                    items.Add(Item(command, named.Label, keys, named.Focus ?? focus, binding));
                    break;
                case MenuSeparator:
                    items.Add(new Separator());
                    break;
                case Submenu submenu:
                    var parent = new MenuItem { Header = submenu.Label, Icon = CommandViews.Icon(submenu.Icon, 16) };
                    Build(parent.Items, submenu.Entries, commands, keys, binding, focus);
                    items.Add(parent);
                    break;
            }
        }
    }

    static MenuItem Item(Command command, string? label, KeyBindings keys, Action? focus, IMenuBinding binding)
    {
        var item = new MenuItem
        {
            Header = label ?? command.Label,
            Icon = CommandViews.Icon(command.Icon, 16),
            InputGesture = CommandViews.ParseGesture(keys.ShortcutOf(command.Id)),
        };
        if (command.Description != null)
        {
            ToolTip.SetTip(item, command.Description);
        }
        if (command.IsToggle)
        {
            item.ToggleType = MenuItemToggleType.CheckBox;
        }
        item.Click += (_, _) =>
        {
            focus?.Invoke();
            command.Execute();
        };
        binding.Bind(command, () =>
        {
            item.IsEnabled = command.CanExecute;
            if (command.IsToggle)
            {
                item.IsChecked = command.IsChecked;
            }
        });
        return item;
    }

    // A choice's options, each a radio item that is marked while it is the one chosen.
    static void AddOptions(ItemCollection items, ChoiceCommand choice, Action? focus, IMenuBinding binding)
    {
        var options = new List<(string Option, MenuItem Item)>();
        foreach (var option in choice.Options)
        {
            var item = new MenuItem { Header = option, ToggleType = MenuItemToggleType.Radio };
            if (choice.Description != null)
            {
                ToolTip.SetTip(item, choice.Description);
            }
            item.Click += (_, _) =>
            {
                focus?.Invoke();
                choice.Select(option);
            };
            options.Add((option, item));
            items.Add(item);
        }
        binding.Bind(choice, () =>
        {
            var selected = choice.Selected;
            var enabled = choice.CanExecute;
            foreach (var (option, item) in options)
            {
                item.IsEnabled = enabled;
                item.IsChecked = option == selected;
            }
        });
    }
}
