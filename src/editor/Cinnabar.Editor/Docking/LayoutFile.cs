using System.Text.Json;
using System.Text.Json.Serialization;

namespace Cinnabar.Editor.Docking;

/// <summary>
/// The saved dock layout: the tree of splits, tool docks and document docks, with each panel and viewport document by ID. Panel state
/// is not in it. A panel that floated is listed in <see cref="Floating"/> and docks again in its default dock, and with
/// <see cref="Windows"/>, which a file from an older editor lacks, a window that kept its place pops out again there.
/// </summary>
public sealed record LayoutFile(int Version, LayoutNode Root, IReadOnlyList<string> Floating, IReadOnlyList<FloatingWindow>? Windows = null)
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

/// <summary>A panel's floating window, by where it was on the desktop.</summary>
public sealed record FloatingWindow(string Panel, double X, double Y, double Width, double Height)
{
    // How much of a window's top must show for it to be found and moved.
    const double MinShown = 64;

    /// <summary>
    /// The window on one of the screens, each as its left, top, width and height: as it is when enough of it shows on one,
    /// as when a monitor that it was on has gone, and otherwise moved onto the first, and made to fit.
    /// </summary>
    public FloatingWindow OnScreen(IReadOnlyList<(double X, double Y, double Width, double Height)> screens)
    {
        if (screens.Count == 0 || screens.Any(s =>
                Math.Min(X + Width, s.X + s.Width) - Math.Max(X, s.X) >= MinShown && Y >= s.Y && Y + MinShown <= s.Y + s.Height))
        {
            return this;
        }
        var (left, top, width, height) = screens[0];
        var (w, h) = (Math.Min(Width, width), Math.Min(Height, height));
        return this with { X = left + (width - w) / 2, Y = top + (height - h) / 2, Width = w, Height = h };
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

/// <summary>
/// A document dock, with the viewport documents it holds, by ID, and the active one. A file from an editor with one
/// viewport lists none (null), which restores the scene view and the Game view; a dock with all its viewports closed lists
/// an empty array.
/// </summary>
public sealed record DocumentsNode(string Id, double? Proportion, IReadOnlyList<string>? Documents = null, string? Active = null)
    : LayoutNode(Id, Proportion);
