using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Ribbon;
using Cinnabar.Editor.Shell;
using static Cinnabar.Editor.Panels.Kit;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.AnimationGraphs;

/// <summary>
/// The animation graph editor (see docs/editor/animation-graph-editor.md#animation-graph-editor): the graph's preview over its
/// settings, parameters and clips on the left, its canvas, and the selected node's details on the right. Docking can
/// rebuild the view at any time, so its state is in its <see cref="AnimationGraphEditor"/>.
/// </summary>
public sealed class AnimationGraphEditorView : DockPanel
{
    readonly EditorShell _shell;
    readonly AnimationGraphEditor _editor;
    readonly TextBlock _status = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center };

    public AnimationGraphEditorView(EditorShell shell, AnimationGraphEditor editor)
    {
        _shell = shell;
        _editor = editor;
        var canvas = new AnimationGraphCanvas(shell, editor);

        var toolbar = new DockPanel { Margin = new Thickness(8, 4) };
        var save = new Button { Content = CommandViews.Icon("save", 16), Classes = { "viewport-tool" }, Focusable = false, Margin = new Thickness(0, 0, 8, 0) };
        ToolTip.SetTip(save, "Save (Ctrl+S)");
        save.Click += (_, _) => shell.SaveGraph(editor);
        DockPanel.SetDock(save, DockSide.Left);
        toolbar.Children.Add(save);
        var text = SmallButton("Open in Script Editor", "Edit the graph's text, such as its clips' events. Save first: this editor does not read the file again.", () => shell.OpenScript(editor.Document.Path));
        DockPanel.SetDock(text, DockSide.Left);
        toolbar.Children.Add(text);
        DockPanel.SetDock(_status, DockSide.Right);
        toolbar.Children.Add(_status);
        toolbar.Children.Add(new Panel());
        var top = new Border { Child = toolbar, BorderBrush = new SolidColorBrush(Color.Parse("#333337")), BorderThickness = new Thickness(0, 0, 0, 1) };
        SetDock(top, DockSide.Top);
        Children.Add(top);

        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("260,4,*,4,280") };
        var left = new Grid { RowDefinitions = new RowDefinitions("240,4,*") };
        left.Children.Add(new Materials.PreviewPane(shell, editor));
        var previewSplit = new GridSplitter { ResizeDirection = GridResizeDirection.Rows };
        Grid.SetRow(previewSplit, 1);
        left.Children.Add(previewSplit);
        var panel = new AnimationGraphPanel(shell, editor);
        Grid.SetRow(panel, 2);
        left.Children.Add(panel);
        grid.Children.Add(left);
        var leftSplit = new GridSplitter { ResizeDirection = GridResizeDirection.Columns };
        Grid.SetColumn(leftSplit, 1);
        grid.Children.Add(leftSplit);
        Grid.SetColumn(canvas, 2);
        grid.Children.Add(canvas);
        var rightSplit = new GridSplitter { ResizeDirection = GridResizeDirection.Columns };
        Grid.SetColumn(rightSplit, 3);
        grid.Children.Add(rightSplit);
        var details = new AnimationNodeDetails(shell, editor);
        Grid.SetColumn(details, 4);
        grid.Children.Add(details);
        Children.Add(grid);

        new ViewSubscriptions(this, attached: Show)
            .Add(() => _editor.Changed += Show, () => _editor.Changed -= Show)
            .Add(() => _editor.ProblemsChanged += Show, () => _editor.ProblemsChanged -= Show)
            .Add(() => _shell.Cook.StateChanged += Show, () => _shell.Cook.StateChanged -= Show);
    }

    void Show()
    {
        var parts = new List<string>();
        var errors = _editor.Problems.Count(p => p.Error);
        if (_shell.Cook.State != Content.CookState.Linked)
        {
            parts.Add("waiting for the cook daemon");
        }
        else if (_editor.CookError != null)
        {
            parts.Add(errors == 1 ? "1 error" : $"{errors} errors");
        }
        else
        {
            parts.Add("cooks");
        }
        if (_editor.Document.IsDirty)
        {
            parts.Add("not saved");
        }
        _status.Text = string.Join("  ·  ", parts);
        _status.Classes.Set("warning", _editor.CookError != null);
        ToolTip.SetTip(_status, _editor.CookError);
    }
}
