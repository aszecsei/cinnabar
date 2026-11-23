namespace Cinnabar.Editor.Shell;

/// <summary>The UI editor's documents (see docs/editor/ui-editor.md#ui-editor).</summary>
public sealed partial class EditorShell
{
    public IReadOnlyList<UiEditor> UiDocuments => [.. _graphEditors.OfType<UiEditor>()];

    /// <summary>The UI editor whose document is active, or null when the viewport or another document is.</summary>
    public UiEditor? ActiveUiDocument => ActiveGraphEditor as UiEditor;

    /// <summary>
    /// Opens a UI document in the UI editor, or shows its open editor. A file that does not start with <c>ui 1</c>
    /// opens in the script editor instead, with the reason in the console.
    /// </summary>
    public UiEditor? OpenUiDocument(Link.Cook.Asset asset) => OpenEditor(asset) as UiEditor;

    // A UI document, a decision, a blackboard or a cutscene that the content browser made opens in its editor, once the
    // index has it.
    internal void OnAssetCreated(string guid, Link.Cook.AssetTemplate template)
    {
        if (template == Link.Cook.AssetTemplate.Ui || OpensWhenCreated(template))
        {
            _pendingOpens.Add(new PendingOpen.ByGuid(guid));
            OpenPending();
        }
    }

    // The game says where a UI preview's elements went.
    void OnUiLayout(Link.Protocol.UiPreviewLayout layout) => UiDocuments.FirstOrDefault(u => u.PreviewId == (int)layout.Id)?.OnLayout(layout);
}
