namespace Cinnabar.Editor.Document;

/// <summary>
/// A scene document, as its file describes it (see docs/editor/document-and-scenes.md#scenes). The editor owns it: the host's world is a
/// mirror of it. It knows nothing of the game's types, so data that the game's DLL no longer has is kept and saved.
/// </summary>
public sealed class Scene
{
    /// <summary>The comment lines before the file's <c>scene 2</c> line, with their <c>#</c>. Other comments are not kept.</summary>
    public List<string> HeaderComments { get; } = [];

    public List<SceneEntity> Entities { get; } = [];

    public SceneEntity? Find(ulong id) => Entities.Find(e => e.Id == id);
}

public sealed class SceneEntity(ulong id)
{
    /// <summary>An override block of the entity on a path inside an instance (see docs/editor/prefabs.md#instances-in-a-scene).</summary>
    public SceneEntity(IReadOnlyList<ulong> path) : this(ScenePath.Id(path)) => Path = path;

    /// <summary>
    /// The scene ID: random, nonzero and unique in the scene. An override block's is its path's, so that
    /// <see cref="Scene.Find"/> finds it.
    /// </summary>
    public ulong Id { get; } = id;
    /// <summary>An override block's path: the instance's ID, any inner instances' and the entity's. Null for any other block.</summary>
    public IReadOnlyList<ulong>? Path { get; }
    /// <summary>An instance block: the GUID of the prefab whose root it stands for, as 32 lowercase hex digits, or "".</summary>
    public string Prefab { get; set; } = "";
    /// <summary>
    /// Which of name, parent and active an instance or override block writes, since it changes only those of the
    /// prefab's entity. A plain entity writes a name that is not empty, a parent that is not 0 and active when false.
    /// An instance block always writes its parent, which is the scene's.
    /// </summary>
    public SceneKeys Keys { get; set; }
    /// <summary>An override block: the entity and its descendants are taken out of the instance.</summary>
    public bool Removed { get; set; }
    /// <summary>An instance or override block: the stable IDs of the prefab's components that it takes away.</summary>
    public List<ulong> RemovedComponents { get; } = [];
    /// <summary>An instance or override block: the scripts of the prefab's behaviours that it takes away.</summary>
    public List<string> RemovedBehaviours { get; } = [];
    public string Name { get; set; } = "";
    /// <summary>The parent's scene ID, or 0.</summary>
    public ulong Parent { get; set; }
    /// <summary>The parent's path when it is inside an instance, which the file writes while its ID is <see cref="Parent"/>.</summary>
    public IReadOnlyList<ulong>? ParentPath { get; set; }
    public bool Active { get; set; } = true;
    /// <summary>Kept sorted by ID.</summary>
    public List<SceneComponent> Components { get; } = [];
    /// <summary>In the order that they are attached.</summary>
    public List<SceneBehaviour> Behaviours { get; } = [];
    /// <summary>Entity keys that this editor does not know, such as from a newer one, with their value's text.</summary>
    public List<(string Key, string Text)> UnknownKeys { get; } = [];

    /// <summary>A copy that shares nothing that can change with this one.</summary>
    public SceneEntity Clone() => Path != null ? CopyInto(new SceneEntity(Path)) : Copy(Id);

    /// <summary>A copy with another scene ID, which is not an override block.</summary>
    public SceneEntity Copy(ulong id) => CopyInto(new SceneEntity(id));

    SceneEntity CopyInto(SceneEntity copy)
    {
        copy.Name = Name;
        copy.Parent = Parent;
        copy.ParentPath = ParentPath;
        copy.Active = Active;
        copy.Prefab = Prefab;
        copy.Keys = Keys;
        copy.Removed = Removed;
        copy.Components.AddRange(Components.Select(c => c.Copy()));
        copy.Behaviours.AddRange(Behaviours.Select(b => b.Copy()));
        copy.UnknownKeys.AddRange(UnknownKeys);
        copy.RemovedComponents.AddRange(RemovedComponents);
        copy.RemovedBehaviours.AddRange(RemovedBehaviours);
        return copy;
    }

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

/// <summary>The entity keys that an instance or override block writes.</summary>
[Flags]
public enum SceneKeys
{
    None = 0,
    Name = 1,
    Parent = 2,
    Active = 4,
}

/// <summary>
/// The scene IDs of paths, <c>&lt;instance&gt;#&lt;entity&gt;</c>, which name the entities inside an instance. The cooker computes
/// the same in <c>asset_format.scene_path_id</c>, and the two must agree.
/// </summary>
public static class ScenePath
{
    /// <summary>The most IDs in a path: an instance at each of eight levels of prefabs, and the entity.</summary>
    public const int MaxLength = 9;

    /// <summary>The scene ID of the entity <paramref name="id"/> inside an instance: FNV-1a over the two IDs' 16 bytes, little-endian, or 1 if that is 0.</summary>
    public static ulong Id(ulong instance, ulong id)
    {
        var hash = 0xcbf29ce484222325UL;
        foreach (var value in (ReadOnlySpan<ulong>)[instance, id])
        {
            for (var i = 0; i < 8; i++)
            {
                hash = (hash ^ (byte)(value >> (8 * i))) * 0x100000001b3UL;
            }
        }
        return hash == 0 ? 1 : hash;
    }

    /// <summary>The scene ID of a path, folded from the end, as expansion places a flat prefab: the inner path's ID is the entity's in the prefab.</summary>
    public static ulong Id(IReadOnlyList<ulong> path)
    {
        if (path.Count == 0)
        {
            return 0;
        }
        var id = path[^1];
        for (var i = path.Count - 2; i >= 0; i--)
        {
            id = Id(path[i], id);
        }
        return id;
    }

    public static string Format(IReadOnlyList<ulong> path) => string.Join("#", path.Select(id => id.ToString("x16", System.Globalization.CultureInfo.InvariantCulture)));
}

/// <summary>A component by its stable ID. The name is for people and messages.</summary>
public sealed record SceneComponent(ulong Id, string Name, List<SceneField> Fields)
{
    public SceneComponent Copy() => this with { Fields = [.. Fields] };
}

/// <summary>A behaviour by its script's GUID, as 32 lowercase hex digits.</summary>
public sealed record SceneBehaviour(string Script, List<SceneField> Fields)
{
    public SceneBehaviour Copy() => this with { Fields = [.. Fields] };
}

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
    /// <summary>An asset's GUID, or none.</summary>
    Asset,
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
    /// <summary>An entity's scene ID. For a reference written as a path, the path's ID.</summary>
    public ulong Entity { get; private init; }
    /// <summary>A reference written as a path into an instance, kept so that the file writes it back. Null otherwise.</summary>
    public IReadOnlyList<ulong>? Path { get; private init; }
    /// <summary>An asset's GUID as 32 lowercase hex digits, or "" for none.</summary>
    public string Asset { get; private init; } = "";

    public static SceneValue Of(bool value) => new() { Kind = SceneValueKind.Bool, Bool = value };

    public static SceneValue Of(params SceneNumber[] numbers) =>
        numbers.Length is >= 1 and <= 4
            ? new() { Kind = SceneValueKind.Number, Numbers = numbers }
            : throw new ArgumentException("a value has one to four numbers", nameof(numbers));

    public static SceneValue String(string text) => new() { Kind = SceneValueKind.String, Text = text };

    public static SceneValue Name(string word) => new() { Kind = SceneValueKind.Name, Text = word };

    public static SceneValue EntityRef(ulong id) => new() { Kind = SceneValueKind.Entity, Entity = id };

    /// <summary>A reference to the entity on a path into an instance, or with one ID, to a scene ID.</summary>
    public static SceneValue EntityRef(IReadOnlyList<ulong> path) =>
        path.Count == 1 ? EntityRef(path[0]) : new() { Kind = SceneValueKind.Entity, Entity = ScenePath.Id(path), Path = path };

    /// <summary>A reference to an asset by its GUID, or "" for none.</summary>
    public static SceneValue AssetRef(string guid) => new() { Kind = SceneValueKind.Asset, Asset = guid.ToLowerInvariant() };

    public bool Equals(SceneValue? other) =>
        other is not null && Kind == other.Kind && Bool == other.Bool && Text == other.Text && Entity == other.Entity && Asset == other.Asset
        && Numbers.SequenceEqual(other.Numbers) && (Path ?? []).SequenceEqual(other.Path ?? []);

    public override int GetHashCode() => HashCode.Combine(Kind, Bool, Text, Entity, Asset, Numbers.Count);
}
