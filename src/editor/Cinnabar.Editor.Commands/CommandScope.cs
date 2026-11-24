namespace Cinnabar.Editor.Commands;

/// <summary>
/// A part of the editor that gives some commands a meaning of its own, such as a graph canvas, for which Delete deletes
/// nodes (see docs/editor/shell-and-panels.md#commands). The registry asks the focused scope first, then its other
/// scopes in order, and runs a command's own action only when none of them takes the command.
/// </summary>
public interface ICommandScope
{
    /// <summary>
    /// What the scope does for a command, or null when the command is not the scope's, which leaves it to the next
    /// scope. A scope that takes a command decides it: one that cannot run it now stops it, so Delete in a graph with
    /// nothing selected deletes nothing, not the selected entities.
    /// </summary>
    ScopedCommand? Handler(string commandId);
}

/// <summary>A scope's action for a command, and when it can run, which is always without <paramref name="CanRun"/>.</summary>
public sealed record ScopedCommand(Action Run, Func<bool>? CanRun = null)
{
    public bool CanExecute => CanRun?.Invoke() ?? true;

    /// <summary>Another command in a scope's place, as Delete in the content browser deletes the selected assets.</summary>
    public static ScopedCommand Of(Command command) => new(() => command.Execute(), () => command.CanExecute);

    /// <summary>A command that the scope takes and that never runs in it, so it does not reach the next scope.</summary>
    public static readonly ScopedCommand Never = new(() => { }, () => false);

    /// <summary>
    /// A ladder, as Esc cancels a drag before it ends a pick: the first rung whose check holds runs, and the command
    /// can run while any rung's does. The checks change nothing, since views ask whether the command can run.
    /// </summary>
    public static ScopedCommand FirstOf(params (Func<bool> When, Action Run)[] rungs) =>
        new(() => Array.Find(rungs, r => r.When()).Run?.Invoke(), () => Array.Exists(rungs, r => r.When()));
}
