using System.Text;

namespace Cinnabar.Editor.Document;

/// <summary>
/// An attribute of an element in a UI document's text, where the text has it: its name, its value as the text spells
/// it, between its quotes if it has them, and the value as the cooker reads it, with its entities decoded.
/// </summary>
public sealed class UiAttribute
{
    internal UiAttribute(string name, int start, int valueStart, int valueEnd, int end, char quote, string value)
    {
        Name = name;
        Start = start;
        ValueStart = valueStart;
        ValueEnd = valueEnd;
        End = end;
        Quote = quote;
        Value = value;
    }

    public string Name { get; }

    /// <summary>The offset of its name in the text.</summary>
    public int Start { get; }

    /// <summary>The span of its value, inside its quotes.</summary>
    public int ValueStart { get; }
    public int ValueEnd { get; }

    /// <summary>The offset after it: after its closing quote, or its value without quotes.</summary>
    public int End { get; }

    /// <summary>The quote that it is in, or '\0' for a value without quotes.</summary>
    public char Quote { get; }

    public string Value { get; }
}

/// <summary>
/// An element of a UI document's text as it is written, whatever it means: its name, its attributes, its children,
/// its text, and where each is in the text. A <c>&lt;style&gt;</c> is one, as is an element that the cooker refuses.
/// </summary>
public sealed class UiElement
{
    internal UiElement(string name, int start, UiElement? parent)
    {
        Name = name;
        Start = start;
        Parent = parent;
    }

    public string Name { get; }

    /// <summary>The offset of its <c>&lt;</c>.</summary>
    public int Start { get; }

    /// <summary>The offset after its start tag's <c>&gt;</c> or <c>/&gt;</c>.</summary>
    public int StartTagEnd { get; internal set; }

    public bool SelfClosing { get; internal set; }

    /// <summary>The span between its tags, empty for an element that closes itself.</summary>
    public int ContentStart { get; internal set; }
    public int ContentEnd { get; internal set; }

    /// <summary>The offset after its end tag, or the text's end for an element that nothing closes.</summary>
    public int End { get; internal set; }

    public UiElement? Parent { get; }

    public List<UiAttribute> Attributes { get; } = [];

    public List<UiElement> Children { get; } = [];

    /// <summary>Its text, its whitespace collapsed and its entities decoded, as the cooker reads it; "" for none.</summary>
    public string Text { get; internal set; } = "";

    /// <summary>The node that the cooker makes of it, by its index in <see cref="UiFile.Nodes"/>, or -1.</summary>
    public int Node { get; internal set; } = -1;

    /// <summary>The first attribute of a name, as the cooker reads it, or null.</summary>
    public UiAttribute? Attribute(string name) => Attributes.Find(a => a.Name == name);

    public string? Get(string name) => Attribute(name)?.Value;
}

/// <summary>
/// A node of a UI document, as the cooker makes them: each element in its tree that it keeps, the templates' too, and a
/// button's text, which is a text node of its own. Nodes are in the order of a walk that visits each before its
/// children, as the blob's are, so a node's index is the one that the game reports it by.
/// </summary>
public sealed class UiNode
{
    internal UiNode(int index, string kind, UiElement element, int parent, bool buttonText, bool inTemplate)
    {
        Index = index;
        Kind = kind;
        Element = element;
        Parent = parent;
        ButtonText = buttonText;
        InTemplate = inTemplate;
    }

    public int Index { get; }

    /// <summary>The element's name, such as "button".</summary>
    public string Kind { get; }

    /// <summary>The element that it is, or for a button's text, the button.</summary>
    public UiElement Element { get; }

    /// <summary>The parent node's index, or -1 for the root.</summary>
    public int Parent { get; }

    public List<int> Children { get; } = [];

    /// <summary>It is a button's text, which the button's own text makes.</summary>
    public bool ButtonText { get; }

    /// <summary>It is a template or in one, so the document itself does not show it.</summary>
    public bool InTemplate { get; }

    public string Id => ButtonText ? "" : Element.Get("id") ?? "";
}

/// <summary>A <c>&lt;style&gt;</c> of the document's root: its name, and the style that it is a variant of, if it is one.</summary>
public sealed class UiStyle
{
    internal UiStyle(UiElement element)
    {
        Element = element;
        Name = element.Get("name") ?? "";
        var colon = Name.IndexOf(':');
        Base = colon < 0 ? Name : Name[..colon];
        State = colon < 0 ? "" : Name[(colon + 1)..];
    }

    public UiElement Element { get; }

    public string Name { get; }

    /// <summary>The style's name without its state: "button" for "button:focus".</summary>
    public string Base { get; }

    /// <summary>The variant's state, such as "focus", or "" for a style that is not a variant.</summary>
    public string State { get; }
}

/// <summary>
/// A UI document's text (see docs/content/kinds/ui-documents.md#ui-documents), read as tools/cook reads it but keeping
/// where each element and attribute is. It writes the text back as it was, and an edit changes only the text that it
/// touches, keeping indents, comments and the order of everything else (see docs/editor/ui-editor.md#the-file).
/// </summary>
public sealed partial class UiFile
{
    /// <summary>The elements that the cooker knows, by name.</summary>
    public static readonly IReadOnlyList<string> Elements = ["ui", "box", "row", "column", "stack", "text", "image", "button", "field", "template"];

    /// <summary>The states that a style's variant applies in, in the order that the cascade applies them.</summary>
    public static readonly IReadOnlyList<string> States = ["hover", "focus", "press", "disabled"];

    const int MaxNodes = 4096;
    const int MaxDepth = 64;

    readonly List<UiNode> _nodes = [];
    readonly List<UiStyle> _styles = [];
    readonly List<UiElement> _top = [];
    int[] _lineStarts = [];

    UiFile(string text)
    {
        Text = text;
        Scan();
    }

    /// <summary>The document's text, as the file has it with the edits.</summary>
    public string Text { get; private set; }

    /// <summary>The document's root, its first <c>&lt;ui&gt;</c>, or null.</summary>
    public UiElement? Root { get; private set; }

    public IReadOnlyList<UiNode> Nodes => _nodes;

    /// <summary>The root's <c>&lt;style&gt;</c> elements, in the text's order.</summary>
    public IReadOnlyList<UiStyle> Styles => _styles;

    /// <summary>The line that the header is on, from 1.</summary>
    public int HeaderLine { get; private set; }

    /// <summary>
    /// Reads a document's text. Only a text whose first line that is not blank is not <c>ui 1</c> is refused, with the
    /// reason at that line: problems in the rest are the cooker's to report.
    /// </summary>
    public static (UiFile? File, MaterialProblem? Problem) Parse(string text)
    {
        var (line, header) = Header(text);
        var words = header.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (words.Length != 2 || words[0] != "ui")
        {
            return (null, new MaterialProblem(Math.Max(line, 1), "a UI document starts with `ui 1`"));
        }
        if (words[1] != "1")
        {
            return (null, new MaterialProblem(line, $"version {words[1]} is not 1, which this editor reads"));
        }
        return (new UiFile(text), null);
    }

    /// <summary>A file's bytes as text, or null if they are not UTF-8. A byte order mark is kept, as the cooker does.</summary>
    public static string? Decode(byte[] bytes)
    {
        try
        {
            return new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
            return null;
        }
    }

    static (int Line, string Header) Header(string text)
    {
        var line = 0;
        var start = 0;
        while (start <= text.Length)
        {
            var end = text.IndexOf('\n', start);
            var row = end < 0 ? text[start..] : text[start..end];
            line++;
            if (row.Trim().Length > 0)
            {
                return (line, row.Trim());
            }
            if (end < 0)
            {
                break;
            }
            start = end + 1;
        }
        return (line, "");
    }

    /// <summary>The line and the column, from 1 and in characters, of an offset of the text.</summary>
    public (int Line, int Column) Position(int offset)
    {
        var line = Array.BinarySearch(_lineStarts, offset);
        if (line < 0)
        {
            line = ~line - 1;
        }
        var column = 1;
        for (var i = _lineStarts[line]; i < offset && i < Text.Length; i++)
        {
            if (!char.IsLowSurrogate(Text[i]))
            {
                column++;
            }
        }
        return (line + 1, column);
    }

    /// <summary>The offset of a line and a column from 1, as the cooker counts them, clamped to the text.</summary>
    public int Offset(int line, int column)
    {
        if (_lineStarts.Length == 0)
        {
            return 0;
        }
        var offset = _lineStarts[Math.Clamp(line - 1, 0, _lineStarts.Length - 1)];
        for (var c = 1; c < column && offset < Text.Length && Text[offset] != '\n'; offset++)
        {
            if (!char.IsLowSurrogate(Text[offset]))
            {
                c++;
            }
        }
        return offset;
    }

    /// <summary>The innermost element that holds a place in the text, a style's too, or null outside the root.</summary>
    public UiElement? ElementAt(int line, int column)
    {
        var offset = Offset(line, column);
        UiElement? found = null;
        foreach (var top in _top)
        {
            Find(top);
        }
        return found;

        void Find(UiElement e)
        {
            if (offset < e.Start || offset >= Math.Max(e.End, e.Start + 1))
            {
                return;
            }
            found = e;
            foreach (var c in e.Children)
            {
                Find(c);
            }
        }
    }

    /// <summary>The node that a problem at a line and column is on: the innermost node of the element there, or null.</summary>
    public int? NodeAt(int line, int column)
    {
        for (var e = ElementAt(line, column); e != null; e = e.Parent)
        {
            if (e.Node >= 0)
            {
                return e.Node;
            }
            if (e.Name == "style")
            {
                return null;
            }
        }
        return null;
    }

    /// <summary>The style that a problem at a line and column is on, or null.</summary>
    public UiStyle? StyleAt(int line, int column)
    {
        var e = ElementAt(line, column);
        return e == null ? null : _styles.Find(s => s.Element == e);
    }

    public UiStyle? Style(string name) => _styles.Find(s => s.Name == name);

    /// <summary>The node of an id outside the templates, or null.</summary>
    public UiNode? NodeById(string id) => id == "" ? null : _nodes.Find(n => !n.InTemplate && n.Id == id);

    /// <summary>The styles that a node takes, in order: the one named for its kind, then those that it names.</summary>
    public IReadOnlyList<UiStyle> StylesOf(UiNode node)
    {
        var styles = new List<UiStyle>();
        if (Style(node.Kind) is { } kind)
        {
            styles.Add(kind);
        }
        if (!node.ButtonText && node.Element.Get("style") is { } names)
        {
            foreach (var name in names.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
            {
                if (!name.Contains(':') && Style(name) is { } s && !styles.Contains(s))
                {
                    styles.Add(s);
                }
            }
        }
        return styles;
    }

    /// <summary>Whether a value takes a binding's braces as the cooker does: a {name}, {{ or }}. A text that does not is not a node's.</summary>
    public static bool ValidBindings(string text)
    {
        for (var i = 0; i < text.Length; i++)
        {
            if (text[i] == '{')
            {
                if (i + 1 < text.Length && text[i + 1] == '{')
                {
                    i++;
                    continue;
                }
                var end = text.IndexOf('}', i);
                if (end < 0 || !ValidName(text[(i + 1)..end]))
                {
                    return false;
                }
                i = end;
            }
            else if (text[i] == '}' && i + 1 < text.Length && text[i + 1] == '}')
            {
                i++;
            }
        }
        return true;
    }

    /// <summary>The names that a text binds, in order, once each.</summary>
    public static IEnumerable<string> Bindings(string text)
    {
        var seen = new HashSet<string>();
        for (var i = 0; i < text.Length; i++)
        {
            if (text[i] == '{')
            {
                if (i + 1 < text.Length && text[i + 1] == '{')
                {
                    i++;
                    continue;
                }
                var end = text.IndexOf('}', i);
                if (end < 0)
                {
                    yield break;
                }
                var name = text[(i + 1)..end];
                if (ValidName(name) && seen.Add(name))
                {
                    yield return name;
                }
                i = end;
            }
            else if (text[i] == '}' && i + 1 < text.Length && text[i + 1] == '}')
            {
                i++;
            }
        }
    }

    /// <summary>Whether a name is an id: lowercase letters, digits, _ and -.</summary>
    public static bool ValidId(string id) => id.Length > 0 && id.All(c => c is >= 'a' and <= 'z' or >= '0' and <= '9' or '_' or '-');

    static bool ValidName(string name) =>
        name.Length > 0 && name[0] is not (>= '0' and <= '9') && name.All(c => c is >= 'a' and <= 'z' or >= '0' and <= '9' or '_');
}
