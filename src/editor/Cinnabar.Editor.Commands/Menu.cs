namespace Cinnabar.Editor.Commands;

/// <summary>
/// An entry of a menu of commands (see docs/editor/shell-and-panels.md#commands): a command by its ID, a line between
/// groups, or a menu under a label. The ribbon's dropdowns and split buttons and the Add menu are lists of these, so
/// a menu is data, as the ribbon is. A command's ID converts to its entry, so a list of IDs is a menu.
/// </summary>
public abstract record MenuEntry
{
    public static implicit operator MenuEntry(string command) => new MenuCommand(command);

    /// <summary>Every command that the entries name, at any depth.</summary>
    public static IEnumerable<string> Commands(IEnumerable<MenuEntry> entries) => entries.SelectMany(e => e switch
    {
        MenuCommand command => [command.Command],
        Submenu submenu => Commands(submenu.Entries),
        _ => Enumerable.Empty<string>(),
    });

    /// <summary>The problems of a menu: a command that the registry does not have, or a menu under a label with nothing in it.</summary>
    public static IEnumerable<string> Validate(CommandRegistry commands, IEnumerable<MenuEntry> entries)
    {
        foreach (var entry in entries)
        {
            switch (entry)
            {
                case MenuCommand command when commands.Find(command.Command) == null:
                    yield return $"there is no command {command.Command}";
                    break;
                case Submenu { Entries.Count: 0 } empty:
                    yield return $"the menu {empty.Label} has no commands";
                    break;
                case Submenu submenu:
                    foreach (var error in Validate(commands, submenu.Entries))
                    {
                        yield return error;
                    }
                    break;
            }
        }
    }
}

/// <summary>A command, which shows with its label, icon, shortcut and check.</summary>
public sealed record MenuCommand(string Command) : MenuEntry;

/// <summary>A line between two groups of entries.</summary>
public sealed record MenuSeparator : MenuEntry;

/// <summary>A menu under a label, such as the lights in the Add menu.</summary>
public sealed record Submenu(string Label, string? Icon, IReadOnlyList<MenuEntry> Entries) : MenuEntry;
