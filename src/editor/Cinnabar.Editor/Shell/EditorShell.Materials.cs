using Cinnabar.Editor.Docking;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;
using AssetKind = Cinnabar.Editor.Link.Cook.AssetKind;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The material editor's documents (see docs/editor/material-editor.md#material-editor): opening a material or a material function from
/// the content browser, each as a document beside the viewport, saving it, and its preview's link to the game.
/// </summary>
public sealed partial class EditorShell
{
    // MAX_PREVIEW_TARGETS in lib/core/gpu/gpu.odin.
    public const int MaxPreviews = 4;

    readonly List<MaterialEditor> _materials = [];
    // A new link knows no previews, and a preview's frames come by its slot.
    readonly PreviewSlots _previewSlots;
    // The material functions that graphs call, read from their files, by GUID, with the file's time.
    readonly Dictionary<string, (DateTime Modified, MaterialGraph? Graph)> _functions = [];
    // Editors that closed with their changes discarded, so their documents close without asking again.
    readonly HashSet<IGraphEditor> _discarding = [];
    // The command line's materials, effects, animation graphs and UI documents, which open once the index has them.
    readonly List<string> _pendingMaterials = [];

    void OpenPendingMaterials()
    {
        foreach (var path in _pendingMaterials.ToList())
        {
            if (Assets.FindByPath(path) is { } asset)
            {
                _pendingMaterials.Remove(path);
                if (asset.Kind == AssetKind.Effect)
                {
                    OpenEffect(asset);
                }
                else if (asset.Kind == AssetKind.AnimationGraph)
                {
                    OpenAnimationGraph(asset);
                }
                else if (asset.Kind == AssetKind.Ui)
                {
                    OpenUiDocument(asset);
                }
                else
                {
                    OpenMaterial(asset);
                }
            }
        }
    }

    public IReadOnlyList<MaterialEditor> Materials => _materials;

    /// <summary>The open graphs of every kind.</summary>
    public IEnumerable<IGraphEditor> GraphEditors => _materials.Concat<IGraphEditor>(_animationGraphs).Concat(_uiDocuments);

    /// <summary>The graph editor whose document is active, or null when the viewport is.</summary>
    public IGraphEditor? ActiveGraphEditor { get; private set; }

    /// <summary>The material editor whose document is active, or null when the viewport or another document is.</summary>
    public MaterialEditor? ActiveMaterial => ActiveGraphEditor as MaterialEditor;

    /// <summary>A graph editor opened, closed or became active.</summary>
    public event Action? GraphEditorsChanged;

    /// <summary>The user closed a graph editor with unsaved changes. The window asks, and calls <see cref="CloseGraph"/>.</summary>
    public event Action<IGraphEditor>? GraphCloseRequested;

    /// <summary>A save would replace what another program wrote. The window asks, and calls <see cref="SaveGraph"/>.</summary>
    public event Action<IGraphEditor>? GraphOverwriteRequested;

    /// <summary>The kinds of node, the shading models and the material functions, as the material editor shows them.</summary>
    public MaterialCatalog MaterialCatalog => new(Assets.Nodes, Assets.ShadingModels, ReadFunction);

    MaterialGraph? ReadFunction(string guid)
    {
        if (!TryFileOf(guid, AssetKind.MaterialFunction, out var path))
        {
            return null;
        }
        // An open function's graph is what its editor has, saved or not.
        if (_materials.Find(m => m.Guid == guid) is { } open)
        {
            return open.Document.Graph;
        }
        var modified = File.Exists(path) ? File.GetLastWriteTimeUtc(path) : default;
        if (_functions.TryGetValue(guid, out var cached) && cached.Modified == modified)
        {
            return cached.Graph;
        }
        MaterialGraph? graph = null;
        try
        {
            graph = MaterialFile.Parse(File.ReadAllText(path), MaterialFileKind.Function).Graph;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
        _functions[guid] = (modified, graph);
        return graph;
    }

    /// <summary>
    /// Opens a material or a material function in the material editor, or shows its open editor. A material whose
    /// evaluate is HLSL opens in the script editor instead.
    /// </summary>
    public MaterialEditor? OpenMaterial(Link.Cook.Asset asset)
    {
        if (_materials.Find(m => m.Guid == asset.Guid) is { } open)
        {
            Layout.ShowDocument(open);
            return open;
        }
        if (Assets.FullPath(asset) is not { } path)
        {
            return null;
        }
        var (document, problems) = MaterialDocument.Open(path, asset.Guid);
        Report("material", path, problems.Select(p => (p.Line, p.Message, p.IsError)));
        if (document == null)
        {
            return null;
        }
        int? previewId = null;
        if (document.Kind == MaterialFileKind.Material)
        {
            previewId = _previewSlots.Free();
            if (previewId == null)
            {
                Console.Add(LogLevel.Warning, $"material: {MaxPreviews} previews are open, so {document.Title} has none");
            }
        }
        var editor = new MaterialEditor(this, document, previewId);
        _materials.Add(editor);
        if (Host.Linked)
        {
            editor.SendPreview();
        }
        _ = editor.CookNow();
        Layout.OpenDocument(new MaterialEditorDocument(editor, () => new global::Cinnabar.Editor.Materials.MaterialEditorView(this, editor)));
        GraphEditorsChanged?.Invoke();
        return editor;
    }

    /// <summary>The document dock's active document changed.</summary>
    void OnActiveDocumentChanged(Dock.Model.Core.IDockable? document)
    {
        var active = (document as GraphEditorDocument)?.GraphEditor;
        if (active != ActiveGraphEditor)
        {
            ActiveGraphEditor = active;
            Commands.InvalidateAll();
            GraphEditorsChanged?.Invoke();
        }
    }

    /// <summary>A graph editor's document wants to close. One with unsaved changes asks first.</summary>
    bool OnDocumentClosing(Dock.Model.Core.IDockable document)
    {
        if (document is not GraphEditorDocument { GraphEditor: var editor } || !editor.Document.IsDirty || _discarding.Contains(editor))
        {
            return true;
        }
        GraphCloseRequested?.Invoke(editor);
        return false;
    }

    void OnDocumentClosed(Dock.Model.Core.IDockable document)
    {
        if (document is EffectPreviewDocument { Preview: var preview })
        {
            OnEffectClosed(preview);
            return;
        }
        if (document is not GraphEditorDocument { GraphEditor: var editor } || !GraphEditors.Contains(editor))
        {
            return;
        }
        if (editor is MaterialEditor material)
        {
            _materials.Remove(material);
            material.ClosePreview();
        }
        if (editor is AnimationGraphEditor graph)
        {
            _animationGraphs.Remove(graph);
            graph.ClosePreview();
        }
        if (editor is UiEditor ui)
        {
            _uiDocuments.Remove(ui);
            ui.ClosePreview();
        }
        _discarding.Remove(editor);
        editor.Dispose();
        if (ActiveGraphEditor == editor)
        {
            ActiveGraphEditor = null;
        }
        Commands.InvalidateAll();
        GraphEditorsChanged?.Invoke();
    }

    /// <summary>Closes a graph editor. With <paramref name="discard"/>, its unsaved changes are lost; without it, it saves first.</summary>
    public void CloseGraph(IGraphEditor editor, bool discard)
    {
        if (!discard && editor.Document.IsDirty && !SaveGraph(editor))
        {
            return;
        }
        _discarding.Add(editor);
        Layout.CloseDocument(editor);
    }

    /// <summary>
    /// Writes a graph editor's graph to its file. A failure goes to the console. An animation graph or a UI document whose
    /// file another program changed since it was read is not written, and the window asks, unless
    /// <paramref name="overwrite"/> says so.
    /// </summary>
    public bool SaveGraph(IGraphEditor editor, bool overwrite = false)
    {
        if (!overwrite && editor.Document is AnimationGraphDocument { ChangedOnDisk: true } or UiDocument { ChangedOnDisk: true })
        {
            GraphOverwriteRequested?.Invoke(editor);
            return false;
        }
        try
        {
            editor.Document.Save();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Console.Add(LogLevel.Error, $"{editor.Noun}: cannot save {editor.Document.Path}: {e.Message}");
            return false;
        }
        Console.Add(LogLevel.Info, $"{editor.Noun}: saved {editor.Document.Path}");
        return true;
    }

    // An open graph's document follows its asset's file, as when the content browser moves or renames it.
    void FollowMovedGraphs()
    {
        foreach (var editor in GraphEditors.ToList())
        {
            if (Assets.Find(editor.Guid) is { } asset && Assets.FullPath(asset) is { } path
                && !string.Equals(path, editor.Document.Path, StringComparison.OrdinalIgnoreCase))
            {
                editor.Document.Move(path);
            }
        }
    }

    // The material editors' previews, then the effects', then the animation graphs', then the UI documents'.
    IEnumerable<PreviewOwner> PreviewOwners() => _materials.Concat<PreviewOwner>(_effects).Concat(_animationGraphs).Concat(_uiDocuments);
}
