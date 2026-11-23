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
/// filters the tracks, the timeline of its bindings, tracks, sections and keys, the curve editor below it when it is
/// open, and the selected block's details under them. Docking can rebuild the view at any time, so its state is in its
/// <see cref="CutsceneEditor"/>.
/// </summary>
public sealed class CutsceneEditorView : DockPanel
{
    readonly EditorShell _shell;
    readonly CutsceneEditor _editor;
    readonly TextBlock _playhead = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center, FontFamily = new FontFamily("Consolas, monospace") };
    readonly Button _playheadButton = new() { Classes = { "viewport-tool" }, Focusable = false, Margin = new Thickness(4, 0) };
    readonly TextBox _timeBox = new() { Classes = { "value-edit" }, MinWidth = 140, FontSize = 12, IsVisible = false, Margin = new Thickness(4, 0), FontFamily = new FontFamily("Consolas, monospace") };
    readonly ComboBox _rate = new() { FontSize = 11, Focusable = false, Margin = new Thickness(4, 0), VerticalAlignment = VerticalAlignment.Center };
    readonly ToggleButton _loop = new() { Content = "Loop", Classes = { "viewport-tool" }, FontSize = 11, Focusable = false, Margin = new Thickness(4, 0) };
    readonly Button _play = new() { Classes = { "viewport-tool" }, Focusable = false, Margin = new Thickness(8, 0, 0, 0) };
    readonly Button _here;
    bool _flushQueued;
    readonly TextBlock _time = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0) };
    readonly TextBlock _status = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBox _search = new() { PlaceholderText = "Filter tracks (Ctrl+F)", Classes = { "value-edit" }, MinWidth = 200, FontSize = 12 };
    readonly ToggleButton _curves = new() { Content = "Curves", Classes = { "viewport-tool" }, FontSize = 11, Focusable = false, Margin = new Thickness(8, 0, 0, 0) };
    readonly RowDefinition _curveRow = new(0, GridUnitType.Pixel);
    readonly RowDefinition _curveSplitRow = new(0, GridUnitType.Pixel);
    readonly CutsceneCurveEditor _curveEditor;
    // The curve editor under its own toolbar, which show and hide together.
    readonly DockPanel _curvePane = new() { IsVisible = false };
    readonly CutsceneTimeline _timeline;
    readonly GridSplitter _curveSplit = new() { ResizeDirection = GridResizeDirection.Rows, IsVisible = false };
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
        // The rate that Space plays at, and the loop.
        foreach (var rate in PlayRates)
        {
            _rate.Items.Add(new ComboBoxItem { Content = $"{rate:0.##}×", Tag = rate });
        }
        ToolTip.SetTip(_rate, "The rate at which Space plays the preview");
        _rate.SelectionChanged += (_, _) =>
        {
            if (_rate.SelectedItem is ComboBoxItem { Tag: float rate })
            {
                editor.PlayRate = rate;
            }
        };
        DockPanel.SetDock(_rate, DockSide.Left);
        toolbar.Children.Add(_rate);
        _loop.IsCheckedChanged += (_, _) => editor.Loop = _loop.IsChecked == true;
        DockPanel.SetDock(_loop, DockSide.Left);
        toolbar.Children.Add(_loop);
        ToolTip.SetTip(_curves, "Show the curves of the selected tracks below the timeline (Ctrl+E)");
        _curves.IsCheckedChanged += (_, _) => editor.CurvesOpen = _curves.IsChecked == true;
        DockPanel.SetDock(_curves, DockSide.Left);
        toolbar.Children.Add(_curves);
        // The playhead's time: a click, or Go to Time, swaps in a box to type a time. Enter jumps there, and Enter or
        // Esc gives the keyboard back to the timeline.
        _playheadButton.Content = _playhead;
        ToolTip.SetTip(_playheadButton, "Type a time to go to (Ctrl+G)");
        _playheadButton.Click += (_, _) => GoToTime();
        DockPanel.SetDock(_playheadButton, DockSide.Left);
        toolbar.Children.Add(_playheadButton);
        DockPanel.SetDock(_timeBox, DockSide.Left);
        toolbar.Children.Add(_timeBox);
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
        var timeline = _timeline = new CutsceneTimeline(editor);
        // Enter and Esc give the keyboard back to the timeline. A click elsewhere leaves it where it went.
        void EndGoToTime(bool jump, bool refocus)
        {
            if (!_timeBox.IsVisible)
            {
                return;
            }
            if (jump && CutsceneTime.TryParse(_timeBox.Text ?? "", editor.File.Rate, out var ticks))
            {
                editor.SetPlayhead(ticks);
            }
            _timeBox.IsVisible = false;
            _playheadButton.IsVisible = true;
            if (refocus)
            {
                timeline.Focus();
            }
        }
        _timeBox.KeyDown += (_, e) =>
        {
            if (e.Key is Key.Enter or Key.Escape)
            {
                EndGoToTime(e.Key == Key.Enter, refocus: true);
                e.Handled = true;
            }
        };
        _timeBox.LostFocus += (_, _) => EndGoToTime(jump: false, refocus: false);
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
        // The timeline, and the curve editor below it on the same time, with a split between them.
        var panes = new Grid { RowDefinitions = [new RowDefinition(1, GridUnitType.Star), _curveSplitRow, _curveRow] };
        panes.Children.Add(timeline);
        Grid.SetRow(_curveSplit, 1);
        panes.Children.Add(_curveSplit);
        _curveEditor = new CutsceneCurveEditor(editor);
        var curveBar = new CutsceneCurveBar(editor);
        DockPanel.SetDock(curveBar, DockSide.Top);
        _curvePane.Children.Add(curveBar);
        _curvePane.Children.Add(_curveEditor);
        Grid.SetRow(_curvePane, 2);
        panes.Children.Add(_curvePane);
        timelinePane.Children.Add(panes);
        // Red around the timeline while auto-key keys this cutscene's bound entities' edits.
        _autoKeyFrame = new Border { Child = timelinePane, Classes = { "auto-key-frame" }, BorderThickness = new Thickness(2) };
        grid.Children.Add(_autoKeyFrame);
        var split = new GridSplitter { ResizeDirection = GridResizeDirection.Rows };
        Grid.SetRow(split, 1);
        grid.Children.Add(split);
        var details = new CutsceneDetails(editor);
        Grid.SetRow(details, 2);
        grid.Children.Add(details);
        Children.Add(grid);

        // Esc cancels a drag on the timeline, on the curves or of a field, as it does every other drag, before the field
        // sees the key.
        AddHandler(KeyDownEvent, (_, e) =>
        {
            if (e.Key == Key.Escape && timeline.Input.Dragging)
            {
                timeline.Input.Escape();
                e.Handled = true;
            }
            else if (e.Key == Key.Escape && _curveEditor.Input.Dragging)
            {
                _curveEditor.Input.Escape();
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
            .Add(() => _editor.GoToTimeRequested += GoToTime, () => _editor.GoToTimeRequested -= GoToTime)
            .Add(() => _editor.PasteTracksRequested += AskTracks, () => _editor.PasteTracksRequested -= AskTracks)
            .Add(() => _editor.ProblemsChanged += Show, () => _editor.ProblemsChanged -= Show)
            .Add(() => _shell.Cook.StateChanged += Show, () => _shell.Cook.StateChanged -= Show)
            .Add(() => _shell.CutscenePreview.Changed += Show, () => _shell.CutscenePreview.Changed -= Show)
            .Add(() => _shell.Keying.Changed += ShowAutoKey, () => _shell.Keying.Changed -= ShowAutoKey)
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

    /// <summary>The rates of the play rate box.</summary>
    static readonly float[] PlayRates = [0.1f, 0.25f, 0.5f, 1f, 2f, 4f];

    void GoToTime()
    {
        _timeBox.Text = CutsceneTime.Timecode(_editor.Playhead, _editor.File.Rate);
        _playheadButton.IsVisible = false;
        _timeBox.IsVisible = true;
        _timeBox.Focus();
        _timeBox.SelectAll();
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

    readonly Border _autoKeyFrame;

    void ShowAutoKey() => _autoKeyFrame.Classes.Set("on", _shell.Keying.AutoKeyShows && _shell.Keying.Cutscene == _editor);

    // The curve editor's rows open and close with it, and it takes the keyboard when it opens.
    void ShowCurves()
    {
        var open = _editor.CurvesOpen;
        if (_curves.IsChecked != open)
        {
            _curves.IsChecked = open;
        }
        if (_curvePane.IsVisible == open)
        {
            return;
        }
        _curvePane.IsVisible = open;
        _curveSplit.IsVisible = open;
        _curveSplitRow.Height = new GridLength(open ? 4 : 0, GridUnitType.Pixel);
        _curveRow.Height = open ? new GridLength(1, GridUnitType.Star) : new GridLength(0, GridUnitType.Pixel);
        if (open)
        {
            _curveEditor.Focus();
        }
        else if (_editor.KeyboardPane != CutscenePane.None)
        {
            _timeline.Focus();
        }
    }

    void Show()
    {
        ShowAutoKey();
        ShowCurves();
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
        if (_loop.IsChecked != _editor.Loop)
        {
            _loop.IsChecked = _editor.Loop;
        }
        var range = _editor.LoopRange is { } loop
            ? $"{CutsceneTime.Timecode(loop.Start, _editor.File.Rate)} to {CutsceneTime.Timecode(loop.End, _editor.File.Rate)}"
            : "nothing: the in and the out point are at one time";
        ToolTip.SetTip(_loop, $"Loop the preview (Ctrl+L) over {range}. I and O set the in and the out point.");
        var selected = Array.FindIndex(PlayRates, r => r == _editor.PlayRate);
        if (_rate.SelectedIndex != selected)
        {
            _rate.SelectedIndex = selected;
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
        var described = preview.Describe(_editor);
        parts.Add(preview.RateIn(_editor) is { } playing && playing != 1 ? $"{described} at {playing:0.##}×" : described);
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

    /// <summary>
    /// Reads a time that a user typed, at a rate: timecode as <c>[[hh:]mm:]ss:ff</c>, or a count of frames as <c>120</c> or
    /// <c>120f</c>. A frame field at or past the rate, or a seconds or minutes field past 59 after the first, does not read.
    /// </summary>
    public static bool TryParse(string text, int rate, out int ticks)
    {
        ticks = 0;
        text = text.Trim();
        if (rate <= 0 || text.Length == 0)
        {
            return false;
        }
        long frames;
        if (!text.Contains(':'))
        {
            if (!long.TryParse(text.EndsWith('f') ? text[..^1] : text, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out frames))
            {
                return false;
            }
        }
        else
        {
            var parts = text.Split(':');
            if (parts.Length > 4)
            {
                return false;
            }
            var values = new long[parts.Length];
            for (var i = 0; i < parts.Length; i++)
            {
                if (!long.TryParse(parts[i], System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out values[i]) || values[i] > int.MaxValue)
                {
                    return false;
                }
            }
            if (values[^1] >= rate || values[1..^1].Any(v => v >= 60))
            {
                return false;
            }
            long seconds = 0;
            foreach (var v in values[..^1])
            {
                seconds = seconds * 60 + v;
            }
            frames = seconds * rate + values[^1];
        }
        var total = frames * FrameTicks(rate);
        if (total > int.MaxValue)
        {
            return false;
        }
        ticks = (int)total;
        return true;
    }
}
