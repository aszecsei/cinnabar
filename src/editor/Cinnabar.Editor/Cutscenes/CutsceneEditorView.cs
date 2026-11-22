using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Ribbon;
using Cinnabar.Editor.Shell;
using static Cinnabar.Editor.Panels.Kit;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.Cutscenes;

/// <summary>
/// The cutscene editor (see docs/editor/cutscene-editor.md#the-tab): a toolbar with the cutscene's length, the timeline of
/// its bindings, tracks, sections and keys, and the selected block's details under it. Docking can rebuild the view at any
/// time, so its state is in its <see cref="CutsceneEditor"/>.
/// </summary>
public sealed class CutsceneEditorView : DockPanel
{
    readonly EditorShell _shell;
    readonly CutsceneEditor _editor;
    readonly TextBlock _time = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0) };
    readonly TextBlock _status = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center };

    public CutsceneEditorView(EditorShell shell, CutsceneEditor editor)
    {
        _shell = shell;
        _editor = editor;
        var toolbar = new DockPanel { Margin = new Thickness(8, 4) };
        var save = new Button { Content = CommandViews.Icon("save", 16), Classes = { "viewport-tool" }, Focusable = false, Margin = new Thickness(0, 0, 8, 0) };
        ToolTip.SetTip(save, "Save (Ctrl+S)");
        save.Click += (_, _) => shell.SaveGraph(editor);
        DockPanel.SetDock(save, DockSide.Left);
        toolbar.Children.Add(save);
        var text = SmallButton("Open in Script Editor", "Edit the cutscene's text. Save first: this editor does not read the file again.", () => shell.OpenScript(editor.Document.Path));
        DockPanel.SetDock(text, DockSide.Left);
        toolbar.Children.Add(text);
        DockPanel.SetDock(_time, DockSide.Left);
        toolbar.Children.Add(_time);
        DockPanel.SetDock(_status, DockSide.Right);
        toolbar.Children.Add(_status);
        toolbar.Children.Add(new Panel());
        var top = new Border { Child = toolbar, BorderBrush = new SolidColorBrush(Color.Parse("#333337")), BorderThickness = new Thickness(0, 0, 0, 1) };
        SetDock(top, DockSide.Top);
        Children.Add(top);

        var grid = new Grid { RowDefinitions = new RowDefinitions("*,4,220") };
        var timeline = new CutsceneTimeline(editor);
        grid.Children.Add(timeline);
        var split = new GridSplitter { ResizeDirection = GridResizeDirection.Rows };
        Grid.SetRow(split, 1);
        grid.Children.Add(split);
        var details = new CutsceneDetails(editor);
        Grid.SetRow(details, 2);
        grid.Children.Add(details);
        Children.Add(grid);

        // Esc cancels a drag on the timeline or of a field, as it does every other drag, before the field sees the key.
        AddHandler(KeyDownEvent, (_, e) =>
        {
            if (e.Key == Key.Escape && timeline.Input.Dragging)
            {
                timeline.Input.Escape();
                e.Handled = true;
            }
            else if (e.Key == Key.Escape && _editor.Document.InTransaction)
            {
                _editor.EndField(cancel: true);
                e.Handled = true;
            }
        }, RoutingStrategies.Tunnel);

        new ViewSubscriptions(this, attached: Show)
            .Add(() => _editor.Changed += Show, () => _editor.Changed -= Show)
            .Add(() => _editor.ProblemsChanged += Show, () => _editor.ProblemsChanged -= Show)
            .Add(() => _shell.Cook.StateChanged += Show, () => _shell.Cook.StateChanged -= Show);
    }

    void Show()
    {
        var file = _editor.File;
        _time.Text = file.Length is { } length
            ? $"{CutsceneTime.Timecode(length, file.Rate)}  ·  {CutsceneTime.Frames(length, file.Rate)} frames at {file.Rate} fps"
            : $"no length  ·  {file.Rate} fps";
        var parts = new List<string>();
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

/// <summary>Times in ticks as the cutscene editor shows them, at a cutscene's display rate.</summary>
public static class CutsceneTime
{
    /// <summary>The whole frames before a time, at a rate. Every display rate divides a second's ticks.</summary>
    public static long Frames(int ticks, int rate) => (long)ticks * rate / CutsceneFile.TicksPerSecond;

    /// <summary>A time as <c>mm:ss:ff</c>, with the frame in its second.</summary>
    public static string Timecode(int ticks, int rate)
    {
        var frames = Frames(ticks, rate);
        var seconds = frames / rate;
        return $"{seconds / 60:00}:{seconds % 60:00}:{frames % rate:00}";
    }

    /// <summary>The ticks of a frame at a rate.</summary>
    public static int FrameTicks(int rate) => CutsceneFile.TicksPerSecond / rate;
}
