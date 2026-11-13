using System.Text;

namespace Cinnabar.Editor.Document;

/// <summary>Whole lines of a decision that belong together. Together, a file's blocks hold every line that it has.</summary>
public abstract class DecisionBlock
{
    internal List<TextLine> Lines { get; } = [];

    /// <summary>The text of the block's lines, without their endings.</summary>
    public IEnumerable<string> LineTexts => Lines.Select(l => l.Text);
}

/// <summary>Comments, blank lines, the header, and lines that the cooker has no place for and reports.</summary>
public sealed class DecisionOther : DecisionBlock;

/// <summary>A <c>&lt;setting&gt; = &lt;value&gt;</c> line outside of a node, such as <c>technique</c> or <c>blackboard</c>.</summary>
public sealed class DecisionSetting(string key) : DecisionBlock
{
    public string Key { get; } = key;

    public string Value => Lines[0].Value;
}

/// <summary>A <c>node &lt;id&gt; &lt;kind&gt;</c> line and the lines of its fields and its writes.</summary>
public sealed class DecisionNode(int id, string kind) : DecisionBlock
{
    public int Id { get; } = id;

    /// <summary>The node's kind, a word that its technique reads, such as <c>sequence</c> or <c>action</c>.</summary>
    public string Kind { get; } = kind;

    IEnumerable<TextLine> Content => Lines.Skip(1).Where(l => !l.IsBlank);

    IEnumerable<TextLine> FieldLines => Content.Where(l => !DecisionFile.IsWrite(l.Code));

    IEnumerable<TextLine> WriteLines => Content.Where(l => DecisionFile.IsWrite(l.Code));

    /// <summary>The fields in the file's order, without the writes. A field that the cooker reports as set twice is here twice.</summary>
    public IEnumerable<(string Key, string Value)> Fields => FieldLines.Select(l => (l.Key, l.Value));

    /// <summary>The <c>set &lt;key&gt; = &lt;value&gt;</c> lines, in their order, which is the order that they apply in.</summary>
    public IReadOnlyList<(string Key, string Value)> Writes => [.. WriteLines.Select(l => (l.Key["set".Length..].Trim(), l.Value))];

    /// <summary>A field's value as the file writes it, or null without it. The first line counts, as in the cooker.</summary>
    public string? Get(string key) => FieldLines.FirstOrDefault(l => l.Key == key)?.Value;

    /// <summary>Sets a field on its own line, keeping the line's comment, or with null, removes it.</summary>
    public void Set(string key, string? value)
    {
        var line = FieldLines.FirstOrDefault(l => l.Key == key);
        if (value == null)
        {
            Lines.RemoveAll(l => l != Lines[0] && !l.IsBlank && !DecisionFile.IsWrite(l.Code) && l.Key == key);
            return;
        }
        // A value is on one line.
        value = value.ReplaceLineEndings(" ");
        if (line != null)
        {
            line.SetValue(value);
            return;
        }
        var fields = FieldLines.ToList();
        var last = fields.LastOrDefault();
        // A position comes first, and the rest in the order that they were set, before the writes.
        var at = key == "position" || last == null ? 1 : Lines.IndexOf(last) + 1;
        Lines.Insert(at, new TextLine($"{Indent}{key} = {value}", ""));
    }

    /// <summary>Replaces the node's writes, keeping the lines of those that stay where they are.</summary>
    public void SetWrites(IReadOnlyList<(string Key, string Value)> writes)
    {
        var old = WriteLines.ToList();
        var at = old.Count > 0 ? Lines.IndexOf(old[0]) : Lines.IndexOf(Content.LastOrDefault() ?? Lines[0]) + 1;
        for (var i = 0; i < writes.Count; i++)
        {
            var code = $"set {writes[i].Key} = {writes[i].Value.ReplaceLineEndings(" ")}";
            if (i < old.Count)
            {
                if (old[i].Code != code)
                {
                    old[i].SetCode(code);
                }
                at = Lines.IndexOf(old[i]) + 1;
                continue;
            }
            Lines.Insert(at++, new TextLine($"{Indent}{code}", ""));
        }
        foreach (var line in old.Skip(writes.Count))
        {
            Lines.Remove(line);
        }
    }

    // The indent of the node's lines, or a tab.
    string Indent => Content.FirstOrDefault() is { } first ? first.Text[..(first.Text.Length - first.Text.TrimStart().Length)] : "\t";

    /// <summary>Where the file puts the node, or null when it does not, or its position is not two numbers.</summary>
    public (double X, double Y)? Position =>
        Get("position") is { } text && GraphNumbers.TryParse(text) is { Values: [var x, var y] } ? (x, y) : null;

    public void SetPosition(double x, double y) =>
        Set("position", $"[{GraphNumbers.Format(Math.Round(x))}, {GraphNumbers.Format(Math.Round(y))}]");

    /// <summary>The IDs that a list field, such as <c>children</c>, names, in their order. A word that is not an ID is left out.</summary>
    public IReadOnlyList<int> Ids(string key) => [.. IdWords(key).Select(w => w.Id).OfType<int>()];

    /// <summary>
    /// Writes a list field's IDs, each as it was written where the list had it, so <c>0x10</c> stays <c>0x10</c>. An empty
    /// list removes the field.
    /// </summary>
    public void SetIds(string key, IEnumerable<int> ids)
    {
        var written = new Dictionary<int, string>();
        foreach (var (word, id) in IdWords(key))
        {
            if (id is { } n)
            {
                written.TryAdd(n, word);
            }
        }
        var words = ids.Select(id => written.GetValueOrDefault(id, id.ToString(System.Globalization.CultureInfo.InvariantCulture))).ToList();
        Set(key, words.Count == 0 ? null : string.Join(", ", words));
    }

    IEnumerable<(string Word, int? Id)> IdWords(string key) =>
        (Get(key) ?? "").Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .Select(w => (w, AnimationGraphFile.TryParseId(w, out var id) ? id : (int?)null));

    /// <summary>
    /// Renames a blackboard key in the node's fields and writes that read keys, or with <paramref name="apply"/> false,
    /// changes nothing. It returns whether a line changes.
    /// </summary>
    internal bool RenameKey(string name, string newName, bool apply = true)
    {
        var changed = false;
        foreach (var line in Content.ToList())
        {
            if (DecisionFile.IsWrite(line.Code))
            {
                var key = line.Key["set".Length..].Trim();
                var value = DecisionKeys.Rename(line.Value, name, newName, DecisionKeys.Where.Value);
                if (key == name || value != line.Value)
                {
                    if (apply)
                    {
                        line.SetCode($"set {(key == name ? newName : key)} = {value}");
                    }
                    changed = true;
                }
                continue;
            }
            if (DecisionKeys.FieldWhere(line.Key) is { } where && DecisionKeys.Rename(line.Value, name, newName, where) is var renamed && renamed != line.Value)
            {
                if (apply)
                {
                    line.SetValue(renamed);
                }
                changed = true;
            }
        }
        return changed;
    }
}

/// <summary>
/// A decision's text (see docs/content/kinds/decisions.md#the-text) as whole lines, each in the block that
/// <c>tools/cook/decisions.odin</c> would read it in: a file writes back as it was, and an edit changes only its own
/// lines. It reads only the structure, the same for every technique. What a block's lines mean, and whether they are
/// right, is the cooker's to say, so a decision with problems still opens, with its problems on its nodes.
/// </summary>
public sealed class DecisionFile
{
    public const string Header = "a decision starts with `decision 1`";

    readonly List<DecisionBlock> _blocks = [];
    // What the file's last line ends with, whichever line that comes to be.
    string _finalEnding = "";

    DecisionFile()
    {
    }

    public IReadOnlyList<DecisionBlock> Blocks => _blocks;

    public IEnumerable<DecisionNode> Nodes => _blocks.OfType<DecisionNode>();

    public IEnumerable<DecisionSetting> Settings => _blocks.OfType<DecisionSetting>();

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

    /// <summary>Whether a line's code is a write, <c>set &lt;key&gt; = &lt;value&gt;</c>, as the cooker tells them from fields.</summary>
    internal static bool IsWrite(string code) => code.StartsWith("set ", StringComparison.Ordinal) || code.StartsWith("set\t", StringComparison.Ordinal);

    /// <summary>
    /// Reads a file's text. The file is null, with a problem at a line, when its first line that is not a comment is
    /// not <c>decision 1</c> in the first column, which is the only thing that it refuses.
    /// </summary>
    public static (DecisionFile? File, MaterialProblem? Problem) Parse(string text)
    {
        var file = new DecisionFile();
        var header = false;
        DecisionNode? open = null;
        // Blank lines and comments: they stay in the open node when an indented line follows them.
        var pending = new List<TextLine>();
        var ids = new HashSet<int>();
        void Other(params IEnumerable<TextLine> lines)
        {
            var block = new DecisionOther();
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
        foreach (var line in TextLine.Split(text))
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
                if (indented || fields is not ["decision", "1"])
                {
                    return (null, new MaterialProblem(number, Header));
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
            DecisionBlock? block = fields[0] == "node" ? ReadNode(fields, ids) : ReadSetting(line);
            if (block == null)
            {
                Other(line);
                continue;
            }
            block.Lines.Add(line);
            file._blocks.Add(block);
            open = block as DecisionNode;
        }
        if (!header)
        {
            return (null, new MaterialProblem(1, Header));
        }
        FlushPending();
        return (file, null);
    }

    // A node's line, or null for one that the cooker reports, whose indented lines then have no node either.
    static DecisionNode? ReadNode(string[] fields, HashSet<int> ids) =>
        fields.Length == 3 && AnimationGraphFile.TryParseId(fields[1], out var id) && id > 0 && MaterialFile.IsIdentifier(fields[2]) && ids.Add(id)
            ? new DecisionNode(id, fields[2])
            : null;

    static DecisionSetting? ReadSetting(TextLine line) =>
        line.Code.Contains('=') && MaterialFile.IsIdentifier(line.Key) && line.Value.Length > 0 ? new DecisionSetting(line.Key) : null;

    /// <summary>The line, from 1, that a block's lines start at.</summary>
    public int LineOf(DecisionBlock block)
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
    public DecisionBlock? BlockAt(int line)
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
    public int? NodeAt(int line) => (BlockAt(line) as DecisionNode)?.Id;

    public DecisionNode? Find(int id) => Nodes.FirstOrDefault(n => n.Id == id);

    /// <summary>The ID after the highest.</summary>
    public int NextId() => Nodes.Select(n => n.Id).DefaultIfEmpty(0).Max() + 1;

    /// <summary>A setting's value, or null without it. The first line counts, as in the cooker.</summary>
    public string? Setting(string key) => Settings.FirstOrDefault(s => s.Key == key)?.Value;

    /// <summary>The technique's name, as the file writes it.</summary>
    public string? Technique => Setting("technique");

    /// <summary>The GUID of the blackboard that the decision names, in lower case and without its <c>$</c>, or null without one.</summary>
    public string? Blackboard => GraphValue.Parse(Setting("blackboard") ?? "") is GraphAsset asset ? asset.Guid : null;

    /// <summary>Sets a setting on its line, or adds its line under the header and the settings, or with null, removes it.</summary>
    public void SetSetting(string key, string? value)
    {
        var setting = Settings.FirstOrDefault(s => s.Key == key);
        if (value == null)
        {
            if (setting != null)
            {
                Remove(setting);
            }
            return;
        }
        if (setting != null)
        {
            setting.Lines[0].SetValue(value);
            return;
        }
        var block = new DecisionSetting(key);
        block.Lines.Add(new TextLine($"{key} = {value}", ""));
        if (Settings.LastOrDefault() is { } last)
        {
            _blocks.Insert(_blocks.IndexOf(last) + 1, block);
            return;
        }
        // Under the header and the comments that follow it.
        var at = _blocks.FindIndex(b => b is DecisionOther && b.Lines.Any(l => !l.IsBlank)) + 1;
        while (at < _blocks.Count && _blocks[at] is DecisionOther && _blocks[at].Lines.All(l => l.Text.TrimStart().StartsWith('#')))
        {
            at++;
        }
        _blocks.Insert(at, block);
    }

    public void SetBlackboard(string guid) => SetSetting("blackboard", $"${guid.ToLowerInvariant()}");

    /// <summary>Adds a node after the last node, or at the end with a blank line before it.</summary>
    public DecisionNode AddNode(string kind)
    {
        var block = new DecisionNode(NextId(), kind);
        block.Lines.Add(new TextLine($"node {block.Id} {kind}", ""));
        if (Nodes.LastOrDefault() is { } last)
        {
            _blocks.Insert(_blocks.IndexOf(last) + 1, block);
            return block;
        }
        if (_blocks[^1].Lines[^1].Text.Trim().Length > 0)
        {
            var blank = new DecisionOther();
            blank.Lines.Add(new TextLine("", ""));
            _blocks.Add(blank);
        }
        _blocks.Add(block);
        return block;
    }

    /// <summary>Removes a block. A node takes the comment right above it, and leaves one blank line where it had one on each side.</summary>
    public void Remove(DecisionBlock block)
    {
        var at = _blocks.IndexOf(block);
        if (at < 0)
        {
            return;
        }
        _blocks.RemoveAt(at);
        if (block is DecisionNode && at > 0 && _blocks[at - 1] is DecisionOther above)
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
        if (at > 0 && at < _blocks.Count && _blocks[at - 1] is DecisionOther before && _blocks[at] is DecisionOther after
            && before.Lines[^1].Text.Trim().Length == 0 && after.Lines[0].Text.Trim().Length == 0)
        {
            after.Lines.RemoveAt(0);
            if (after.Lines.Count == 0)
            {
                _blocks.RemoveAt(at);
            }
        }
    }

    /// <summary>
    /// Renames a blackboard key wherever the decision reads or writes it: conditions, times, action arguments' values,
    /// writes, and the planning techniques' keys, tests and effects. Quoted strings, action and argument names and other
    /// fields stay as they are. It returns whether a line changed.
    /// </summary>
    public bool RenameKey(string name, string newName) => RenameKey(name, newName, apply: true);

    /// <summary>Whether the decision reads or writes a key, which a rename of the key would change.</summary>
    public bool ReadsKey(string name) => RenameKey(name, name + "_", apply: false);

    bool RenameKey(string name, string newName, bool apply)
    {
        var changed = false;
        foreach (var setting in Settings)
        {
            if (DecisionKeys.FieldWhere(setting.Key) is { } where && DecisionKeys.Rename(setting.Value, name, newName, where) is var renamed && renamed != setting.Value)
            {
                if (apply)
                {
                    setting.Lines[0].SetValue(renamed);
                }
                changed = true;
            }
        }
        foreach (var node in Nodes)
        {
            changed |= node.RenameKey(name, newName, apply);
        }
        return changed;
    }
}

/// <summary>Where blackboard keys are in a decision's values, so renaming a key changes those words and no others.</summary>
static class DecisionKeys
{
    public enum Where
    {
        /// <summary>Any word that is not a call's name: a condition, a time, a test or an effect, a key list.</summary>
        Value,

        /// <summary>An action reference: only the arguments' values, and not the action's name or the arguments' names.</summary>
        Action,
    }

    /// <summary>Where a field or setting's value names keys, or null for one that names none.</summary>
    public static Where? FieldWhere(string key) => key switch
    {
        "action" => Where.Action,
        "when" or "condition" or "seconds" or "cooldown" or "time_limit" or "input" or "target" or "keys" or "desired" or "preconditions"
            or "effects" or "cost" => Where.Value,
        _ => null,
    };

    /// <summary>A value with each word that names a key renamed. A value that does not name it comes back as it was.</summary>
    public static string Rename(string value, string name, string newName, Where where)
    {
        var text = new StringBuilder();
        var changed = false;
        var depth = 0;
        for (var i = 0; i < value.Length;)
        {
            var c = value[i];
            if (c == '"')
            {
                var end = i + 1;
                while (end < value.Length && value[end] != '"')
                {
                    end += value[end] == '\\' ? 2 : 1;
                }
                end = Math.Min(end + 1, value.Length);
                text.Append(value, i, end - i);
                i = end;
                continue;
            }
            if (char.IsAsciiLetter(c) || c == '_')
            {
                var end = i + 1;
                while (end < value.Length && (char.IsAsciiLetterOrDigit(value[end]) || value[end] == '_'))
                {
                    end++;
                }
                var word = value[i..end];
                var next = end;
                while (next < value.Length && value[next] is ' ' or '\t')
                {
                    next++;
                }
                var call = next < value.Length && value[next] == '(';
                var argumentName = where == Where.Action && next < value.Length && value[next] == '=' && (next + 1 >= value.Length || value[next + 1] != '=');
                var isKey = word == name && !call && (where == Where.Value || (depth > 0 && !argumentName));
                text.Append(isKey ? newName : word);
                changed |= isKey;
                i = end;
                continue;
            }
            if (char.IsAsciiDigit(c))
            {
                // A number, with what follows its digits, such as 1e3 or 0x1f, is not a word.
                var end = i + 1;
                while (end < value.Length && (char.IsAsciiLetterOrDigit(value[end]) || value[end] is '_' or '.'))
                {
                    end++;
                }
                text.Append(value, i, end - i);
                i = end;
                continue;
            }
            depth += c == '(' ? 1 : c == ')' ? -1 : 0;
            text.Append(c);
            i++;
        }
        return changed ? text.ToString() : value;
    }
}
