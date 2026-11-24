using System.Windows.Input;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Ribbon;

/// <summary>A <see cref="Command"/> as an Avalonia <see cref="ICommand"/>, so buttons and menu items enable themselves.</summary>
sealed class CommandAdapter : ICommand
{
    public CommandAdapter(Command command)
    {
        Command = command;
        command.Changed += () => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
    }

    public Command Command { get; }

    public event EventHandler? CanExecuteChanged;

    public bool CanExecute(object? parameter) => Command.CanExecute;

    public void Execute(object? parameter) => Command.Execute();
}

/// <summary>
/// A command as a shortcut: while the game has the keys the shortcut does nothing, except on the function keys, so F5 and
/// Shift+F5 work during play. Nor does one that a text box uses, while a text box has the focus. Avalonia runs the key
/// bindings of the focused control and of each control around it, nearest first and the window's last, before the
/// focused control sees the key, and a binding that cannot run leaves the key to the next one and then to the control.
/// So Delete in a search box would otherwise delete the selected entities, and a panel that gives Delete its own meaning
/// does so as the focused command scope (see <see cref="Commands.ICommandScope"/>), not in its key handler.
/// </summary>
sealed class ShortcutCommand(ICommand command, KeyGesture gesture, Func<bool> gameHasKeys, Func<bool> textHasFocus) : ICommand
{
    /// <summary>
    /// Whether a text box uses a key: any key alone or with Shift but the function keys, and with Ctrl what edits text and
    /// moves through it.
    /// </summary>
    public static bool TextBoxUses(KeyGesture gesture)
    {
        if (gesture.Key is >= Key.F1 and <= Key.F24)
        {
            return false;
        }
        return (gesture.KeyModifiers & ~KeyModifiers.Shift) switch
        {
            KeyModifiers.None => true,
            KeyModifiers.Control => gesture.Key is Key.A or Key.C or Key.V or Key.X or Key.Z or Key.Y
                or Key.Left or Key.Right or Key.Up or Key.Down or Key.Home or Key.End or Key.Back or Key.Delete,
            _ => false,
        };
    }

    public event EventHandler? CanExecuteChanged
    {
        add => command.CanExecuteChanged += value;
        remove => command.CanExecuteChanged -= value;
    }

    public bool CanExecute(object? parameter) =>
        (gesture.Key is >= Key.F1 and <= Key.F24 || !gameHasKeys())
        && !(TextBoxUses(gesture) && textHasFocus())
        && command.CanExecute(parameter);

    public void Execute(object? parameter) => command.Execute(parameter);
}

/// <summary>
/// The shortcuts of a scope on its control (see <see cref="Commands.ShortcutScopes"/>), which Avalonia runs before the
/// window's. A scope's key is the scope's: when its command cannot run now, the key does nothing, and does not reach the
/// window, as Tab in the viewport outside a mesh does not move the keyboard. The key passes on only while the game has
/// the keys, while a text box uses it, or while <c>keysFree</c> says the control needs it for itself, as a flight does
/// the keys that fly. <c>beatsText</c> takes the keys from a text box while it holds, as a drag under way in a cutscene
/// keeps Esc while a value box has the keyboard.
/// </summary>
static class ScopeShortcuts
{
    public static void Attach(Control control, string scope, EditorShell shell, Func<Key, bool>? keysFree = null, Func<bool>? beatsText = null)
    {
        foreach (var (id, shortcut) in shell.KeyBindings.InScope(scope))
        {
            if (CommandViews.ParseGesture(shortcut) is not { } gesture)
            {
                continue;
            }
            var free = keysFree;
            var command = new CommunityToolkit.Mvvm.Input.RelayCommand(
                () => shell.Commands.Find(id)?.Execute(),
                () => (free == null || free(gesture.Key))
                    && (beatsText?.Invoke() == true || TopLevel.GetTopLevel(control)?.FocusManager?.GetFocusedElement() is not TextBox));
            control.KeyBindings.Add(new KeyBinding { Gesture = gesture, Command = new ShortcutCommand(command, gesture, () => shell.GameHasKeys, () => false) });
        }
    }
}

/// <summary>What views of commands share: one adapter per command, icons, shortcuts and tooltips.</summary>
sealed class CommandViews(CommandRegistry commands, KeyBindings keyBindings)
{
    readonly Dictionary<string, CommandAdapter> _adapters = [];

    public CommandRegistry Commands { get; } = commands;

    public KeyBindings KeyBindings { get; } = keyBindings;

    public CommandAdapter Adapter(string id)
    {
        // A game command is registered again when the game's commands change, so an adapter can hold an old one.
        if (!_adapters.TryGetValue(id, out var adapter) || adapter.Command != Commands.Find(id))
        {
            adapter = new CommandAdapter(Commands.Get(id));
            _adapters[id] = adapter;
        }
        return adapter;
    }

    public KeyGesture? Gesture(string id) => ParseGesture(KeyBindings.ShortcutOf(id));

    /// <summary>A shortcut as a key gesture, or null for none or for one that is not a gesture.</summary>
    public static KeyGesture? ParseGesture(string? shortcut)
    {
        try
        {
            return shortcut == null ? null : KeyGesture.Parse(shortcut);
        }
        catch (ArgumentException)
        {
            return null;
        }
    }

    /// <summary>
    /// A tip that names a command's key as the bindings give it, such as "Save (Ctrl+S)", or the text alone when the
    /// command has no key, so a rebinding shows in the tip.
    /// </summary>
    public static string Tip(KeyBindings keyBindings, string text, string commandId) =>
        keyBindings.ShortcutOf(commandId) is { } key ? $"{text} ({key})" : text;

    /// <summary>An editor tab's Save button, which saves the tab's document, with Save's key in its tip.</summary>
    public static Button SaveButton(EditorShell shell, IGraphEditor editor)
    {
        var save = new Button { Content = Icon("save", 16), Classes = { "viewport-tool" }, Focusable = false, Margin = new Thickness(0, 0, 8, 0) };
        ToolTip.SetTip(save, Tip(shell.KeyBindings, "Save", EditorCommands.Save));
        save.Click += (_, _) => shell.SaveGraph(editor);
        return save;
    }

    public string Tooltip(Command command)
    {
        var shortcut = KeyBindings.Describe(command.Id);
        var title = shortcut == null ? command.Label : $"{command.Label} ({shortcut})";
        return command.Description == null ? title : $"{title}\n{command.Description}";
    }

    public static PathIcon? Icon(string? key, double size)
    {
        if (key == null || Application.Current?.TryGetResource($"Icon.{key}", null, out var resource) != true || resource is not Geometry geometry)
        {
            return null;
        }
        return new PathIcon { Data = geometry, Width = size, Height = size };
    }

    /// <summary>
    /// Adds a menu's entries to a menu's items (see <see cref="MenuEntry"/>): a command as <see cref="MenuItem"/> makes
    /// it, a line for a separator, and a menu under a label with its own entries. An entry whose command the registry
    /// no longer has, as a game's command after a reload, is left out.
    /// </summary>
    public void AddEntries(ItemCollection items, IEnumerable<MenuEntry> entries, List<Action> unsubscribe)
    {
        foreach (var entry in entries)
        {
            switch (entry)
            {
                case MenuCommand command when Commands.Find(command.Command) != null:
                    items.Add(MenuItem(command.Command, unsubscribe));
                    break;
                case MenuSeparator:
                    items.Add(new Separator());
                    break;
                case Submenu submenu:
                    var item = new MenuItem { Header = submenu.Label, Icon = Icon(submenu.Icon, 16) };
                    AddEntries(item.Items, submenu.Entries, unsubscribe);
                    items.Add(item);
                    break;
            }
        }
    }

    /// <summary>
    /// Fills a menu's items from its entries as the menu opens, with each command's state then: for a menu that a view
    /// makes many times, which must leave nothing listening to the commands. <paramref name="before"/> runs before a
    /// command does, as to select what the menu was opened on.
    /// </summary>
    public static void Fill(CommandRegistry commands, ItemCollection items, IEnumerable<MenuEntry> entries, Action? before = null)
    {
        foreach (var entry in entries)
        {
            switch (entry)
            {
                case MenuCommand { Command: var id } when commands.Find(id) is { } command:
                    var item = new MenuItem { Header = command.Label, Icon = Icon(command.Icon, 16), IsEnabled = command.CanExecute };
                    if (command.IsToggle)
                    {
                        item.ToggleType = MenuItemToggleType.CheckBox;
                        item.IsChecked = command.IsChecked;
                    }
                    item.Click += (_, _) =>
                    {
                        before?.Invoke();
                        command.Execute();
                    };
                    ToolTip.SetTip(item, command.Description);
                    items.Add(item);
                    break;
                case MenuSeparator:
                    items.Add(new Separator());
                    break;
                case Submenu submenu:
                    var parent = new MenuItem { Header = submenu.Label, Icon = Icon(submenu.Icon, 16) };
                    Fill(commands, parent.Items, submenu.Entries, before);
                    items.Add(parent);
                    break;
            }
        }
    }

    /// <summary>A flyout of a menu's entries, for a button.</summary>
    public MenuFlyout Flyout(IEnumerable<MenuEntry> entries, List<Action> unsubscribe)
    {
        var menu = new MenuFlyout();
        AddEntries(menu.Items, entries, unsubscribe);
        return menu;
    }

    /// <summary>A menu item that runs a command, with its icon, shortcut and check mark, and its description as a tooltip.</summary>
    public MenuItem MenuItem(string id, List<Action> unsubscribe)
    {
        var command = Commands.Get(id);
        var item = new MenuItem
        {
            Header = command.Label,
            Icon = Icon(command.Icon, 16),
            Command = Adapter(id),
            InputGesture = Gesture(id),
        };
        if (command.Description != null)
        {
            ToolTip.SetTip(item, command.Description);
        }
        if (command.IsToggle)
        {
            item.ToggleType = MenuItemToggleType.CheckBox;
            void Update() => item.IsChecked = command.IsChecked;
            Update();
            command.Changed += Update;
            unsubscribe.Add(() => command.Changed -= Update);
        }
        return item;
    }
}
