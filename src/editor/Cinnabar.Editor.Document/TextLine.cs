namespace Cinnabar.Editor.Document;

/// <summary>
/// A line of a text file that the editors keep whole, as the graph files do, and the line ending after it, which is ""
/// for a new line or a last line without one.
/// </summary>
sealed class TextLine(string text, string ending)
{
    public string Text { get; set; } = text;

    public string Ending { get; set; } = ending;

    /// <summary>The line without its comment and the white space around it.</summary>
    public string Code => StripComment(Text).Trim();

    public bool IsBlank => Code.Length == 0;

    /// <summary>Replaces the line's code, keeping its indent and its comment.</summary>
    public void SetCode(string code)
    {
        var stripped = StripComment(Text);
        var indent = stripped[..(stripped.Length - stripped.TrimStart().Length)];
        var kept = stripped.TrimEnd().Length;
        Text = indent + code + Text[kept..];
    }

    /// <summary>The text after the line's first <c>=</c>, or "" without one.</summary>
    public string Value => Code.IndexOf('=') is >= 0 and var at ? Code[(at + 1)..].Trim() : "";

    /// <summary>The text before the line's first <c>=</c>.</summary>
    public string Key => Code.IndexOf('=') is >= 0 and var at ? Code[..at].Trim() : Code;

    /// <summary>Replaces what follows the line's first <c>=</c>, keeping the spaces after it.</summary>
    public void SetValue(string value)
    {
        var code = Code;
        var at = code.IndexOf('=');
        if (at < 0)
        {
            SetCode($"{code} = {value}");
            return;
        }
        var after = code[(at + 1)..];
        var spaces = after.Length == 0 ? " " : after[..(after.Length - after.TrimStart().Length)];
        SetCode(code[..(at + 1)] + spaces + value);
    }

    /// <summary>A line without a <c>#</c> and what follows it, outside of quotes.</summary>
    public static string StripComment(string line)
    {
        var quoted = false;
        for (var i = 0; i < line.Length; i++)
        {
            switch (line[i])
            {
                case '\\' when quoted:
                    // The escaped character does not end the string.
                    i++;
                    break;
                case '"':
                    quoted = !quoted;
                    break;
                case '#' when !quoted:
                    return line[..i];
            }
        }
        return line;
    }

    /// <summary>A text's lines, each with its own ending, so the text writes back as it was.</summary>
    public static IEnumerable<TextLine> Split(string text)
    {
        var start = 0;
        while (start < text.Length)
        {
            var end = text.IndexOf('\n', start);
            if (end < 0)
            {
                yield return new TextLine(text[start..], "");
                yield break;
            }
            var crlf = end > start && text[end - 1] == '\r';
            yield return new TextLine(text[start..(crlf ? end - 1 : end)], crlf ? "\r\n" : "\n");
            start = end + 1;
        }
    }
}
