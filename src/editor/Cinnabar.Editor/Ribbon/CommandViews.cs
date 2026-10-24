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

/// <summary>What views of commands share: one adapter per command, icons, shortcuts and tooltips.</summary>
sealed class CommandViews(CommandRegistry commands, KeyBindings keyBindings)
{
    readonly Dictionary<string, CommandAdapter> _adapters = [];

    public CommandRegistry Commands { get; } = commands;

    public KeyBindings KeyBindings { get; } = keyBindings;

    public CommandAdapter Adapter(string id)
    {
        if (!_adapters.TryGetValue(id, out var adapter))
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
