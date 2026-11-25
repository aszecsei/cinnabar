using Avalonia.Controls;
using Cinnabar.Editor.Document;
using AssetKind = Cinnabar.Editor.Link.Cook.AssetKind;

namespace Cinnabar.Editor.Shell;

/// <summary>What reading a file for its editor gave.</summary>
public abstract record OpenResult
{
    /// <summary>The document, with problems that did not stop it opening.</summary>
    public sealed record Opened(IGraphDocument Document, IReadOnlyList<MaterialProblem> Problems) : OpenResult;

    /// <summary>The file does not open in its editor, for these problems.</summary>
    public sealed record Refused(IReadOnlyList<MaterialProblem> Problems) : OpenResult;

    /// <summary>The file does not start as its kind, so it opens in the script editor at the problem's line.</summary>
    public sealed record NotOfKind(MaterialProblem Problem) : OpenResult;

    /// <summary>The answer of a text kind's <c>Open</c>: a document, or the problem that it does not start as its kind.</summary>
    public static OpenResult Of<T>((T? Document, MaterialProblem? Problem) read) where T : class, IGraphDocument =>
        read.Document != null ? new Opened(read.Document, []) : new NotOfKind(read.Problem!);

    /// <summary>The answer of a material's <c>Open</c>, whose problems are reported whether or not it opened.</summary>
    public static OpenResult OfMaterial((MaterialDocument? Document, IReadOnlyList<MaterialProblem> Problems) read) =>
        read.Document != null ? new Opened(read.Document, read.Problems) : new Refused(read.Problems);
}

/// <summary>
/// A kind of asset that opens in a graph editor, as a document beside the viewport (see
/// docs/editor/shell-and-panels.md#shell): how its file is read, what editor and view it gets, and what its close
/// ends. <see cref="EditorShell"/> opens and closes every kind by one path.
/// </summary>
public interface IGraphEditorKind
{
    /// <summary>Whether assets of a kind open in this editor. A material and a material function share one.</summary>
    bool Handles(AssetKind kind);

    /// <summary>What the console calls the kind, such as <c>animation graph</c>.</summary>
    string Noun { get; }

    /// <summary>The document's ID before its GUID, such as <c>animation_graph</c>.</summary>
    string IdPrefix { get; }

    /// <summary>What opening the asset is called in its menu.</summary>
    string OpenLabel { get; }

    OpenResult Open(string path, string guid);

    /// <summary>Whether the document's editor takes a preview slot.</summary>
    bool WantsPreview(IGraphDocument document);

    IGraphEditor Create(EditorShell shell, IGraphDocument document, int? previewId);

    Control CreateView(EditorShell shell, IGraphEditor editor);

    /// <summary>What the editor's close ends in the shell, once the shell no longer lists it.</summary>
    void OnClosed(EditorShell shell, IGraphEditor editor);
}

/// <summary>A row of the table of graph editor kinds, over its document and editor types.</summary>
sealed class GraphEditorKind<TDocument, TEditor>(
    AssetKind[] kinds,
    string noun,
    string idPrefix,
    string openLabel,
    Func<string, string, OpenResult> open,
    Func<EditorShell, TDocument, int?, TEditor> create,
    Func<EditorShell, TEditor, Control> createView,
    Func<TDocument, bool>? wantsPreview = null,
    Action<EditorShell, TEditor>? onClosed = null) : IGraphEditorKind
    where TDocument : IGraphDocument
    where TEditor : IGraphEditor
{
    public bool Handles(AssetKind kind) => kinds.Contains(kind);

    public string Noun => noun;

    public string IdPrefix => idPrefix;

    public string OpenLabel => openLabel;

    public OpenResult Open(string path, string guid) => open(path, guid);

    public bool WantsPreview(IGraphDocument document) => wantsPreview?.Invoke((TDocument)document) ?? false;

    public IGraphEditor Create(EditorShell shell, IGraphDocument document, int? previewId) => create(shell, (TDocument)document, previewId);

    public Control CreateView(EditorShell shell, IGraphEditor editor) => createView(shell, (TEditor)editor);

    public void OnClosed(EditorShell shell, IGraphEditor editor) => onClosed?.Invoke(shell, (TEditor)editor);
}

public sealed partial class EditorShell
{
    /// <summary>The kinds of asset that open in a graph editor. A new kind is a row here, an editor and a view.</summary>
    internal static readonly IGraphEditorKind[] GraphEditorKinds =
    [
        new GraphEditorKind<MaterialDocument, MaterialEditor>([AssetKind.Material, AssetKind.MaterialFunction], "material", "material", "Open in Material Editor",
            (path, guid) => OpenResult.OfMaterial(MaterialDocument.Open(path, guid)),
            (s, d, preview) => new MaterialEditor(s, d, preview),
            (s, e) => new Materials.MaterialEditorView(s, e),
            wantsPreview: d => d.Kind == MaterialFileKind.Material),
        new GraphEditorKind<AnimationGraphDocument, AnimationGraphEditor>([AssetKind.AnimationGraph], "animation graph", "animation_graph", "Open in Animation Graph Editor",
            (path, guid) => OpenResult.Of(AnimationGraphDocument.Open(path, guid)),
            (s, d, preview) => new AnimationGraphEditor(s, d, preview),
            (s, e) => new AnimationGraphs.AnimationGraphEditorView(s, e),
            wantsPreview: _ => true),
        new GraphEditorKind<UiDocument, UiEditor>([AssetKind.Ui], "UI document", "ui", "Open in UI Editor",
            (path, guid) => OpenResult.Of(UiDocument.Open(path, guid)),
            (s, d, preview) => new UiEditor(s, d, preview),
            (s, e) => new UiDocuments.UiEditorView(s, e),
            wantsPreview: _ => true),
        new GraphEditorKind<DecisionDocument, DecisionEditor>([AssetKind.Decision], "decision", "decision", "Open in Decision Editor",
            (path, guid) => OpenResult.Of(DecisionDocument.Open(path, guid)),
            (s, d, _) => new DecisionEditor(s, d),
            (s, e) => new Decisions.DecisionEditorView(s, e)),
        new GraphEditorKind<BlackboardDocument, BlackboardEditor>([AssetKind.Blackboard], "blackboard", "blackboard", "Open in Blackboard Editor",
            (path, guid) => OpenResult.Of(BlackboardDocument.Open(path, guid)),
            (s, d, _) => new BlackboardEditor(s, d),
            (s, e) => new Decisions.BlackboardEditorView(s, e)),
        new GraphEditorKind<WorldDocument, WorldEditor>([AssetKind.World], "world", "world", "Open in World Editor",
            (path, guid) => OpenResult.Of(WorldDocument.Open(path, guid)),
            (s, d, _) => new WorldEditor(s, d),
            (s, e) => new Worlds.WorldEditorView(s, e)),
        new GraphEditorKind<CutsceneDocument, CutsceneEditor>([AssetKind.Cutscene], "cutscene", "cutscene", "Open in Cutscene Editor",
            (path, guid) => OpenResult.Of(CutsceneDocument.Open(path, guid)),
            (s, d, _) => new CutsceneEditor(s, d),
            (s, e) => new Cutscenes.CutsceneEditorView(s, e),
            // The pick and the keyed state read the shell's list, so they end after the editor left it.
            onClosed: (s, e) =>
            {
                s.EndBindingPickFor(null, e);
                s.CutscenePreview.OnTabClosed(e);
                s.RenderOuts.OnOwnerClosed(e);
                s.ForgetKeyed();
            }),
    ];

    static IGraphEditorKind? GraphEditorKindOf(AssetKind kind) => GraphEditorKinds.FirstOrDefault(k => k.Handles(kind));
}
