using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using static Cinnabar.Editor.Panels.Kit;

namespace Cinnabar.Editor.Cutscenes;

/// <summary>
/// The details strip of a cutscene (see docs/editor/cutscene-editor.md#the-tab): the selected block's fields, with a
/// row for each of its settings. A time's name scrubs it a frame a pixel, in one undo entry, and Esc cancels the drag.
/// </summary>
sealed class CutsceneDetails : ScrollViewer
{
    readonly CutsceneEditor _editor;
    readonly StackPanel _content = new() { Margin = new Thickness(8), Spacing = 2, MaxWidth = 520, HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Left };
    string _shown = "";

    // A subclass takes ScrollViewer's template only by its style key.
    protected override Type StyleKeyOverride => typeof(ScrollViewer);

    public CutsceneDetails(CutsceneEditor editor)
    {
        _editor = editor;
        Content = _content;
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        new ViewSubscriptions(this, attached: Refresh)
            .Add(() => _editor.Changed += Refresh, () => _editor.Changed -= Refresh);
    }

    void Rebuild()
    {
        _shown = "";
        Refresh();
    }

    void Refresh()
    {
        var block = _editor.Selected;
        // A drag shows in the outline and the toolbar. Its own rows build again only when it ends.
        if (_editor.Document.InTransaction && block != null)
        {
            return;
        }
        // A binding's state and whether a delete can remove it depend on the scenes and the other blocks.
        var binding = block?.Kind == CutsceneBlockKind.Binding ? $"#{_editor.InfoOf(block)}#{_editor.DeleteBindingRefusal()}" : "";
        var shown = block == null ? "" : $"{_editor.Selection}#{string.Join("\n", block.LineTexts)}#{_editor.File.Rate}{binding}";
        if (shown == _shown)
        {
            return;
        }
        _shown = shown;
        _content.Children.Clear();
        if (block == null)
        {
            _content.Children.Add(Dim("Select a row, a section, an event, a key or a marker to see its details."));
            return;
        }
        var rate = _editor.File.Rate;
        _content.Children.Add(Heading(block.Kind.ToString()));
        if (block.Id is { } id)
        {
            _content.Children.Add(Row("ID", new TextBlock { Text = id.ToString(System.Globalization.CultureInfo.InvariantCulture), FontSize = 12 }));
        }
        switch (block.Kind)
        {
            case CutsceneBlockKind.Binding or CutsceneBlockKind.Track:
                if (block.TrackKind is { } kind)
                {
                    _content.Children.Add(Row("Kind", new TextBlock { Text = kind, FontSize = 12 }));
                }
                _content.Children.Add(Row("Name", ValueBox(block.Name ?? "", "name", text =>
                    _editor.EditSelected("Rename", b => b.SetName(text.Trim())))));
                if (block.Kind == CutsceneBlockKind.Binding)
                {
                    // See docs/editor/cutscene-editor.md#bindings.
                    var info = _editor.InfoOf(block);
                    var what = info.Kind switch
                    {
                        CutsceneBindingKind.Possessed => "Possesses",
                        CutsceneBindingKind.Spawned => "Spawns",
                        _ => "Binds",
                    };
                    _content.Children.Add(Row(what, new TextBlock { Text = info.TargetName ?? "?", FontSize = 12 }));
                    if (info.Reason is { } reason)
                    {
                        _content.Children.Add(Dim(info.State == CutsceneBindingState.NotLoaded ? $"Not loaded: {reason}" : $"Broken: {reason}"));
                    }
                    if (_editor.DeleteBindingRefusal() is { } refusal)
                    {
                        _content.Children.Add(Dim($"Delete: {refusal}"));
                    }
                }
                break;
            case CutsceneBlockKind.Section or CutsceneBlockKind.Range:
                _content.Children.Add(TicksRow("Start", "Move Start", b => b.Start, (b, t) => b.SetSpan(t, b.End ?? t + 1), rate));
                _content.Children.Add(TicksRow("End", "Move End", b => b.End, (b, t) => b.SetSpan(b.Start ?? 0, t), rate));
                break;
            case CutsceneBlockKind.Trigger:
                _content.Children.Add(TicksRow("Time", "Move Trigger", b => b.Start, (b, t) => b.SetTime(t), rate));
                break;
            case CutsceneBlockKind.Key:
                _content.Children.Add(TicksRow("Time", "Move Key", b => b.Start, (b, t) => b.SetTime(t), rate));
                _content.Children.Add(Row("Value", ValueBox(block.KeyValue ?? "", "value", text =>
                    _editor.EditSelected("Set Key Value", b => b.SetKeyValue(text)))));
                _content.Children.Add(Row("Interpolation", ValueBox(block.KeyInterpolation ?? "", "linear", text =>
                    _editor.EditSelected("Set Interpolation", b => b.SetKeyInterpolation(text)))));
                break;
            case CutsceneBlockKind.Marker:
                // The markers stay in time order, as the editor keeps them.
                _content.Children.Add(TicksRow("Time", "Move Marker", b => b.Start, (b, t) =>
                {
                    b.SetTime(Math.Min(t, _editor.File.Length ?? t));
                    CutsceneFile.SortChildren(b.Parent!);
                }, rate));
                _content.Children.Add(Row("Name", ValueBox(block.Name ?? "", "name", text =>
                {
                    if (text.Trim().Length == 0)
                    {
                        Rebuild();
                        return;
                    }
                    _editor.EditSelected("Rename Marker", b => b.SetName(text.Trim()));
                })));
                _content.Children.Add(Row("Color", ValueBox(block.Get("color") is { } color ? TextQuote.Unquote(color) ?? color : "", "#f5a623", text =>
                {
                    var hex = text.Trim();
                    _editor.EditSelected("Set Marker Color", b => b.Set("color", hex.Length == 0 ? null : TextQuote.Quote(hex.StartsWith('#') ? hex : "#" + hex)));
                })));
                break;
            case CutsceneBlockKind.Cutscene:
                _content.Children.Add(TicksRow("length", "Set Length", b => _editor.File.Length, (b, t) => b.Set("length", Format(Math.Max(t, 1))), rate));
                break;
        }
        foreach (var (key, value) in block.Settings)
        {
            if ((block.Kind == CutsceneBlockKind.Cutscene && key == "length") || (block.Kind == CutsceneBlockKind.Marker && key == "color"))
            {
                continue;
            }
            var name = key;
            _content.Children.Add(Row(name, ValueBox(value, "value", text =>
            {
                if (text.Trim().Length == 0)
                {
                    Rebuild();
                    return;
                }
                _editor.EditSelected($"Set {name}", b => b.Set(name, text.Trim()));
            }), SmallButton("×", $"Remove {name}", () => _editor.EditSelected($"Remove {name}", b => b.Set(name, null)))));
        }
        if (block.Kind is not (CutsceneBlockKind.Key or CutsceneBlockKind.Channel or CutsceneBlockKind.Marker))
        {
            _content.Children.Add(Row("Add", ValueBox("", "name = value", text =>
            {
                var at = text.IndexOf('=');
                var (key, value) = at > 0 ? (text[..at].Trim(), text[(at + 1)..].Trim()) : ("", "");
                if (key.Length == 0 || value.Length == 0)
                {
                    Rebuild();
                    return;
                }
                _editor.EditSelected($"Set {key}", b => b.Set(key, value));
            })));
        }
    }

    static string Format(int ticks) => ticks.ToString(System.Globalization.CultureInfo.InvariantCulture);

    // A time in ticks, typed or scrubbed by its name a frame a pixel.
    Control TicksRow(string name, string label, Func<CutsceneBlock, int?> read, Action<CutsceneBlock, int> write, int rate)
    {
        var block = _editor.Selected!;
        var value = read(block);
        var row = Row(name, ValueBox(value is { } v ? Format(v) : "", "ticks", text =>
        {
            if (!CutsceneFile.TryParseTicks(text.Trim(), out var ticks))
            {
                Rebuild();
                return;
            }
            _editor.EditSelected(label, b => write(b, ticks));
        }), new TextBlock
        {
            Text = value is { } t ? CutsceneTime.Timecode(t, rate) : "",
            Classes = { "empty" },
            FontSize = 12,
            VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center,
            Margin = new Thickness(6, 0, 0, 0),
        });
        // The name takes the keyboard's focus when a scrub begins, so Esc reaches the view and cancels the scrub.
        var handle = row.Children[0];
        handle.Focusable = true;
        handle.PointerPressed += (_, _) => handle.Focus();
        FieldView.Scrubbable(handle, new TicksScrub(_editor, label, read, write, CutsceneTime.FrameTicks(rate)), 0);
        return row;
    }

    // A drag on a time's name: a frame a pixel, ten with Shift, in one undo entry from begin to end.
    sealed class TicksScrub(CutsceneEditor editor, string label, Func<CutsceneBlock, int?> read, Action<CutsceneBlock, int> write, int frame) : IFieldEditor
    {
        // The time when the drag began, while one is under way.
        int? _start;

        public bool Commit(int axis, string text)
        {
            if (!CutsceneFile.TryParseTicks(text.Trim(), out var ticks))
            {
                return false;
            }
            editor.EditSelected(label, b => write(b, ticks));
            return true;
        }

        public void BeginScrub(int axis)
        {
            _start = editor.Selected is { } block && read(block) is { } start && editor.BeginField(label) ? start : null;
        }

        public void Scrub(int axis, double pixels, KeyModifiers modifiers)
        {
            if (_start is not { } start)
            {
                return;
            }
            var frames = (long)Math.Round(pixels * ScrubSession.Scale(modifiers));
            var ticks = (int)Math.Clamp(start + frames * frame, 0, int.MaxValue);
            editor.StepField(b => write(b, ticks));
        }

        // Only a drag that this scrub began: one that another began, or that Esc cancelled, is not this one's to end.
        public void EndScrub()
        {
            if (_start == null)
            {
                return;
            }
            _start = null;
            editor.EndField(cancel: false);
        }
    }
}
