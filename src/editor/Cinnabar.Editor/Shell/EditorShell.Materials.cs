using Cinnabar.Editor.Docking;
using Cinnabar.Editor.Document;
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
    readonly HashSet<MaterialEditor> _discarding = [];
    // The command line's materials and effects, which open once the index has them.
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
                else
                {
                    OpenMaterial(asset);
                }
            }
        }
    }

    public IReadOnlyList<MaterialEditor> Materials => _materials;

    /// <summary>The material editor whose document is active, or null when the viewport is.</summary>
    public MaterialEditor? ActiveMaterial { get; private set; }

    /// <summary>A material editor opened, closed or became active.</summary>
    public event Action? MaterialsChanged;

    /// <summary>The user closed a material editor with unsaved changes. The window asks, and calls <see cref="CloseMaterial"/>.</summary>
    public event Action<MaterialEditor>? MaterialCloseRequested;

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
        MaterialsChanged?.Invoke();
        return editor;
    }

    /// <summary>The document dock's active document changed.</summary>
    void OnActiveDocumentChanged(Dock.Model.Core.IDockable? document)
    {
        var active = (document as MaterialEditorDocument)?.Editor;
        if (active != ActiveMaterial)
        {
            ActiveMaterial = active;
            Commands.InvalidateAll();
            MaterialsChanged?.Invoke();
        }
    }

    /// <summary>A material editor's document wants to close. One with unsaved changes asks first.</summary>
    bool OnDocumentClosing(Dock.Model.Core.IDockable document)
    {
        if (document is not MaterialEditorDocument { Editor: var editor } || !editor.Document.IsDirty || _discarding.Contains(editor))
        {
            return true;
        }
        MaterialCloseRequested?.Invoke(editor);
        return false;
    }

    void OnDocumentClosed(Dock.Model.Core.IDockable document)
    {
        if (document is EffectPreviewDocument { Preview: var preview })
        {
            OnEffectClosed(preview);
            return;
        }
        if (document is not MaterialEditorDocument { Editor: var editor } || !_materials.Remove(editor))
        {
            return;
        }
        _discarding.Remove(editor);
        editor.ClosePreview();
        editor.Dispose();
        if (ActiveMaterial == editor)
        {
            ActiveMaterial = null;
        }
        Commands.InvalidateAll();
        MaterialsChanged?.Invoke();
    }

    /// <summary>Closes a material editor. With <paramref name="discard"/>, its unsaved changes are lost; without it, it saves first.</summary>
    public void CloseMaterial(MaterialEditor editor, bool discard)
    {
        if (!discard && editor.Document.IsDirty && !SaveMaterial(editor))
        {
            return;
        }
        _discarding.Add(editor);
        Layout.CloseDocument(editor);
    }

    /// <summary>Writes a material editor's graph to its file. A failure goes to the console.</summary>
    public bool SaveMaterial(MaterialEditor editor)
    {
        try
        {
            editor.Document.Save();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Console.Add(LogLevel.Error, $"material: cannot save {editor.Document.Path}: {e.Message}");
            return false;
        }
        Console.Add(LogLevel.Info, $"material: saved {editor.Document.Path}");
        return true;
    }

    // The material editors' previews, then the effects'.
    IEnumerable<PreviewOwner> PreviewOwners() => _materials.Concat<PreviewOwner>(_effects);
}
