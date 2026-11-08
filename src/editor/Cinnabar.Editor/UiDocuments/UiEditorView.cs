using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Ribbon;
using Cinnabar.Editor.Shell;
using static Cinnabar.Editor.Panels.Kit;
using DockSide = Avalonia.Controls.Dock;
using UiPreviewBackground = Cinnabar.Editor.Link.Protocol.UiPreviewBackground;

namespace Cinnabar.Editor.UiDocuments;

/// <summary>
/// The UI editor (see docs/editor/ui-editor.md#ui-editor): a toolbar of the screen, its scale and the view; the tree over
/// the styles on the left, the canvas, and the properties over the bindings on the right. Docking can rebuild the view
/// at any time, so its state is in its <see cref="UiEditor"/>.
/// </summary>
public sealed class UiEditorView : DockPanel
{
    const string Custom = "Custom";

    readonly EditorShell _shell;
    readonly UiEditor _editor;
    readonly TextBlock _status = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center };

    public UiEditorView(EditorShell shell, UiEditor editor)
    {
        _shell = shell;
        _editor = editor;

        var toolbar = new WrapPanel { Margin = new Thickness(8, 4) };
        var save = new Button { Content = CommandViews.Icon("save", 16), Classes = { "viewport-tool" }, Focusable = false, Margin = new Thickness(0, 0, 8, 0) };
        ToolTip.SetTip(save, "Save (Ctrl+S)");
        save.Click += (_, _) => shell.SaveGraph(editor);
        toolbar.Children.Add(save);
        toolbar.Children.Add(SmallButton("Open in Script Editor", "Edit the document's text. Save first: this editor does not read the file again.", () => shell.OpenScript(editor.Document.Path)));
        toolbar.Children.Add(Gap());

        var screens = UiEditor.Screens.Select(s => s.Label).Append(Custom).ToList();
        var current = UiEditor.Screens.FirstOrDefault(s => (s.Width, s.Height) == editor.Screen).Label ?? Custom;
        var width = ValueBox(editor.Screen.Width.ToString(CultureInfo.InvariantCulture), "width", text =>
        {
            if (int.TryParse(text, out var w))
            {
                editor.SetScreen(w, editor.Screen.Height);
            }
        });
        var height = ValueBox(editor.Screen.Height.ToString(CultureInfo.InvariantCulture), "height", text =>
        {
            if (int.TryParse(text, out var h))
            {
                editor.SetScreen(editor.Screen.Width, h);
            }
        });
        width.Width = height.Width = 56;
        width.IsVisible = height.IsVisible = current == Custom;
        var screen = Choice(screens, current, pick =>
        {
            var preset = UiEditor.Screens.FirstOrDefault(s => s.Label == pick);
            width.IsVisible = height.IsVisible = preset.Label == null;
            if (preset.Label != null)
            {
                editor.SetScreen(preset.Width, preset.Height);
            }
        });
        screen.Width = 120;
        ToolTip.SetTip(screen, "The screen that the document is laid out on, as a player's");
        toolbar.Children.Add(screen);
        toolbar.Children.Add(width);
        toolbar.Children.Add(height);

        var scale = ValueBox(editor.ScaleFactor.ToString(CultureInfo.InvariantCulture), "ui.scale", text =>
        {
            if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var factor))
            {
                editor.SetScaleFactor(factor);
            }
        });
        scale.Width = 48;
        ToolTip.SetTip(scale, "What multiplies the screen's UI scale, as the project's ui.scale does: from 0.25 to 4");
        toolbar.Children.Add(Label("scale"));
        toolbar.Children.Add(scale);
        toolbar.Children.Add(Gap());
        toolbar.Children.Add(SmallButton("Fit", "Fit the screen in the canvas (F)", editor.Fit));
        toolbar.Children.Add(SmallButton("100%", "One pixel of the screen for each pixel of the canvas, as the game draws it", () =>
        {
            var (w, h) = editor.Size;
            editor.ZoomView(1, w / 2.0, h / 2.0);
        }));
        var background = Choice(["Dark", "Light"], editor.Background.ToString(), pick => editor.SetBackground(Enum.Parse<UiPreviewBackground>(pick)));
        background.Width = 72;
        ToolTip.SetTip(background, "What the canvas draws the document over");
        toolbar.Children.Add(Gap());
        toolbar.Children.Add(background);
        toolbar.Children.Add(Gap());
        toolbar.Children.Add(_status);
        var top = new Border { Child = toolbar, BorderBrush = new SolidColorBrush(Color.Parse("#333337")), BorderThickness = new Thickness(0, 0, 0, 1) };
        SetDock(top, DockSide.Top);
        Children.Add(top);

        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("260,4,*,4,300") };
        var left = new Grid { RowDefinitions = new RowDefinitions("*,4,200") };
        left.Children.Add(new UiTreeView(shell, editor));
        Split(left, 1, GridResizeDirection.Rows);
        var styles = new UiStylesPanel(editor);
        Grid.SetRow(styles, 2);
        left.Children.Add(styles);
        grid.Children.Add(left);
        Split(grid, 1, GridResizeDirection.Columns);
        var canvas = new UiCanvas(shell, editor);
        Grid.SetColumn(canvas, 2);
        grid.Children.Add(canvas);
        Split(grid, 3, GridResizeDirection.Columns);
        var right = new Grid { RowDefinitions = new RowDefinitions("*,4,150") };
        right.Children.Add(new UiDetails(shell, editor));
        Split(right, 1, GridResizeDirection.Rows);
        var bindings = new UiBindingsPanel(editor);
        Grid.SetRow(bindings, 2);
        right.Children.Add(bindings);
        Grid.SetColumn(right, 4);
        grid.Children.Add(right);
        Children.Add(grid);

        new ViewSubscriptions(this, attached: Show)
            .Add(() => _editor.Changed += Show, () => _editor.Changed -= Show)
            .Add(() => _editor.ProblemsChanged += Show, () => _editor.ProblemsChanged -= Show)
            .Add(() => _shell.Cook.StateChanged += Show, () => _shell.Cook.StateChanged -= Show);
    }

    static Control Gap() => new Border { Width = 12 };

    static TextBlock Label(string text) => new() { Text = text, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 4, 0), Classes = { "field-name" } };

    static void Split(Grid grid, int at, GridResizeDirection direction)
    {
        var split = new GridSplitter { ResizeDirection = direction };
        if (direction == GridResizeDirection.Rows)
        {
            Grid.SetRow(split, at);
        }
        else
        {
            Grid.SetColumn(split, at);
        }
        grid.Children.Add(split);
    }

    void Show()
    {
        var parts = new List<string> { $"UI scale {_editor.Scale.ToString("0.##", CultureInfo.InvariantCulture)}" };
        var errors = _editor.Problems.Count(p => p.Error);
        if (!_shell.Cook.Linked)
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
