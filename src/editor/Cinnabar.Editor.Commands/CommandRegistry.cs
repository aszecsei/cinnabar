namespace Cinnabar.Editor.Commands;

/// <summary>
/// Every command, by ID. The ribbon, menus, shortcuts and the command palette all run commands from it. A command that
/// a scope takes runs the scope's action (see <see cref="ICommandScope"/>): the focused scope's first, then those of
/// <see cref="AddScope"/> in order.
/// </summary>
public sealed class CommandRegistry
{
    readonly Dictionary<string, Command> _commands = [];
    readonly List<ICommandScope> _scopes = [];
    ICommandScope? _focused;

    public IEnumerable<Command> All => _commands.Values;

    public T Register<T>(T command) where T : Command
    {
        if (!_commands.TryAdd(command.Id, command))
        {
            throw new InvalidOperationException($"the command {command.Id} is already registered");
        }
        command.Registry = this;
        return command;
    }

    /// <summary>Removes a command, as when the game's commands change. Views that hold it find it gone.</summary>
    public bool Unregister(string id)
    {
        if (!_commands.Remove(id, out var command))
        {
            return false;
        }
        command.Registry = null;
        return true;
    }

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

    /// <summary>The scope that has the keyboard, which comes before every other: a panel or a canvas, or none.</summary>
    public ICommandScope? Focused => _focused;

    /// <summary>A scope that comes after the focused one, and after those added before it, such as the active editor's.</summary>
    public void AddScope(ICommandScope scope) => _scopes.Add(scope);

    /// <summary>The one writer of <see cref="Focused"/>, which a scope's view calls as the keyboard moves into it.</summary>
    public void Focus(ICommandScope scope) => SetFocused(scope);

    /// <summary>
    /// A scope lost the keyboard: no scope has it, unless another took it first, since a scope that the keyboard moves
    /// into says so before the one it left does.
    /// </summary>
    public void Leave(ICommandScope scope)
    {
        if (_focused == scope)
        {
            SetFocused(null);
        }
    }

    void SetFocused(ICommandScope? scope)
    {
        if (_focused != scope)
        {
            _focused = scope;
            // What the commands do, and whether they can, may have changed with the scope.
            InvalidateAll();
        }
    }

    /// <summary>
    /// What a scope can run may have changed, as when its selection changes: views ask the commands again while the
    /// scope is in the chain, so the ribbon's Delete enables with the graph's selection.
    /// </summary>
    public void Refresh(ICommandScope scope)
    {
        if (scope == _focused || _scopes.Contains(scope))
        {
            InvalidateAll();
        }
    }

    /// <summary>The action of the first scope that takes a command, or null when none does and the command's own runs.</summary>
    public ScopedCommand? HandlerOf(string commandId)
    {
        if (_focused?.Handler(commandId) is { } focused)
        {
            return focused;
        }
        foreach (var scope in _scopes)
        {
            if (scope.Handler(commandId) is { } handler)
            {
                return handler;
            }
        }
        return null;
    }
}
