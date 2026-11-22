using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using static Cinnabar.Editor.Panels.Kit;

namespace Cinnabar.Editor.Cutscenes;

/// <summary>
/// The outline of a cutscene (see docs/editor/cutscene-editor.md#the-tab): a row for every block, the cutscene, its
/// bindings, its tracks with their sections, triggers and ranges, and the sections' channels with their keys, and a mark
/// on a row whose lines have problems.
/// Clicking a row selects its block. The timeline (#550) takes its place.
/// </summary>
sealed class CutsceneOutline : ScrollViewer
{
    readonly CutsceneEditor _editor;
    readonly StackPanel _rows = new() { Margin = new Thickness(8), Spacing = 1 };
    string _shown = "";

    // A subclass takes ScrollViewer's template only by its style key.
    protected override Type StyleKeyOverride => typeof(ScrollViewer);

    public CutsceneOutline(CutsceneEditor editor)
    {
        _editor = editor;
        Content = _rows;
        HorizontalScrollBarVisibility = ScrollBarVisibility.Auto;
        new ViewSubscriptions(this, attached: Refresh)
            .Add(() => _editor.Changed += Refresh, () => _editor.Changed -= Refresh)
            .Add(() => _editor.ProblemsChanged += Refresh, () => _editor.ProblemsChanged -= Refresh);
    }

    // The blocks that have rows, with their depth.
    IEnumerable<(CutsceneBlock Block, int Depth)> Rows()
    {
        var file = _editor.File;
        yield return (file.Root, 0);
        foreach (var binding in file.Bindings)
        {
            yield return (binding, 1);
        }
        foreach (var track in file.Tracks)
        {
            foreach (var block in track.Descendants())
            {
                var depth = 0;
                for (var at = block; at.Parent != null; at = at.Parent)
                {
                    depth++;
                }
                yield return (block, depth);
            }
        }
    }

    void Refresh()
    {
        var rows = Rows().ToList();
        var shown = string.Join("|", rows.Select(r => $"{CutsceneFile.PathOf(r.Block)} {Label(r.Block)}")) + "#" + _editor.Selection
            + "#" + string.Join("|", _editor.Problems.Select(p => p.Line + p.Text));
        if (shown == _shown)
        {
            return;
        }
        _shown = shown;
        _rows.Children.Clear();
        foreach (var (block, depth) in rows)
        {
            _rows.Children.Add(Row(block, depth));
        }
        foreach (var p in _editor.Problems.Where(p => p.Line == 0))
        {
            _rows.Children.Add(AnimationGraphs.AnimationGraphPanel.ProblemText(p));
        }
        if (!_editor.File.Tracks.Any() && !_editor.File.Bindings.Any())
        {
            _rows.Children.Add(Dim("The cutscene has no bindings or tracks. Add them in its text for now: the timeline comes next."));
        }
    }

    Control Row(CutsceneBlock block, int depth)
    {
        var problems = _editor.ProblemsOf(block).ToList();
        var selected = _editor.Selection == CutsceneFile.PathOf(block);
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(depth * 16, 0, 0, 0) };
        line.Children.Add(new TextBlock { Text = Label(block), VerticalAlignment = VerticalAlignment.Center, FontSize = 12 });
        if (Span(block) is { } span)
        {
            line.Children.Add(new TextBlock { Text = span, Classes = { "empty" }, VerticalAlignment = VerticalAlignment.Center, FontSize = 12 });
        }
        if (problems.Count > 0)
        {
            var mark = new TextBlock
            {
                Text = problems.Any(p => p.Error) ? "●" : "▲",
                Classes = { problems.Any(p => p.Error) ? "error" : "warning" },
                VerticalAlignment = VerticalAlignment.Center,
            };
            ToolTip.SetTip(mark, string.Join("\n", problems.Select(p => p.Text)));
            line.Children.Add(mark);
        }
        var row = new Border
        {
            Child = line,
            Padding = new Thickness(4, 2),
            CornerRadius = new CornerRadius(2),
            Background = selected ? new SolidColorBrush(Color.Parse("#2F4F7F")) : Brushes.Transparent,
            Cursor = new Cursor(StandardCursorType.Hand),
        };
        row.PointerPressed += (_, e) =>
        {
            if (e.GetCurrentPoint(row).Properties.IsLeftButtonPressed)
            {
                _editor.Select(block);
                e.Handled = true;
            }
        };
        var column = new StackPanel { Children = { row } };
        if (selected)
        {
            foreach (var p in problems)
            {
                var text = AnimationGraphs.AnimationGraphPanel.ProblemText(p);
                text.Margin = new Thickness(depth * 16 + 4, 0, 0, 2);
                column.Children.Add(text);
            }
        }
        return column;
    }

    static string Label(CutsceneBlock block) => block.Kind switch
    {
        CutsceneBlockKind.Cutscene => "Cutscene",
        CutsceneBlockKind.Binding => $"Binding {block.Id}  {block.Name}",
        CutsceneBlockKind.Track => $"{block.TrackKind} {block.Id}  {block.Name}",
        CutsceneBlockKind.Section => $"Section {block.Id}",
        CutsceneBlockKind.Trigger => $"Trigger {block.Id}  {block.Name}",
        CutsceneBlockKind.Range => $"Range {block.Id}  {block.Name}",
        CutsceneBlockKind.Channel => $"Channel  {block.Name}",
        CutsceneBlockKind.Key => $"Key  {block.KeyValue} {block.KeyInterpolation}",
        _ => block.Kind.ToString(),
    };

    string? Span(CutsceneBlock block)
    {
        var rate = _editor.File.Rate;
        return block.Kind switch
        {
            CutsceneBlockKind.Section or CutsceneBlockKind.Range when block.Start is { } start && block.End is { } end =>
                $"{CutsceneTime.Timecode(start, rate)} – {CutsceneTime.Timecode(end, rate)}",
            CutsceneBlockKind.Trigger when block.Start is { } time => CutsceneTime.Timecode(time, rate),
            // A key's time is from its section's start.
            CutsceneBlockKind.Key when block.Start is { } time => $"+{CutsceneTime.Timecode(time, rate)}",
            _ => null,
        };
    }
}
