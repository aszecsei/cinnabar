using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Content;
using Cinnabar.Editor.Model;
using Asset = Cinnabar.Editor.Link.Cook.Asset;
using ComponentType = Cinnabar.Editor.Link.Protocol.ComponentType;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// What the Add Component picker offers, as catalog items (see docs/editor/shell-and-panels.md#properties). A component
/// type is in the folder that its game registers it in, which for a game's own type is the game's package unless the
/// game says otherwise. A behaviour is in the folder that its class names with <c>category</c>, or else under
/// Behaviours, in the folder that its script is in, so a project's folders of scripts are the picker's folders.
/// </summary>
static class ComponentCatalog
{
    /// <summary>The category of a type that the engine adds and removes itself, which the picker leaves out (ecs.NO_CATEGORY).</summary>
    public const string NoCategory = "-";

    /// <summary>The folder that every behaviour is under.</summary>
    public const string BehavioursFolder = "Behaviours";

    // The folder that a project's scripts are in by convention, which is not a folder of the picker: its scripts are
    // right under Behaviours.
    const string ScriptsFolder = "scripts";

    const string ComponentPrefix = "component:";
    const string BehaviourPrefix = "behaviour:";

    /// <summary>The types as items, without those that the picker leaves out.</summary>
    public static IEnumerable<CatalogItem> Components(IEnumerable<ComponentType> types) =>
        types.Where(t => t.Category != NoCategory)
            .Select(t => new CatalogItem(ComponentPrefix + t.Id.ToString(System.Globalization.CultureInfo.InvariantCulture), FieldValues.Humanize(t.Name), t.Category));

    /// <summary>
    /// The scripts that define a behaviour as items, each named for its class, in the folder that its class names, or
    /// else in its script's folder. A class with the category <see cref="NoCategory"/> is left out.
    /// </summary>
    public static IEnumerable<CatalogItem> Behaviours(IEnumerable<Asset> scripts) =>
        scripts.Where(a => a.Category != NoCategory)
            .Select(a => new CatalogItem(BehaviourPrefix + a.Guid, FieldValues.Humanize(a.Behaviour), a.Category.Length > 0 ? a.Category : BehaviourFolder(a.Path), Detail: $"{a.Root}/{a.Path}"));

    /// <summary>The ID of the component type that an item is, or null for an item that is none.</summary>
    public static ulong? ComponentOf(CatalogItem item) =>
        item.Id.StartsWith(ComponentPrefix, StringComparison.Ordinal) && ulong.TryParse(item.Id[ComponentPrefix.Length..], out var id) ? id : null;

    /// <summary>The GUID of the script whose behaviour an item is, or null for an item that is none.</summary>
    public static string? ScriptOf(CatalogItem item) =>
        item.Id.StartsWith(BehaviourPrefix, StringComparison.Ordinal) ? item.Id[BehaviourPrefix.Length..] : null;

    /// <summary>
    /// Where the picker puts a script's behaviour, by the script's path in its content root: <c>scripts/ai/guard.luau</c>
    /// is in <c>Behaviours/ai</c>, which the picker shows as Behaviours, then Ai, and <c>scripts/door.luau</c> in
    /// <c>Behaviours</c>.
    /// </summary>
    public static string BehaviourFolder(string path)
    {
        var folders = AssetIndex.Parent(path).Split('/', StringSplitOptions.RemoveEmptyEntries).AsEnumerable();
        if (string.Equals(folders.FirstOrDefault(), ScriptsFolder, StringComparison.OrdinalIgnoreCase))
        {
            folders = folders.Skip(1);
        }
        return string.Join('/', folders.Prepend(BehavioursFolder));
    }

    /// <summary>The icon of a folder of the picker, by the first folder of its path: the engine's have one each.</summary>
    public static string? FolderIcon(string folder) => folder.Split('/')[0] switch
    {
        "Lighting" => "light-point",
        "Rendering" => "camera",
        "Volumes" => "volume",
        "Physics" => "collider",
        "Audio" => "audio",
        "Navigation" => "nav-path",
        "AI" => "decision",
        "Level Design" => "block",
        "Animation" => "animation",
        "UI" => "ui-document",
        "Transform" => "move",
        BehavioursFolder => "script",
        _ => "folder",
    };
}
