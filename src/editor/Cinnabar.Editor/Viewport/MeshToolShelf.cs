using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.VisualTree;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Viewport;

/// <summary>
/// Mesh mode's tools, beside the Scene's views while the mode is on (see docs/editor/mesh-editing.md#mesh-mode): the
/// selection, the edits, the pivot, the tools that make geometry with the parameters of what they make, the texture's
/// options, and the grid. Each button is a command, so the command palette and the key bindings have them too. The
/// faces' material and mapping, with the texture tools, are the Face panel's.
/// </summary>
public sealed class MeshToolShelf : Border
{
    readonly EditorShell _shell;
    readonly StackPanel _content = new() { Classes = { "tool-shelf" } };
    // Sections that the user collapsed stay collapsed while the mode comes and goes.
    readonly SectionExpander _sections = new();

    public MeshToolShelf(EditorShell shell)
    {
        _shell = shell;
        Classes.Add("tool-shelf");
        IsVisible = false;
        Section("Select",
            Buttons(EditorCommands.SelectAll, EditorCommands.MeshSelectLinked, EditorCommands.MeshGrow, EditorCommands.MeshShrink),
            Wide(EditorCommands.MeshSelectThrough));
        Section("Edit",
            Buttons(EditorCommands.MeshExtrude, EditorCommands.MeshPushPull, EditorCommands.MeshOffset, EditorCommands.MeshBevel,
                EditorCommands.MeshInset, EditorCommands.MeshOutset, EditorCommands.MeshDuplicate, EditorCommands.MeshInvert,
                EditorCommands.MeshCollapse, EditorCommands.MeshMergeFaces, EditorCommands.MeshBridge, EditorCommands.MeshCap, EditorCommands.MeshDetach, EditorCommands.MeshExtract,
                EditorCommands.DeleteEntity, EditorCommands.MeshClean),
            Wide(EditorCommands.MeshRecalculateNormals),
            ToolButton.Choice(shell, EditorCommands.MeshBevelSegments),
            ToolButton.Choice(shell, EditorCommands.MeshNormalAngle));
        Section("Create",
            Buttons(EditorCommands.MeshCreate, EditorCommands.MeshCut, EditorCommands.MeshDraw, EditorCommands.MeshApplyPoints),
            ToolButton.Choice(shell, EditorCommands.MeshPrimitive),
            ToolButton.Choice(shell, EditorCommands.MeshSides),
            ToolButton.Choice(shell, EditorCommands.MeshSegments),
            ToolButton.Choice(shell, EditorCommands.MeshRings),
            ToolButton.Choice(shell, EditorCommands.MeshSteps),
            ToolButton.Choice(shell, EditorCommands.MeshArc),
            ToolButton.Choice(shell, EditorCommands.MeshThickness),
            ToolButton.Choice(shell, EditorCommands.MeshTubeRadius));
        Section("Pivot",
            Buttons(EditorCommands.MeshEditPivot, EditorCommands.MeshCenterPivot),
            Wide(EditorCommands.MeshPivotToGrid));
        Section("Texture",
            Wide(EditorCommands.MeshTransformTexture),
            ToolButton.Choice(shell, EditorCommands.MeshDevMaterial),
            ToolButton.Choice(shell, EditorCommands.MeshTexelDensity),
            new TextBlock { Text = "The Face panel has the faces' material, mapping and texture tools.", Classes = { "dim" }, FontSize = 11, TextWrapping = TextWrapping.Wrap });
        Section("Grid",
            Buttons(EditorCommands.MeshGridFiner, EditorCommands.MeshGridCoarser),
            Wide(EditorCommands.MeshGridToggle),
            Wide(EditorCommands.MeshKeepPlanar));
        Child = new ScrollViewer { Content = _content, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };

        AttachedToVisualTree += (_, _) =>
        {
            _shell.Mesh.MeshModeChanged += ShowMode;
            ShowMode();
        };
        DetachedFromVisualTree += (_, _) => _shell.Mesh.MeshModeChanged -= ShowMode;
        ShowMode();
    }

    void ShowMode() => IsVisible = _shell.Mesh.InMeshMode;

    void Section(string title, params Control[] parts)
    {
        var stack = new StackPanel { Spacing = 4 };
        stack.Children.AddRange(parts);
        var expander = _sections.Create(title, stack);
        expander.Classes.Add("shelf");
        _content.Children.Add(expander);
    }

    // The commands as buttons with their labels, two to a row.
    UniformGrid Buttons(params string[] commands)
    {
        var grid = new UniformGrid { Columns = 2 };
        grid.Children.AddRange(commands.Select(id => ToolButton.Create(_shell, id, label: true, "shelf-button", ShortLabel(id))));
        return grid;
    }

    Button Wide(string command) => ToolButton.Create(_shell, command, label: true, "shelf-button");

    // The labels that are too long for half the shelf, shorter. The tooltip has the command's own.
    string? ShortLabel(string id) => id switch
    {
        EditorCommands.MeshDuplicate => "Duplicate",
        EditorCommands.MeshSelectLinked => "Linked",
        EditorCommands.SelectAll => "All",
        EditorCommands.MeshApplyPoints => "Apply",
        EditorCommands.MeshGridFiner => "Finer",
        EditorCommands.MeshGridCoarser => "Coarser",
        EditorCommands.MeshMergeFaces => "Merge",
        _ => null,
    };
}

/// <summary>
/// The Scene document's view (see docs/editor/viewport.md#views): the tool strip, mesh mode's shelf while the mode is on,
/// the Landscape tool's shelf while it is the tool, and the scene views. The strip and the shelves are the Scene's, not
/// a view's, because the tool, the space, snapping and mesh mode are the same in every view. Their buttons take no
/// keyboard, so that the view keeps its keys; a press on one while the keyboard is elsewhere, as in a graph, gives it to
/// the active view, so the strip's Delete deletes the scene's entities, not what a graph's scope would.
/// </summary>
public sealed class SceneDocumentView : DockPanel
{
    public SceneDocumentView(EditorShell shell)
    {
        AddHandler(PointerPressedEvent, (_, _) =>
        {
            if (!IsKeyboardFocusWithin)
            {
                var views = this.GetVisualDescendants().OfType<ViewportView>().ToList();
                (views.FirstOrDefault(v => v.Viewport == shell.ActiveViewport) ?? views.FirstOrDefault())?.Focus();
            }
        }, Avalonia.Interactivity.RoutingStrategies.Tunnel, handledEventsToo: true);
        var strip = new SceneToolStrip(shell);
        var shelf = new MeshToolShelf(shell);
        var landscape = new LandscapeShelf(shell);
        SetDock(strip, Avalonia.Controls.Dock.Left);
        SetDock(shelf, Avalonia.Controls.Dock.Left);
        SetDock(landscape, Avalonia.Controls.Dock.Left);
        Children.Add(strip);
        Children.Add(shelf);
        Children.Add(landscape);
        Children.Add(new SceneLayoutView(shell));
    }
}
