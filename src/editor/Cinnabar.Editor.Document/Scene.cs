namespace Cinnabar.Editor.Document;

/// <summary>
/// A scene document, as its file describes it (see docs/editor.md#scenes). The editor owns it: the host's world is a
/// mirror of it. It knows nothing of the game's types, so data that the game's DLL no longer has is kept and saved.
/// </summary>
public sealed class Scene
{
    /// <summary>The comment lines before the file's <c>scene 1</c> line, with their <c>#</c>. Other comments are not kept.</summary>
    public List<string> HeaderComments { get; } = [];

    public List<SceneEntity> Entities { get; } = [];

    public SceneEntity? Find(ulong id) => Entities.Find(e => e.Id == id);
}

public sealed class SceneEntity(ulong id)
{
    /// <summary>The scene ID: random, nonzero and unique in the scene.</summary>
    public ulong Id { get; } = id;
    public string Name { get; set; } = "";
    /// <summary>The parent's scene ID, or 0.</summary>
    public ulong Parent { get; set; }
    public bool Active { get; set; } = true;
    /// <summary>Kept sorted by ID.</summary>
    public List<SceneComponent> Components { get; } = [];
    /// <summary>In the order that they are attached.</summary>
    public List<SceneBehaviour> Behaviours { get; } = [];
    /// <summary>Entity keys that this editor does not know, such as from a newer one, with their value's text.</summary>
    public List<(string Key, string Text)> UnknownKeys { get; } = [];

    /// <summary>A new random scene ID that is not 0.</summary>
    public static ulong NewId()
    {
        Span<byte> bytes = stackalloc byte[8];
        ulong id;
        do
        {
            Random.Shared.NextBytes(bytes);
            id = BitConverter.ToUInt64(bytes);
        } while (id == 0);
        return id;
    }
}

/// <summary>A component by its stable ID. The name is for people and messages.</summary>
public sealed record SceneComponent(ulong Id, string Name, List<SceneField> Fields);

/// <summary>A behaviour by its script's GUID, as 32 lowercase hex digits.</summary>
public sealed record SceneBehaviour(string Script, List<SceneField> Fields);

public sealed record SceneField(string Name, SceneValue Value);

public enum SceneValueKind
{
    Bool,
    /// <summary>One to four numbers, such as <c>90</c> or <c>[0, 0.7071068, 0, 0.7071068]</c>.</summary>
    Number,
    /// <summary>A quoted string.</summary>
    String,
    /// <summary>A bare word, such as an enum value's name.</summary>
    Name,
    /// <summary>An entity's scene ID, or 0 for none.</summary>
    Entity,
}

/// <summary>
/// A number as the file writes it. An integer is kept exactly, because raw positions are beyond a double's exact
/// range, and a u64 field can be beyond a long's.
/// </summary>
public readonly record struct SceneNumber(double Float, Int128? Integer)
{
    public bool IsInteger => Integer != null;

    public static SceneNumber Of(long value) => new(value, value);

    public static SceneNumber Of(double value) => new(value, null);
}

/// <summary>A field's value, tagged as the file writes it. The game converts it to its field's kind.</summary>
public sealed record SceneValue
{
    public SceneValueKind Kind { get; private init; }
    public bool Bool { get; private init; }
    public IReadOnlyList<SceneNumber> Numbers { get; private init; } = [];
    /// <summary>The text of a String or a Name.</summary>
    public string Text { get; private init; } = "";
    public ulong Entity { get; private init; }

    public static SceneValue Of(bool value) => new() { Kind = SceneValueKind.Bool, Bool = value };

    public static SceneValue Of(params SceneNumber[] numbers) =>
        numbers.Length is >= 1 and <= 4
            ? new() { Kind = SceneValueKind.Number, Numbers = numbers }
            : throw new ArgumentException("a value has one to four numbers", nameof(numbers));

    public static SceneValue String(string text) => new() { Kind = SceneValueKind.String, Text = text };

    public static SceneValue Name(string word) => new() { Kind = SceneValueKind.Name, Text = word };

    public static SceneValue EntityRef(ulong id) => new() { Kind = SceneValueKind.Entity, Entity = id };

    public bool Equals(SceneValue? other) =>
        other is not null && Kind == other.Kind && Bool == other.Bool && Text == other.Text && Entity == other.Entity
        && Numbers.SequenceEqual(other.Numbers);

    public override int GetHashCode() => HashCode.Combine(Kind, Bool, Text, Entity, Numbers.Count);
}
