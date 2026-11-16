using Avalonia.Controls;
using Avalonia.Media;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Viewport;

/// <summary>
/// The Landscape tool's brush, beside the Scene's views while it is the tool (see docs/editor/landscape.md#the-tool):
/// what the brush does, its radius, its strength and its falloff. Each is a command, so the command palette has them too.
/// </summary>
public sealed class LandscapeShelf : Border
{
    readonly EditorShell _shell;
    readonly TextBlock _hint = new() { Classes = { "dim" }, FontSize = 11, TextWrapping = TextWrapping.Wrap };

    public LandscapeShelf(EditorShell shell)
    {
        _shell = shell;
        Classes.Add("tool-shelf");
        IsVisible = false;
        var stack = new StackPanel { Spacing = 4 };
        stack.Children.Add(ToolButton.Choice(shell, EditorCommands.LandscapeBrush));
        stack.Children.Add(ToolButton.Choice(shell, EditorCommands.LandscapeRadius));
        stack.Children.Add(ToolButton.Choice(shell, EditorCommands.LandscapeStrength));
        stack.Children.Add(ToolButton.Choice(shell, EditorCommands.LandscapeFalloff));
        stack.Children.Add(_hint);
        var expander = new SectionExpander().Create("Landscape", stack);
        expander.Classes.Add("shelf");
        Child = new ScrollViewer
        {
            Content = new StackPanel { Classes = { "tool-shelf" }, Children = { expander } },
            HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled,
        };
        AttachedToVisualTree += (_, _) =>
        {
            _shell.ToolsChanged += Show;
            _shell.Mesh.MeshModeChanged += Show;
            _shell.Context.Changed += Show;
            Show();
        };
        DetachedFromVisualTree += (_, _) =>
        {
            _shell.ToolsChanged -= Show;
            _shell.Mesh.MeshModeChanged -= Show;
            _shell.Context.Changed -= Show;
        };
        Show();
    }

    void Show()
    {
        IsVisible = _shell.Tool == Tool.Landscape && !_shell.Mesh.InMeshMode;
        _hint.Text = _shell.Context.IsActive(LandscapeSession.TerrainContext)
            ? "Drag on the terrain to paint. Ctrl+Z undoes a stroke; saving the scene writes its maps."
            : "Select a terrain: an entity with a Surface_Renderer.";
    }
}
