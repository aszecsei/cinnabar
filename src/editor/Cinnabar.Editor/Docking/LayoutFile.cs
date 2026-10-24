using System.Text.Json;
using System.Text.Json.Serialization;

namespace Cinnabar.Editor.Docking;

/// <summary>
/// The saved dock layout: the tree of splits, tool docks and the document dock, with each panel by ID. Panel state
/// is not in it. A panel that floated is listed in <see cref="Floating"/> and docks again in its default dock.
/// </summary>
public sealed record LayoutFile(int Version, LayoutNode Root, IReadOnlyList<string> Floating)
{
    public const int CurrentVersion = 1;

    static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public string ToJson() => JsonSerializer.Serialize(this, Options);

    /// <summary>The layout in <paramref name="json"/>, or null if it is not a layout of the current version.</summary>
    public static LayoutFile? FromJson(string json)
    {
        try
        {
            var file = JsonSerializer.Deserialize<LayoutFile>(json, Options);
            return file?.Version == CurrentVersion ? file : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

/// <summary>A node of the layout tree. A null proportion lets the dock share the space that is left.</summary>
[JsonPolymorphic(TypeDiscriminatorPropertyName = "kind")]
[JsonDerivedType(typeof(SplitNode), "split")]
[JsonDerivedType(typeof(ToolsNode), "tools")]
[JsonDerivedType(typeof(DocumentsNode), "documents")]
public abstract record LayoutNode(string Id, double? Proportion);

public sealed record SplitNode(string Id, double? Proportion, bool Vertical, IReadOnlyList<LayoutNode> Children)
    : LayoutNode(Id, Proportion);

public sealed record ToolsNode(string Id, double? Proportion, string Alignment, IReadOnlyList<string> Panels, string? Active)
    : LayoutNode(Id, Proportion);

public sealed record DocumentsNode(string Id, double? Proportion) : LayoutNode(Id, Proportion);
