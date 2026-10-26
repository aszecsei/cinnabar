namespace Cinnabar.Editor.Commands;

/// <summary>
/// Something the user can do: from the ribbon, a menu, a shortcut or the command palette (see
/// docs/editor/shell-and-panels.md#commands). A command whose <see cref="IsCheckedWhen"/> is set is a toggle.
/// </summary>
public class Command
{
    readonly Action _execute;

    public Command(string id, string label, Action execute)
    {
        Id = id;
        Label = label;
        _execute = execute;
    }

    /// <summary>A dotted name such as <c>host.restart</c>. Layouts and key bindings refer to commands by ID.</summary>
    public string Id { get; }

    public string Label { get; }

    /// <summary>A sentence for tooltips and the command palette.</summary>
    public string? Description { get; init; }

    /// <summary>The key of the command's icon in the editor's icon set.</summary>
    public string? Icon { get; init; }

    /// <summary>The default key gesture, such as <c>Ctrl+Shift+P</c>. Key bindings can replace it.</summary>
    public string? Shortcut { get; init; }

    public Func<bool>? CanExecuteWhen { get; init; }

    public Func<bool>? IsCheckedWhen { get; init; }

    public bool IsToggle => IsCheckedWhen != null;

    public bool CanExecute => CanExecuteWhen?.Invoke() ?? true;

    public bool IsChecked => IsCheckedWhen?.Invoke() ?? false;

    /// <summary>The command's state may have changed. Views ask <see cref="CanExecute"/> and <see cref="IsChecked"/> again.</summary>
    public event Action? Changed;

    /// <summary>Runs the command if it can run, and returns whether it ran.</summary>
    public bool Execute()
    {
        if (!CanExecute)
        {
            return false;
        }
        _execute();
        Invalidate();
        return true;
    }

    public void Invalidate() => Changed?.Invoke();
}

/// <summary>A command that picks one of a list of options, shown as a combo box.</summary>
public sealed class ChoiceCommand : Command
{
    readonly Func<string> _selected;
    readonly Action<string> _select;

    public ChoiceCommand(string id, string label, IReadOnlyList<string> options, Func<string> selected, Action<string> select)
        : base(id, label, () => { })
    {
        if (options.Count == 0)
        {
            throw new ArgumentException($"{id} has no options", nameof(options));
        }
        Options = options;
        _selected = selected;
        _select = select;
    }

    public IReadOnlyList<string> Options { get; }

    public string Selected => _selected();

    public void Select(string option)
    {
        if (!Options.Contains(option))
        {
            throw new ArgumentException($"{option} is not an option of {Id}", nameof(option));
        }
        if (CanExecute && option != Selected)
        {
            _select(option);
            Invalidate();
        }
    }
}
