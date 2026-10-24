using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace Cinnabar.Editor.Link.Generator;

/// <summary>
/// A small JSON reader for the schema. A generator cannot easily carry System.Text.Json, and the schema needs only
/// objects, arrays, strings and integers. Objects are dictionaries, arrays are lists, and numbers are longs.
/// </summary>
static class Json
{
    public static object Parse(string text)
    {
        var pos = 0;
        var value = Value(text, ref pos);
        SkipSpace(text, ref pos);
        if (pos != text.Length)
        {
            throw new FormatException($"unexpected text at {pos}");
        }
        return value;
    }

    static object Value(string text, ref int pos)
    {
        SkipSpace(text, ref pos);
        if (pos >= text.Length)
        {
            throw new FormatException("unexpected end");
        }
        switch (text[pos])
        {
            case '{':
                var obj = new Dictionary<string, object>();
                pos++;
                SkipSpace(text, ref pos);
                if (text[pos] == '}')
                {
                    pos++;
                    return obj;
                }
                while (true)
                {
                    SkipSpace(text, ref pos);
                    var key = String(text, ref pos);
                    SkipSpace(text, ref pos);
                    Expect(text, ref pos, ':');
                    obj[key] = Value(text, ref pos);
                    SkipSpace(text, ref pos);
                    if (text[pos] == ',')
                    {
                        pos++;
                        continue;
                    }
                    Expect(text, ref pos, '}');
                    return obj;
                }
            case '[':
                var list = new List<object>();
                pos++;
                SkipSpace(text, ref pos);
                if (text[pos] == ']')
                {
                    pos++;
                    return list;
                }
                while (true)
                {
                    list.Add(Value(text, ref pos));
                    SkipSpace(text, ref pos);
                    if (text[pos] == ',')
                    {
                        pos++;
                        continue;
                    }
                    Expect(text, ref pos, ']');
                    return list;
                }
            case '"':
                return String(text, ref pos);
            default:
                var start = pos;
                while (pos < text.Length && (char.IsDigit(text[pos]) || text[pos] == '-'))
                {
                    pos++;
                }
                if (start == pos)
                {
                    throw new FormatException($"unexpected '{text[pos]}' at {pos}");
                }
                return long.Parse(text.Substring(start, pos - start), CultureInfo.InvariantCulture);
        }
    }

    static string String(string text, ref int pos)
    {
        Expect(text, ref pos, '"');
        var sb = new StringBuilder();
        while (text[pos] != '"')
        {
            if (text[pos] == '\\')
            {
                pos++;
                sb.Append(text[pos] switch
                {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    var c => c,
                });
            }
            else
            {
                sb.Append(text[pos]);
            }
            pos++;
        }
        pos++;
        return sb.ToString();
    }

    static void Expect(string text, ref int pos, char c)
    {
        if (pos >= text.Length || text[pos] != c)
        {
            throw new FormatException($"expected '{c}' at {pos}");
        }
        pos++;
    }

    static void SkipSpace(string text, ref int pos)
    {
        while (pos < text.Length && char.IsWhiteSpace(text[pos]))
        {
            pos++;
        }
    }
}
