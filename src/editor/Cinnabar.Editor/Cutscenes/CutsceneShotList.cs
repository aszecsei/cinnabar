using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Shell;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.Cutscenes;

/// <summary>
/// The shot list beside the timeline (see docs/editor/cutscene-editor.md#shot-list): a row for each of the shown level's
/// sub-sequence sections, in time order, with its name, start, length and camera. A click goes to the shot, a
/// double-click or F2 on a row renames it, and a drag onto another row of its track moves it there.
/// </summary>
public sealed class CutsceneShotList : DockPanel
{
    static readonly IBrush RowBrush = new SolidColorBrush(Color.Parse("#252528"));
    static readonly IBrush SelectedBrush = new SolidColorBrush(Color.Parse("#2f4a6b"));
    static readonly IBrush DropBrush = new SolidColorBrush(Color.Parse("#4c8ed9"));
    static readonly IBrush DimBrush = new SolidColorBrush(Color.Parse("#9a9aa0"));
    const double DragDistance = 4;

    readonly CutsceneEditor _editor;
    readonly StackPanel _rows = new() { Spacing = 1 };
    readonly TextBlock _empty = new() { Text = "No sub-sequence sections. New Shot at Playhead makes one.", Classes = { "empty" }, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(8) };
    readonly List<(Border Row, CutsceneShotRow Shot)> _shown = [];
    string? _key;
    // A drag from a row: where it was pressed, and the row under the pointer, which takes the shot on release.
    (CutsceneShotRow Shot, Point From, bool Moving)? _drag;
    Border? _dropOn;
    TextBox? _renaming;

    public CutsceneShotList(CutsceneEditor editor)
    {
        _editor = editor;
        Focusable = true;
        var header = new TextBlock { Text = "Shots", FontSize = 11, FontWeight = FontWeight.SemiBold, Margin = new Thickness(8, 4) };
        SetDock(header, DockSide.Top);
        Children.Add(header);
        SetDock(_empty, DockSide.Top);
        Children.Add(_empty);
        Children.Add(new ScrollViewer { Content = _rows });
    }

    /// <summary>Builds the rows again when the shots, the selection or the rate change.</summary>
    public void Show()
    {
        var rows = _editor.ShotRows;
        var rate = _editor.File.Rate;
        var key = string.Join("\n", rows.Select(r => $"{r.Path}|{r.Name}|{r.Start}|{r.Length}|{r.Camera}")) + $"\n{rate}\n{_editor.Selection}";
        if (key == _key || _renaming != null)
        {
            return;
        }
        _key = key;
        _empty.IsVisible = rows.Count == 0;
        _rows.Children.Clear();
        _shown.Clear();
        foreach (var shot in rows)
        {
            var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto,Auto"), Margin = new Thickness(8, 3) };
            var name = new StackPanel();
            name.Children.Add(new TextBlock { Text = shot.Name, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis });
            if (shot.Camera.Length > 0)
            {
                name.Children.Add(new TextBlock { Text = shot.Camera, FontSize = 10, Foreground = DimBrush, TextTrimming = TextTrimming.CharacterEllipsis });
            }
            grid.Children.Add(name);
            var start = new TextBlock { Text = CutsceneTime.Timecode(shot.Start, rate), FontSize = 11, Foreground = DimBrush, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(start, 1);
            grid.Children.Add(start);
            var length = new TextBlock { Text = CutsceneTime.Timecode(shot.Length, rate), FontSize = 11, Foreground = DimBrush, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(length, 2);
            grid.Children.Add(length);
            var row = new Border
            {
                Child = grid,
                Background = shot.Path == _editor.Selection ? SelectedBrush : RowBrush,
                BorderBrush = DropBrush,
                BorderThickness = new Thickness(0),
            };
            ToolTip.SetTip(row, $"{shot.Name}: starts at {CutsceneTime.Timecode(shot.Start, rate)}, {CutsceneTime.Timecode(shot.Length, rate)} long. Drag onto another shot of its track to move it there.");
            row.PointerPressed += (_, e) => Press(row, shot, e);
            _rows.Children.Add(row);
            _shown.Add((row, shot));
        }
    }

    void Press(Border row, CutsceneShotRow shot, PointerPressedEventArgs e)
    {
        if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed)
        {
            return;
        }
        Focus();
        if (e.ClickCount == 2)
        {
            Rename(row, shot);
            e.Handled = true;
            return;
        }
        _drag = (shot, e.GetPosition(this), false);
        e.Pointer.Capture(this);
        e.Handled = true;
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        if (_drag is not { } drag)
        {
            return;
        }
        var at = e.GetPosition(this);
        if (!drag.Moving && Math.Abs(at.Y - drag.From.Y) < DragDistance)
        {
            return;
        }
        _drag = drag with { Moving = true };
        var over = RowAt(at);
        SetDropOn(over is { } o && o.Shot.Path != drag.Shot.Path ? o.Row : null, below: over is { } r && Index(r.Shot) > Index(drag.Shot));
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);
        if (_drag is not { } drag)
        {
            return;
        }
        _drag = null;
        e.Pointer.Capture(null);
        SetDropOn(null, false);
        if (!drag.Moving)
        {
            _editor.GoToShot(drag.Shot.Path);
            return;
        }
        if (RowAt(e.GetPosition(this)) is { } over && over.Shot.Path != drag.Shot.Path)
        {
            _editor.MoveShot(drag.Shot.Path, over.Shot.Path);
        }
    }

    protected override void OnPointerCaptureLost(PointerCaptureLostEventArgs e)
    {
        base.OnPointerCaptureLost(e);
        _drag = null;
        SetDropOn(null, false);
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (e.Key == Key.F2 && _renaming == null && _shown.FirstOrDefault(s => s.Shot.Path == _editor.Selection) is { Row: not null } selected)
        {
            Rename(selected.Row, selected.Shot);
            e.Handled = true;
        }
        else if (e.Key == Key.Escape && _drag != null)
        {
            _drag = null;
            SetDropOn(null, false);
            e.Handled = true;
        }
    }

    int Index(CutsceneShotRow shot) => _shown.FindIndex(s => s.Shot.Path == shot.Path);

    (Border Row, CutsceneShotRow Shot)? RowAt(Point at)
    {
        foreach (var shown in _shown)
        {
            if (shown.Row.TranslatePoint(new Point(0, 0), this) is { } origin && at.Y >= origin.Y && at.Y < origin.Y + shown.Row.Bounds.Height)
            {
                return shown;
            }
        }
        return null;
    }

    // The line where a dragged shot goes: under the row it lands on when it moves down, else over it.
    void SetDropOn(Border? row, bool below)
    {
        if (_dropOn != null)
        {
            _dropOn.BorderThickness = new Thickness(0);
        }
        _dropOn = row;
        if (row != null)
        {
            row.BorderThickness = below ? new Thickness(0, 0, 0, 2) : new Thickness(0, 2, 0, 0);
        }
    }

    // A box in place of the row's name: Enter renames the shot, and Esc or a click elsewhere leaves it.
    void Rename(Border row, CutsceneShotRow shot)
    {
        if (row.Child is not Grid grid)
        {
            return;
        }
        var box = new TextBox { Text = shot.Name, FontSize = 12, MinHeight = 0, Padding = new Thickness(2, 0) };
        var name = grid.Children[0];
        name.IsVisible = false;
        grid.Children.Add(box);
        _renaming = box;
        void End(bool commit)
        {
            if (_renaming != box)
            {
                return;
            }
            _renaming = null;
            var text = box.Text ?? "";
            grid.Children.Remove(box);
            name.IsVisible = true;
            _key = null;
            if (commit)
            {
                _editor.RenameShot(shot.Path, text);
            }
            Show();
            Focus();
        }
        box.KeyDown += (_, e) =>
        {
            if (e.Key is Key.Enter or Key.Escape)
            {
                End(e.Key == Key.Enter);
                e.Handled = true;
            }
        };
        box.LostFocus += (_, _) => End(commit: false);
        box.AttachedToVisualTree += (_, _) =>
        {
            box.Focus();
            box.SelectAll();
        };
    }
}
