namespace Cinnabar.Editor.Commands;

/// <summary>Every command, by ID. The ribbon, menus, shortcuts and the command palette all run commands from it.</summary>
public sealed class CommandRegistry
{
    readonly Dictionary<string, Command> _commands = [];

    public IEnumerable<Command> All => _commands.Values;

    public T Register<T>(T command) where T : Command
    {
        if (!_commands.TryAdd(command.Id, command))
        {
            throw new InvalidOperationException($"the command {command.Id} is already registered");
        }
        return command;
    }

    /// <summary>Removes a command, as when the game's commands change. Views that hold it find it gone.</summary>
    public bool Unregister(string id) => _commands.Remove(id);

    public Command? Find(string id) => _commands.GetValueOrDefault(id);

    public Command Get(string id) =>
        Find(id) ?? throw new KeyNotFoundException($"no command {id}");

    /// <summary>State that many commands depend on has changed, such as the host's state.</summary>
    public void InvalidateAll()
    {
        foreach (var command in _commands.Values)
        {
            command.Invalidate();
        }
    }
}
