namespace Cinnabar.Editor.Document;

/// <summary>
/// A line of a text file that the editors keep whole, as the graph files do, and the line ending after it, which is ""
/// for a new line or a last line without one. With <paramref name="hashInWord"/>, as a cutscene's lines are, a <c>#</c>
/// inside a word is not a comment, so an instance's path such as <c>@&lt;guid&gt;/&lt;instance&gt;#&lt;entity&gt;</c> stays whole.
/// </summary>
sealed class TextLine(string text, string ending, bool hashInWord = false)
{
    public string Text { get; set; } = text;

    public string Ending { get; set; } = ending;

    /// <summary>Whether a <c>#</c> starts a comment only at the line's start or after a space or a tab.</summary>
    public bool HashInWord { get; } = hashInWord;

    /// <summary>The line without its comment and the white space around it.</summary>
    public string Code => StripComment(Text, HashInWord).Trim();

    public bool IsBlank => Code.Length == 0;

    /// <summary>The spaces and tabs that the line starts with.</summary>
    public string Indent => Text[..(Text.Length - Text.TrimStart().Length)];

    /// <summary>Replaces the line's code, keeping its indent and its comment.</summary>
    public void SetCode(string code)
    {
        var stripped = StripComment(Text, HashInWord);
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

    /// <summary>
    /// A line without a <c>#</c> and what follows it, outside of quotes. With <paramref name="hashInWord"/>, a <c>#</c>
    /// inside a word, after a character that is not a space or a tab, is not a comment.
    /// </summary>
    public static string StripComment(string line, bool hashInWord = false)
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
                case '#' when !quoted && (!hashInWord || i == 0 || line[i - 1] is ' ' or '\t'):
                    return line[..i];
            }
        }
        return line;
    }

    /// <summary>A text's lines, each with its own ending, so the text writes back as it was.</summary>
    public static IEnumerable<TextLine> Split(string text, bool hashInWord = false)
    {
        var start = 0;
        while (start < text.Length)
        {
            var end = text.IndexOf('\n', start);
            if (end < 0)
            {
                yield return new TextLine(text[start..], "", hashInWord);
                yield break;
            }
            var crlf = end > start && text[end - 1] == '\r';
            yield return new TextLine(text[start..(crlf ? end - 1 : end)], crlf ? "\r\n" : "\n", hashInWord);
            start = end + 1;
        }
    }
}
