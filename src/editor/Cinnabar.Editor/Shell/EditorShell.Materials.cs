using Cinnabar.Editor.Docking;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Model;
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

    // The open graph editors of every kind, in the order that they were opened or shown again. The last World editor in it
    // is the world that the viewport shows.
    readonly List<IGraphEditor> _graphEditors = [];
    // A new link knows no previews, and a preview's frames come by its slot.
    readonly PreviewSlots _previewSlots;
    // The material functions that graphs call, read from their files, by GUID, with the file's time.
    readonly Dictionary<string, (DateTime Modified, MaterialGraph? Graph)> _functions = [];
    // Editors that closed with their changes discarded, so their documents close without asking again.
    readonly HashSet<IGraphEditor> _discarding = [];
    // The command line's assets, by path, and the content browser's new assets, by GUID, which open once the index has them.
    readonly List<PendingOpen> _pendingOpens = [];

    abstract record PendingOpen
    {
        public sealed record ByPath(string Path) : PendingOpen;

        public sealed record ByGuid(string Guid) : PendingOpen;
    }

    void OpenPending()
    {
        foreach (var pending in _pendingOpens.ToList())
        {
            var asset = pending switch
            {
                PendingOpen.ByPath byPath => Assets.FindByPath(byPath.Path),
                PendingOpen.ByGuid byGuid => Assets.Find(byGuid.Guid),
                _ => null,
            };
            if (asset != null)
            {
                _pendingOpens.Remove(pending);
                OpenAsset(asset);
            }
        }
    }

    public IReadOnlyList<MaterialEditor> Materials => [.. _graphEditors.OfType<MaterialEditor>()];

    /// <summary>The open graphs of every kind.</summary>
    public IEnumerable<IGraphEditor> GraphEditors => _graphEditors;

    /// <summary>
    /// Opens an asset in its graph editor (see <see cref="GraphEditorKinds"/>), or shows its open editor. A file that its
    /// kind does not read opens in the script editor instead, with the reason in the console; a material's problems only
    /// go to the console. Null for an asset that has no graph editor or did not open.
    /// </summary>
    internal IGraphEditor? OpenEditor(Link.Cook.Asset asset)
    {
        if (GraphEditorKindOf(asset.Kind) is not { } kind)
        {
            return null;
        }
        if (_graphEditors.Find(e => e.Guid == asset.Guid) is { } open)
        {
            // The World editor that was shown last is the world that the viewport shows.
            _graphEditors.Remove(open);
            _graphEditors.Add(open);
            Layout.ShowDocument(open);
            SendWorldView();
            return open;
        }
        if (Assets.FullPath(asset) is not { } path)
        {
            return null;
        }
        IGraphDocument document;
        switch (kind.Open(path, asset.Guid))
        {
            case OpenResult.Opened opened:
                Report(kind.Noun, path, opened.Problems.Select(p => (p.Line, p.Message, p.IsError)));
                document = opened.Document;
                break;
            case OpenResult.Refused refused:
                Report(kind.Noun, path, refused.Problems.Select(p => (p.Line, p.Message, p.IsError)));
                return null;
            case OpenResult.NotOfKind { Problem: var problem }:
                Report(kind.Noun, path, [(problem.Line, problem.Message, true)]);
                OpenScript(path, (uint)problem.Line);
                return null;
            default:
                return null;
        }
        int? previewId = null;
        if (kind.WantsPreview(document))
        {
            previewId = _previewSlots.Free();
            if (previewId == null)
            {
                Console.Add(LogLevel.Warning, $"{kind.Noun}: {MaxPreviews} previews are open, so {document.Title} has none");
            }
        }
        var editor = kind.Create(this, document, previewId);
        // The document's activation reads the list, so the editor is in it first.
        _graphEditors.Add(editor);
        if (Host.Linked && editor is PreviewOwner owner)
        {
            owner.SendPreview();
        }
        _ = editor.CookNow();
        Layout.OpenDocument(new GraphEditorDocument(editor, kind, () => kind.CreateView(this, editor)));
        GraphEditorsChanged?.Invoke();
        SendWorldView();
        return editor;
    }

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
        if (_graphEditors.Find(e => e.Guid == guid) is MaterialEditor open)
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
    public MaterialEditor? OpenMaterial(Link.Cook.Asset asset) => OpenEditor(asset) as MaterialEditor;

    /// <summary>The document dock's active document changed.</summary>
    void OnActiveDocumentChanged(Dock.Model.Core.IDockable? document)
    {
        var active = (document as GraphEditorDocument)?.GraphEditor;
        if (active != ActiveGraphEditor)
        {
            ActiveGraphEditor = active;
            CutscenePreview.OnActivated(active as CutsceneEditor);
            EndBindingPickFor(active as CutsceneEditor, null);
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
        if (document is not GraphEditorDocument { GraphEditor: var editor, Kind: var kind } || !_graphEditors.Remove(editor))
        {
            return;
        }
        (editor as PreviewOwner)?.ClosePreview();
        kind.OnClosed(this, editor);
        _discarding.Remove(editor);
        editor.Dispose();
        if (ActiveGraphEditor == editor)
        {
            ActiveGraphEditor = null;
        }
        Commands.InvalidateAll();
        GraphEditorsChanged?.Invoke();
        SendWorldView();
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
    /// Writes a graph editor's graph to its file. A failure goes to the console. A text file that the editor keeps whole,
    /// such as an animation graph, a UI document, a decision or a blackboard, whose file another program changed since it was read is not written, and the window asks, unless
    /// <paramref name="overwrite"/> says so. Refused during a drag, whose steps the file must not get as saved.
    /// </summary>
    public bool SaveGraph(IGraphEditor editor, bool overwrite = false)
    {
        if (editor.Document.InTransaction)
        {
            Console.Add(LogLevel.Warning, $"{editor.Noun}: cannot save {editor.Document.Path} while a drag is open. Finish or cancel it first.");
            return false;
        }
        if (!overwrite && editor.Document is ITextGraphDocument { ChangedOnDisk: true })
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

    // The graph editors' previews, then the effects'.
    IEnumerable<PreviewOwner> PreviewOwners() => _graphEditors.OfType<PreviewOwner>().Concat(_effects);
}
