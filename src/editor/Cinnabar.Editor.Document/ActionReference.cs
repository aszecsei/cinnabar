namespace Cinnabar.Editor.Document;

/// <summary>
/// A decision's action reference, <c>&lt;name&gt;(&lt;argument&gt; = &lt;value&gt;, ...)</c> or <c>&lt;name&gt;</c>, split as the cooker
/// splits it (see docs/content/kinds/decisions.md#action-references): each value is a constant, a key's name or
/// <c>self</c>, as the text writes it.
/// </summary>
public sealed record ActionReference(string Name, IReadOnlyList<(string Name, string Value)> Arguments)
{
    /// <summary>Reads a reference, or null for text that the cooker would not read as one.</summary>
    public static ActionReference? Parse(string text)
    {
        text = text.Trim();
        var open = text.IndexOf('(');
        var name = (open < 0 ? text : text[..open]).Trim();
        if (!MaterialFile.IsIdentifier(name) || (open >= 0 && !text.EndsWith(')')))
        {
            return null;
        }
        if (open < 0)
        {
            return new ActionReference(name, []);
        }
        if (Split(text[(open + 1)..^1]) is not { } parts)
        {
            return null;
        }
        var arguments = new List<(string, string)>();
        foreach (var part in parts)
        {
            var at = part.IndexOf('=');
            if (at < 0 || !MaterialFile.IsIdentifier(part[..at].Trim()) || part[(at + 1)..].Trim().Length == 0)
            {
                return null;
            }
            arguments.Add((part[..at].Trim(), part[(at + 1)..].Trim()));
        }
        return new ActionReference(name, arguments);
    }

    /// <summary>The reference as the file writes it, without parentheses when it has no arguments.</summary>
    public string Write() =>
        Arguments.Count == 0 ? Name : $"{Name}({string.Join(", ", Arguments.Select(a => $"{a.Name} = {a.Value}"))})";

    /// <summary>An argument's value, or null without it.</summary>
    public string? Get(string name) => Arguments.FirstOrDefault(a => a.Name == name) is { Name: not null } a ? a.Value : null;

    /// <summary>The reference with an argument set, in its place or after the others, or with null or "", removed.</summary>
    public ActionReference With(string name, string? value)
    {
        var arguments = Arguments.ToList();
        var at = arguments.FindIndex(a => a.Name == name);
        if (string.IsNullOrWhiteSpace(value))
        {
            if (at >= 0)
            {
                arguments.RemoveAt(at);
            }
        }
        else if (at >= 0)
        {
            arguments[at] = (name, value.Trim());
        }
        else
        {
            arguments.Add((name, value.Trim()));
        }
        return this with { Arguments = arguments };
    }

    // A list split at its top-level commas, keeping [x, y, z] and quoted strings whole, or null when a bracket or a
    // quote is not closed.
    static List<string>? Split(string text)
    {
        var parts = new List<string>();
        var (depth, start, quoted) = (0, 0, false);
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            switch (c)
            {
                case '\\' when quoted:
                    i++;
                    break;
                case '"':
                    quoted = !quoted;
                    break;
                case '[' when !quoted:
                    depth++;
                    break;
                case ']' when !quoted:
                    depth--;
                    break;
                case ',' when !quoted && depth == 0:
                    parts.Add(text[start..i].Trim());
                    start = i + 1;
                    break;
            }
        }
        if (quoted || depth != 0)
        {
            return null;
        }
        if (text[start..].Trim() is var last && (last.Length > 0 || parts.Count > 0))
        {
            parts.Add(last);
        }
        return parts;
    }
}
