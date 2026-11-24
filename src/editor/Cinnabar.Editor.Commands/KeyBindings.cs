namespace Cinnabar.Editor.Commands;

/// <summary>
/// The shortcut of each command: the user's binding if there is one, or else the command's default. A binding to an
/// empty string removes the shortcut. Gestures are text, such as <c>Ctrl+Shift+P</c>, so this has no UI dependency. A
/// command's shortcut works in the whole window, or only in the scopes that the command names (see
/// <see cref="Command.ShortcutScopes"/>), and a binding changes the key in those scopes. Two commands conflict only when
/// they have the same key in the same scope: the nearest control's binding comes first, so W in the viewport and W in
/// the window are not the same key.
/// </summary>
public sealed class KeyBindings
{
    // The window's shortcuts, as a scope with no name of its own.
    const string Window = "";

    readonly Dictionary<string, string> _shortcuts = [];
    readonly Dictionary<string, IReadOnlyList<string>> _scopes = [];

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
        var owners = new Dictionary<(string Scope, string Gesture), string>();
        foreach (var command in commands.All.OrderBy(c => c.Id, StringComparer.Ordinal))
        {
            var shortcut = overrides.TryGetValue(command.Id, out var bound) ? bound : command.Shortcut;
            if (string.IsNullOrWhiteSpace(shortcut))
            {
                continue;
            }
            var normal = Normalize(shortcut);
            IReadOnlyList<string> scopes = command.ShortcutScopes is { Count: > 0 } named ? named : [Window];
            // A command keeps its key in the scopes where no command before it by ID has the key.
            var kept = new List<string>();
            foreach (var scope in scopes)
            {
                if (owners.TryGetValue((scope, normal), out var owner))
                {
                    var where = scope == Window ? "" : $" {ShortcutScopes.Label(scope)}";
                    warnings.Add($"key bindings: {shortcut}{where} is bound to both {owner} and {command.Id}; {owner} keeps it");
                    continue;
                }
                owners[(scope, normal)] = command.Id;
                kept.Add(scope);
            }
            if (kept.Count == 0)
            {
                continue;
            }
            _shortcuts[command.Id] = shortcut;
            if (kept is not [Window])
            {
                _scopes[command.Id] = kept;
            }
        }
        Warnings = warnings;
    }

    /// <summary>A command's key, in the window or in its scopes, as menus and the command palette show it.</summary>
    public string? ShortcutOf(string commandId) => _shortcuts.GetValueOrDefault(commandId);

    /// <summary>The scopes in which a command's key works, or none for a key of the whole window.</summary>
    public IReadOnlyList<string> ScopesOf(string commandId) => _scopes.GetValueOrDefault(commandId) ?? [];

    /// <summary>A command's key and where it works, for a tooltip, such as <c>W in the viewport</c>, or null for none.</summary>
    public string? Describe(string commandId) => ShortcutOf(commandId) is not { } shortcut
        ? null
        : ScopesOf(commandId) is [] ? shortcut : $"{shortcut} {string.Join(" or ", ScopesOf(commandId).Select(ShortcutScopes.Label))}";

    /// <summary>The shortcuts of the whole window, which the window's key bindings have.</summary>
    public IEnumerable<(string CommandId, string Shortcut)> All =>
        _shortcuts.Where(p => !_scopes.ContainsKey(p.Key)).Select(p => (p.Key, p.Value));

    /// <summary>The shortcuts of a scope, which the key bindings of the scope's control have.</summary>
    public IEnumerable<(string CommandId, string Shortcut)> InScope(string scope) =>
        _scopes.Where(p => p.Value.Contains(scope)).Select(p => (p.Key, _shortcuts[p.Key]));

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
