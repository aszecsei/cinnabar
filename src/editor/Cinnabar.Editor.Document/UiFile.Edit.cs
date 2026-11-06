using System.Text.RegularExpressions;

namespace Cinnabar.Editor.Document;

// The edits. Each changes a span of the text and reads the text again, so the elements and nodes from before an edit
// are not the file's after it: find them again by their index or their path.
public sealed partial class UiFile
{
    /// <summary>The line ending that new lines take: the file's first, or a line feed.</summary>
    public string Newline
    {
        get
        {
            var lf = Text.IndexOf('\n');
            return lf > 0 && Text[lf - 1] == '\r' ? "\r\n" : "\n";
        }
    }

    /// <summary>One level of indent: the first indented element's, a tab or spaces, or a tab.</summary>
    public string IndentUnit
    {
        get
        {
            foreach (var start in _lineStarts)
            {
                var i = start;
                while (i < Text.Length && Text[i] is ' ' or '\t')
                {
                    i++;
                }
                if (i > start && i < Text.Length && Text[i] == '<')
                {
                    return Text[start] == '\t' ? "\t" : new string(' ', i - start);
                }
            }
            return "\t";
        }
    }

    void Splice(int start, int end, string with)
    {
        Text = string.Concat(Text.AsSpan(0, start), with, Text.AsSpan(end));
        Scan();
    }

    int LineStart(int offset)
    {
        var lf = offset == 0 ? -1 : Text.LastIndexOf('\n', Math.Min(offset, Text.Length) - 1);
        return lf + 1;
    }

    // LineEnd is where the line that holds an offset ends, before its line ending.
    int LineEnd(int offset)
    {
        var lf = Text.IndexOf('\n', Math.Min(offset, Text.Length));
        if (lf < 0)
        {
            return Text.Length;
        }
        return lf > 0 && Text[lf - 1] == '\r' ? lf - 1 : lf;
    }

    // AfterLine is past the line ending of the line that ends at a LineEnd.
    int AfterLine(int lineEnd)
    {
        if (lineEnd >= Text.Length)
        {
            return Text.Length;
        }
        return Text[lineEnd] == '\r' ? Math.Min(lineEnd + 2, Text.Length) : lineEnd + 1;
    }

    string LineIndent(int offset)
    {
        var start = LineStart(offset);
        var i = start;
        while (i < Text.Length && Text[i] is ' ' or '\t')
        {
            i++;
        }
        return Text[start..i];
    }

    bool Blank(int from, int to)
    {
        for (var i = from; i < to; i++)
        {
            if (!IsSpace(Text[i]))
            {
                return false;
            }
        }
        return true;
    }

    // Trivia is whether a span has only whitespace and whole comments.
    bool Trivia(int from, int to)
    {
        var i = from;
        while (i < to)
        {
            if (IsSpace(Text[i]))
            {
                i++;
                continue;
            }
            if (string.CompareOrdinal(Text, i, "<!--", 0, 4) != 0)
            {
                return false;
            }
            var end = Text.IndexOf("-->", i + 4, StringComparison.Ordinal);
            if (end < 0 || end + 3 > to)
            {
                return false;
            }
            i = end + 3;
        }
        return true;
    }

    bool OnOwnLine(UiElement e) => Blank(LineStart(e.Start), e.Start);

    // WholeLines is whether an element has lines of its own: nothing before it on its first line, and nothing but
    // comments after it on its last, where its parent does not end.
    bool WholeLines(UiElement e)
    {
        var end = LineEnd(e.End);
        return OnOwnLine(e) && Trivia(e.End, end) && (e.Parent == null || e.Parent.ContentEnd >= end);
    }

    // Extent is the span that an element's text takes: its whole lines, with a comment of its own above it if asked,
    // or the element alone when it shares its lines.
    (int Start, int End) Extent(UiElement e, bool withComment)
    {
        if (!WholeLines(e))
        {
            return (e.Start, e.End);
        }
        var start = LineStart(e.Start);
        var end = AfterLine(LineEnd(e.End));
        if (withComment && start > 0)
        {
            // A comment on the lines right above it, which starts its own line inside its parent, is its own.
            var floor = e.Parent?.ContentStart ?? 0;
            var above = LineStart(start - 1);
            var close = Text.LastIndexOf("-->", LineEnd(above), StringComparison.Ordinal);
            if (close >= above && Blank(close + 3, LineEnd(above)))
            {
                var open = Text.LastIndexOf("<!--", close, StringComparison.Ordinal);
                if (open >= floor && Blank(LineStart(open), open))
                {
                    start = LineStart(open);
                }
            }
        }
        return (start, end);
    }

    // Block is an element's text, its first line's indent taken off each of its lines, so it can go at another depth.
    string Block(UiElement e, bool withComment)
    {
        var (start, end) = Extent(e, withComment);
        var text = Text[start..end];
        if (!WholeLines(e))
        {
            return text;
        }
        var indent = LineIndent(e.Start);
        var lines = text.TrimEnd('\n').TrimEnd('\r').Split('\n');
        return string.Join('\n', lines.Select(l => (l.StartsWith(indent, StringComparison.Ordinal) ? l[indent.Length..] : l.TrimStart(' ', '\t')).TrimEnd('\r')));
    }

    string ChildIndent(UiElement parent)
    {
        foreach (var c in parent.Children)
        {
            if (OnOwnLine(c))
            {
                return LineIndent(c.Start);
            }
        }
        return LineIndent(parent.Start) + IndentUnit;
    }

    static string Escape(string value, char quote) =>
        value.Replace("&", "&amp;").Replace("<", "&lt;").Replace(quote == '\'' ? "'" : "\"", quote == '\'' ? "&apos;" : "&quot;");

    static string EscapeText(string text) => text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");

    [GeneratedRegex(@"^[A-Za-z0-9_$#%.+\-]+$")]
    private static partial Regex BareValue();

    /// <summary>The path to an element from the text's first element: its index among its parent's children, down.</summary>
    public IReadOnlyList<int> PathOf(UiElement e)
    {
        var path = new List<int>();
        for (var at = e; at != null; at = at.Parent)
        {
            path.Insert(0, at.Parent == null ? _top.IndexOf(at) : at.Parent.Children.IndexOf(at));
        }
        return path;
    }

    /// <summary>The element at a path, or null.</summary>
    public UiElement? At(IReadOnlyList<int> path)
    {
        if (path.Count == 0 || path[0] < 0 || path[0] >= _top.Count)
        {
            return null;
        }
        var e = _top[path[0]];
        for (var i = 1; i < path.Count; i++)
        {
            if (path[i] < 0 || path[i] >= e.Children.Count)
            {
                return null;
            }
            e = e.Children[path[i]];
        }
        return e;
    }

    /// <summary>
    /// Sets an attribute of an element: a new value goes between its quotes, or at the end of its start tag for an
    /// attribute that it does not have, and null takes it out.
    /// </summary>
    public void SetAttribute(UiElement e, string name, string? value)
    {
        var a = e.Attribute(name);
        if (a == null)
        {
            if (value == null)
            {
                return;
            }
            var at = e.Attributes.Count > 0 ? e.Attributes[^1].End : e.Start + 1 + e.Name.Length;
            Splice(at, at, $" {name}=\"{Escape(value, '"')}\"");
            return;
        }
        if (value == null)
        {
            var lineStart = LineStart(a.Start);
            var lineEnd = LineEnd(a.End);
            if (Blank(lineStart, a.Start) && Blank(a.End, lineEnd))
            {
                Splice(lineStart, AfterLine(lineEnd), "");
                return;
            }
            var start = a.Start;
            while (start > lineStart && Text[start - 1] is ' ' or '\t')
            {
                start--;
            }
            if (start == lineStart)
            {
                // The first on a line of its own keeps the line's indent for the next.
                var end = a.End;
                while (end < lineEnd && Text[end] is ' ' or '\t')
                {
                    end++;
                }
                Splice(a.Start, end, "");
                return;
            }
            Splice(start, a.End, "");
            return;
        }
        if (a.Value == value)
        {
            return;
        }
        if (a.Quote != '\0')
        {
            Splice(a.ValueStart, a.ValueEnd, Escape(value, a.Quote));
        }
        else
        {
            Splice(a.ValueStart, a.ValueEnd, BareValue().IsMatch(value) ? value : $"\"{Escape(value, '"')}\"");
        }
    }

    /// <summary>The span of an element's own text, without the whitespace about it, or null for none.</summary>
    (int Start, int End)? TextSpan(UiElement e)
    {
        if (e.SelfClosing || e.Children.Count > 0)
        {
            return null;
        }
        int? first = null;
        var last = 0;
        var i = e.ContentStart;
        while (i < e.ContentEnd)
        {
            if (string.CompareOrdinal(Text, i, "<!--", 0, 4) == 0)
            {
                var close = Text.IndexOf("-->", i + 4, StringComparison.Ordinal);
                i = close < 0 ? e.ContentEnd : close + 3;
                continue;
            }
            if (!IsSpace(Text[i]))
            {
                first ??= i;
                last = i + 1;
            }
            i++;
        }
        return first is { } f ? (f, last) : null;
    }

    /// <summary>
    /// Sets the text of a text, a button or a field: the text in the element, or its text attribute if it has one and
    /// no text in it. Empty text takes it out.
    /// </summary>
    public void SetText(UiElement e, string text)
    {
        if (e.Text == "" && e.Attribute("text") != null)
        {
            SetAttribute(e, "text", text == "" ? null : text);
            return;
        }
        if (e.Text == text)
        {
            return;
        }
        if (e.SelfClosing)
        {
            if (text == "")
            {
                return;
            }
            var close = e.StartTagEnd - 2;
            while (close > e.Start && IsSpace(Text[close - 1]))
            {
                close--;
            }
            Splice(close, e.StartTagEnd, $">{EscapeText(text)}</{e.Name}>");
            return;
        }
        if (TextSpan(e) is { } span)
        {
            Splice(span.Start, span.End, EscapeText(text));
        }
        else if (e.Children.Count == 0)
        {
            Splice(e.ContentStart, e.ContentEnd, EscapeText(text));
        }
    }

    /// <summary>
    /// Puts an element's text, whose lines are indented from its own depth, among a parent's children at an index:
    /// on lines of its own at the children's indent, opening a parent that closes itself.
    /// </summary>
    public void Insert(UiElement parent, int index, string block)
    {
        var nl = Newline;
        var childIndent = ChildIndent(parent);
        var parentIndent = LineIndent(parent.Start);
        var lines = block.Replace("\r\n", "\n").Split('\n');
        var indented = string.Join(nl, lines.Select(l => l == "" ? "" : childIndent + l));
        var flat = string.Join(nl, lines);
        if (parent.SelfClosing)
        {
            var close = parent.StartTagEnd - 2;
            while (close > parent.Start && IsSpace(Text[close - 1]))
            {
                close--;
            }
            Splice(close, parent.StartTagEnd, $">{nl}{indented}{nl}{parentIndent}</{parent.Name}>");
            return;
        }
        var children = parent.Children;
        index = Math.Clamp(index, 0, children.Count);
        // After the child before it, if that has lines of its own, so a blank line after a group stays after it.
        if (index > 0 && WholeLines(children[index - 1]))
        {
            var after = LineEnd(children[index - 1].End);
            Splice(after, after, nl + indented);
            return;
        }
        if (index < children.Count)
        {
            var next = children[index];
            if (OnOwnLine(next))
            {
                var (start, _) = Extent(next, withComment: true);
                start = Math.Min(start, LineStart(next.Start));
                Splice(start, start, indented + nl);
            }
            else
            {
                Splice(next.Start, next.Start, flat);
            }
            return;
        }
        if (children.Count > 0)
        {
            var last = children[^1];
            var lineEnd = LineEnd(last.End);
            if (WholeLines(last))
            {
                Splice(lineEnd, lineEnd, nl + indented);
            }
            else if (OnOwnLine(last))
            {
                Splice(last.End, last.End, nl + indented);
            }
            else
            {
                Splice(last.End, last.End, flat);
            }
            return;
        }
        var endLine = LineStart(parent.ContentEnd);
        if (endLine > parent.ContentStart && Trivia(parent.ContentStart, parent.ContentEnd) && Blank(endLine, parent.ContentEnd))
        {
            Splice(endLine, endLine, indented + nl);
        }
        else if (Trivia(parent.ContentStart, parent.ContentEnd))
        {
            Splice(parent.ContentEnd, parent.ContentEnd, nl + indented + nl + parentIndent);
        }
        else
        {
            Splice(parent.ContentEnd, parent.ContentEnd, nl + indented + nl + parentIndent);
        }
    }

    /// <summary>Takes an element out, with its lines and a comment of its own above it, and one of two blank lines that meet.</summary>
    public void Remove(UiElement e)
    {
        var (start, end) = Extent(e, withComment: true);
        if (WholeLines(e))
        {
            var aboveBlank = start > 0 && Blank(LineStart(start - 1), start);
            var belowBlank = end < Text.Length && Blank(end, LineEnd(end));
            if (aboveBlank && belowBlank)
            {
                end = AfterLine(LineEnd(end));
            }
        }
        else
        {
            var lineStart = LineStart(start);
            var s = start;
            while (s > lineStart && Text[s - 1] is ' ' or '\t')
            {
                s--;
            }
            if (s > lineStart)
            {
                start = s;
            }
        }
        Splice(start, end, "");
    }

    /// <summary>Moves an element, with its comment, to an index among a parent's children, as they are before the move.</summary>
    public void Move(UiElement e, UiElement parent, int index)
    {
        var block = Block(e, withComment: true);
        var from = PathOf(e);
        var to = PathOf(parent).ToList();
        var sameParent = e.Parent == parent;
        var oldIndex = from[^1];
        if (sameParent && (index == oldIndex || index == oldIndex + 1))
        {
            return;
        }
        // Taking it out moves the later children of its parent up one, the parent's path among them.
        if (to.Count >= from.Count && to.Take(from.Count - 1).SequenceEqual(from.Take(from.Count - 1)) && to[from.Count - 1] > oldIndex)
        {
            to[from.Count - 1]--;
        }
        if (to.Count >= from.Count && to.Take(from.Count).SequenceEqual(from))
        {
            throw new InvalidOperationException("an element cannot move into itself");
        }
        Remove(e);
        if (sameParent && index > oldIndex)
        {
            index--;
        }
        Insert(At(to)!, index, block);
    }

    /// <summary>Copies an element after itself, its ids made new, and gives the copy's path.</summary>
    public IReadOnlyList<int> Duplicate(UiElement e)
    {
        var path = PathOf(e).ToList();
        var parent = e.Parent ?? throw new InvalidOperationException("the root is not copied");
        Insert(parent, path[^1] + 1, Block(e, withComment: false));
        path[^1]++;
        var ids = new HashSet<string>(AllElements().Select(x => x.Get("id") ?? "").Where(id => id != ""));
        var copy = At(path)!;
        var inCopy = new List<IReadOnlyList<int>>();
        Walk(copy, x =>
        {
            if (x.Attribute("id") != null)
            {
                inCopy.Add(PathOf(x));
            }
        });
        foreach (var p in inCopy)
        {
            var x = At(p)!;
            var id = x.Get("id")!;
            var stem = Regex.Replace(id, @"_\d+$", "");
            var n = 2;
            while (ids.Contains($"{stem}_{n}"))
            {
                n++;
            }
            var fresh = $"{stem}_{n}";
            ids.Add(fresh);
            SetAttribute(x, "id", fresh);
        }
        return path;
    }

    /// <summary>Adds a style after the root's last one, or as its first child, and gives its element's path.</summary>
    public IReadOnlyList<int> AddStyle(string name)
    {
        var root = Root ?? throw new InvalidOperationException("the document has no <ui>");
        var last = root.Children.FindLastIndex(c => c.Name == "style");
        var rootPath = PathOf(root).ToList();
        Insert(root, last + 1, $"<style name=\"{Escape(name, '"')}\"/>");
        rootPath.Add(last + 1);
        return rootPath;
    }

    /// <summary>Renames a style, its variants, and the style lists that name it.</summary>
    public void RenameStyle(string from, string to)
    {
        foreach (var (path, state) in _styles.Where(s => s.Base == from).Select(s => (PathOf(s.Element), s.State)).ToList())
        {
            SetAttribute(At(path)!, "name", state == "" ? to : $"{to}:{state}");
        }
        foreach (var path in AllElements().Where(x => x.Get("style") is { } list && list.Split(' ', StringSplitOptions.RemoveEmptyEntries).Contains(from)).Select(PathOf).ToList())
        {
            var x = At(path)!;
            var words = x.Get("style")!.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Select(w => w == from ? to : w);
            SetAttribute(x, "style", string.Join(' ', words));
        }
    }

    /// <summary>Every element of the text, each before its children.</summary>
    public IEnumerable<UiElement> AllElements()
    {
        var all = new List<UiElement>();
        foreach (var top in _top)
        {
            Walk(top, all.Add);
        }
        return all;
    }

    static void Walk(UiElement e, Action<UiElement> visit)
    {
        visit(e);
        foreach (var c in e.Children)
        {
            Walk(c, visit);
        }
    }
}
