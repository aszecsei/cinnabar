using Avalonia.Controls;
using Dock.Model.Mvvm.Controls;

namespace Cinnabar.Editor.Docking;

/// <summary>
/// A tool panel (see docs/editor/shell-and-panels.md#panels). Each panel exists once. Closing it removes it from the layout, and
/// showing it again puts the same panel back, so its state survives.
/// </summary>
public sealed class PanelTool : Tool
{
    readonly Func<Control> _createView;

    public PanelTool(string id, string title, string icon, string defaultDock, Func<Control> createView)
    {
        Id = id;
        Title = title;
        Icon = icon;
        DefaultDock = defaultDock;
        _createView = createView;
        // Pinned panels would need their own place in the saved layout.
        CanPin = false;
    }

    public string Icon { get; }

    /// <summary>The ID of the tool dock that the panel goes back to when it is shown again.</summary>
    public string DefaultDock { get; }

    /// <summary>Docking can template a panel more than once, so each call makes a new view over the same state.</summary>
    public Control CreateView() => _createView();
}

/// <summary>
/// A document beside the viewport that an editor opens and the user closes: a material editor or an effect preview.
/// <see cref="Owner"/> is what it shows. The layout file does not keep it.
/// </summary>
public abstract class EditorDocument : Dock.Model.Mvvm.Controls.Document
{
    readonly Func<Control> _createView;

    protected EditorDocument(object owner, Func<Control> createView)
    {
        _createView = createView;
        Shows = owner;
    }

    /// <summary>The material editor or the effect preview that the document shows.</summary>
    public object Shows { get; }

    /// <summary>Docking can template a document more than once, so each call makes a new view over the same state.</summary>
    public Control CreateView() => _createView();
}

/// <summary>
/// A graph in its editor: a document beside the viewport, which closes, and asks first when it has unsaved changes. Its ID
/// is its kind's prefix and its GUID, such as <c>cutscene.{guid}</c>.
/// </summary>
public sealed class GraphEditorDocument : EditorDocument
{
    public GraphEditorDocument(Shell.IGraphEditor editor, Shell.IGraphEditorKind kind, Func<Control> createView) : base(editor, createView)
    {
        GraphEditor = editor;
        Kind = kind;
        Id = $"{kind.IdPrefix}.{editor.Guid}";
        Title = editor.Document.Title;
        CanFloat = false;
        CanPin = false;
        // A tab can hold more documents than its own, as a cutscene's levels in context, so its editor's changes mark it too.
        void Mark() => Title = editor.IsDirty ? $"{editor.Document.Title} •" : editor.Document.Title;
        editor.Document.Changed += Mark;
        editor.Changed += Mark;
    }

    public Shell.IGraphEditor GraphEditor { get; }

    /// <summary>The row of the shell's table of graph editor kinds that opened it.</summary>
    public Shell.IGraphEditorKind Kind { get; }
}

/// <summary>An effect's preview (see docs/rendering/particles.md#previews): a document beside the viewport, which closes.</summary>
public sealed class EffectPreviewDocument : EditorDocument
{
    public EffectPreviewDocument(Shell.EffectPreview preview, Func<Control> createView) : base(preview, createView)
    {
        Preview = preview;
        Id = $"effect.{preview.Guid}";
        Title = preview.Title;
        CanFloat = false;
        CanPin = false;
    }

    public Shell.EffectPreview Preview { get; }
}

/// <summary>
/// The Scene or the Game view, as a document (see docs/editor/viewport.md#views). Each exists once. Closing it removes it
/// from the layout, and showing it again puts the same document back, so the cameras and settings of the views in it
/// survive. It tabs, splits and closes like other documents, and does not float.
/// </summary>
public sealed class ViewportDocument : Dock.Model.Mvvm.Controls.Document
{
    /// <summary>The ID of the Scene document, which holds the scene views.</summary>
    public const string SceneId = "scene";

    /// <summary>The ID of the Game document, which holds the Game view.</summary>
    public const string GameId = "game";

    readonly Func<Control> _createView;

    public ViewportDocument(string id, string title, Func<Control> createView)
    {
        _createView = createView;
        Id = id;
        Title = title;
        CanFloat = false;
        CanPin = false;
    }

    /// <summary>Docking can template a document more than once, so each call makes a new view over the same viewports.</summary>
    public Control CreateView() => _createView();
}
