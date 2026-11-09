using Avalonia.Controls;
using Cinnabar.Editor.Shell;
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
/// One of the editor's viewports, as a document (see docs/editor/viewport.md#views): "Scene", "Scene 2", "Scene 3" or
/// "Game". Each exists once. Closing it removes it from the layout, and showing it again puts the same document back, so
/// its camera and settings survive. It tabs, splits and closes like other documents, and does not float.
/// </summary>
public sealed class ViewportDocument : Dock.Model.Mvvm.Controls.Document
{
    readonly Func<Control> _createView;

    public ViewportDocument(EditorViewport viewport, Func<Control> createView)
    {
        _createView = createView;
        Id = IdOf(viewport.Index);
        Title = viewport.Title;
        Viewport = viewport;
        CanFloat = false;
        CanPin = false;
    }

    /// <summary>The document's ID in the layout: <c>viewport.0</c> to <c>viewport.3</c>.</summary>
    public static string IdOf(int index) => $"viewport.{index}";

    public EditorViewport Viewport { get; }

    /// <summary>Docking can template the viewport more than once, so each call makes a new view over the same viewport.</summary>
    public Control CreateView() => _createView();
}
