using System.Text;

namespace Cinnabar.Editor.Document;

/// <summary>Strings in double quotes, as the scene and material text files write them: quote, backslash, newline and tab are escaped.</summary>
public static class TextQuote
{
    public static string Quote(string text)
    {
        var b = new StringBuilder("\"");
        foreach (var c in text)
        {
            b.Append(c switch
            {
                '"' => "\\\"",
                '\\' => "\\\\",
                '\n' => "\\n",
                '\t' => "\\t",
                _ => c.ToString(),
            });
        }
        return b.Append('"').ToString();
    }

    public static string? Unquote(string text)
    {
        if (text.Length < 2 || text[0] != '"' || text[^1] != '"')
        {
            return null;
        }
        var b = new StringBuilder();
        for (var i = 1; i < text.Length - 1; i++)
        {
            var c = text[i];
            if (c == '"')
            {
                return null;
            }
            if (c != '\\')
            {
                b.Append(c);
                continue;
            }
            if (++i == text.Length - 1)
            {
                return null;
            }
            switch (text[i])
            {
                case '"' or '\\':
                    b.Append(text[i]);
                    break;
                case 'n':
                    b.Append('\n');
                    break;
                case 't':
                    b.Append('\t');
                    break;
                default:
                    return null;
            }
        }
        return b.ToString();
    }
}
