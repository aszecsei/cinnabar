using Cinnabar.Editor.Docking;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Shell;

/// <summary>The UI editor's documents (see docs/editor/ui-editor.md#ui-editor).</summary>
public sealed partial class EditorShell
{
    readonly List<UiEditor> _uiDocuments = [];
    // New UI documents, by GUID, which open in the editor once the index has them.
    readonly List<string> _pendingUi = [];

    public IReadOnlyList<UiEditor> UiDocuments => _uiDocuments;

    /// <summary>The UI editor whose document is active, or null when the viewport or another document is.</summary>
    public UiEditor? ActiveUiDocument => ActiveGraphEditor as UiEditor;

    /// <summary>
    /// Opens a UI document in the UI editor, or shows its open editor. A file that does not start with <c>ui 1</c>
    /// opens in the script editor instead, with the reason in the console.
    /// </summary>
    public UiEditor? OpenUiDocument(Link.Cook.Asset asset)
    {
        if (_uiDocuments.Find(u => u.Guid == asset.Guid) is { } open)
        {
            Layout.ShowDocument(open);
            return open;
        }
        if (Assets.FullPath(asset) is not { } path)
        {
            return null;
        }
        var (document, problem) = UiDocument.Open(path, asset.Guid);
        if (document == null)
        {
            Report("UI document", path, [(problem!.Line, problem.Message, true)]);
            OpenScript(path, (uint)problem.Line);
            return null;
        }
        var previewId = _previewSlots.Free();
        if (previewId == null)
        {
            Console.Add(LogLevel.Warning, $"UI document: {MaxPreviews} previews are open, so {document.Title} has none");
        }
        var editor = new UiEditor(this, document, previewId);
        _uiDocuments.Add(editor);
        if (Host.Linked)
        {
            editor.SendPreview();
        }
        _ = editor.CookNow();
        Layout.OpenDocument(new UiEditorDocument(editor, () => new UiDocuments.UiEditorView(this, editor)));
        GraphEditorsChanged?.Invoke();
        return editor;
    }

    // A UI document, a decision or a blackboard that the content browser made opens in its editor, once the index has it.
    internal void OnAssetCreated(string guid, Link.Cook.AssetTemplate template)
    {
        if (template == Link.Cook.AssetTemplate.Ui || OpensWhenCreated(template))
        {
            _pendingUi.Add(guid);
            OpenPendingUi();
        }
    }

    void OpenPendingUi()
    {
        foreach (var guid in _pendingUi.ToList())
        {
            if (Assets.Find(guid) is { } asset)
            {
                _pendingUi.Remove(guid);
                OpenAsset(asset);
            }
        }
    }

    // The game says where a UI preview's elements went.
    void OnUiLayout(Link.Protocol.UiPreviewLayout layout) => _uiDocuments.Find(u => u.PreviewId == (int)layout.Id)?.OnLayout(layout);
}
