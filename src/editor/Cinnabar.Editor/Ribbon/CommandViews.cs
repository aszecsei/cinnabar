using System.Windows.Input;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Cinnabar.Editor.Commands;

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
/// Shift+F5 work during play. Nor does one that a text box uses, while a text box has the focus: a window's key bindings
/// come before the focused control sees the key, so Delete in a search box would delete the selected entities.
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

    public KeyGesture? Gesture(string id)
    {
        var shortcut = KeyBindings.ShortcutOf(id);
        try
        {
            return shortcut == null ? null : KeyGesture.Parse(shortcut);
        }
        catch (ArgumentException)
        {
            return null;
        }
    }

    public string Tooltip(Command command)
    {
        var shortcut = KeyBindings.ShortcutOf(command.Id);
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

    /// <summary>A menu item that runs a command, with its icon, shortcut and check mark.</summary>
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
