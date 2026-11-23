using System.Text;

namespace Cinnabar.Editor.Document;

/// <summary>Whole lines of a file that belong together. Together, a file's blocks hold every line that it has.</summary>
public abstract class LineBlock
{
    private protected LineBlock()
    {
    }

    internal List<TextLine> Lines { get; } = [];

    /// <summary>The text of the block's lines, without their endings.</summary>
    public IEnumerable<string> LineTexts => Lines.Select(l => l.Text);

    // The line of the block that LineOf gives: its keyword line. Only a block that keeps the comments above its keyword
    // line, as a cutscene's does, starts with another line.
    internal virtual int HeadIndex => 0;
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

    /// <summary>The line, from 1, of a block's keyword line, which is its first line unless it keeps the comments above it.</summary>
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

/// <summary>A line file whose blocks are one list, with comments, blank lines and lines of no block in its other blocks.</summary>
public abstract class BlockListFile<TBlock, TOther> : LineFile<TBlock>
    where TBlock : LineBlock
    where TOther : TBlock, new()
{
    private protected readonly List<TBlock> _blocks = [];

    private protected BlockListFile()
    {
    }

    public IReadOnlyList<TBlock> Blocks => _blocks;

    private protected override IEnumerable<TBlock> InOrder => _blocks;

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
        if (_blocks.LastOrDefault() is not TOther other)
        {
            other = new TOther();
            _blocks.Add(other);
        }
        other.Lines.Add(line);
    }
}

/// <summary>Where a format puts a setting that its file does not have yet.</summary>
enum SettingPlace
{
    /// <summary>Under the header and the comments that follow it, above the settings that the file has.</summary>
    UnderHeader,

    /// <summary>After the file's last setting, or without one, under the header and the comments that follow it.</summary>
    AfterLastSetting,
}

/// <summary>
/// A line file whose lines in the first column start blocks, and whose indented lines belong to the block above them,
/// as the animation graph's and the decision's cookers read them. A format says what block a line starts.
/// </summary>
public abstract class IndentedLineFile<TBlock, TOther> : BlockListFile<TBlock, TOther>
    where TBlock : LineBlock
    where TOther : TBlock, new()
{
    private protected IndentedLineFile()
    {
    }

    // The word of the header, which is `<word> 1`.
    private protected abstract string HeaderWord { get; }

    // The problem of a file that does not start with its header.
    private protected abstract string HeaderProblem { get; }

    // Where a new setting goes.
    private protected abstract SettingPlace NewSettingPlace { get; }

    // The block that a line in the first column starts, without the line, or null for a line that the cooker has no
    // place for, whose indented lines then have no place either.
    private protected abstract TBlock? ReadBlock(TextLine line, string[] fields, HashSet<int> ids);

    // Whether the indented lines after a block are its own. Those after another block have no place.
    private protected abstract bool HasIndentedLines(TBlock block);

    // Reads a file's text into this file, which is empty. The problem is at a line when its first line that is not a
    // comment is not the header in the first column, which is the only thing that it refuses.
    private protected MaterialProblem? Read(string text)
    {
        var header = false;
        TBlock? open = null;
        // Blank lines and comments: they stay in the open block when an indented line follows them.
        var pending = new List<TextLine>();
        var ids = new HashSet<int>();
        void Other(params IEnumerable<TextLine> lines)
        {
            var block = new TOther();
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

    // Puts a new setting's block where the format puts new settings.
    private protected void InsertSetting(TBlock setting, TBlock? lastSetting)
    {
        if (NewSettingPlace == SettingPlace.AfterLastSetting && lastSetting != null)
        {
            _blocks.Insert(_blocks.IndexOf(lastSetting) + 1, setting);
            return;
        }
        // Under the header and the comments that follow it.
        var at = _blocks.FindIndex(b => b is TOther && b.Lines.Any(l => !l.IsBlank)) + 1;
        while (at < _blocks.Count && _blocks[at] is TOther && _blocks[at].Lines.All(l => l.Text.TrimStart().StartsWith('#')))
        {
            at++;
        }
        _blocks.Insert(at, setting);
    }

    // After the last of a group; or before what follows the group, with a blank line after it; or at the end, with a
    // blank line before it.
    private protected void InsertInGroup(TBlock block, TBlock? last, TBlock? next)
    {
        if (last != null)
        {
            _blocks.Insert(_blocks.IndexOf(last) + 1, block);
            return;
        }
        var blank = new TOther();
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

    // Removes a block, and with takeComment, the comment right above it. It leaves one blank line where it had one on
    // each side.
    private protected void Remove(TBlock block, bool takeComment)
    {
        var at = _blocks.IndexOf(block);
        if (at < 0)
        {
            return;
        }
        _blocks.RemoveAt(at);
        if (takeComment && at > 0 && _blocks[at - 1] is TOther above)
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
        if (at > 0 && at < _blocks.Count && _blocks[at - 1] is TOther before && _blocks[at] is TOther after
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
/// The <c>key = value</c> field lines under a node's first line, which the animation graph's and the decision's nodes
/// share. Each format says which of a node's lines are fields, and what indent a new field takes.
/// </summary>
static class NodeFields
{
    /// <summary>A field's value as the file writes it, or null without it. The first line counts, as in the cookers.</summary>
    public static string? Get(IEnumerable<TextLine> fields, string key) => fields.FirstOrDefault(l => l.Key == key)?.Value;

    /// <summary>
    /// Sets a field on its own line, keeping the line's comment, or with null, removes each of its lines. A new position
    /// goes first, under the node's line, and another new field after the last field, at <paramref name="indent"/>.
    /// </summary>
    public static void Set(List<TextLine> lines, Func<TextLine, bool> isField, string key, string? value, string indent)
    {
        var head = lines[0];
        var fields = lines.Skip(1).Where(l => !l.IsBlank && isField(l)).ToList();
        if (value == null)
        {
            lines.RemoveAll(l => l != head && !l.IsBlank && isField(l) && l.Key == key);
            return;
        }
        // A value is on one line.
        value = value.ReplaceLineEndings(" ");
        if (fields.Find(l => l.Key == key) is { } line)
        {
            line.SetValue(value);
            return;
        }
        var last = fields.LastOrDefault();
        // A position comes first, and the rest in the order that they were set.
        var at = key == "position" || last == null ? 1 : lines.IndexOf(last) + 1;
        lines.Insert(at, new TextLine($"{indent}{key} = {value}", ""));
    }

    /// <summary>A <c>position</c> field's two numbers, or null when it is not two numbers.</summary>
    public static (double X, double Y)? Position(string? value) =>
        value is { } text && GraphNumbers.TryParse(text) is { Values: [var x, var y] } ? (x, y) : null;

    /// <summary>A position as a <c>position</c> field writes it, in whole units.</summary>
    public static string PositionValue(double x, double y) => $"[{GraphNumbers.Format(Math.Round(x))}, {GraphNumbers.Format(Math.Round(y))}]";
}
