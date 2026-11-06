using System.Globalization;
using System.Text;

namespace Cinnabar.Editor.Document;

// The scanner and the walk to nodes, as lib/engine/asset/format/ui_text.odin has them. They agree with it on where each
// element starts and ends and which elements are nodes, which the files in lib/engine/asset/format/testdata/ui pin.
public sealed partial class UiFile
{
    int _pos;

    void Scan()
    {
        _nodes.Clear();
        _styles.Clear();
        _top.Clear();
        Root = null;
        var starts = new List<int> { 0 };
        for (var i = 0; i < Text.Length; i++)
        {
            if (Text[i] == '\n')
            {
                starts.Add(i + 1);
            }
        }
        _lineStarts = [.. starts];
        var (line, _) = Header(Text);
        HeaderLine = line;
        _pos = line < _lineStarts.Length ? _lineStarts[line] : Text.Length;
        while (true)
        {
            SkipSpace();
            if (Done)
            {
                break;
            }
            if (At("<!--"))
            {
                SkipComment();
                continue;
            }
            if (!At("<"))
            {
                while (!Done && Text[_pos] != '<')
                {
                    _pos++;
                }
                continue;
            }
            var e = ScanElement(null);
            _top.Add(e);
            if (Root == null && e.Name == "ui")
            {
                Root = e;
            }
        }
        if (Root == null)
        {
            return;
        }
        foreach (var child in Root.Children)
        {
            if (child.Name == "style")
            {
                _styles.Add(new UiStyle(child));
            }
        }
        var root = AddNode("ui", Root, -1, false, false);
        foreach (var child in Root.Children)
        {
            if (child.Name != "style")
            {
                CompileNode(child, root, 1, false);
            }
        }
    }

    bool Done => _pos >= Text.Length;

    bool At(string prefix) => string.CompareOrdinal(Text, _pos, prefix, 0, prefix.Length) == 0;

    static bool IsSpace(char c) => c is ' ' or '\t' or '\n' or '\r' or '\v' or '\f';

    static bool IsNameChar(char c) => c is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9' or '_' or '-' or ':';

    void SkipSpace()
    {
        while (!Done && IsSpace(Text[_pos]))
        {
            _pos++;
        }
    }

    string ScanName()
    {
        var start = _pos;
        while (!Done && IsNameChar(Text[_pos]))
        {
            _pos++;
        }
        return Text[start.._pos];
    }

    void SkipComment()
    {
        var end = Text.IndexOf("-->", _pos + 4, StringComparison.Ordinal);
        _pos = end < 0 ? Text.Length : end + 3;
    }

    UiElement ScanElement(UiElement? parent)
    {
        var start = _pos;
        _pos++;
        var e = new UiElement(ScanName(), start, parent);
        while (true)
        {
            SkipSpace();
            if (Done)
            {
                e.StartTagEnd = e.ContentStart = e.ContentEnd = e.End = Text.Length;
                return e;
            }
            if (At("/>"))
            {
                _pos += 2;
                e.SelfClosing = true;
                e.StartTagEnd = e.ContentStart = e.ContentEnd = e.End = _pos;
                return e;
            }
            if (At(">"))
            {
                _pos++;
                break;
            }
            var nameStart = _pos;
            var name = ScanName();
            if (name == "")
            {
                _pos++;
                continue;
            }
            SkipSpace();
            if (!At("="))
            {
                continue;
            }
            _pos++;
            SkipSpace();
            if (!Done && Text[_pos] is '"' or '\'')
            {
                var quote = Text[_pos];
                var close = Text.IndexOf(quote, _pos + 1);
                if (close < 0)
                {
                    _pos = Text.Length;
                    e.StartTagEnd = e.ContentStart = e.ContentEnd = e.End = Text.Length;
                    return e;
                }
                var raw = Text[(_pos + 1)..close];
                var (decoded, ok) = DecodeEntities(raw);
                e.Attributes.Add(new UiAttribute(name, nameStart, _pos + 1, close, close + 1, quote, ok ? decoded : raw));
                _pos = close + 1;
            }
            else
            {
                var valueStart = _pos;
                while (!Done && !IsSpace(Text[_pos]) && Text[_pos] != '>' && !At("/>"))
                {
                    _pos++;
                }
                e.Attributes.Add(new UiAttribute(name, nameStart, valueStart, _pos, _pos, '\0', Text[valueStart.._pos]));
            }
        }
        e.StartTagEnd = e.ContentStart = _pos;
        var text = new StringBuilder();
        while (true)
        {
            if (Done)
            {
                e.ContentEnd = e.End = Text.Length;
                break;
            }
            if (At("<!--"))
            {
                SkipComment();
                continue;
            }
            if (At("</"))
            {
                e.ContentEnd = _pos;
                _pos += 2;
                ScanName();
                SkipSpace();
                if (At(">"))
                {
                    _pos++;
                }
                e.End = _pos;
                break;
            }
            if (At("<"))
            {
                e.Children.Add(ScanElement(e));
                continue;
            }
            var runStart = _pos;
            while (!Done && Text[_pos] != '<')
            {
                _pos++;
            }
            text.Append(Text, runStart, _pos - runStart).Append(' ');
        }
        var collapsed = Collapse(text.ToString());
        var (value, valid) = DecodeEntities(collapsed);
        e.Text = valid ? value : collapsed;
        return e;
    }

    static string Collapse(string text) => string.Join(' ', text.Split([' ', '\t', '\n', '\r', '\v', '\f'], StringSplitOptions.RemoveEmptyEntries));

    /// <summary>A text with &amp;lt; &amp;gt; &amp;amp; &amp;quot; &amp;apos; and character references decoded, or false if one is not an entity.</summary>
    public static (string Text, bool Ok) DecodeEntities(string text)
    {
        if (!text.Contains('&'))
        {
            return (text, true);
        }
        var b = new StringBuilder();
        for (var i = 0; i < text.Length; i++)
        {
            if (text[i] != '&')
            {
                b.Append(text[i]);
                continue;
            }
            var end = text.IndexOf(';', i);
            if (end < 0)
            {
                return (text, false);
            }
            var entity = text[(i + 1)..end];
            switch (entity)
            {
                case "lt": b.Append('<'); break;
                case "gt": b.Append('>'); break;
                case "amp": b.Append('&'); break;
                case "quot": b.Append('"'); break;
                case "apos": b.Append('\''); break;
                default:
                    var ok = false;
                    ulong code = 0;
                    if (entity.StartsWith("#x", StringComparison.Ordinal))
                    {
                        ok = ulong.TryParse(entity[2..], NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out code);
                    }
                    else if (entity.StartsWith('#'))
                    {
                        ok = ulong.TryParse(entity[1..], NumberStyles.None, CultureInfo.InvariantCulture, out code);
                    }
                    if (!ok || code == 0 || code > 0x10ffff || code is >= 0xd800 and <= 0xdfff)
                    {
                        return (text, false);
                    }
                    b.Append(char.ConvertFromUtf32((int)code));
                    break;
            }
            i = end;
        }
        return (b.ToString(), true);
    }

    int AddNode(string kind, UiElement element, int parent, bool buttonText, bool inTemplate)
    {
        var index = _nodes.Count;
        _nodes.Add(new UiNode(index, kind, element, parent, buttonText, inTemplate));
        if (parent >= 0)
        {
            _nodes[parent].Children.Add(index);
        }
        if (!buttonText)
        {
            element.Node = index;
        }
        return index;
    }

    // CompileNode makes a node of an element and its subtree as compile_node and compile_one do: an element that the
    // cooker refuses, and what is in it, is no node.
    void CompileNode(UiElement e, int parent, int depth, bool inTemplate)
    {
        if (!Elements.Contains(e.Name) || e.Name == "ui")
        {
            return;
        }
        if (e.Name == "template" && (parent != 0 || inTemplate))
        {
            return;
        }
        if (depth > MaxDepth || _nodes.Count >= MaxNodes)
        {
            return;
        }
        inTemplate |= e.Name == "template";
        var index = AddNode(e.Name, e, parent, false, inTemplate);
        if (e.Name is "text" or "image" or "field" && e.Children.Count > 0)
        {
            return;
        }
        if (e.Name == "template" && e.Children.Count != 1)
        {
            return;
        }
        if (e.Name == "button" && e.Text != "" && e.Children.Count == 0 && ValidBindings(e.Text))
        {
            AddNode("text", e, index, true, inTemplate);
        }
        foreach (var child in e.Children)
        {
            CompileNode(child, index, depth + 1, inTemplate);
        }
    }
}
