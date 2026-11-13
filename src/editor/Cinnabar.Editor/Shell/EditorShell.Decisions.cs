using Cinnabar.Editor.Docking;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Shell;

/// <summary>The decision editor's and the blackboard editor's documents (see docs/editor/decision-editor.md#decision-editor).</summary>
public sealed partial class EditorShell
{
    readonly List<DecisionEditor> _decisions = [];
    readonly List<BlackboardEditor> _blackboards = [];

    public IReadOnlyList<DecisionEditor> Decisions => _decisions;

    public IReadOnlyList<BlackboardEditor> Blackboards => _blackboards;

    /// <summary>The decision editor whose document is active, or null when the viewport or another document is.</summary>
    public DecisionEditor? ActiveDecision => ActiveGraphEditor as DecisionEditor;

    /// <summary>
    /// Opens a decision in the decision editor, or shows its open editor. A file that does not start with
    /// <c>decision 1</c> opens in the script editor instead, with the reason in the console.
    /// </summary>
    public DecisionEditor? OpenDecision(Asset asset)
    {
        if (_decisions.Find(d => d.Guid == asset.Guid) is { } open)
        {
            Layout.ShowDocument(open);
            return open;
        }
        if (Assets.FullPath(asset) is not { } path)
        {
            return null;
        }
        var (document, problem) = DecisionDocument.Open(path, asset.Guid);
        if (document == null)
        {
            Report("decision", path, [(problem!.Line, problem.Message, true)]);
            OpenScript(path, (uint)problem.Line);
            return null;
        }
        var editor = new DecisionEditor(this, document);
        _decisions.Add(editor);
        _ = editor.CookNow();
        Layout.OpenDocument(new DecisionEditorDocument(editor, () => new Decisions.DecisionEditorView(this, editor)));
        GraphEditorsChanged?.Invoke();
        return editor;
    }

    /// <summary>
    /// Opens a blackboard in the blackboard editor, or shows its open editor. A file that does not start with
    /// <c>blackboard 1</c> opens in the script editor instead, with the reason in the console.
    /// </summary>
    public BlackboardEditor? OpenBlackboard(Asset asset)
    {
        if (_blackboards.Find(b => b.Guid == asset.Guid) is { } open)
        {
            Layout.ShowDocument(open);
            return open;
        }
        if (Assets.FullPath(asset) is not { } path)
        {
            return null;
        }
        var (document, problem) = BlackboardDocument.Open(path, asset.Guid);
        if (document == null)
        {
            Report("blackboard", path, [(problem!.Line, problem.Message, true)]);
            OpenScript(path, (uint)problem.Line);
            return null;
        }
        var editor = new BlackboardEditor(this, document);
        _blackboards.Add(editor);
        _ = editor.CookNow();
        Layout.OpenDocument(new BlackboardEditorDocument(editor, () => new Decisions.BlackboardEditorView(this, editor)));
        GraphEditorsChanged?.Invoke();
        return editor;
    }

    /// <summary>A blackboard's text: its open editor's, with what it has not saved, or its file's, or null.</summary>
    public string? BlackboardText(string guid)
    {
        if (_blackboards.Find(b => b.Guid == guid) is { } open)
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
        if (_decisions.Find(d => d.Guid == asset.Guid) is { } open)
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

    // A decision or a blackboard that the content browser made opens in its editor, once the index has it.
    static bool OpensWhenCreated(AssetTemplate template) =>
        template is AssetTemplate.Blackboard or AssetTemplate.DecisionBehaviorTree or AssetTemplate.DecisionUtility or AssetTemplate.DecisionGoap
            or AssetTemplate.DecisionHtn;
}
