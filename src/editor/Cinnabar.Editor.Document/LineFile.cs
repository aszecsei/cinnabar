using System.Text;

namespace Cinnabar.Editor.Document;

/// <summary>
/// Whole lines of a file that belong together: a keyword line, the lines under it, and in a cutscene, the comments
/// above it. Together, a file's blocks hold every line that it has.
/// </summary>
public abstract class LineBlock
{
    private protected LineBlock()
    {
    }

    internal List<TextLine> Lines { get; } = [];

    /// <summary>The text of the block's lines, without their endings.</summary>
    public IEnumerable<string> LineTexts => Lines.Select(l => l.Text);

    // The keyword line: the first that is not blank or a comment.
    internal TextLine? Head => Lines.FirstOrDefault(l => !l.IsBlank);

    // The lines under the keyword line that are not blank or comments.
    internal IEnumerable<TextLine> ContentLines => Lines.SkipWhile(l => l != Head).Skip(1).Where(l => !l.IsBlank);

    // The line of the block that a file's LineOf gives: its keyword line.
    internal int HeadIndex => Head is { } head ? Lines.IndexOf(head) : 0;
}

/// <summary>Comments, blank lines, the header, and lines that the cooker has no place for and reports.</summary>
public sealed class OtherBlock : LineBlock;

/// <summary>A <c>&lt;setting&gt; = &lt;value&gt;</c> line outside of a block, such as a decision's <c>technique</c>.</summary>
public sealed class SettingBlock(string key) : LineBlock
{
    public string Key { get; } = key;

    public string Value => Lines[0].Value;
}

/// <summary>A block whose lines under its keyword line are <c>key = value</c> fields.</summary>
public abstract class FieldBlock : LineBlock
{
    private protected FieldBlock()
    {
    }

    // Whether a line under the keyword line is a field. A decision's writes are not.
    private protected virtual bool IsField(TextLine line) => true;

    // Whether a new field goes under the keyword line, before the others, as a node's position does.
    private protected virtual bool ComesFirst(string key) => false;

    // A new line's indent: the last line's under the keyword line, or a tab more than the keyword line.
    internal virtual string NewLineIndent => ContentLines.LastOrDefault()?.Indent ?? (Head?.Indent ?? "") + "\t";

    internal IEnumerable<TextLine> FieldLines => ContentLines.Where(IsField);

    /// <summary>The fields in the file's order. A field that the cooker reports as set twice is here twice.</summary>
    public IEnumerable<(string Key, string Value)> Fields => FieldLines.Select(l => (l.Key, l.Value));

    /// <summary>A field's value as the file writes it, or null without it. The first line counts.</summary>
    public string? Get(string key) => FieldLines.FirstOrDefault(l => l.Key == key)?.Value;

    /// <summary>
    /// Sets a field on its own line, keeping the line's comment, or with null, removes each of its lines. A new field
    /// goes after the last field, so it comes before what follows the fields.
    /// </summary>
    public void Set(string key, string? value)
    {
        var fields = FieldLines.ToList();
        if (value == null)
        {
            Lines.RemoveAll(l => fields.Contains(l) && l.Key == key);
            return;
        }
        // A value is on one line.
        value = value.ReplaceLineEndings(" ");
        if (fields.Find(l => l.Key == key) is { } line)
        {
            line.SetValue(value);
            return;
        }
        var under = Head is { } head ? Lines.IndexOf(head) + 1 : Lines.Count;
        var at = ComesFirst(key) || fields.Count == 0 ? under : Lines.IndexOf(fields[^1]) + 1;
        Lines.Insert(at, new TextLine($"{NewLineIndent}{key} = {value}", "", Head?.HashInWord ?? false));
    }
}

/// <summary>A node of a graph file: a <c>node &lt;id&gt; &lt;kind&gt;</c> line and the lines of its fields.</summary>
public abstract class GraphNodeBlock : FieldBlock
{
    private protected GraphNodeBlock(int id) => Id = id;

    public int Id { get; }

    private protected override bool ComesFirst(string key) => key == "position";

    /// <summary>Where the file puts the node, or null when it does not, or its position is not two numbers.</summary>
    public (double X, double Y)? Position =>
        Get("position") is { } text && GraphNumbers.TryParse(text) is { Values: [var x, var y] } ? (x, y) : null;

    public void SetPosition(double x, double y) =>
        Set("position", $"[{GraphNumbers.Format(Math.Round(x))}, {GraphNumbers.Format(Math.Round(y))}]");
}

/// <summary>
/// A text file as whole lines, each in the block that its cooker would read it in: a file writes back as it was, and an
/// edit changes only its own lines. A format says which blocks it has, in the file's order.
/// </summary>
public abstract class LineFile<TBlock> where TBlock : LineBlock
{
    private protected LineFile()
    {
    }

    // What the file's last line ends with, whichever line that comes to be. A reader sets it for each line that it reads.
    private protected string FinalEnding { get; set; } = "";

    // The blocks in the file's order, whose lines in that order are the file's.
    private protected abstract IEnumerable<TBlock> InOrder { get; }

    /// <summary>The file's text.</summary>
    public string Text
    {
        get
        {
            var lines = InOrder.SelectMany(b => b.Lines).ToList();
            // A new line ends as the file's lines do.
            var ending = lines.Find(l => l.Ending != "")?.Ending ?? "\n";
            var text = new StringBuilder();
            for (var i = 0; i < lines.Count; i++)
            {
                text.Append(lines[i].Text).Append(i == lines.Count - 1 ? FinalEnding : lines[i].Ending != "" ? lines[i].Ending : ending);
            }
            return text.ToString();
        }
    }

    /// <summary>The line, from 1, of a block's keyword line, or of its first line for a block without one.</summary>
    public int LineOf(TBlock block)
    {
        var line = 1;
        foreach (var b in InOrder)
        {
            if (b == block)
            {
                return line + block.HeadIndex;
            }
            line += b.Lines.Count;
        }
        throw new ArgumentException("the block is not in this file", nameof(block));
    }

    /// <summary>The block whose own lines hold a line, from 1, or null past the end.</summary>
    public TBlock? BlockAt(int line)
    {
        var first = 1;
        foreach (var block in InOrder)
        {
            first += block.Lines.Count;
            if (line >= 1 && line < first)
            {
                return block;
            }
        }
        return null;
    }
}

/// <summary>A line file whose blocks are one list, with comments, blank lines and lines of no block in other blocks.</summary>
public abstract class BlockListFile : LineFile<LineBlock>
{
    private protected readonly List<LineBlock> _blocks = [];

    private protected BlockListFile()
    {
    }

    public IReadOnlyList<LineBlock> Blocks => _blocks;

    private protected override IEnumerable<LineBlock> InOrder => _blocks;

    // Adds lines at the end, in the last block when it is an other block.
    private protected void AppendOther(IEnumerable<TextLine> lines)
    {
        foreach (var line in lines)
        {
            AppendOther(line);
        }
    }

    private protected void AppendOther(TextLine line)
    {
        if (_blocks.LastOrDefault() is not OtherBlock other)
        {
            other = new OtherBlock();
            _blocks.Add(other);
        }
        other.Lines.Add(line);
    }

    // After the last of a group; or before what follows the group, with a blank line after it; or at the end, with a
    // blank line before it.
    private protected void InsertInGroup(LineBlock block, LineBlock? last, LineBlock? next)
    {
        if (last != null)
        {
            _blocks.Insert(_blocks.IndexOf(last) + 1, block);
            return;
        }
        var blank = new OtherBlock();
        blank.Lines.Add(new TextLine("", ""));
        if (next != null)
        {
            var at = _blocks.IndexOf(next);
            _blocks.Insert(at, block);
            _blocks.Insert(at + 1, blank);
            return;
        }
        // A blank line after the last block's lines, unless the file ends with one.
        if (_blocks[^1].Lines[^1].Text.Trim().Length > 0)
        {
            _blocks.Add(blank);
        }
        _blocks.Add(block);
    }

    /// <summary>
    /// Removes a block with the comment right above it, and leaves one blank line where it had one on each side.
    /// </summary>
    public void Remove(LineBlock block)
    {
        var at = _blocks.IndexOf(block);
        if (at < 0)
        {
            return;
        }
        _blocks.RemoveAt(at);
        if (at > 0 && _blocks[at - 1] is OtherBlock above)
        {
            while (above.Lines.Count > 0 && above.Lines[^1].Text.TrimStart().StartsWith('#'))
            {
                above.Lines.RemoveAt(above.Lines.Count - 1);
            }
            if (above.Lines.Count == 0)
            {
                _blocks.RemoveAt(--at);
            }
        }
        if (at > 0 && at < _blocks.Count && _blocks[at - 1] is OtherBlock before && _blocks[at] is OtherBlock after
            && before.Lines[^1].Text.Trim().Length == 0 && after.Lines[0].Text.Trim().Length == 0)
        {
            after.Lines.RemoveAt(0);
            if (after.Lines.Count == 0)
            {
                _blocks.RemoveAt(at);
            }
        }
    }
}

/// <summary>
/// A line file whose lines in the first column start blocks, and whose indented lines belong to the block above them,
/// as the animation graph's and the decision's cookers read them. A format says what block a line starts.
/// </summary>
public abstract class IndentedLineFile : BlockListFile
{
    private protected IndentedLineFile()
    {
    }

    // The word of the header, which is `<word> 1`.
    private protected abstract string HeaderWord { get; }

    // The problem of a file that does not start with its header.
    private protected abstract string HeaderProblem { get; }

    // The block that a line in the first column starts, without the line, or null for a line that the cooker has no
    // place for, whose indented lines then have no place either.
    private protected abstract LineBlock? ReadBlock(TextLine line, string[] fields, HashSet<int> ids);

    // Whether the indented lines after a block are its own. Those after another block have no place.
    private protected abstract bool HasIndentedLines(LineBlock block);

    /// <summary>The settings, in the file's order.</summary>
    public IEnumerable<SettingBlock> Settings => _blocks.OfType<SettingBlock>();

    // Reads a file's text into this file, which is empty. The problem is at a line when its first line that is not a
    // comment is not the header in the first column, which is the only thing that it refuses.
    private protected MaterialProblem? Read(string text)
    {
        var header = false;
        LineBlock? open = null;
        // Blank lines and comments: they stay in the open block when an indented line follows them.
        var pending = new List<TextLine>();
        var ids = new HashSet<int>();
        void Other(params IEnumerable<TextLine> lines)
        {
            var block = new OtherBlock();
            block.Lines.AddRange(lines);
            if (block.Lines.Count > 0)
            {
                _blocks.Add(block);
            }
        }
        void FlushPending()
        {
            Other(pending);
            pending.Clear();
        }
        var number = 0;
        foreach (var line in TextLine.Split(text))
        {
            number++;
            FinalEnding = line.Ending;
            if (line.IsBlank)
            {
                pending.Add(line);
                continue;
            }
            var indented = line.Text[0] is '\t' or ' ';
            var fields = line.Code.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (!header)
            {
                if (indented || fields is not [var word, "1"] || word != HeaderWord)
                {
                    return new MaterialProblem(number, HeaderProblem);
                }
                header = true;
                FlushPending();
                Other(line);
                continue;
            }
            if (indented)
            {
                if (open == null)
                {
                    FlushPending();
                    Other(line);
                }
                else
                {
                    open.Lines.AddRange(pending);
                    pending.Clear();
                    open.Lines.Add(line);
                }
                continue;
            }
            FlushPending();
            open = null;
            var block = ReadBlock(line, fields, ids);
            if (block == null)
            {
                Other(line);
                continue;
            }
            block.Lines.Add(line);
            _blocks.Add(block);
            open = HasIndentedLines(block) ? block : null;
        }
        if (!header)
        {
            return new MaterialProblem(1, HeaderProblem);
        }
        FlushPending();
        return null;
    }

    /// <summary>
    /// Sets a setting on one line, the first, and removes its other lines, so every cooker reads the one value. A new
    /// setting goes after the last setting, or under the header and its comments. Null removes each of its lines.
    /// </summary>
    public void SetSetting(string key, string? value)
    {
        var lines = Settings.Where(s => s.Key == key).ToList();
        foreach (var extra in value == null ? lines : lines.Skip(1))
        {
            Remove(extra);
        }
        if (value == null)
        {
            return;
        }
        if (lines.Count > 0)
        {
            lines[0].Lines[0].SetValue(value);
            return;
        }
        var block = new SettingBlock(key);
        block.Lines.Add(new TextLine($"{key} = {value}", ""));
        if (Settings.LastOrDefault() is { } last)
        {
            _blocks.Insert(_blocks.IndexOf(last) + 1, block);
            return;
        }
        // Under the header and the comments that follow it.
        var at = _blocks.FindIndex(b => b is OtherBlock && b.Lines.Any(l => !l.IsBlank)) + 1;
        while (at < _blocks.Count && _blocks[at] is OtherBlock && _blocks[at].Lines.All(l => l.Text.TrimStart().StartsWith('#')))
        {
            at++;
        }
        _blocks.Insert(at, block);
    }

    /// <summary>The node whose lines hold a line, from 1, or null for a line of no node.</summary>
    public int? NodeAt(int line) => (BlockAt(line) as GraphNodeBlock)?.Id;

    /// <summary>The ID after the highest.</summary>
    public int NextId() => _blocks.OfType<GraphNodeBlock>().Select(n => n.Id).DefaultIfEmpty(0).Max() + 1;
}
