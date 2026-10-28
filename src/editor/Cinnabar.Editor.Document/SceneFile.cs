using System.Globalization;
using System.Text;

namespace Cinnabar.Editor.Document;

/// <summary>An error or a warning in a scene file, at a line from 1, or 0 for the whole file.</summary>
public sealed record SceneProblem(int Line, string Message, bool IsError)
{
    public override string ToString() => Line > 0 ? $"{Line}: {Message}" : Message;
}

/// <summary>
/// Reads and writes scene files (see docs/editor/document-and-scenes.md#scenes). The cooker reads the same format with
/// <c>asset_format.scene_parse</c>, and the two must agree. Writing sorts entities by scene ID, with an instance's
/// override blocks after it by path (see docs/editor/prefabs.md#instances-in-a-scene), and components by ID, so an edit
/// changes only the lines of the entity that it touches. A prefab is a scene file with one root. The reader takes
/// version 1 too, which has no instances.
/// </summary>
public static class SceneFile
{
    public const int Version = 2;
    public const string Extension = ".scene";
    public const string PrefabExtension = ".prefab";

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
        foreach (var e in scene.Entities.OrderBy(e => e.Path ?? [e.Id], PathOrder.Instance))
        {
            sb.Append("\nentity ").Append(e.Path != null ? ScenePath.Format(e.Path) : e.Id.ToString("x16", CultureInfo.InvariantCulture)).Append('\n');
            // A plain entity writes what differs from an entity's defaults, and a prefab's entity what it overrides.
            var plain = e.Path == null && e.Prefab == "";
            if (plain ? e.Name.Length > 0 : e.Keys.HasFlag(SceneKeys.Name))
            {
                sb.Append("name = ").Append(Quote(e.Name)).Append('\n');
            }
            if (e.Path == null ? e.Parent != 0 : e.Keys.HasFlag(SceneKeys.Parent))
            {
                var parent = e.ParentPath is { } path && ScenePath.Id(path) == e.Parent ? SceneValue.EntityRef(path) : SceneValue.EntityRef(e.Parent);
                sb.Append("parent = ").Append(FormatValue(parent)).Append('\n');
            }
            if (e.Prefab != "")
            {
                sb.Append("prefab = $").Append(e.Prefab).Append('\n');
            }
            if (plain ? !e.Active : e.Keys.HasFlag(SceneKeys.Active))
            {
                sb.Append(e.Active ? "active = true\n" : "active = false\n");
            }
            if (e.Removed)
            {
                sb.Append("removed = true\n");
            }
            foreach (var (key, value) in e.UnknownKeys)
            {
                sb.Append(key).Append(" = ").Append(value).Append('\n');
            }
            foreach (var id in e.RemovedComponents)
            {
                sb.Append(CultureInfo.InvariantCulture, $"remove component {id}\n");
            }
            foreach (var script in e.RemovedBehaviours)
            {
                sb.Append("remove behaviour $").Append(script).Append('\n');
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

    // Paths in order of their IDs, a path before the longer ones that it starts.
    sealed class PathOrder : IComparer<IReadOnlyList<ulong>>
    {
        public static readonly PathOrder Instance = new();

        public int Compare(IReadOnlyList<ulong>? a, IReadOnlyList<ulong>? b)
        {
            for (var i = 0; i < Math.Min(a!.Count, b!.Count); i++)
            {
                if (a[i] != b[i])
                {
                    return a[i].CompareTo(b[i]);
                }
            }
            return a.Count.CompareTo(b.Count);
        }
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
        _ when value.Path != null => "@" + ScenePath.Format(value.Path),
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
                    if (trimmed != "scene 1" && trimmed != $"scene {Version}")
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
                    case "remove" when !indented:
                        ParseRemove(argument);
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
            FinishEntity();
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
            FinishEntity();
            if (ParsePath(argument) is not { } path)
            {
                Error($"an entity needs a nonzero scene ID of 16 hex digits, or a path of them joined by #, not \"{argument}\"");
                path = [0];
            }
            _entity = path.Count > 1 ? new SceneEntity(path) : new SceneEntity(path[0]);
            _block = null;
            Scene.Entities.Add(_entity);
        }

        // Only the block of a prefab's entity can take away what the prefab gives it.
        void FinishEntity()
        {
            if (_entity is { Path: null, Prefab: "" } && (_entity.RemovedComponents.Count > 0 || _entity.RemovedBehaviours.Count > 0))
            {
                Error($"entity {_entity.Id:x16}: only an instance or an override block removes a component or a behaviour");
            }
        }

        // A scene ID, or a path of up to ScenePath.MaxLength of them joined by #, each 16 hex digits and nonzero.
        static List<ulong>? ParsePath(string text)
        {
            var parts = text.Split('#');
            if (parts.Length > ScenePath.MaxLength)
            {
                return null;
            }
            var path = new List<ulong>(parts.Length);
            foreach (var part in parts)
            {
                if (part.Length != 16 || !ulong.TryParse(part, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out var id) || id == 0)
                {
                    return null;
                }
                path.Add(id);
            }
            return path;
        }

        // `remove component <id>` and `remove behaviour $<guid>`.
        void ParseRemove(string argument)
        {
            if (_entity == null)
            {
                Error("a remove needs an entity line before it");
                return;
            }
            _block = null;
            var space = argument.IndexOf(' ');
            var what = space < 0 ? argument : argument[..space];
            var target = space < 0 ? "" : argument[(space + 1)..].Trim();
            switch (what)
            {
                case "component":
                    if (!ulong.TryParse(target, NumberStyles.None, CultureInfo.InvariantCulture, out var id) || id == 0)
                    {
                        Error($"remove component takes the component's stable ID in decimal, not \"{target}\"");
                        return;
                    }
                    _entity.RemovedComponents.Add(id);
                    break;
                case "behaviour":
                    if (target.Length != 33 || target[0] != '$' || !target.Skip(1).All(Uri.IsHexDigit))
                    {
                        Error($"remove behaviour takes the script's GUID, such as $9d2e41c0b7a35f6e81c4d2a90b3e7f15, not \"{target}\"");
                        return;
                    }
                    _entity.RemovedBehaviours.Add(target[1..].ToLowerInvariant());
                    break;
                default:
                    Error($"remove takes component <id> or behaviour $<guid>, not \"{argument}\"");
                    break;
            }
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
                    _entity.Keys |= SceneKeys.Name;
                    break;
                case "name":
                    Error("name takes a quoted string");
                    break;
                case "parent" when value.Kind == SceneValueKind.Entity:
                    _entity.Parent = value.Entity;
                    _entity.ParentPath = value.Path;
                    _entity.Keys |= SceneKeys.Parent;
                    break;
                case "parent":
                    Error("parent takes a scene ID, such as @1b04c7e95a2f3d88");
                    break;
                case "active" when value.Kind == SceneValueKind.Bool:
                    _entity.Active = value.Bool;
                    _entity.Keys |= SceneKeys.Active;
                    break;
                case "active":
                    Error("active takes true or false");
                    break;
                case "prefab" when value.Kind != SceneValueKind.Asset || value.Asset == "":
                    Error("prefab takes the prefab's GUID, such as $9db8150cc7215ffc2708d20d77cf60bf");
                    break;
                case "prefab":
                    if (_entity.Path != null)
                    {
                        Error("an override block cannot change which prefab an entity instantiates");
                    }
                    _entity.Prefab = value.Asset;
                    break;
                case "removed" when value.Kind != SceneValueKind.Bool:
                    Error("removed takes true or false");
                    break;
                case "removed":
                    if (_entity.Path == null)
                    {
                        Error("only an override block, whose ID is a path, takes removed");
                    }
                    _entity.Removed = value.Bool;
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
                case '@' when text.Contains('#'):
                    if (ParsePath(text[1..]) is not { } path)
                    {
                        Error($"a path is scene IDs of 16 hex digits joined by # after @, not \"{text}\"");
                        return null;
                    }
                    return SceneValue.EntityRef(path);
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
