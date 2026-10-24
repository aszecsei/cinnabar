namespace Cinnabar.Editor.Commands;

/// <summary>
/// The shortcut of each command: the user's binding if there is one, or else the command's default. A binding to an
/// empty string removes the shortcut. Gestures are text, such as <c>Ctrl+Shift+P</c>, so this has no UI dependency.
/// </summary>
public sealed class KeyBindings
{
    readonly Dictionary<string, string> _shortcuts = [];

    public IReadOnlyList<string> Warnings { get; }

    public KeyBindings(CommandRegistry commands, IReadOnlyDictionary<string, string> overrides)
    {
        var warnings = new List<string>();
        foreach (var (id, shortcut) in overrides)
        {
            if (commands.Find(id) == null)
            {
                warnings.Add($"key bindings: there is no command {id}");
            }
        }
        var owners = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var command in commands.All.OrderBy(c => c.Id, StringComparer.Ordinal))
        {
            var shortcut = overrides.TryGetValue(command.Id, out var bound) ? bound : command.Shortcut;
            if (string.IsNullOrWhiteSpace(shortcut))
            {
                continue;
            }
            var normal = Normalize(shortcut);
            if (owners.TryGetValue(normal, out var owner))
            {
                warnings.Add($"key bindings: {shortcut} is bound to both {owner} and {command.Id}; {owner} keeps it");
                continue;
            }
            owners[normal] = command.Id;
            _shortcuts[command.Id] = shortcut;
        }
        Warnings = warnings;
    }

    public string? ShortcutOf(string commandId) => _shortcuts.GetValueOrDefault(commandId);

    public IEnumerable<(string CommandId, string Shortcut)> All => _shortcuts.Select(p => (p.Key, p.Value));

    /// <summary>The same gesture written differently, such as <c>shift+ctrl+p</c> and <c>Ctrl+Shift+P</c>, normalizes the same.</summary>
    public static string Normalize(string gesture)
    {
        var parts = gesture.Split('+', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .Select(p => p.ToLowerInvariant() switch
            {
                "control" => "ctrl",
                var other => other,
            })
            .ToList();
        if (parts.Count == 0)
        {
            return "";
        }
        var key = parts[^1];
        var modifiers = parts.Take(parts.Count - 1).Order(StringComparer.Ordinal);
        return string.Join('+', modifiers.Append(key));
    }
}
