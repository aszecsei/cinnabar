namespace Cinnabar.Editor.Commands.Ribbon;

/// <summary>
/// The ribbon as data: tabs, groups in each tab and items in each group (see docs/editor.md#ribbon). Every item names
/// commands by ID, so the ribbon has no logic of its own.
/// </summary>
public sealed record RibbonLayout(IReadOnlyList<RibbonCategory> Categories, IReadOnlyList<RibbonTab> Tabs)
{
    /// <summary>The problems that would make the layout show the wrong thing. An empty list means it is valid.</summary>
    public IReadOnlyList<string> Validate(CommandRegistry commands)
    {
        var errors = new List<string>();
        var categories = new HashSet<string>();
        foreach (var category in Categories)
        {
            if (!categories.Add(category.Id))
            {
                errors.Add($"ribbon: category {category.Id} is defined twice");
            }
        }
        var tabs = new HashSet<string>();
        foreach (var tab in Tabs)
        {
            if (!tabs.Add(tab.Id))
            {
                errors.Add($"ribbon: tab {tab.Id} is defined twice");
            }
            if (tab.Category != null && !categories.Contains(tab.Category))
            {
                errors.Add($"ribbon: tab {tab.Id} names the unknown category {tab.Category}");
            }
            foreach (var group in tab.Groups)
            {
                foreach (var item in group.Items)
                {
                    errors.AddRange(item.Validate(commands).Select(e => $"ribbon: {tab.Id}/{group.Label}: {e}"));
                }
            }
        }
        return errors;
    }

    /// <summary>The tabs to show: every tab without a context, and contextual tabs whose context is active.</summary>
    public IEnumerable<RibbonTab> VisibleTabs(EditorContext context) =>
        Tabs.Where(t => t.Context == null || context.IsActive(t.Context));
}

/// <summary>A named, colored band over the tabs that belong to it, such as Art or Design.</summary>
public sealed record RibbonCategory(string Id, string Label, string Color);

public sealed record RibbonTab(string Id, string Label, IReadOnlyList<RibbonGroup> Groups)
{
    public string? Category { get; init; }

    /// <summary>The context that shows this tab, or null for a tab that always shows.</summary>
    public string? Context { get; init; }
}

public sealed record RibbonGroup(string Label, IReadOnlyList<RibbonItem> Items);

public abstract record RibbonItem
{
    internal abstract IEnumerable<string> Validate(CommandRegistry commands);

    private protected static IEnumerable<string> Missing(CommandRegistry commands, IEnumerable<string> ids) =>
        ids.Where(id => commands.Find(id) == null).Select(id => $"there is no command {id}");
}

/// <summary>A button with a large icon over its label. A toggle command shows as a toggle button.</summary>
public sealed record LargeButton(string Command) : RibbonItem
{
    internal override IEnumerable<string> Validate(CommandRegistry commands) => Missing(commands, [Command]);
}

/// <summary>Up to three small buttons, one over another.</summary>
public sealed record SmallStack(IReadOnlyList<string> Commands) : RibbonItem
{
    public const int MaxCommands = 3;

    internal override IEnumerable<string> Validate(CommandRegistry commands)
    {
        if (Commands.Count is 0 or > MaxCommands)
        {
            yield return $"a small stack holds 1 to {MaxCommands} commands, not {Commands.Count}";
        }
        foreach (var error in Missing(commands, Commands))
        {
            yield return error;
        }
    }
}

/// <summary>A large button that runs its command, with an arrow that opens a menu of more commands.</summary>
public sealed record SplitButton(string Command, IReadOnlyList<string> Menu) : RibbonItem
{
    internal override IEnumerable<string> Validate(CommandRegistry commands) => Missing(commands, Menu.Prepend(Command));
}

/// <summary>A large button that only opens a menu of commands.</summary>
public sealed record Dropdown(string Label, string? Icon, IReadOnlyList<string> Menu) : RibbonItem
{
    internal override IEnumerable<string> Validate(CommandRegistry commands)
    {
        if (Menu.Count == 0)
        {
            yield return $"the dropdown {Label} has no commands";
        }
        foreach (var error in Missing(commands, Menu))
        {
            yield return error;
        }
    }
}

/// <summary>A labeled combo box for a <see cref="ChoiceCommand"/>.</summary>
public sealed record ComboBox(string Command) : RibbonItem
{
    internal override IEnumerable<string> Validate(CommandRegistry commands) => commands.Find(Command) switch
    {
        null => [$"there is no command {Command}"],
        ChoiceCommand => [],
        _ => [$"the combo box {Command} needs a choice command"],
    };
}
