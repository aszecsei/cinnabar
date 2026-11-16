namespace Cinnabar.Editor.Commands;

/// <summary>
/// Something that a picker offers, in a folder: a component type, a behaviour (see
/// docs/editor/shell-and-panels.md#properties). <see cref="Category"/> is its folders with / between them, such as
/// <c>Physics/Joints</c>, or "" for none. <see cref="Detail"/> is a dim note beside the label, such as a script's path.
/// </summary>
public sealed record CatalogItem(string Id, string Label, string Category, string? Icon = null, string? Detail = null);

/// <summary>A row of a picker: a folder's heading, or an item, at a depth.</summary>
public sealed record CatalogRow(string Label, int Depth, CatalogItem? Item, string Folder)
{
    public bool IsFolder => Item == null;
}

/// <summary>Arranges a picker's items: as a tree of their folders, or as the matches of a search.</summary>
public static class Catalog
{
    /// <summary>Where an item without a category goes.</summary>
    public const string Uncategorized = "Other";

    /// <summary>
    /// A category as a picker shows it: each folder trimmed, with a capital first letter, so a game's package name reads
    /// as a title. "" and a category of only slashes are <see cref="Uncategorized"/>.
    /// </summary>
    public static string Normalize(string category)
    {
        var folders = category.Split('/', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .Select(f => char.ToUpperInvariant(f[0]) + f[1..]);
        var path = string.Join('/', folders);
        return path.Length == 0 ? Uncategorized : path;
    }

    /// <summary>
    /// The rows of a picker. Without a query, the folders in alphabetical order, <see cref="Uncategorized"/> last, each
    /// with its items by label and then the folders under it; a folder that <paramref name="isExpanded"/> refuses shows
    /// its heading alone, and without the function every folder is open. With a query, only the items whose label or
    /// category has every word of it, best first, as the command palette ranks: a label that starts with the query,
    /// then a word of the label that does, then the rest.
    /// </summary>
    public static IReadOnlyList<CatalogRow> Rows(IEnumerable<CatalogItem> items, string query, Func<string, bool>? isExpanded = null)
    {
        var all = items.Select(i => i with { Category = Normalize(i.Category) }).ToList();
        var words = query.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (words.Length > 0)
        {
            var trimmed = query.Trim();
            return [.. all
                .Where(i => words.All(w => i.Label.Contains(w, StringComparison.OrdinalIgnoreCase) || i.Category.Contains(w, StringComparison.OrdinalIgnoreCase)))
                .OrderBy(i => Rank(i.Label, trimmed))
                .ThenBy(i => i.Label, StringComparer.OrdinalIgnoreCase)
                .Select(i => new CatalogRow(i.Label, 0, i, i.Category))];
        }
        var rows = new List<CatalogRow>();
        AddFolder(rows, all, "", 0, isExpanded ?? (_ => true));
        return rows;
    }

    // The items of a folder, then each folder under it with its own.
    static void AddFolder(List<CatalogRow> rows, List<CatalogItem> all, string folder, int depth, Func<string, bool> isExpanded)
    {
        foreach (var item in all.Where(i => i.Category == folder).OrderBy(i => i.Label, StringComparer.OrdinalIgnoreCase))
        {
            rows.Add(new CatalogRow(item.Label, depth, item, folder));
        }
        var prefix = folder.Length == 0 ? "" : folder + "/";
        var children = all
            .Where(i => i.Category.StartsWith(prefix, StringComparison.Ordinal) && i.Category.Length > prefix.Length)
            .Select(i => i.Category[prefix.Length..].Split('/')[0])
            .Distinct()
            .OrderBy(name => name == Uncategorized && depth == 0 ? 1 : 0)
            .ThenBy(name => name, StringComparer.OrdinalIgnoreCase);
        foreach (var name in children)
        {
            var path = prefix + name;
            rows.Add(new CatalogRow(name, depth, null, path));
            if (isExpanded(path))
            {
                AddFolder(rows, all, path, depth + 1, isExpanded);
            }
        }
    }

    static int Rank(string label, string query)
    {
        if (label.StartsWith(query, StringComparison.OrdinalIgnoreCase))
        {
            return 0;
        }
        return label.Split(' ', StringSplitOptions.RemoveEmptyEntries).Any(w => w.StartsWith(query, StringComparison.OrdinalIgnoreCase)) ? 1 : 2;
    }
}
