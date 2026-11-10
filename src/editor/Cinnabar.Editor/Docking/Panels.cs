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

/// <summary>A graph in its editor: a document beside the viewport, which closes, and asks first when it has unsaved changes.</summary>
public abstract class GraphEditorDocument : EditorDocument
{
    protected GraphEditorDocument(Shell.IGraphEditor editor, string id, Func<Control> createView) : base(editor, createView)
    {
        GraphEditor = editor;
        Id = id;
        Title = editor.Document.Title;
        CanFloat = false;
        CanPin = false;
        editor.Document.Changed += () => Title = editor.Document.IsDirty ? $"{editor.Document.Title} •" : editor.Document.Title;
    }

    public Shell.IGraphEditor GraphEditor { get; }
}

/// <summary>A material or a material function in the material editor (see docs/editor/material-editor.md#material-editor).</summary>
public sealed class MaterialEditorDocument(Shell.MaterialEditor editor, Func<Control> createView)
    : GraphEditorDocument(editor, $"material.{editor.Guid}", createView);

/// <summary>An animation graph in its editor (see docs/editor/animation-graph-editor.md#animation-graph-editor).</summary>
public sealed class AnimationGraphEditorDocument(Shell.AnimationGraphEditor editor, Func<Control> createView)
    : GraphEditorDocument(editor, $"animation_graph.{editor.Guid}", createView);

/// <summary>A UI document in the UI editor (see docs/editor/ui-editor.md#ui-editor).</summary>
public sealed class UiEditorDocument(Shell.UiEditor editor, Func<Control> createView)
    : GraphEditorDocument(editor, $"ui.{editor.Guid}", createView);

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
