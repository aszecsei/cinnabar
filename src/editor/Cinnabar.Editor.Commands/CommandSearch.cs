namespace Cinnabar.Editor.Commands;

/// <summary>Finds commands for the command palette.</summary>
public static class CommandSearch
{
    /// <summary>
    /// The commands whose label or ID contains every word of the query, best first: a label that starts with the
    /// query, then a word of the label that starts with it, then any other match. Ties keep alphabetical order.
    /// </summary>
    public static IReadOnlyList<Command> Find(CommandRegistry commands, string query)
    {
        var words = query.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        var trimmed = query.Trim();
        return commands.All
            .Where(c => words.All(w => c.Label.Contains(w, StringComparison.OrdinalIgnoreCase)
                || c.Id.Contains(w, StringComparison.OrdinalIgnoreCase)))
            .OrderBy(c => Rank(c, trimmed))
            .ThenBy(c => c.Label, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    static int Rank(Command command, string query)
    {
        if (query.Length == 0 || command.Label.StartsWith(query, StringComparison.OrdinalIgnoreCase))
        {
            return 0;
        }
        var labelWords = command.Label.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return labelWords.Any(w => w.StartsWith(query, StringComparison.OrdinalIgnoreCase)) ? 1 : 2;
    }
}
