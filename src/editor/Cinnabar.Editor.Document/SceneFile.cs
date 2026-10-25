using System.Globalization;
using System.Text;

namespace Cinnabar.Editor.Document;

/// <summary>An error or a warning in a scene file, at a line from 1, or 0 for the whole file.</summary>
public sealed record SceneProblem(int Line, string Message, bool IsError)
{
    public override string ToString() => Line > 0 ? $"{Line}: {Message}" : Message;
}

/// <summary>
/// Reads and writes scene files (see docs/editor.md#scenes). The cooker reads the same format with
/// <c>asset_format.scene_parse</c>, and the two must agree. Writing sorts entities by scene ID and components by ID,
/// so an edit changes only the lines of the entity that it touches.
/// </summary>
public static class SceneFile
{
    public const int Version = 1;
    public const string Extension = ".scene";

    /// <summary>Parses a file. The scene is null when a problem is an error.</summary>
    public static (Scene? Scene, IReadOnlyList<SceneProblem> Problems) Parse(string text)
    {
        var parser = new Parser();
        parser.Run(text);
        return (parser.Problems.Any(p => p.IsError) ? null : parser.Scene, parser.Problems);
    }

    public static string Write(Scene scene)
    {
        var sb = new StringBuilder();
        foreach (var comment in scene.HeaderComments)
        {
            sb.Append(comment).Append('\n');
        }
        sb.Append(CultureInfo.InvariantCulture, $"scene {Version}\n");
        foreach (var e in scene.Entities.OrderBy(e => e.Id))
        {
            sb.Append(CultureInfo.InvariantCulture, $"\nentity {e.Id:x16}\n");
            if (e.Name.Length > 0)
            {
                sb.Append("name = ").Append(Quote(e.Name)).Append('\n');
            }
            if (e.Parent != 0)
            {
                sb.Append("parent = ").Append(FormatValue(SceneValue.EntityRef(e.Parent))).Append('\n');
            }
            if (!e.Active)
            {
                sb.Append("active = false\n");
            }
            foreach (var (key, value) in e.UnknownKeys)
            {
                sb.Append(key).Append(" = ").Append(value).Append('\n');
            }
            foreach (var c in e.Components.OrderBy(c => c.Id))
            {
                sb.Append(CultureInfo.InvariantCulture, $"component {c.Id} {c.Name}\n");
                WriteFields(sb, c.Fields);
            }
            foreach (var b in e.Behaviours)
            {
                sb.Append("behaviour ").Append(b.Script).Append('\n');
                WriteFields(sb, b.Fields);
            }
        }
        return sb.ToString();
    }

    static void WriteFields(StringBuilder sb, List<SceneField> fields)
    {
        foreach (var f in fields)
        {
            sb.Append('\t').Append(f.Name).Append(" = ").Append(FormatValue(f.Value)).Append('\n');
        }
    }

    public static string FormatValue(SceneValue value) => value.Kind switch
    {
        SceneValueKind.Bool => value.Bool ? "true" : "false",
        SceneValueKind.Number when value.Numbers.Count == 1 => FormatNumber(value.Numbers[0]),
        SceneValueKind.Number => "[" + string.Join(", ", value.Numbers.Select(FormatNumber)) + "]",
        SceneValueKind.String => Quote(value.Text),
        SceneValueKind.Name => value.Text,
        SceneValueKind.Asset => value.Asset == "" ? "$0" : $"${value.Asset}",
        _ => value.Entity == 0 ? "@0" : $"@{value.Entity:x16}",
    };

    // A float always has a point or an exponent, so it reads back as a float. A value that an f32 holds exactly, as
    // the editor writes for f32 fields, gets the f32's shortest form, so 0.70710677 is not 0.7071067690849304.
    static string FormatNumber(SceneNumber n)
    {
        if (n.Integer is { } integer)
        {
            return integer.ToString(CultureInfo.InvariantCulture);
        }
        var single = (float)n.Float;
        var text = single == n.Float
            ? single.ToString("R", CultureInfo.InvariantCulture)
            : n.Float.ToString("R", CultureInfo.InvariantCulture);
        return text.AsSpan().IndexOfAny(".Ee") >= 0 || !double.IsFinite(n.Float) ? text : text + ".0";
    }

    static string Quote(string text)
    {
        var sb = new StringBuilder("\"");
        foreach (var c in text)
        {
            sb.Append(c switch
            {
                '"' => "\\\"",
                '\\' => "\\\\",
                '\n' => "\\n",
                '\t' => "\\t",
                _ => c.ToString(),
            });
        }
        return sb.Append('"').ToString();
    }

    sealed class Parser
    {
        public Scene Scene { get; } = new();
        public List<SceneProblem> Problems { get; } = [];

        int _line;
        SceneEntity? _entity;
        List<SceneField>? _block;

        public void Run(string text)
        {
            var header = false;
            foreach (var raw in text.Split('\n'))
            {
                _line++;
                var line = raw.TrimEnd();
                var trimmed = line.TrimStart();
                if (trimmed.Length == 0 || trimmed[0] == '#')
                {
                    if (!header && trimmed.Length > 0)
                    {
                        Scene.HeaderComments.Add(trimmed);
                    }
                    continue;
                }
                if (!header)
                {
                    header = true;
                    if (trimmed != $"scene {Version}")
                    {
                        Error($"a scene file starts with `scene {Version}`");
                        return;
                    }
                    continue;
                }
                var indented = trimmed.Length < line.Length;
                var space = trimmed.IndexOf(' ');
                var word = space < 0 ? trimmed : trimmed[..space];
                var argument = space < 0 ? "" : trimmed[(space + 1)..].Trim();
                switch (word)
                {
                    case "entity" when !indented:
                        BeginEntity(argument);
                        break;
                    case "component" when !indented:
                        BeginComponent(argument);
                        break;
                    case "behaviour" when !indented:
                        BeginBehaviour(argument);
                        break;
                    default:
                        ParseLine(trimmed, indented);
                        break;
                }
            }
            if (!header)
            {
                _line = 1;
                Error($"a scene file starts with `scene {Version}`");
            }
            foreach (var group in Scene.Entities.GroupBy(e => e.Id).Where(g => g.Count() > 1))
            {
                _line = 0;
                Error($"two entities have the scene ID {group.Key:x16}");
            }
        }

        void Error(string message) => Problems.Add(new SceneProblem(_line, message, true));

        void Warning(string message) => Problems.Add(new SceneProblem(_line, message, false));

        void BeginEntity(string argument)
        {
            if (argument.Length != 16 || !ulong.TryParse(argument, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out var id) || id == 0)
            {
                Error($"an entity needs a nonzero scene ID of 16 hex digits, not \"{argument}\"");
                id = 0;
            }
            _entity = new SceneEntity(id);
            _block = null;
            Scene.Entities.Add(_entity);
        }

        void BeginComponent(string argument)
        {
            if (_entity == null)
            {
                Error("a component needs an entity line before it");
                return;
            }
            var space = argument.IndexOf(' ');
            var idText = space < 0 ? argument : argument[..space];
            var name = space < 0 ? "" : argument[(space + 1)..].Trim();
            if (!ulong.TryParse(idText, NumberStyles.None, CultureInfo.InvariantCulture, out var id) || id == 0)
            {
                Error($"a component needs its stable ID in decimal and its name, not \"{argument}\"");
            }
            if (_entity.Components.Any(c => c.Id == id))
            {
                Error($"the entity has component {id} twice");
            }
            var component = new SceneComponent(id, name, []);
            var at = _entity.Components.FindIndex(c => c.Id > id);
            _entity.Components.Insert(at < 0 ? _entity.Components.Count : at, component);
            _block = component.Fields;
        }

        void BeginBehaviour(string argument)
        {
            if (_entity == null)
            {
                Error("a behaviour needs an entity line before it");
                return;
            }
            if (argument.Length != 32 || !argument.All(Uri.IsHexDigit))
            {
                Error($"a behaviour needs its script's GUID of 32 hex digits, not \"{argument}\"");
            }
            var script = argument.ToLowerInvariant();
            if (_entity.Behaviours.Any(b => b.Script == script))
            {
                Error($"the entity has the behaviour {argument} twice");
            }
            var behaviour = new SceneBehaviour(script, []);
            _entity.Behaviours.Add(behaviour);
            _block = behaviour.Fields;
        }

        void ParseLine(string line, bool indented)
        {
            var equals = line.IndexOf('=');
            var key = equals < 0 ? "" : line[..equals].Trim();
            if (equals < 0 || key.Length == 0 || !key.All(c => IsWordChar(c) || c == '.'))
            {
                Error($"expected `name = value`, not \"{line}\"");
                return;
            }
            if (_entity == null)
            {
                Error($"{key} needs an entity line before it");
                return;
            }
            var text = line[(equals + 1)..].Trim();
            if (ParseValue(text) is not { } value)
            {
                return;
            }
            if (indented)
            {
                if (_block == null)
                {
                    Error($"the field {key} is indented, but no component or behaviour is open");
                    return;
                }
                if (_block.Any(f => f.Name == key))
                {
                    Error($"the field {key} is set twice");
                }
                _block.Add(new SceneField(key, value));
                return;
            }
            switch (key)
            {
                case "name" when value.Kind == SceneValueKind.String:
                    _entity.Name = value.Text;
                    break;
                case "name":
                    Error("name takes a quoted string");
                    break;
                case "parent" when value.Kind == SceneValueKind.Entity:
                    _entity.Parent = value.Entity;
                    break;
                case "parent":
                    Error("parent takes a scene ID, such as @1b04c7e95a2f3d88");
                    break;
                case "active" when value.Kind == SceneValueKind.Bool:
                    _entity.Active = value.Bool;
                    break;
                case "active":
                    Error("active takes true or false");
                    break;
                default:
                    Warning($"the entity key {key} is unknown, so the editor keeps it as it is");
                    _entity.UnknownKeys.Add((key, text));
                    break;
            }
        }

        static bool IsWordChar(char c) => c == '_' || char.IsAsciiLetterOrDigit(c);

        SceneValue? ParseValue(string text)
        {
            if (text.Length == 0)
            {
                Error("a value is missing");
                return null;
            }
            if (text is "true" or "false")
            {
                return SceneValue.Of(text == "true");
            }
            switch (text[0])
            {
                case '"':
                    return ParseString(text);
                case '@':
                    if (text.Length is < 2 or > 17 || !ulong.TryParse(text.AsSpan(1), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out var id))
                    {
                        Error($"a scene ID is up to 16 hex digits after @, not \"{text}\"");
                        return null;
                    }
                    return SceneValue.EntityRef(id);
                case '$':
                    if (text == "$0")
                    {
                        return SceneValue.AssetRef("");
                    }
                    if (text.Length != 33 || !text.Skip(1).All(Uri.IsHexDigit))
                    {
                        Error($"an asset is 32 hex digits after $, or $0 for none, not \"{text}\"");
                        return null;
                    }
                    return SceneValue.AssetRef(text[1..]);
                case '[':
                    if (text[^1] != ']')
                    {
                        Error($"an array ends with ], not \"{text}\"");
                        return null;
                    }
                    var elements = text[1..^1].Split(',');
                    if (elements.Length > 4)
                    {
                        Error($"an array has at most 4 numbers, not {elements.Length}");
                        return null;
                    }
                    var numbers = new SceneNumber[elements.Length];
                    for (var i = 0; i < elements.Length; i++)
                    {
                        if (ParseNumber(elements[i].Trim()) is not { } n)
                        {
                            return null;
                        }
                        numbers[i] = n;
                    }
                    return SceneValue.Of(numbers);
                case '-' or '+' or '.' or (>= '0' and <= '9'):
                    return ParseNumber(text) is { } number ? SceneValue.Of(number) : null;
            }
            if (!text.All(IsWordChar))
            {
                Error($"a value is a number, an array, a quoted string, a scene ID or a word, not \"{text}\"");
                return null;
            }
            return SceneValue.Name(text);
        }

        SceneNumber? ParseNumber(string text)
        {
            var digits = text[0] is '-' or '+' ? text[1..] : text;
            if (digits.Length > 0 && digits.All(char.IsAsciiDigit))
            {
                var value = Int128.Parse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture);
                if (value < long.MinValue || value > ulong.MaxValue)
                {
                    Error($"{text} does not fit in 64 bits");
                    return null;
                }
                return new SceneNumber((double)value, value);
            }
            if (!double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var f))
            {
                Error($"\"{text}\" is not a number");
                return null;
            }
            return SceneNumber.Of(f);
        }

        SceneValue? ParseString(string text)
        {
            if (text.Length < 2 || text[^1] != '"')
            {
                Error($"a string ends with a quote: {text}");
                return null;
            }
            var inner = text[1..^1];
            var sb = new StringBuilder();
            for (var i = 0; i < inner.Length; i++)
            {
                var c = inner[i];
                if (c == '"')
                {
                    Error($"a quote in a string needs a backslash before it: {text}");
                    return null;
                }
                if (c != '\\')
                {
                    sb.Append(c);
                    continue;
                }
                if (++i == inner.Length)
                {
                    Error($"a string ends with a backslash: {text}");
                    return null;
                }
                switch (inner[i])
                {
                    case '"' or '\\':
                        sb.Append(inner[i]);
                        break;
                    case 'n':
                        sb.Append('\n');
                        break;
                    case 't':
                        sb.Append('\t');
                        break;
                    default:
                        Error($"\\{inner[i]} is not an escape. A string has \\\", \\\\, \\n and \\t.");
                        return null;
                }
            }
            return SceneValue.String(sb.ToString());
        }
    }
}
