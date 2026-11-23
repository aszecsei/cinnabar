namespace Cinnabar.Editor.Document;

public enum AnimationGraphNodeKind
{
    State,
    Blend1D,
    Transition,
}

/// <summary>Whole lines of an animation graph that belong together. Together, a file's blocks hold every line that it has.</summary>
public abstract class AnimationGraphBlock : LineBlock;

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

    IEnumerable<TextLine> FieldLines => Lines.Skip(1).Where(l => !l.IsBlank);

    // A new field's indent: the last field's, or a tab.
    string NewFieldIndent => FieldLines.LastOrDefault()?.Indent ?? "\t";

    /// <summary>A field's value as the file writes it, or null without it. The first line counts, as in the cooker.</summary>
    public string? Get(string key) => NodeFields.Get(FieldLines, key);

    /// <summary>Sets a field on its own line, keeping the line's comment, or with null, removes it.</summary>
    public void Set(string key, string? value) => NodeFields.Set(Lines, _ => true, key, value, NewFieldIndent);

    /// <summary>Gives a field's line another key, as a blend's inputs do when one before them goes.</summary>
    public void RenameField(string key, string renamed)
    {
        if (FieldLines.FirstOrDefault(l => l.Key == key) is { } line)
        {
            line.SetCode($"{renamed} = {line.Value}");
        }
    }

    /// <summary>Where the file puts the node, or null when it does not, or its position is not two numbers.</summary>
    public (double X, double Y)? Position => NodeFields.Position(Get("position"));

    public void SetPosition(double x, double y) => Set("position", NodeFields.PositionValue(x, y));
}

/// <summary>
/// An animation graph's text (see docs/content/kinds/animation-graphs.md#animation-graphs) as whole lines, each in the block that
/// <c>tools/cook/animation_graphs.odin</c> would read it in: a file writes back as it was, and an edit changes only its
/// own lines. It reads only the structure. What a block's lines mean, and whether they are right, is the cooker's to
/// say, so a graph with problems still opens, with its problems on its nodes.
/// </summary>
public sealed class AnimationGraphFile
    : IndentedLineFile<AnimationGraphBlock, AnimationGraphOther>, ITextFile<AnimationGraphFile>
{
    AnimationGraphFile()
    {
    }

    public IEnumerable<AnimationGraphNode> Nodes => _blocks.OfType<AnimationGraphNode>();

    public IEnumerable<AnimationGraphParam> Params => _blocks.OfType<AnimationGraphParam>();

    public IEnumerable<AnimationGraphClip> Clips => _blocks.OfType<AnimationGraphClip>();

    private protected override string HeaderWord => "animation_graph";

    private protected override string HeaderProblem => "an animation graph starts with `animation_graph 1`";

    // A new setting goes under the header, above the settings that the file has.
    private protected override SettingPlace NewSettingPlace => SettingPlace.UnderHeader;

    /// <summary>A line without a <c>#</c> and what follows it, outside of quotes.</summary>
    public static string StripComment(string line) => TextLine.StripComment(line);

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
        return file.Read(text) is { } problem ? (null, problem) : (file, null);
    }

    private protected override bool HasIndentedLines(AnimationGraphBlock block) => block is AnimationGraphClip or AnimationGraphNode;

    private protected override AnimationGraphBlock? ReadBlock(TextLine line, string[] fields, HashSet<int> ids)
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
        block.Lines.Add(new TextLine($"{key} = {value}", ""));
        InsertSetting(block, _blocks.OfType<AnimationGraphSetting>().LastOrDefault());
    }

    /// <summary>Adds a parameter's line after the last parameter's, or before the clips and the nodes, with a blank line.</summary>
    public AnimationGraphParam AddParam(string name, string type, string? value)
    {
        var block = new AnimationGraphParam();
        block.Lines.Add(new TextLine(ParamCode(name, type, value), ""));
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
        block.Lines.Add(new TextLine($"clip {name} = ${guid}", ""));
        InsertInGroup(block, Clips.LastOrDefault(), _blocks.FirstOrDefault(b => b is AnimationGraphNode));
        return block;
    }

    public static void SetClip(AnimationGraphClip clip, string name, string guid) => clip.Lines[0].SetCode($"clip {name} = ${guid}");

    /// <summary>Adds a node after the last of its kind, or after the last node, with a blank line.</summary>
    public AnimationGraphNode AddNode(AnimationGraphNodeKind kind)
    {
        var block = new AnimationGraphNode(NextId(), kind);
        var word = kind switch { AnimationGraphNodeKind.State => "state", AnimationGraphNodeKind.Blend1D => "blend_1d", _ => "transition" };
        block.Lines.Add(new TextLine($"node {block.Id} {word}", ""));
        InsertInGroup(block, Nodes.LastOrDefault(n => n.Kind == kind), null);
        return block;
    }

    /// <summary>Removes a block. A node takes the comment right above it, and leaves one blank line where it had one on each side.</summary>
    public void Remove(AnimationGraphBlock block) => Remove(block, takeComment: block is AnimationGraphNode);

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
