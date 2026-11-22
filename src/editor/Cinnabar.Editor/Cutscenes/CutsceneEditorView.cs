using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Host;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Ribbon;
using Cinnabar.Editor.Shell;
using static Cinnabar.Editor.Panels.Kit;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.Cutscenes;

/// <summary>
/// The cutscene editor (see docs/editor/cutscene-editor.md#the-tab): a toolbar with the cutscene's length, a strip that
/// filters the tracks, the timeline of its bindings, tracks, sections and keys, and the selected block's details under it. Docking can rebuild the view at any
/// time, so its state is in its <see cref="CutsceneEditor"/>.
/// </summary>
public sealed class CutsceneEditorView : DockPanel
{
    readonly EditorShell _shell;
    readonly CutsceneEditor _editor;
    readonly TextBlock _playhead = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0), FontFamily = new FontFamily("Consolas, monospace") };
    readonly Button _play = new() { Classes = { "viewport-tool" }, Focusable = false, Margin = new Thickness(8, 0, 0, 0) };
    readonly Button _here;
    bool _flushQueued;
    readonly TextBlock _time = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0) };
    readonly TextBlock _status = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBox _search = new() { PlaceholderText = "Filter tracks (Ctrl+F)", Classes = { "value-edit" }, MinWidth = 200, FontSize = 12 };
    readonly ToggleButton _keysUnder = new() { Content = "Keys under selection", Classes = { "viewport-tool" }, FontSize = 11, Focusable = false, Margin = new Thickness(8, 0, 0, 0) };

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
        ToolTip.SetTip(_play, "Play or pause the preview in the game (Space)");
        _play.Click += (_, _) => shell.CutscenePreview.PlayPause();
        DockPanel.SetDock(_play, DockSide.Left);
        toolbar.Children.Add(_play);
        DockPanel.SetDock(_playhead, DockSide.Left);
        toolbar.Children.Add(_playhead);
        DockPanel.SetDock(_time, DockSide.Left);
        toolbar.Children.Add(_time);
        _here = SmallButton("Preview here", "Show this cutscene in the game, in place of the one that it shows now.", () => shell.CutscenePreview.Take(editor));
        _here.Margin = new Thickness(8, 0, 0, 0);
        DockPanel.SetDock(_here, DockSide.Right);
        toolbar.Children.Add(_here);
        DockPanel.SetDock(_status, DockSide.Right);
        toolbar.Children.Add(_status);
        toolbar.Children.Add(new Panel());
        var top = new Border { Child = toolbar, BorderBrush = new SolidColorBrush(Color.Parse("#333337")), BorderThickness = new Thickness(0, 0, 0, 1) };
        SetDock(top, DockSide.Top);
        Children.Add(top);

        var grid = new Grid { RowDefinitions = new RowDefinitions("*,4,220") };
        var timeline = new CutsceneTimeline(editor);
        // The strip over the timeline: the search box, which filters the tracks by binding or track name as it is
        // typed, and Esc in it clears it and gives the keyboard back to the timeline; and the keys-under-selection toggle.
        _search.Text = editor.FilterText;
        _search.TextChanged += (_, _) => editor.SetFilterText(_search.Text ?? "");
        _search.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                _search.Text = "";
                timeline.Focus();
                e.Handled = true;
            }
        };
        ToolTip.SetTip(_keysUnder, "Show only the tracks with keys in the span of the selection, as it is when this is turned on.");
        _keysUnder.IsCheckedChanged += (_, _) => editor.SetKeysUnderSelection(_keysUnder.IsChecked == true);
        var strip = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(8, 4) };
        strip.Children.Add(new Border { Classes = { "value-box", "editable" }, Child = _search });
        strip.Children.Add(_keysUnder);
        var timelinePane = new DockPanel();
        SetDock(strip, DockSide.Top);
        timelinePane.Children.Add(strip);
        timelinePane.Children.Add(timeline);
        grid.Children.Add(timelinePane);
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

        void Find()
        {
            _search.Focus();
            _search.SelectAll();
        }
        void AskTracks(IReadOnlyList<string> kinds) => _ = AskPasteTracks(kinds);
        new ViewSubscriptions(this, attached: Show)
            .Add(() => _editor.Changed += Show, () => _editor.Changed -= Show)
            .Add(() => _editor.FindRequested += Find, () => _editor.FindRequested -= Find)
            .Add(() => _editor.PasteTracksRequested += AskTracks, () => _editor.PasteTracksRequested -= AskTracks)
            .Add(() => _editor.ProblemsChanged += Show, () => _editor.ProblemsChanged -= Show)
            .Add(() => _shell.Cook.StateChanged += Show, () => _shell.Cook.StateChanged -= Show)
            .Add(() => _shell.CutscenePreview.Changed += Show, () => _shell.CutscenePreview.Changed -= Show)
            .Add(() => _editor.PlayheadChanged += OnPlayhead, () => _editor.PlayheadChanged -= OnPlayhead)
            .Add(() => _shell.Host.StateChanged += OnHostState, () => _shell.Host.StateChanged -= OnHostState);
    }

    // A paste needs tracks that the cutscene lacks: Add pastes with them, Cancel pastes nothing.
    async Task AskPasteTracks(IReadOnlyList<string> kinds)
    {
        if (TopLevel.GetTopLevel(this) is not Window window)
        {
            return;
        }
        var names = string.Join(", ", kinds.Select(k => k.Replace('_', ' ')));
        var answer = await Dialogs.Ask(window, "Add tracks to paste?",
            $"The paste needs tracks of these kinds, which the target does not have: {names}. Add them, like the tracks that were copied?",
            "Add Tracks", "Cancel");
        if (answer == "Add Tracks")
        {
            _editor.Paste(addTracks: true);
        }
    }

    void OnHostState(HostState _) => Show();

    void OnPlayhead()
    {
        ShowPlayhead();
        ScheduleFlush();
    }

    void ShowPlayhead()
    {
        var file = _editor.File;
        var at = _editor.Playhead;
        _playhead.Text = $"{CutsceneTime.Timecode(at, file.Rate)}  ·  frame {CutsceneTime.Frames(at, file.Rate)}";
    }

    // A scrub sends its tick once a frame, at the next one, however many times the pointer moved before it.
    void ScheduleFlush()
    {
        if (_flushQueued || !_shell.CutscenePreview.Pending || TopLevel.GetTopLevel(this) is not { } top)
        {
            return;
        }
        _flushQueued = true;
        top.RequestAnimationFrame(_ =>
        {
            _flushQueued = false;
            _shell.CutscenePreview.Flush();
        });
    }

    void Show()
    {
        ShowPlayhead();
        ScheduleFlush();
        var preview = _shell.CutscenePreview;
        _play.Content = CommandViews.Icon(preview.IsPlayingIn(_editor) ? "pause" : "play", 16);
        _play.IsEnabled = preview.CanPlay(_editor);
        _here.IsVisible = preview.CanTake(_editor);
        if (_keysUnder.IsChecked != _editor.KeysUnderSelection)
        {
            _keysUnder.IsChecked = _editor.KeysUnderSelection;
        }
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
        parts.Add(preview.Describe(_editor));
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
