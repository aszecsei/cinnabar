using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Ribbon;
using Cinnabar.Editor.Shell;
using static Cinnabar.Editor.Materials.MaterialControls;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.Materials;

/// <summary>
/// The material editor (see docs/editor.md#material-editor): the material's settings over its node canvas, its
/// preview and parameters on the left, and the selected node's details on the right. A material function has its
/// canvas and details only. Docking can rebuild the view at any time, so its state is in its <see cref="MaterialEditor"/>.
/// </summary>
public sealed class MaterialEditorView : DockPanel
{
    readonly EditorShell _shell;
    readonly MaterialEditor _editor;
    readonly StackPanel _settings = new() { Orientation = Orientation.Horizontal, Spacing = 10, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock _status = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
    string _shownSettings = "";

    public MaterialEditorView(EditorShell shell, MaterialEditor editor)
    {
        _shell = shell;
        _editor = editor;
        var canvas = new GraphCanvas(shell, editor);

        var toolbar = new DockPanel { Margin = new Thickness(8, 4) };
        var save = new Button { Content = CommandViews.Icon("save", 16), Classes = { "viewport-tool" }, Focusable = false, Margin = new Thickness(0, 0, 8, 0) };
        ToolTip.SetTip(save, "Save (Ctrl+S)");
        save.Click += (_, _) => shell.SaveMaterial(editor);
        DockPanel.SetDock(save, DockSide.Left);
        toolbar.Children.Add(save);
        DockPanel.SetDock(_status, DockSide.Right);
        toolbar.Children.Add(_status);
        toolbar.Children.Add(_settings);
        var top = new Border { Child = toolbar, BorderBrush = new SolidColorBrush(Color.Parse("#333337")), BorderThickness = new Thickness(0, 0, 0, 1) };
        SetDock(top, DockSide.Top);
        Children.Add(top);

        var grid = new Grid();
        var material = editor.Document.Kind == MaterialFileKind.Material;
        grid.ColumnDefinitions = material ? new ColumnDefinitions("260,4,*,4,280") : new ColumnDefinitions("0,0,*,4,280");
        if (material)
        {
            var left = new Grid { RowDefinitions = new RowDefinitions("260,4,*") };
            left.Children.Add(new PreviewPane(shell, editor));
            var split = new GridSplitter { ResizeDirection = GridResizeDirection.Rows };
            Grid.SetRow(split, 1);
            left.Children.Add(split);
            var parameters = new ParametersPanel(shell, editor, () => canvas.Middle);
            Grid.SetRow(parameters, 2);
            left.Children.Add(parameters);
            grid.Children.Add(left);
            var leftSplit = new GridSplitter { ResizeDirection = GridResizeDirection.Columns };
            Grid.SetColumn(leftSplit, 1);
            grid.Children.Add(leftSplit);
        }
        Grid.SetColumn(canvas, 2);
        grid.Children.Add(canvas);
        var rightSplit = new GridSplitter { ResizeDirection = GridResizeDirection.Columns };
        Grid.SetColumn(rightSplit, 3);
        grid.Children.Add(rightSplit);
        var details = new NodeDetails(shell, editor);
        Grid.SetColumn(details, 4);
        grid.Children.Add(details);
        Children.Add(grid);

        AttachedToVisualTree += (_, _) =>
        {
            _editor.Changed += Show;
            _editor.ProblemsChanged += Show;
            _shell.Assets.Changed += Show;
            _shell.Cook.StateChanged += Show;
            Show();
        };
        DetachedFromVisualTree += (_, _) =>
        {
            _editor.Changed -= Show;
            _editor.ProblemsChanged -= Show;
            _shell.Assets.Changed -= Show;
            _shell.Cook.StateChanged -= Show;
        };
    }

    void Show()
    {
        ShowSettings();
        var asset = _shell.Assets.Find(_editor.Guid);
        var parts = new List<string>();
        if (_editor.Document.Kind == MaterialFileKind.Material && asset is { Permutations: > 0 } a)
        {
            parts.Add($"{a.Permutations} {(a.Permutations == 1 ? "permutation" : "permutations")}");
        }
        var errors = _editor.Problems.Count(p => p.Error);
        if (_editor.CookError != null)
        {
            parts.Add(errors > 1 ? $"{errors} errors" : "does not cook");
        }
        else if (_editor.PreviewId != null)
        {
            parts.Add(_shell.Cook.State != Content.CookState.Linked ? "waiting for the cook daemon" : _editor.ShowsUnsaved ? "preview cooked" : "cooking the preview");
        }
        if (_editor.Document.IsDirty)
        {
            parts.Add("not saved");
        }
        _status.Text = string.Join("  ·  ", parts);
        _status.Classes.Set("warning", _editor.CookError != null);
        ToolTip.SetTip(_status, _editor.CookError);
    }

    // The material's settings: its shading model, its blend and cutoff, two-sided and casting shadows.
    void ShowSettings()
    {
        var graph = _editor.Document.Graph;
        var models = _editor.Catalog.ShadingModels.Select(s => s.Name).ToList();
        var shown = $"{graph.Kind}|{graph.Shading}|{graph.Blend}|{graph.Cutoff}|{graph.TwoSided}|{graph.CastShadows}|{string.Join(",", models)}";
        if (shown == _shownSettings)
        {
            return;
        }
        _shownSettings = shown;
        _settings.Children.Clear();
        if (graph.Kind == MaterialFileKind.Function)
        {
            _settings.Children.Add(new TextBlock { Text = "Material function", FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Classes = { "dim" } });
            return;
        }
        if (!models.Contains(graph.Shading))
        {
            models.Add(graph.Shading);
        }
        _settings.Children.Add(Labeled("Shading", Choice(models, graph.Shading, s => _editor.SetSettings("Set Shading Model", g => g.Shading = s)), 110));
        _settings.Children.Add(Labeled("Blend", Choice(MaterialGraph.Blends, graph.Blend, b => _editor.SetSettings("Set Blend", g => g.Blend = b)), 100));
        if (graph.Blend == "masked")
        {
            _settings.Children.Add(Labeled("Cutoff", ValueBox(GraphNumbers.Format(graph.Cutoff), "0.5", text =>
            {
                if (double.TryParse(text, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var cutoff))
                {
                    _editor.SetSettings("Set Cutoff", g => g.Cutoff = cutoff);
                }
            }), 60));
        }
        _settings.Children.Add(Check("Two-sided", graph.TwoSided, on => _editor.SetSettings("Set Two-Sided", g => g.TwoSided = on)));
        _settings.Children.Add(Check("Casts shadows", graph.CastShadows, on => _editor.SetSettings("Set Casts Shadows", g => g.CastShadows = on)));
    }

    static Control Labeled(string label, Control control, double width)
    {
        control.Width = width;
        return new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            Children = { new TextBlock { Text = label, Classes = { "field-name" }, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, MinWidth = 0 }, control },
        };
    }

    static CheckBox Check(string label, bool value, Action<bool> set)
    {
        var box = new CheckBox { Content = label, IsChecked = value, FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
        box.IsCheckedChanged += (_, _) => set(box.IsChecked == true);
        return box;
    }
}
