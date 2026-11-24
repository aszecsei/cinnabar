using System.Text;

namespace Cinnabar.Editor.Document;

/// <summary>A <c>node &lt;id&gt; &lt;kind&gt;</c> line and the lines of its fields and its writes.</summary>
public sealed class DecisionNode(int id, string kind) : GraphNodeBlock(id)
{
    /// <summary>The node's kind, a word that its technique reads, such as <c>sequence</c> or <c>action</c>.</summary>
    public string Kind { get; } = kind;

    // A write is not a field.
    private protected override bool IsField(TextLine line) => !DecisionFile.IsWrite(line.Code);

    IEnumerable<TextLine> WriteLines => ContentLines.Where(l => DecisionFile.IsWrite(l.Code));

    /// <summary>The <c>set &lt;key&gt; = &lt;value&gt;</c> lines, in their order, which is the order that they apply in.</summary>
    public IReadOnlyList<(string Key, string Value)> Writes => [.. WriteLines.Select(l => (l.Key["set".Length..].Trim(), l.Value))];

    /// <summary>Replaces the node's writes, keeping the lines of those that stay where they are.</summary>
    public void SetWrites(IReadOnlyList<(string Key, string Value)> writes)
    {
        var old = WriteLines.ToList();
        var at = old.Count > 0 ? Lines.IndexOf(old[0]) : Lines.IndexOf(ContentLines.LastOrDefault() ?? Lines[0]) + 1;
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
            Lines.Insert(at++, new TextLine($"{NewLineIndent}{code}", ""));
        }
        foreach (var line in old.Skip(writes.Count))
        {
            Lines.Remove(line);
        }
    }

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
        foreach (var line in ContentLines.ToList())
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
public sealed class DecisionFile : IndentedLineFile, ITextFile<DecisionFile>
{
    public const string Header = "a decision starts with `decision 1`";

    DecisionFile()
    {
    }

    public IEnumerable<DecisionNode> Nodes => _blocks.OfType<DecisionNode>();

    private protected override string HeaderWord => "decision";

    private protected override string HeaderProblem => Header;

    /// <summary>Whether a line's code is a write, <c>set &lt;key&gt; = &lt;value&gt;</c>, as the cooker tells them from fields.</summary>
    internal static bool IsWrite(string code) => code.StartsWith("set ", StringComparison.Ordinal) || code.StartsWith("set\t", StringComparison.Ordinal);

    /// <summary>
    /// Reads a file's text. The file is null, with a problem at a line, when its first line that is not a comment is
    /// not <c>decision 1</c> in the first column, which is the only thing that it refuses.
    /// </summary>
    public static (DecisionFile? File, MaterialProblem? Problem) Parse(string text)
    {
        var file = new DecisionFile();
        return file.Read(text) is { } problem ? (null, problem) : (file, null);
    }

    private protected override LineBlock? ReadBlock(TextLine line, string[] fields, HashSet<int> ids) =>
        fields[0] == "node" ? ReadNode(fields, ids) : ReadSetting(line);

    private protected override bool HasIndentedLines(LineBlock block) => block is DecisionNode;

    // A node's line, or null for one that the cooker reports, whose indented lines then have no node either.
    static DecisionNode? ReadNode(string[] fields, HashSet<int> ids) =>
        fields.Length == 3 && AnimationGraphFile.TryParseId(fields[1], out var id) && id > 0 && MaterialFile.IsIdentifier(fields[2]) && ids.Add(id)
            ? new DecisionNode(id, fields[2])
            : null;

    static SettingBlock? ReadSetting(TextLine line) =>
        line.Code.Contains('=') && MaterialFile.IsIdentifier(line.Key) && line.Value.Length > 0 ? new SettingBlock(line.Key) : null;

    public DecisionNode? Find(int id) => Nodes.FirstOrDefault(n => n.Id == id);

    /// <summary>A setting's value, or null without it. The first line counts, as in the cooker.</summary>
    public string? Setting(string key) => Settings.FirstOrDefault(s => s.Key == key)?.Value;

    /// <summary>The technique's name, as the file writes it.</summary>
    public string? Technique => Setting("technique");

    /// <summary>The GUID of the blackboard that the decision names, in lower case and without its <c>$</c>, or null without one.</summary>
    public string? Blackboard => GraphValue.Parse(Setting("blackboard") ?? "") is GraphAsset asset ? asset.Guid : null;

    public void SetBlackboard(string guid) => SetSetting("blackboard", $"${guid.ToLowerInvariant()}");

    /// <summary>Adds a node after the last node, or at the end with a blank line before it.</summary>
    public DecisionNode AddNode(string kind)
    {
        var block = new DecisionNode(NextId(), kind);
        block.Lines.Add(new TextLine($"node {block.Id} {kind}", ""));
        InsertInGroup(block, Nodes.LastOrDefault(), null);
        return block;
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
