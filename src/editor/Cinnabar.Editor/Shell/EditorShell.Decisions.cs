using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;

namespace Cinnabar.Editor.Shell;

/// <summary>The decision editor's and the blackboard editor's documents (see docs/editor/decision-editor.md#decision-editor).</summary>
public sealed partial class EditorShell
{
    public IReadOnlyList<DecisionEditor> Decisions => [.. _graphEditors.OfType<DecisionEditor>()];

    public IReadOnlyList<BlackboardEditor> Blackboards => [.. _graphEditors.OfType<BlackboardEditor>()];

    /// <summary>The decision editor whose document is active, or null when the viewport or another document is.</summary>
    public DecisionEditor? ActiveDecision => ActiveGraphEditor as DecisionEditor;

    /// <summary>
    /// Opens a decision in the decision editor, or shows its open editor. A file that does not start with
    /// <c>decision 1</c> opens in the script editor instead, with the reason in the console.
    /// </summary>
    public DecisionEditor? OpenDecision(Asset asset) => OpenEditor(asset) as DecisionEditor;

    /// <summary>
    /// Opens a blackboard in the blackboard editor, or shows its open editor. A file that does not start with
    /// <c>blackboard 1</c> opens in the script editor instead, with the reason in the console.
    /// </summary>
    public BlackboardEditor? OpenBlackboard(Asset asset) => OpenEditor(asset) as BlackboardEditor;

    /// <summary>A blackboard's text: its open editor's, with what it has not saved, or its file's, or null.</summary>
    public string? BlackboardText(string guid)
    {
        if (_graphEditors.Find(e => e.Guid == guid) is BlackboardEditor open)
        {
            return open.Document.Text;
        }
        return Assets.Find(guid) is { Kind: AssetKind.Blackboard } asset ? ReadText(asset) : null;
    }

    /// <summary>The blackboard's text changed in its editor, so the decisions that read its keys show them again.</summary>
    public event Action<string>? BlackboardChanged;

    internal void OnBlackboardChanged(string guid) => BlackboardChanged?.Invoke(guid);

    // An asset's text: its open decision editor's, or its file's, or null when it cannot be read.
    string? ReadText(Asset asset)
    {
        if (_graphEditors.Find(e => e.Guid == asset.Guid) is DecisionEditor open)
        {
            return open.Document.Text;
        }
        try
        {
            return Assets.FullPath(asset) is { } path ? AnimationGraphFile.Decode(File.ReadAllBytes(path)) : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>The decisions that name a blackboard and read or write one of its keys, which a rename of the key changes.</summary>
    public IReadOnlyList<Asset> DecisionsReading(string blackboard, string key) =>
        [.. Assets.Assets.Values.Where(a => a.Kind == AssetKind.Decision).Where(a =>
            ReadText(a) is { } text && DecisionFile.Parse(text).File is { } file && file.Blackboard == blackboard && file.ReadsKey(key))
            .OrderBy(a => a.Path, StringComparer.OrdinalIgnoreCase)];

    // A decision, a blackboard or a cutscene that the content browser made opens in its editor, once the index has it.
    static bool OpensWhenCreated(AssetTemplate template) =>
        template is AssetTemplate.Blackboard or AssetTemplate.DecisionBehaviorTree or AssetTemplate.DecisionUtility or AssetTemplate.DecisionGoap
            or AssetTemplate.DecisionHtn or AssetTemplate.Cutscene;
}
