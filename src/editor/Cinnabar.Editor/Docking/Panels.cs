using Avalonia.Controls;
using Cinnabar.Editor.Viewport;
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
        // Pinned panels would need their own place in the saved layout. Floating panels dock again on restart.
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
/// A material or a material function in the material editor (see docs/editor/material-editor.md#material-editor): a document beside the
/// viewport, which closes, and asks first when it has unsaved changes.
/// </summary>
public sealed class MaterialEditorDocument : EditorDocument
{
    public MaterialEditorDocument(Shell.MaterialEditor editor, Func<Control> createView) : base(editor, createView)
    {
        Editor = editor;
        Id = $"material.{editor.Guid}";
        Title = editor.Document.Title;
        CanFloat = false;
        CanPin = false;
        editor.Changed += () => Title = editor.Document.IsDirty ? $"{editor.Document.Title} •" : editor.Document.Title;
    }

    public Shell.MaterialEditor Editor { get; }
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

/// <summary>The viewport, as the first document. It cannot close, float or move into a tool dock.</summary>
public sealed class ViewportDocument : Dock.Model.Mvvm.Controls.Document
{
    public const string PanelId = "viewport";

    readonly Func<Control> _createView;

    public ViewportDocument(ViewportSession session, Func<Control> createView)
    {
        _createView = createView;
        Id = PanelId;
        Title = "Viewport";
        Session = session;
        CanClose = false;
        CanFloat = false;
        CanDrag = false;
        CanPin = false;
    }

    public ViewportSession Session { get; }

    /// <summary>Docking can template the viewport more than once, so each call makes a new view over the same session.</summary>
    public Control CreateView() => _createView();
}
