namespace Cinnabar.Editor.Document;

public enum AnimationGraphNodeKind
{
    State,
    Blend1D,
    Transition,
}

/// <summary>A <c>param &lt;name&gt; &lt;type&gt; [&lt;default&gt;]</c> line.</summary>
public sealed class AnimationGraphParam : LineBlock
{
    string[] Fields => Lines[0].Code.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);

    public string Name => Fields[1];

    /// <summary><c>float</c>, <c>bool</c> or <c>trigger</c>, or another word, which the cooker reports.</summary>
    public string Type => Fields[2];

    public string? Default => Fields.Length > 3 ? Fields[3] : null;
}

/// <summary>A <c>clip &lt;name&gt; = $&lt;guid&gt;</c> line and the lines of its events.</summary>
public sealed class AnimationGraphClip : LineBlock
{
    public string Name => Lines[0].Key["clip".Length..].Trim();

    /// <summary>The GUID in lower case, without its <c>$</c>.</summary>
    public string Guid => Lines[0].Value[1..].ToLowerInvariant();

    /// <summary>Its events' lines, as the file has them.</summary>
    public IEnumerable<string> Events => Lines.Skip(1).Where(l => !l.IsBlank).Select(l => l.Code);
}

/// <summary>A <c>node &lt;id&gt; &lt;kind&gt;</c> line and the lines of its fields.</summary>
public sealed class AnimationGraphNode(int id, AnimationGraphNodeKind kind) : GraphNodeBlock(id)
{
    public AnimationGraphNodeKind Kind { get; } = kind;

    /// <summary>Gives a field's line another key, as a blend's inputs do when one before them goes.</summary>
    public void RenameField(string key, string renamed)
    {
        if (FieldLines.FirstOrDefault(l => l.Key == key) is { } line)
        {
            line.SetCode($"{renamed} = {line.Value}");
        }
    }
}

/// <summary>
/// An animation graph's text (see docs/content/kinds/animation-graphs.md#animation-graphs) as whole lines, each in the block that
/// <c>tools/cook/animation_graphs.odin</c> would read it in: a file writes back as it was, and an edit changes only its
/// own lines. It reads only the structure. What a block's lines mean, and whether they are right, is the cooker's to
/// say, so a graph with problems still opens, with its problems on its nodes.
/// </summary>
public sealed class AnimationGraphFile : IndentedLineFile, ITextFile<AnimationGraphFile>
{
    AnimationGraphFile()
    {
    }

    public IEnumerable<AnimationGraphNode> Nodes => _blocks.OfType<AnimationGraphNode>();

    public IEnumerable<AnimationGraphParam> Params => _blocks.OfType<AnimationGraphParam>();

    public IEnumerable<AnimationGraphClip> Clips => _blocks.OfType<AnimationGraphClip>();

    private protected override string HeaderWord => "animation_graph";

    private protected override string HeaderProblem => "an animation graph starts with `animation_graph 1`";

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

    private protected override bool HasIndentedLines(LineBlock block) => block is AnimationGraphClip or AnimationGraphNode;

    private protected override LineBlock? ReadBlock(TextLine line, string[] fields, HashSet<int> ids)
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
                return line.Key is "entry" or "root_motion" ? new SettingBlock(line.Key) : null;
        }
    }

    public AnimationGraphNode? Find(int id) => Nodes.FirstOrDefault(n => n.Id == id);

    /// <summary>The state that the graph starts in, by name: the last good line counts, as in the cooker.</summary>
    public string? Entry => SettingsOf("entry").Select(s => s.Value).LastOrDefault(MaterialFile.IsIdentifier);

    /// <summary>The joint that the graph reports root motion for: the last good line counts, as in the cooker.</summary>
    public string? RootMotion =>
        SettingsOf("root_motion").Select(s => GraphValue.Parse(s.Value)).OfType<GraphText>().LastOrDefault()?.Text;

    IEnumerable<SettingBlock> SettingsOf(string key) => Settings.Where(s => s.Key == key);

    public void SetEntry(string state) => SetSetting("entry", state);

    /// <summary>Names the joint for root motion, or with null or "", none.</summary>
    public void SetRootMotion(string? joint) => SetSetting("root_motion", string.IsNullOrEmpty(joint) ? null : TextQuote.Quote(joint));

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

    /// <summary>Swaps two blocks' places in the file, which for two transitions from a state is which the graph tries first.</summary>
    public void Swap(LineBlock a, LineBlock b)
    {
        var (first, second) = (_blocks.IndexOf(a), _blocks.IndexOf(b));
        if (first >= 0 && second >= 0)
        {
            (_blocks[first], _blocks[second]) = (b, a);
        }
    }
}
