namespace Cinnabar.Editor.Document;

/// <summary>The sub-sequences of a cutscene's text: the children that its sections play, and the cycles that a new one would make.</summary>
public static class CutsceneSubSequences
{
    /// <summary>The GUIDs of the children that a cutscene's sub-sequence sections play, once each, in the text's order.</summary>
    public static IReadOnlyList<string> Children(CutsceneFile file) =>
    [
        .. file.Tracks.Where(t => t.TrackKind == "sub_sequence")
            .SelectMany(t => t.Children)
            .Where(s => s.Kind == CutsceneBlockKind.Section)
            .Select(GuidOf)
            .OfType<string>()
            .Distinct(StringComparer.OrdinalIgnoreCase),
    ];

    /// <summary>The GUID that a sub-sequence section's <c>asset = $guid</c> names, or null.</summary>
    public static string? GuidOf(CutsceneBlock section) =>
        section.Get("asset")?.Trim() is ['$', .. var guid] && guid.Length > 0 ? guid : null;

    /// <summary>
    /// The cycle that a sub-sequence of a child in a cutscene would make, as the cooker's <c>cutscene_cycles</c> reports
    /// one: the GUIDs from the cutscene, through the child and the shortest way down from it, back to the cutscene. Null
    /// when the child does not play the cutscene, at any depth. read gives a cutscene's text by GUID, the open document's
    /// when there is one, or null when it cannot be read, which has no children.
    /// </summary>
    public static IReadOnlyList<string>? Cycle(string parent, string child, Func<string, CutsceneFile?> read)
    {
        if (string.Equals(parent, child, StringComparison.OrdinalIgnoreCase))
        {
            return [parent, child];
        }
        var from = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) { [child] = "" };
        var queue = new Queue<string>([child]);
        while (queue.Count > 0)
        {
            var at = queue.Dequeue();
            if (read(at) is not { } file)
            {
                continue;
            }
            foreach (var next in Children(file))
            {
                if (string.Equals(next, parent, StringComparison.OrdinalIgnoreCase))
                {
                    var path = new List<string> { parent };
                    for (var step = at; step != ""; step = from[step])
                    {
                        path.Add(step);
                    }
                    path.Add(parent);
                    // The walk went from the child down, so the steps between the ends are in reverse.
                    path.Reverse(1, path.Count - 2);
                    return path;
                }
                if (from.TryAdd(next, at))
                {
                    queue.Enqueue(next);
                }
            }
        }
        return null;
    }
}
