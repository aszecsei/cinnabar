namespace Cinnabar.Editor.Commands;

/// <summary>
/// Every command, by ID. The ribbon, menus, shortcuts and the command palette all run commands from it. A command that
/// a scope takes runs the scope's action (see <see cref="ICommandScope"/>): the focused scope's first, then those of
/// <see cref="AddScope"/> in order.
/// <para>
/// Owners of state that commands depend on raise only their own change events. The registry observes them (see
/// <see cref="InvalidateOn"/>) and asks every command again at most once per dispatcher turn.
/// </para>
/// </summary>
public sealed class CommandRegistry
{
    readonly Dictionary<string, Command> _commands = [];
    readonly List<ICommandScope> _scopes = [];
    readonly Action<Action> _post;
    ICommandScope? _focused;
    RefreshState _refresh = RefreshState.Idle;

    enum RefreshState
    {
        /// <summary>No refresh waits.</summary>
        Idle,
        /// <summary>A refresh is posted and has not run.</summary>
        Queued,
        /// <summary>The owner closed: nothing is posted again, and a refresh that waits does nothing.</summary>
        Closed,
    }

    /// <param name="post">
    /// Runs an action on a later dispatcher turn, such as the UI thread's post. The default runs it at once, so each
    /// request refreshes the commands straight away.
    /// </param>
    public CommandRegistry(Action<Action>? post = null)
    {
        _post = post ?? (action => action());
    }

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

    /// <summary>
    /// Observes an owner's change event: <paramref name="subscribe"/> gets the handler to add, and each raise requests a
    /// refresh, as <c>InvalidateOn(h =&gt; Layout.Changed += h)</c>.
    /// </summary>
    public void InvalidateOn(Action<Action> subscribe) => subscribe(RequestInvalidate);

    /// <summary>
    /// State that many commands depend on has changed. Views ask the commands again on a later dispatcher turn, once for
    /// all the requests before it.
    /// </summary>
    public void RequestInvalidate()
    {
        if (_refresh == RefreshState.Idle)
        {
            _refresh = RefreshState.Queued;
            _post(Flush);
        }
    }

    /// <summary>Runs the refresh that waits, if one does: as the dispatcher does, or a test that has no dispatcher.</summary>
    public void Flush()
    {
        if (_refresh == RefreshState.Queued)
        {
            _refresh = RefreshState.Idle;
            InvalidateAll();
        }
    }

    /// <summary>
    /// The owner closed: a refresh that waits does nothing, no request posts another, and a change of scope refreshes
    /// nothing, since the commands read an owner that is gone.
    /// </summary>
    public void Close() => _refresh = RefreshState.Closed;

    void InvalidateAll()
    {
        if (_refresh == RefreshState.Closed)
        {
            return;
        }
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
