using Avalonia.Controls;
using Cinnabar.Editor.Viewport;
using Dock.Model.Mvvm.Controls;

namespace Cinnabar.Editor.Docking;

/// <summary>
/// A tool panel (see docs/editor.md#panels). Each panel exists once. Closing it removes it from the layout, and
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

/// <summary>The viewport, as the only document. It cannot close, float or move into a tool dock.</summary>
public sealed class ViewportDocument : Dock.Model.Mvvm.Controls.Document
{
    public const string PanelId = "viewport";

    public ViewportDocument(ViewportSession session)
    {
        Id = PanelId;
        Title = "Viewport";
        Session = session;
        CanClose = false;
        CanFloat = false;
        CanDrag = false;
        CanPin = false;
    }

    public ViewportSession Session { get; }
}
