using System.Text;

namespace Cinnabar.Editor.Document;

public enum AnimationGraphNodeKind
{
    State,
    Blend1D,
    Transition,
}

/// <summary>A line of the file and the line ending after it, which is "" for a new line or a last line without one.</summary>
sealed class AnimationGraphLine(string text, string ending)
{
    public string Text { get; set; } = text;

    public string Ending { get; set; } = ending;

    /// <summary>The line without its comment and the white space around it.</summary>
    public string Code => AnimationGraphFile.StripComment(Text).Trim();

    public bool IsBlank => Code.Length == 0;

    /// <summary>Replaces the line's code, keeping its indent and its comment.</summary>
    public void SetCode(string code)
    {
        var stripped = AnimationGraphFile.StripComment(Text);
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
}

/// <summary>Whole lines of the file that belong together. Together, a file's blocks hold every line that it has.</summary>
public abstract class AnimationGraphBlock
{
    internal List<AnimationGraphLine> Lines { get; } = [];

    /// <summary>The text of the block's lines, without their endings.</summary>
    public IEnumerable<string> LineTexts => Lines.Select(l => l.Text);
}

/// <summary>Comments, blank lines, the header, and lines that the cooker has no place for and reports.</summary>
public sealed class AnimationGraphOther : AnimationGraphBlock;

/// <summary>An <c>entry = ...</c> or <c>root_motion = ...</c> line.</summary>
public sealed class AnimationGraphSetting(string key) : AnimationGraphBlock
{
    public string Key { get; } = key;

    public string Value => Lines[0].Value;
}

/// <summary>A <c>param &lt;name&gt; &lt;type&gt; [&lt;default&gt;]</c> line.</summary>
public sealed class AnimationGraphParam : AnimationGraphBlock
{
    string[] Fields => Lines[0].Code.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);

    public string Name => Fields[1];

    /// <summary><c>float</c>, <c>bool</c> or <c>trigger</c>, or another word, which the cooker reports.</summary>
    public string Type => Fields[2];

    public string? Default => Fields.Length > 3 ? Fields[3] : null;
}

/// <summary>A <c>clip &lt;name&gt; = $&lt;guid&gt;</c> line and the lines of its events.</summary>
public sealed class AnimationGraphClip : AnimationGraphBlock
{
    public string Name => Lines[0].Key["clip".Length..].Trim();

    /// <summary>The GUID in lower case, without its <c>$</c>.</summary>
    public string Guid => Lines[0].Value[1..].ToLowerInvariant();

    /// <summary>Its events' lines, as the file has them.</summary>
    public IEnumerable<string> Events => Lines.Skip(1).Where(l => !l.IsBlank).Select(l => l.Code);
}

/// <summary>A <c>node &lt;id&gt; &lt;kind&gt;</c> line and the lines of its fields.</summary>
public sealed class AnimationGraphNode(int id, AnimationGraphNodeKind kind) : AnimationGraphBlock
{
    public int Id { get; } = id;

    public AnimationGraphNodeKind Kind { get; } = kind;

    /// <summary>The fields in the file's order. A field that the cooker reports as set twice is here twice.</summary>
    public IEnumerable<(string Key, string Value)> Fields => FieldLines.Select(l => (l.Key, l.Value));

    IEnumerable<AnimationGraphLine> FieldLines => Lines.Skip(1).Where(l => !l.IsBlank);

    /// <summary>A field's value as the file writes it, or null without it. The first line counts, as in the cooker.</summary>
    public string? Get(string key) => FieldLines.FirstOrDefault(l => l.Key == key)?.Value;

    /// <summary>Sets a field on its own line, keeping the line's comment, or with null, removes it.</summary>
    public void Set(string key, string? value)
    {
        var line = FieldLines.FirstOrDefault(l => l.Key == key);
        if (value == null)
        {
            Lines.RemoveAll(l => l != Lines[0] && !l.IsBlank && l.Key == key);
            return;
        }
        // A value is on one line.
        value = value.ReplaceLineEndings(" ");
        if (line != null)
        {
            line.SetValue(value);
            return;
        }
        var last = FieldLines.LastOrDefault();
        var indent = last == null ? "\t" : last.Text[..(last.Text.Length - last.Text.TrimStart().Length)];
        // A position comes first, and the rest in the order that they were set.
        var at = key == "position" || last == null ? 1 : Lines.IndexOf(last) + 1;
        Lines.Insert(at, new AnimationGraphLine($"{indent}{key} = {value}", ""));
    }

    /// <summary>Gives a field's line another key, as a blend's inputs do when one before them goes.</summary>
    public void RenameField(string key, string renamed)
    {
        if (FieldLines.FirstOrDefault(l => l.Key == key) is { } line)
        {
            line.SetCode($"{renamed} = {line.Value}");
        }
    }

    /// <summary>Where the file puts the node, or null when it does not, or its position is not two numbers.</summary>
    public (double X, double Y)? Position =>
        Get("position") is { } text && GraphNumbers.TryParse(text) is { Values: [var x, var y] } ? (x, y) : null;

    public void SetPosition(double x, double y) =>
        Set("position", $"[{GraphNumbers.Format(Math.Round(x))}, {GraphNumbers.Format(Math.Round(y))}]");
}

/// <summary>
/// An animation graph's text (see docs/content/kinds/animation-graphs.md#animation-graphs) as whole lines, each in the block that
/// <c>tools/cook/animation_graphs.odin</c> would read it in: a file writes back as it was, and an edit changes only its
/// own lines. It reads only the structure. What a block's lines mean, and whether they are right, is the cooker's to
/// say, so a graph with problems still opens, with its problems on its nodes.
/// </summary>
public sealed class AnimationGraphFile
{
    static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    readonly List<AnimationGraphBlock> _blocks = [];
    // What the file's last line ends with, whichever line that comes to be.
    string _finalEnding = "";

    AnimationGraphFile()
    {
    }

    public IReadOnlyList<AnimationGraphBlock> Blocks => _blocks;

    public IEnumerable<AnimationGraphNode> Nodes => _blocks.OfType<AnimationGraphNode>();

    public IEnumerable<AnimationGraphParam> Params => _blocks.OfType<AnimationGraphParam>();

    public IEnumerable<AnimationGraphClip> Clips => _blocks.OfType<AnimationGraphClip>();

    /// <summary>The file's text.</summary>
    public string Text
    {
        get
        {
            var lines = _blocks.SelectMany(b => b.Lines).ToList();
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

    /// <summary>The bytes of a file as text, or null when they are not UTF-8.</summary>
    public static string? Decode(byte[] bytes)
    {
        try
        {
            // This keeps a byte order mark, which the cooker has no place for either.
            return StrictUtf8.GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
            return null;
        }
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

    /// <summary>Reads a node's ID as the cooker does: with a sign, a prefix for its base, and <c>_</c> between its digits.</summary>
    public static bool TryParseId(string text, out int id)
    {
        id = 0;
        var negative = text.StartsWith('-');
        var digits = negative || text.StartsWith('+') ? text[1..] : text;
        var radix = 10;
        if (digits.Length > 1 && digits[0] == '0')
        {
            var prefix = char.ToLowerInvariant(digits[1]) switch { 'b' => 2, 'o' => 8, 'd' => 10, 'z' => 12, 'x' => 16, _ => 0 };
            if (prefix != 0)
            {
                radix = prefix;
                digits = digits[2..];
            }
        }
        long value = 0;
        foreach (var c in digits)
        {
            if (c == '_')
            {
                continue;
            }
            var digit = char.IsAsciiHexDigit(c) ? Convert.ToInt32(c.ToString(), 16) : radix;
            if (digit >= radix)
            {
                return false;
            }
            value = value * radix + digit;
            if (value > int.MaxValue)
            {
                return false;
            }
        }
        id = negative ? -(int)value : (int)value;
        return digits.Length > 0;
    }

    /// <summary>
    /// Reads a file's text. The file is null, with a problem at a line, when its first line that is not a comment is
    /// not <c>animation_graph 1</c>, which is the only thing that it refuses.
    /// </summary>
    public static (AnimationGraphFile? File, MaterialProblem? Problem) Parse(string text)
    {
        var file = new AnimationGraphFile();
        var header = false;
        AnimationGraphBlock? open = null;
        // Blank lines and comments: they stay in the open block when an indented line follows them.
        var pending = new List<AnimationGraphLine>();
        var ids = new HashSet<int>();
        void Other(params IEnumerable<AnimationGraphLine> lines)
        {
            var block = new AnimationGraphOther();
            block.Lines.AddRange(lines);
            if (block.Lines.Count > 0)
            {
                file._blocks.Add(block);
            }
        }
        void FlushPending()
        {
            Other(pending);
            pending.Clear();
        }
        var number = 0;
        foreach (var line in SplitLines(text))
        {
            number++;
            file._finalEnding = line.Ending;
            if (line.IsBlank)
            {
                pending.Add(line);
                continue;
            }
            var indented = line.Text[0] is '\t' or ' ';
            var fields = line.Code.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (!header)
            {
                if (indented || fields is not ["animation_graph", "1"])
                {
                    return (null, new MaterialProblem(number, "an animation graph starts with `animation_graph 1`"));
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
            file._blocks.Add(block);
            open = block is AnimationGraphClip or AnimationGraphNode ? block : null;
        }
        if (!header)
        {
            return (null, new MaterialProblem(1, "an animation graph starts with `animation_graph 1`"));
        }
        FlushPending();
        return (file, null);
    }

    static IEnumerable<AnimationGraphLine> SplitLines(string text)
    {
        var start = 0;
        while (start < text.Length)
        {
            var end = text.IndexOf('\n', start);
            if (end < 0)
            {
                yield return new AnimationGraphLine(text[start..], "");
                yield break;
            }
            var crlf = end > start && text[end - 1] == '\r';
            yield return new AnimationGraphLine(text[start..(crlf ? end - 1 : end)], crlf ? "\r\n" : "\n");
            start = end + 1;
        }
    }

    // The block that an unindented line starts, or null for a line that the cooker has no place for, whose indented
    // lines then have no place either.
    static AnimationGraphBlock? ReadBlock(AnimationGraphLine line, string[] fields, HashSet<int> ids)
    {
        switch (fields[0])
        {
            case "param":
                return fields.Length is 3 or 4 && MaterialFile.IsIdentifier(fields[1]) ? new AnimationGraphParam() : null;
            case "clip":
                var name = line.Key["clip".Length..].Trim();
                return MaterialFile.IsIdentifier(name) && line.Code.Contains('=') && GraphValue.Parse(line.Value) is GraphAsset ? new AnimationGraphClip() : null;
            case "node":
                if (fields.Length != 3 || !TryParseId(fields[1], out var id) || id <= 0)
                {
                    return null;
                }
                AnimationGraphNodeKind? kind = fields[2] switch
                {
                    "state" => AnimationGraphNodeKind.State,
                    "blend_1d" => AnimationGraphNodeKind.Blend1D,
                    "transition" => AnimationGraphNodeKind.Transition,
                    _ => null,
                };
                return kind != null && ids.Add(id) ? new AnimationGraphNode(id, kind.Value) : null;
            default:
                return line.Key is "entry" or "root_motion" ? new AnimationGraphSetting(line.Key) : null;
        }
    }

    /// <summary>The line, from 1, that a block's lines start at.</summary>
    public int LineOf(AnimationGraphBlock block)
    {
        var line = 1;
        foreach (var b in _blocks)
        {
            if (b == block)
            {
                return line;
            }
            line += b.Lines.Count;
        }
        throw new ArgumentException("the block is not in this file", nameof(block));
    }

    /// <summary>The block that holds a line, from 1, or null past the end.</summary>
    public AnimationGraphBlock? BlockAt(int line)
    {
        var first = 1;
        foreach (var block in _blocks)
        {
            first += block.Lines.Count;
            if (line >= 1 && line < first)
            {
                return block;
            }
        }
        return null;
    }

    /// <summary>The node whose lines hold a line, from 1, or null for a line of no node.</summary>
    public int? NodeAt(int line) => (BlockAt(line) as AnimationGraphNode)?.Id;

    public AnimationGraphNode? Find(int id) => Nodes.FirstOrDefault(n => n.Id == id);

    /// <summary>The ID after the highest.</summary>
    public int NextId() => Nodes.Select(n => n.Id).DefaultIfEmpty(0).Max() + 1;

    /// <summary>The state that the graph starts in, by name: the last good line counts, as in the cooker.</summary>
    public string? Entry => Settings("entry").Select(s => s.Value).LastOrDefault(MaterialFile.IsIdentifier);

    /// <summary>The joint that the graph reports root motion for: the last good line counts, as in the cooker.</summary>
    public string? RootMotion =>
        Settings("root_motion").Select(s => GraphValue.Parse(s.Value)).OfType<GraphText>().LastOrDefault()?.Text;

    IEnumerable<AnimationGraphSetting> Settings(string key) => _blocks.OfType<AnimationGraphSetting>().Where(s => s.Key == key);

    public void SetEntry(string state) => SetSetting("entry", state);

    /// <summary>Names the joint for root motion, or with null or "", none.</summary>
    public void SetRootMotion(string? joint)
    {
        if (string.IsNullOrEmpty(joint))
        {
            foreach (var setting in Settings("root_motion").ToList())
            {
                Remove(setting);
            }
            return;
        }
        SetSetting("root_motion", TextQuote.Quote(joint));
    }

    void SetSetting(string key, string value)
    {
        if (Settings(key).LastOrDefault() is { } setting)
        {
            setting.Lines[0].SetValue(value);
            return;
        }
        var block = new AnimationGraphSetting(key);
        block.Lines.Add(new AnimationGraphLine($"{key} = {value}", ""));
        // Under the header and the comments that follow it.
        var at = _blocks.FindIndex(b => b is AnimationGraphOther && b.Lines.Any(l => !l.IsBlank)) + 1;
        while (at < _blocks.Count && _blocks[at] is AnimationGraphOther && _blocks[at].Lines.All(l => l.Text.TrimStart().StartsWith('#')))
        {
            at++;
        }
        Insert(at, block);
    }

    /// <summary>Adds a parameter's line after the last parameter's, or before the clips and the nodes, with a blank line.</summary>
    public AnimationGraphParam AddParam(string name, string type, string? value)
    {
        var block = new AnimationGraphParam();
        block.Lines.Add(new AnimationGraphLine(ParamCode(name, type, value), ""));
        InsertInGroup(block, Params.LastOrDefault(), _blocks.FirstOrDefault(b => b is AnimationGraphClip or AnimationGraphNode));
        return block;
    }

    public static void SetParam(AnimationGraphParam param, string name, string type, string? value) =>
        param.Lines[0].SetCode(ParamCode(name, type, value));

    static string ParamCode(string name, string type, string? value) => value == null ? $"param {name} {type}" : $"param {name} {type} {value}";

    /// <summary>Adds a clip's line after the last clip, or before the nodes, with a blank line.</summary>
    public AnimationGraphClip AddClip(string name, string guid)
    {
        var block = new AnimationGraphClip();
        block.Lines.Add(new AnimationGraphLine($"clip {name} = ${guid}", ""));
        InsertInGroup(block, Clips.LastOrDefault(), _blocks.FirstOrDefault(b => b is AnimationGraphNode));
        return block;
    }

    public static void SetClip(AnimationGraphClip clip, string name, string guid) => clip.Lines[0].SetCode($"clip {name} = ${guid}");

    /// <summary>Adds a node after the last of its kind, or after the last node, with a blank line.</summary>
    public AnimationGraphNode AddNode(AnimationGraphNodeKind kind)
    {
        var block = new AnimationGraphNode(NextId(), kind);
        var word = kind switch { AnimationGraphNodeKind.State => "state", AnimationGraphNodeKind.Blend1D => "blend_1d", _ => "transition" };
        block.Lines.Add(new AnimationGraphLine($"node {block.Id} {word}", ""));
        InsertInGroup(block, Nodes.LastOrDefault(n => n.Kind == kind), null);
        return block;
    }

    // After the last of a group; or before what follows the group, with a blank line after it; or at the end, with a
    // blank line before it.
    void InsertInGroup(AnimationGraphBlock block, AnimationGraphBlock? last, AnimationGraphBlock? next)
    {
        if (last != null)
        {
            Insert(_blocks.IndexOf(last) + 1, block);
            return;
        }
        var blank = new AnimationGraphOther();
        blank.Lines.Add(new AnimationGraphLine("", ""));
        if (next != null)
        {
            var at = _blocks.IndexOf(next);
            Insert(at, block);
            Insert(at + 1, blank);
            return;
        }
        // A blank line after the last node's lines, unless the file ends with one.
        if (_blocks[^1].Lines[^1].Text.Trim().Length > 0)
        {
            Insert(_blocks.Count, blank);
        }
        Insert(_blocks.Count, block);
    }

    void Insert(int at, AnimationGraphBlock block) => _blocks.Insert(at, block);

    /// <summary>Removes a block. A node takes the comment right above it, and leaves one blank line where it had one on each side.</summary>
    public void Remove(AnimationGraphBlock block)
    {
        var at = _blocks.IndexOf(block);
        if (at < 0)
        {
            return;
        }
        _blocks.RemoveAt(at);
        if (block is AnimationGraphNode && at > 0 && _blocks[at - 1] is AnimationGraphOther above)
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
        if (at > 0 && at < _blocks.Count && _blocks[at - 1] is AnimationGraphOther before && _blocks[at] is AnimationGraphOther after
            && before.Lines[^1].Text.Trim().Length == 0 && after.Lines[0].Text.Trim().Length == 0)
        {
            after.Lines.RemoveAt(0);
            if (after.Lines.Count == 0)
            {
                _blocks.RemoveAt(at);
            }
        }
    }

    /// <summary>Swaps two blocks' places in the file, which for two transitions from a state is which the graph tries first.</summary>
    public void Swap(AnimationGraphBlock a, AnimationGraphBlock b)
    {
        var (first, second) = (_blocks.IndexOf(a), _blocks.IndexOf(b));
        if (first >= 0 && second >= 0)
        {
            (_blocks[first], _blocks[second]) = (b, a);
        }
    }
}
