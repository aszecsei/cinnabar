namespace Cinnabar.Editor.Document;

/// <summary>A key's line: <c>&lt;type&gt; &lt;name&gt; [= &lt;default&gt;]</c>, or <c>enum &lt;name&gt; (&lt;value&gt;, ...) [= &lt;default&gt;]</c>.</summary>
public sealed class BlackboardKey : LineBlock
{
    internal BlackboardKey(string type, string name, IReadOnlyList<string> values, string? @default)
    {
        Type = type;
        Name = name;
        Values = values;
        Default = @default;
    }

    /// <summary><c>float</c>, <c>int</c>, <c>bool</c>, <c>enum</c>, <c>entity</c>, <c>position</c> or <c>vector</c>.</summary>
    public string Type { get; private set; }

    public string Name { get; private set; }

    /// <summary>An enum's names, in their order, and none for another type.</summary>
    public IReadOnlyList<string> Values { get; private set; }

    /// <summary>The default as the file writes it, or null without one.</summary>
    public string? Default { get; private set; }

    internal void Set(string type, string name, IReadOnlyList<string> values, string? @default)
    {
        (Type, Name, Values, Default) = (type, name, type == "enum" ? values : [], string.IsNullOrWhiteSpace(@default) ? null : @default.Trim());
        Lines[0].SetCode(BlackboardFile.Code(Type, Name, Values, Default));
    }
}

/// <summary>
/// A blackboard's text (see docs/content/kinds/blackboards.md#the-text) as whole lines: a file writes back as it was,
/// and an edit changes only its own lines. It reads the keys' lines as the cooker does, and a line that the cooker would
/// refuse is kept as it is, so a blackboard with problems still opens.
/// </summary>
public sealed class BlackboardFile : BlockListFile, ITextFile<BlackboardFile>
{
    public const string Header = "a blackboard starts with `blackboard 1`";

    /// <summary>The types that a key can have, in the order that the editor offers them.</summary>
    public static readonly IReadOnlyList<string> Types = ["float", "int", "bool", "enum", "entity", "position", "vector"];

    BlackboardFile()
    {
    }

    /// <summary>The keys in their slots' order, which is the file's.</summary>
    public IEnumerable<BlackboardKey> Keys => _blocks.OfType<BlackboardKey>();

    public BlackboardKey? Find(string name) => Keys.FirstOrDefault(k => k.Name == name);

    /// <summary>
    /// Reads a file's text. The file is null, with a problem at a line, when its first line that is not a comment is
    /// not <c>blackboard 1</c>, which is the only thing that it refuses.
    /// </summary>
    public static (BlackboardFile? File, MaterialProblem? Problem) Parse(string text)
    {
        var file = new BlackboardFile();
        var header = false;
        var number = 0;
        foreach (var line in TextLine.Split(text))
        {
            number++;
            file.FinalEnding = line.Ending;
            if (!header && !line.IsBlank)
            {
                if (line.Code.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries) is not ["blackboard", "1"])
                {
                    return (null, new MaterialProblem(number, Header));
                }
                header = true;
            }
            if (header && !line.IsBlank && file._blocks.Count > 0 && ReadKey(line.Code) is { } key)
            {
                key.Lines.Add(line);
                file._blocks.Add(key);
            }
            else
            {
                file.AppendOther(line);
            }
        }
        return header ? (file, null) : (null, new MaterialProblem(1, Header));
    }

    // A key's line, as the cooker splits it, or null for a line that it reports. The default is not checked: the cooker
    // says whether it fits.
    static BlackboardKey? ReadKey(string code)
    {
        var at = code.IndexOf('=');
        var declaration = (at < 0 ? code : code[..at]).Trim();
        var @default = at < 0 ? null : code[(at + 1)..].Trim();
        var space = declaration.IndexOf(' ');
        var type = space < 0 ? declaration : declaration[..space];
        var rest = space < 0 ? "" : declaration[(space + 1)..].Trim();
        if (!Types.Contains(type))
        {
            return null;
        }
        IReadOnlyList<string> values = [];
        var name = rest;
        if (type == "enum")
        {
            var open = rest.IndexOf('(');
            if (open < 0 || !rest.EndsWith(')'))
            {
                return null;
            }
            name = rest[..open].Trim();
            values = [.. rest[(open + 1)..^1].Split(',').Select(v => v.Trim())];
        }
        return MaterialFile.IsIdentifier(name) ? new BlackboardKey(type, name, values, @default) : null;
    }

    internal static string Code(string type, string name, IReadOnlyList<string> values, string? @default)
    {
        var declaration = type == "enum" ? $"enum {name} ({string.Join(", ", values)})" : $"{type} {name}";
        return @default == null ? declaration : $"{declaration} = {@default}";
    }

    /// <summary>The key on a line, from 1, or null for a line of no key.</summary>
    public BlackboardKey? KeyAt(int line) => BlockAt(line) as BlackboardKey;

    /// <summary>Adds a key after the last key, or at the end of a blackboard without keys, with a blank line before it.</summary>
    public BlackboardKey AddKey(string type, string name, IReadOnlyList<string> values, string? @default)
    {
        var key = new BlackboardKey(type, name, type == "enum" ? values : [], @default);
        key.Lines.Add(new TextLine(Code(type, name, key.Values, @default), ""));
        InsertInGroup(key, Keys.LastOrDefault(), null);
        return key;
    }

    /// <summary>Changes a key's line, keeping its comment.</summary>
    public static void SetKey(BlackboardKey key, string type, string name, IReadOnlyList<string> values, string? @default) => key.Set(type, name, values, @default);

    /// <summary>Moves a key one slot up or down, past the key before or after it, with what lies between them.</summary>
    public void Move(BlackboardKey key, int by)
    {
        var keys = Keys.ToList();
        var at = keys.IndexOf(key);
        if (at < 0 || at + by < 0 || at + by >= keys.Count)
        {
            return;
        }
        var other = keys[at + by];
        var (a, b) = (_blocks.IndexOf(key), _blocks.IndexOf(other));
        (_blocks[a], _blocks[b]) = (other, key);
    }
}

/// <summary>An open blackboard and its edits.</summary>
public sealed class BlackboardDocument : TextGraphDocument<BlackboardFile>
{
    BlackboardDocument(string path, string guid, BlackboardFile file, string text) : base(path, guid, file, text)
    {
    }

    /// <summary>Reads a file. The document is null, with a problem, when it cannot be read or does not start as a blackboard does.</summary>
    public static (BlackboardDocument? Document, MaterialProblem? Problem) Open(string path, string guid) =>
        Open(path, (full, file, text) => new BlackboardDocument(full, guid, file, text));
}
