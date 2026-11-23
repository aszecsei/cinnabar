using System.Globalization;
using System.Text;

namespace Cinnabar.Editor.Document;

public enum CutsceneBlockKind
{
    /// <summary>The <c>cutscene 1</c> line and the header's settings, whose children are the bindings and the tracks.</summary>
    Cutscene,
    Binding,
    Track,
    Section,
    Channel,
    Trigger,
    Range,
    Key,
    /// <summary>A <c>marker &lt;id&gt; &lt;time&gt; "&lt;name&gt;"</c> under the cutscene: a named, colored point on its time.</summary>
    Marker,
}

/// <summary>
/// A block of a cutscene's text: its own whole lines, which are the comments and blank lines above it, its keyword line
/// and its settings, and the blocks under it. Together, a file's blocks hold every line that it has, in order: a block's
/// own lines, then its children's.
/// </summary>
public sealed class CutsceneBlock
{
    internal CutsceneBlock(CutsceneBlockKind kind, CutsceneBlock? parent)
    {
        Kind = kind;
        Parent = parent;
    }

    /// <summary>A new block of a kind with one keyword line, which is not in a file yet.</summary>
    internal static CutsceneBlock Of(CutsceneBlockKind kind, string line)
    {
        var block = new CutsceneBlock(kind, null);
        block.Lines.Add(new TextLine(line, "", hashInWord: true));
        return block;
    }

    public CutsceneBlockKind Kind { get; }

    public CutsceneBlock? Parent { get; private set; }

    internal List<TextLine> Lines { get; } = [];

    internal List<CutsceneBlock> ChildList { get; } = [];

    public IReadOnlyList<CutsceneBlock> Children => ChildList;

    /// <summary>The text of the block's own lines, without their endings.</summary>
    public IEnumerable<string> LineTexts => Lines.Select(l => l.Text);

    // The keyword line: the first that is not blank or a comment. Only the cutscene's block has none before its header.
    internal TextLine? Head => Lines.FirstOrDefault(l => !l.IsBlank);

    // The words of the keyword line after the keyword.
    string[] Words => Head?.Code.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries) is [_, .. var rest] ? rest : [];

    // The setting lines, after the keyword line.
    IEnumerable<TextLine> SettingLines => Lines.SkipWhile(l => l != Head).Skip(1).Where(l => !l.IsBlank);

    /// <summary>The ID of a binding, track, section, trigger, range or marker, or null for another block or a bad ID.</summary>
    public int? Id => Kind is CutsceneBlockKind.Binding or CutsceneBlockKind.Track or CutsceneBlockKind.Section
            or CutsceneBlockKind.Trigger or CutsceneBlockKind.Range or CutsceneBlockKind.Marker
        && Words is [var id, ..] && CutsceneFile.TryParseTicks(id, out var value) && value > 0
            ? value
            : null;

    /// <summary>A track's kind, such as <c>camera_cut</c>, or null for another block.</summary>
    public string? TrackKind => Kind == CutsceneBlockKind.Track && Words is [_, var kind, ..] ? kind : null;

    /// <summary>
    /// The name of a binding, a track or a marker, unquoted, a channel's, or the event of a trigger or a range, or null
    /// when the block has none.
    /// </summary>
    public string? Name => Kind switch
    {
        CutsceneBlockKind.Binding => Quoted(1),
        CutsceneBlockKind.Track => Quoted(2),
        CutsceneBlockKind.Channel => Words is [var name, ..] ? name : null,
        CutsceneBlockKind.Trigger => Rest(2),
        CutsceneBlockKind.Range => Rest(3),
        CutsceneBlockKind.Marker => Quoted(2),
        _ => null,
    };

    // The rest of the keyword line from a word on, which for a name is quoted.
    string? Quoted(int word) => Rest(word) is { } rest && TextQuote.Unquote(rest) is { } name ? name : null;

    // The keyword line from a word after the keyword to its end, or null when it has no such word.
    string? Rest(int word)
    {
        if (Head?.Code is not { } code)
        {
            return null;
        }
        var at = 0;
        // Past the keyword and the words before this one.
        for (var i = 0; i <= word; i++)
        {
            while (at < code.Length && char.IsWhiteSpace(code[at]))
            {
                at++;
            }
            while (at < code.Length && !char.IsWhiteSpace(code[at]))
            {
                at++;
            }
        }
        var rest = code[at..].Trim();
        return rest.Length == 0 ? null : rest;
    }

    /// <summary>A section's or a range's start in ticks, or a key's, a trigger's or a marker's time, or null.</summary>
    public int? Start => Kind switch
    {
        CutsceneBlockKind.Section or CutsceneBlockKind.Range or CutsceneBlockKind.Trigger or CutsceneBlockKind.Marker => Ticks(1),
        CutsceneBlockKind.Key => Ticks(0),
        _ => null,
    };

    /// <summary>A section's or a range's end in ticks, or null.</summary>
    public int? End => Kind is CutsceneBlockKind.Section or CutsceneBlockKind.Range ? Ticks(2) : null;

    int? Ticks(int word) => Words.Length > word && CutsceneFile.TryParseTicks(Words[word], out var ticks) ? ticks : null;

    /// <summary>A key's value as the file writes it, or null for another block.</summary>
    public string? KeyValue => Kind == CutsceneBlockKind.Key && Words.Length > 1 ? Words[1] : null;

    /// <summary>A key's interpolation and what follows it, such as <c>bezier 0.5 -0.25</c>, or null for another block.</summary>
    public string? KeyInterpolation => Kind == CutsceneBlockKind.Key && Words.Length > 2 ? string.Join(' ', Words[2..]) : null;

    /// <summary>The settings in the file's order, with a sub-sequence's <c>bind &lt;child&gt;</c> as its key.</summary>
    public IEnumerable<(string Key, string Value)> Settings => SettingLines.Select(l => (l.Key, l.Value));

    /// <summary>A setting's value as the file writes it, or null without it. The first line counts.</summary>
    public string? Get(string key) => SettingLines.FirstOrDefault(l => l.Key == key)?.Value;

    /// <summary>
    /// Sets a setting on its own line, keeping the line's comment, or with null, removes it. A new setting goes after
    /// the block's last one, so it comes before the blocks under it, as the cooker reads it.
    /// </summary>
    public void Set(string key, string? value)
    {
        if (value == null)
        {
            foreach (var setting in SettingLines.Where(l => l.Key == key).ToList())
            {
                Lines.Remove(setting);
            }
            return;
        }
        value = value.ReplaceLineEndings(" ");
        if (SettingLines.FirstOrDefault(l => l.Key == key) is { } line)
        {
            line.SetValue(value);
            return;
        }
        var last = SettingLines.LastOrDefault();
        string indent;
        if (last != null)
        {
            indent = Indent(last);
        }
        else
        {
            // The cutscene's settings are not indented. Every other block's are, a level under its keyword line.
            indent = Kind == CutsceneBlockKind.Cutscene || Head == null ? "" : Indent(Head) + "\t";
        }
        var at = last != null ? Lines.IndexOf(last) + 1 : Head != null ? Lines.IndexOf(Head) + 1 : Lines.Count;
        Lines.Insert(at, new TextLine($"{indent}{key} = {value}", "", hashInWord: true));
    }

    /// <summary>
    /// Puts another setting on a setting's line, keeping its indent and its comment, so every line stays where it was.
    /// False without the setting.
    /// </summary>
    public bool ReplaceSetting(string key, string newKey, string value)
    {
        if (SettingLines.FirstOrDefault(l => l.Key == key) is not { } line)
        {
            return false;
        }
        line.SetCode($"{newKey} = {value.ReplaceLineEndings(" ")}");
        return true;
    }

    /// <summary>Makes a setting's lines comments, so the cooker skips them and every line stays where it was.</summary>
    public void CommentOut(string key)
    {
        foreach (var line in SettingLines.Where(l => l.Key == key).ToList())
        {
            line.Text = $"{Indent(line)}# {line.Text.TrimStart()}";
        }
    }

    internal static string Indent(TextLine line) => line.Text[..(line.Text.Length - line.Text.TrimStart().Length)];

    /// <summary>Renames a binding, a track or a marker, keeping its ID and its kind or time.</summary>
    public void SetName(string name)
    {
        var words = Words;
        switch (Kind)
        {
            case CutsceneBlockKind.Binding when words.Length >= 1:
                SetHead($"binding {words[0]} {TextQuote.Quote(name)}");
                break;
            case CutsceneBlockKind.Track when words.Length >= 2:
                SetHead($"track {words[0]} {words[1]} {TextQuote.Quote(name)}");
                break;
            case CutsceneBlockKind.Marker when words.Length >= 2:
                SetHead($"marker {words[0]} {words[1]} {TextQuote.Quote(name)}");
                break;
            default:
                throw new InvalidOperationException($"a {Kind} has no name to set");
        }
    }

    /// <summary>Sets a section's or a range's start and end in ticks.</summary>
    public void SetSpan(int start, int end)
    {
        var words = Words;
        switch (Kind)
        {
            case CutsceneBlockKind.Section when words.Length >= 1:
                SetHead($"section {words[0]} {Format(start)} {Format(end)}");
                break;
            case CutsceneBlockKind.Range when words.Length >= 4:
                SetHead($"range {words[0]} {Format(start)} {Format(end)} {Rest(3)}");
                break;
            default:
                throw new InvalidOperationException($"a {Kind} has no span to set");
        }
    }

    /// <summary>Sets a key's, a trigger's or a marker's time in ticks.</summary>
    public void SetTime(int time)
    {
        var words = Words;
        switch (Kind)
        {
            case CutsceneBlockKind.Key when words.Length >= 1:
                SetHead(string.Join(' ', ["key", Format(time), .. words[1..]]));
                break;
            case CutsceneBlockKind.Trigger when words.Length >= 3:
                SetHead($"trigger {words[0]} {Format(time)} {Rest(2)}");
                break;
            case CutsceneBlockKind.Marker when words.Length >= 2:
                SetHead($"marker {words[0]} {Format(time)} {Rest(2)}");
                break;
            default:
                throw new InvalidOperationException($"a {Kind} has no time to set");
        }
    }

    /// <summary>Sets a key's value, as the file writes it.</summary>
    public void SetKeyValue(string value)
    {
        var words = Words;
        if (Kind != CutsceneBlockKind.Key || words.Length < 2)
        {
            throw new InvalidOperationException($"a {Kind} has no key value to set");
        }
        SetHead(string.Join(' ', ["key", words[0], value.Trim(), .. words[2..]]));
    }

    /// <summary>Sets a key's interpolation and what follows it, such as <c>linear</c> or <c>bezier 0.5</c>.</summary>
    public void SetKeyInterpolation(string interpolation)
    {
        var words = Words;
        if (Kind != CutsceneBlockKind.Key || words.Length < 2)
        {
            throw new InvalidOperationException($"a {Kind} has no interpolation to set");
        }
        SetHead($"key {words[0]} {words[1]} {interpolation.Trim()}");
    }

    void SetHead(string code)
    {
        Head!.SetCode(code);
        Touch();
    }

    // The paths of the file's blocks, which the cutscene's block keeps, by path, and null for a path that two blocks
    // share. A change of a keyword line or of the tree drops it.
    Dictionary<string, CutsceneBlock?>? _index;

    // Drops the file's index of paths, as a block's ID, name or place changed.
    internal void Touch()
    {
        var root = this;
        while (root.Parent != null)
        {
            root = root.Parent;
        }
        root._index = null;
    }

    // The file's blocks by path, from the cutscene's block, built once for each change of the tree.
    internal Dictionary<string, CutsceneBlock?> Index()
    {
        if (_index != null)
        {
            return _index;
        }
        var index = new Dictionary<string, CutsceneBlock?>();
        void Add(string path, CutsceneBlock block) => index[path] = index.ContainsKey(path) ? null : block;
        void Walk(CutsceneBlock block, string path)
        {
            var keys = 0;
            foreach (var child in block.ChildList)
            {
                var childPath = child.Kind switch
                {
                    CutsceneBlockKind.Channel => $"{path}/channel:{child.Name}",
                    CutsceneBlockKind.Key => $"{path}/key:{keys++}",
                    _ => CutsceneFile.PathOf(child),
                };
                Add(childPath, child);
                Walk(child, childPath);
            }
        }
        Walk(this, "");
        return _index = index;
    }

    static string Format(int ticks) => ticks.ToString(CultureInfo.InvariantCulture);

    internal void Adopt(CutsceneBlock child)
    {
        child.Parent = this;
        ChildList.Add(child);
        Touch();
    }

    // Takes this block out of its parent, which has already let it go, so it can go in again.
    internal void Detach() => Parent = null;

    // Puts this block under a parent at an index.
    internal void Adopt(CutsceneBlock parent, int index)
    {
        Parent = parent;
        parent.ChildList.Insert(index, this);
        Touch();
    }

    /// <summary>
    /// Sets a section's ID, keeping its span. A section that another one's copy becomes, as a split makes, takes a new ID.
    /// </summary>
    public void SetSectionId(int id)
    {
        var words = Words;
        if (Kind != CutsceneBlockKind.Section || words.Length < 3)
        {
            throw new InvalidOperationException($"a {Kind} has no section ID to set");
        }
        SetHead($"section {Format(id)} {words[1]} {words[2]}");
    }

    /// <summary>
    /// Sets the ID of a section, a trigger, a range, a marker or a track, keeping the rest of its keyword line: a pasted
    /// copy takes a new one.
    /// </summary>
    public void SetId(int id)
    {
        if (Kind is not (CutsceneBlockKind.Section or CutsceneBlockKind.Trigger or CutsceneBlockKind.Range or CutsceneBlockKind.Marker
            or CutsceneBlockKind.Track) || Head?.Code is not { } code || Words.Length < 1)
        {
            throw new InvalidOperationException($"a {Kind} has no ID to set");
        }
        var keyword = code.TrimStart().Split((char[]?)null, 2, StringSplitOptions.RemoveEmptyEntries)[0];
        SetHead(Rest(1) is { } rest ? $"{keyword} {Format(id)} {rest}" : $"{keyword} {Format(id)}");
    }

    /// <summary>
    /// A copy of the block and the blocks under it, with no parent, for <see cref="CutsceneFile.Insert"/>. The comments
    /// above it are the original's, so the copy leaves them out, and keeps the blank lines.
    /// </summary>
    public CutsceneBlock Copy()
    {
        var copy = new CutsceneBlock(Kind, null);
        var head = Head;
        var before = true;
        foreach (var line in Lines)
        {
            if (line == head)
            {
                before = false;
            }
            if (before && line.Text.Trim().Length > 0)
            {
                continue;
            }
            copy.Lines.Add(new TextLine(line.Text, line.Ending, hashInWord: true));
        }
        foreach (var child in ChildList)
        {
            copy.Adopt(child.Copy());
        }
        return copy;
    }

    /// <summary>A new key of a channel at a time, written as a key line indented as this key's is.</summary>
    public CutsceneBlock KeyLike(int time, string value, string interpolation)
    {
        if (Kind != CutsceneBlockKind.Key || Head is not { } head)
        {
            throw new InvalidOperationException($"a {Kind} is not a key");
        }
        var key = new CutsceneBlock(CutsceneBlockKind.Key, null);
        key.Lines.Add(new TextLine($"{Indent(head)}key {Format(time)} {value} {interpolation}", "", hashInWord: true));
        return key;
    }

    // The blocks under this one in start order, keeping the order of blocks with one start. A block with no start
    // leaves the order as it is, since the cooker reports it. Under the cutscene, only the markers change places, among
    // the places that markers have, since the bindings and the tracks have no start.
    internal bool SortChildren()
    {
        if (Kind == CutsceneBlockKind.Cutscene)
        {
            return SortMarkers();
        }
        if (ChildList.Count < 2 || ChildList.Any(c => c.Start == null))
        {
            return false;
        }
        var sorted = ChildList.OrderBy(c => c.Start!.Value).ToList();
        if (sorted.SequenceEqual(ChildList))
        {
            return false;
        }
        ChildList.Clear();
        ChildList.AddRange(sorted);
        Touch();
        return true;
    }

    bool SortMarkers()
    {
        var slots = ChildList.Select((c, i) => (c, i)).Where(p => p.c.Kind == CutsceneBlockKind.Marker).Select(p => p.i).ToList();
        var markers = slots.Select(i => ChildList[i]).ToList();
        if (markers.Any(m => m.Start == null))
        {
            return false;
        }
        var sorted = markers.OrderBy(m => m.Start!.Value).ToList();
        if (sorted.SequenceEqual(markers))
        {
            return false;
        }
        for (var i = 0; i < slots.Count; i++)
        {
            ChildList[slots[i]] = sorted[i];
        }
        Touch();
        return true;
    }

    /// <summary>The block and every block under it, in the file's order.</summary>
    public IEnumerable<CutsceneBlock> Descendants()
    {
        yield return this;
        foreach (var child in ChildList)
        {
            foreach (var block in child.Descendants())
            {
                yield return block;
            }
        }
    }
}

/// <summary>
/// A cutscene's text (see docs/content/kinds/cutscenes.md) as whole lines, each in the block that
/// <c>tools/cook/cutscenes.odin</c> would read it in: a file writes back as it was, and an edit changes only its own
/// lines. The cooker ignores indents, so a block starts at its keyword line, and its settings are the lines up to the
/// next keyword line. It reads only the structure. What a block's lines mean, and whether they are right, is the
/// cooker's to say, so a cutscene with problems still opens, with its problems on its blocks.
/// </summary>
public sealed class CutsceneFile
{
    /// <summary>A second's ticks, the unit of every time in the file.</summary>
    public const int TicksPerSecond = 60000;

    /// <summary>The display rate of a cutscene that does not set one.</summary>
    public const int DefaultRate = 30;

    // What the file's last line ends with, whichever line that comes to be.
    string _finalEnding = "";

    CutsceneFile(CutsceneBlock root) => Root = root;

    /// <summary>The cutscene's block: the header and its settings, with the bindings and the tracks under it.</summary>
    public CutsceneBlock Root { get; }

    public IEnumerable<CutsceneBlock> Blocks => Root.Descendants();

    public IEnumerable<CutsceneBlock> Bindings => Root.Children.Where(b => b.Kind == CutsceneBlockKind.Binding);

    public IEnumerable<CutsceneBlock> Tracks => Root.Children.Where(b => b.Kind == CutsceneBlockKind.Track);

    /// <summary>The markers, in the file's order, which the editor keeps in time order.</summary>
    public IEnumerable<CutsceneBlock> Markers => Root.Children.Where(b => b.Kind == CutsceneBlockKind.Marker);

    /// <summary>The length in ticks, or null when the file does not set a good one.</summary>
    public int? Length => Root.Get("length") is { } text && TryParseTicks(text, out var ticks) && ticks > 0 ? ticks : null;

    /// <summary>The display rate in frames a second: the file's, when it is one that the cooker takes, or 30.</summary>
    public int Rate => Root.Get("rate") is { } text && int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var rate)
        && rate is 24 or 25 or 30 or 48 or 50 or 60
            ? rate
            : DefaultRate;

    /// <summary>The file's text.</summary>
    public string Text
    {
        get
        {
            var lines = Blocks.SelectMany(b => b.Lines).ToList();
            // A new line ends as the file's lines do.
            var ending = lines.Find(l => l.Ending != "")?.Ending ?? "\n";
            var text = new StringBuilder();
            for (var i = 0; i < lines.Count; i++)
            {
                text.Append(lines[i].Text).Append(i == lines.Count - 1 ? _finalEnding : lines[i].Ending != "" ? lines[i].Ending : ending);
            }
            return text.ToString();
        }
    }

    /// <summary>Reads a time or an ID as the cooker does: digits, with <c>_</c> between them, up to 2147483647.</summary>
    public static bool TryParseTicks(string text, out int ticks)
    {
        ticks = 0;
        long value = 0;
        var digits = 0;
        foreach (var c in text)
        {
            if (c == '_' && digits > 0)
            {
                continue;
            }
            if (!char.IsAsciiDigit(c))
            {
                return false;
            }
            value = value * 10 + (c - '0');
            digits++;
            if (value > int.MaxValue)
            {
                return false;
            }
        }
        ticks = (int)value;
        return digits > 0;
    }

    /// <summary>
    /// Reads a file's text. The file is null, with a problem at a line, when its first line that is not a comment is
    /// not <c>cutscene 1</c>, which is the only thing that it refuses.
    /// </summary>
    public static (CutsceneFile? File, MaterialProblem? Problem) Parse(string text)
    {
        var root = new CutsceneBlock(CutsceneBlockKind.Cutscene, null);
        var file = new CutsceneFile(root);
        var header = false;
        var open = root;
        // Blank lines and comments, which belong to the next block, or at the end, to the open one.
        var pending = new List<TextLine>();
        var number = 0;
        foreach (var line in TextLine.Split(text, hashInWord: true))
        {
            number++;
            file._finalEnding = line.Ending;
            if (line.IsBlank)
            {
                pending.Add(line);
                continue;
            }
            var fields = line.Code.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (!header)
            {
                if (fields is not ["cutscene", "1"])
                {
                    return (null, new MaterialProblem(number, "a cutscene starts with `cutscene 1`"));
                }
                header = true;
                root.Lines.AddRange(pending);
                pending.Clear();
                root.Lines.Add(line);
                continue;
            }
            // As in the cooker, a line is a block's when what follows its first word does not start with `=`.
            var rest = fields.Length > 1 ? line.Code[fields[0].Length..].TrimStart() : "";
            var parent = rest.StartsWith('=') ? null : ParentOf(fields[0], open);
            if (parent == null)
            {
                // A setting, or a line that the cooker reports, which stays in the open block.
                open.Lines.AddRange(pending);
                pending.Clear();
                open.Lines.Add(line);
                continue;
            }
            var block = new CutsceneBlock(KindOf(fields[0]), parent);
            block.Lines.AddRange(pending);
            pending.Clear();
            block.Lines.Add(line);
            parent.Adopt(block);
            // A key has no settings: the lines after it are the channel's, as the cooker reads them.
            open = block.Kind == CutsceneBlockKind.Key ? parent : block;
        }
        if (!header)
        {
            return (null, new MaterialProblem(1, "a cutscene starts with `cutscene 1`"));
        }
        // Comments and blank lines at the end stay with the block above them.
        var last = file.Blocks.Last();
        last.Lines.AddRange(pending);
        return (file, null);
    }

    static CutsceneBlockKind KindOf(string word) => word switch
    {
        "binding" => CutsceneBlockKind.Binding,
        "track" => CutsceneBlockKind.Track,
        "section" => CutsceneBlockKind.Section,
        "channel" => CutsceneBlockKind.Channel,
        "trigger" => CutsceneBlockKind.Trigger,
        "range" => CutsceneBlockKind.Range,
        "marker" => CutsceneBlockKind.Marker,
        _ => CutsceneBlockKind.Key,
    };

    // The block that a keyword line goes under, from the open block, or null for a line that is not a block's or that
    // the cooker has no place for and reports.
    static CutsceneBlock? ParentOf(string word, CutsceneBlock open)
    {
        CutsceneBlock? Up(CutsceneBlockKind kind)
        {
            for (var at = open; at != null; at = at.Parent)
            {
                if (at.Kind == kind)
                {
                    return at;
                }
            }
            return null;
        }
        return word switch
        {
            "binding" or "track" or "marker" => Up(CutsceneBlockKind.Cutscene),
            // A track's sections and events, after its settings or another section's or event's lines.
            "section" or "trigger" or "range" => open.Kind is CutsceneBlockKind.Track or CutsceneBlockKind.Section or CutsceneBlockKind.Channel
                or CutsceneBlockKind.Trigger or CutsceneBlockKind.Range
                ? Up(CutsceneBlockKind.Track)
                : null,
            "channel" => open.Kind is CutsceneBlockKind.Section or CutsceneBlockKind.Channel ? Up(CutsceneBlockKind.Section) : null,
            "key" => open.Kind == CutsceneBlockKind.Channel ? open : null,
            _ => null,
        };
    }

    /// <summary>The line, from 1, of a block's keyword line, or of its first line for the cutscene's block.</summary>
    public int LineOf(CutsceneBlock block)
    {
        var line = 1;
        foreach (var b in Blocks)
        {
            if (b == block)
            {
                return block.Head is { } head ? line + block.Lines.IndexOf(head) : line;
            }
            line += b.Lines.Count;
        }
        throw new ArgumentException("the block is not in this file", nameof(block));
    }

    /// <summary>The block whose own lines hold a line, from 1, or null past the end.</summary>
    public CutsceneBlock? BlockAt(int line)
    {
        var first = 1;
        foreach (var block in Blocks)
        {
            first += block.Lines.Count;
            if (line >= 1 && line < first)
            {
                return block;
            }
        }
        return null;
    }

    /// <summary>
    /// A block's path, which names it across an undo, as the undo reads the file again: its kind and ID, and for a
    /// channel, its section's path and its name, or for a key, its channel's path and its place in it. "" is the
    /// cutscene's block.
    /// </summary>
    public static string PathOf(CutsceneBlock block) => block.Kind switch
    {
        CutsceneBlockKind.Cutscene => "",
        CutsceneBlockKind.Channel => $"{PathOf(block.Parent!)}/channel:{block.Name}",
        CutsceneBlockKind.Key => $"{PathOf(block.Parent!)}/key:{block.Parent!.Children.Where(c => c.Kind == CutsceneBlockKind.Key).ToList().IndexOf(block)}",
        _ => $"{block.Kind.ToString().ToLowerInvariant()}:{block.Id}",
    };

    /// <summary>The block with a path, or null when the file has none, or more than one, as two sections with one ID do.</summary>
    public CutsceneBlock? Find(string path)
    {
        if (path == "")
        {
            return Root;
        }
        return Root.Index().GetValueOrDefault(path);
    }

    /// <summary>
    /// The ID after the highest of a kind's blocks. Sections' IDs are the cutscene's, so they count across tracks, and
    /// triggers and ranges share theirs, as the cooker checks them together.
    /// </summary>
    public int NextId(CutsceneBlockKind kind)
    {
        bool Shares(CutsceneBlock b) => b.Kind == kind
            || (kind is CutsceneBlockKind.Trigger or CutsceneBlockKind.Range && b.Kind is CutsceneBlockKind.Trigger or CutsceneBlockKind.Range);
        return Blocks.Where(Shares).Select(b => b.Id ?? 0).DefaultIfEmpty(0).Max() + 1;
    }

    /// <summary>Puts a block, as <see cref="CutsceneBlock.Copy"/> or <see cref="CutsceneBlock.KeyLike"/> makes it, under a parent at an index.</summary>
    public void Insert(CutsceneBlock parent, int index, CutsceneBlock block)
    {
        if (block.Parent != null)
        {
            throw new InvalidOperationException("the block is in a file already");
        }
        block.Adopt(parent, index);
    }

    /// <summary>
    /// Puts a block's children in start order, as the cooker wants a track's sections and a channel's keys, each with the
    /// comments above it. Children with one start keep their order. Returns whether the order changed.
    /// </summary>
    public static bool SortChildren(CutsceneBlock block) => block.SortChildren();

    /// <summary>Removes a block and the blocks under it, with the comments and blank lines above it.</summary>
    public void Remove(CutsceneBlock block)
    {
        if (block.Parent is not { } parent)
        {
            throw new InvalidOperationException("the cutscene's block stays");
        }
        parent.ChildList.Remove(block);
        parent.Touch();
        block.Detach();
    }
}

/// <summary>
/// An open cutscene and its edits. Its first state is the file's text as it is, so opening a file changes nothing, and
/// the first save changes only the lines of its edits.
/// </summary>
public sealed class CutsceneDocument : TextGraphDocument<CutsceneFile>
{
    CutsceneDocument(string path, string guid, CutsceneFile graph, string text) : base(path, guid, graph, text)
    {
    }

    /// <summary>Reads a file. The document is null, with a problem, when it cannot be read or does not start as a cutscene does.</summary>
    public static (CutsceneDocument? Document, MaterialProblem? Problem) Open(string path, string guid)
    {
        var (full, text, problem) = Read(path);
        if (text == null)
        {
            return (null, problem);
        }
        var (file, refused) = CutsceneFile.Parse(text);
        return (file == null ? null : new CutsceneDocument(full, guid, file, text), refused);
    }

    protected override string WriteGraph() => Graph.Text;

    protected override CutsceneFile ReadGraph(string text) => CutsceneFile.Parse(text).File!;
}
