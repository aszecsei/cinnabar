namespace Cinnabar.Editor.Document;

/// <summary>
/// The stand-ins that the editor previews a cutscene's provided bindings with (see
/// docs/editor/cutscene-editor.md#script-slots): for each binding that a script gives, by ID, an entity of a scene as
/// <c>@&lt;guid&gt;/&lt;id&gt;</c> or a prefab as <c>$&lt;guid&gt;</c>. They are each user's, not the asset's, so only
/// the text that the preview cooks has them.
/// </summary>
public static class CutsceneStandIns
{
    /// <summary>Whether a stand-in names a prefab, as <c>$&lt;guid&gt;</c>, and not an entity.</summary>
    public static bool IsPrefab(string standIn) => standIn.TrimStart().StartsWith('$');

    /// <summary>
    /// The text that the preview cooks: each provided binding with a stand-in possesses or spawns it in place of its
    /// <c>provided = true</c>, on the same line. A spawn has no <c>policy</c>, so a prefab's makes that line a comment.
    /// Every line stays where it was, so the cooker's problems are on the lines of the text that the designer edits. A
    /// text that does not parse, or has no stand-in to put in, comes back as it was.
    /// </summary>
    public static string PreviewText(string text, IReadOnlyDictionary<int, string> standIns)
    {
        if (standIns.Count == 0 || CutsceneFile.Parse(text).File is not { } file)
        {
            return text;
        }
        var changed = false;
        foreach (var binding in file.Bindings)
        {
            if (binding.Id is not { } id || !CutsceneBindings.IsProvided(binding) || !standIns.TryGetValue(id, out var standIn))
            {
                continue;
            }
            var prefab = IsPrefab(standIn);
            binding.ReplaceSetting("provided", prefab ? "spawn" : "possess", standIn.Trim());
            if (prefab)
            {
                binding.CommentOut("policy");
            }
            changed = true;
        }
        return changed ? file.Text : text;
    }
}
