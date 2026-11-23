using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Cutscenes;

/// <summary>
/// The curve editor's toolbar, above its curves (see docs/editor/cutscene-editor.md#curves): the normalized view, what
/// the curves do before their first key and after their last, and the selected keys' time and value, which take typed
/// entries. It shows the editor's state and writes through its methods, so it keeps no state of its own but a box's text
/// while it is typed in.
/// </summary>
public sealed class CutsceneCurveBar : StackPanel
{
    /// <summary>The infinity modes' labels, in <see cref="CurveInfinity"/>'s order.</summary>
    static readonly string[] InfinityLabels = ["Constant", "Linear", "Cycle", "Cycle with offset", "Oscillate"];

    readonly CutsceneEditor _editor;
    readonly ToggleButton _normalized = new() { Content = "Normalized", Classes = { "viewport-tool" }, FontSize = 11, Focusable = false };
    readonly ToggleButton _valueSnap = new() { Content = "Value snap", Classes = { "viewport-tool" }, FontSize = 11, Focusable = false };
    readonly ComboBox _pre = InfinityBox();
    readonly ComboBox _post = InfinityBox();
    readonly TextBox _time = EntryBox(110);
    readonly TextBox _value = EntryBox(90);
    readonly Action _refocus;
    // True while Show sets the controls, so their events do not write back what they show.
    bool _showing;

    /// <summary>The bar of an editor's curve editor; refocus gives the keyboard back to the curves after a typed entry.</summary>
    public CutsceneCurveBar(CutsceneEditor editor, Action refocus)
    {
        _editor = editor;
        _refocus = refocus;
        Orientation = Orientation.Horizontal;
        Margin = new Thickness(8, 2);
        Spacing = 4;
        ToolTip.SetTip(_normalized, "Scale each curve to -1 to 1, to compare curves of different sizes. The keys keep their values (Alt+N).");
        _normalized.IsCheckedChanged += (_, _) =>
        {
            if (!_showing)
            {
                editor.CurvesNormalized = _normalized.IsChecked == true;
            }
        };
        Children.Add(_normalized);
        ToolTip.SetTip(_valueSnap, "Snap a dragged key's value to the grid's lines. Ctrl during the drag does not snap (Alt+V).");
        _valueSnap.IsCheckedChanged += (_, _) =>
        {
            if (!_showing)
            {
                editor.ValueSnap = _valueSnap.IsChecked == true;
            }
        };
        Children.Add(_valueSnap);
        AddInfinity("Before", _pre, InfinitySide.Pre, "What the curves of the selected keys, or the shown curves, do before their first key (8)");
        AddInfinity("After", _post, InfinitySide.Post, "What the curves of the selected keys, or the shown curves, do after their last key (9)");
        AddEntry("Time", _time, "The selected keys' time. Type timecode or frames, or += or -= one, and press Enter.", editor.SetCurveKeyTime);
        AddEntry("Value", _value, "The selected keys' value. Type a number, or += or -= one, and press Enter.", editor.SetCurveKeyValue);
        new ViewSubscriptions(this, attached: Show).Add(() => _editor.Changed += Show, () => _editor.Changed -= Show);
    }

    static ComboBox InfinityBox()
    {
        var box = new ComboBox { FontSize = 11, Focusable = false, VerticalAlignment = VerticalAlignment.Center, MinWidth = 110 };
        foreach (var label in InfinityLabels)
        {
            box.Items.Add(new ComboBoxItem { Content = label });
        }
        return box;
    }

    void AddInfinity(string label, ComboBox box, InfinitySide side, string tip)
    {
        Children.Add(new TextBlock { Text = label, FontSize = 11, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) });
        ToolTip.SetTip(box, tip);
        box.SelectionChanged += (_, _) =>
        {
            if (!_showing && box.SelectedIndex >= 0)
            {
                _editor.SetInfinity(side, (CurveInfinity)box.SelectedIndex);
                // A curve that does not take the mode keeps its own, so show what the curves have now.
                Show();
            }
        };
        Children.Add(box);
    }

    static TextBox EntryBox(double width) => new()
    {
        Classes = { "value-edit" },
        FontSize = 11,
        MinWidth = width,
        FontFamily = new FontFamily("Consolas, monospace"),
        VerticalAlignment = VerticalAlignment.Center,
    };

    // A box that takes a typed entry: Enter sets it and gives the keyboard back to the curves, Esc puts back what the
    // keys have, and leaving the box puts it back too. An entry with a problem stays, with the problem as its tip.
    void AddEntry(string label, TextBox box, string tip, Func<string, string?> set)
    {
        Children.Add(new TextBlock { Text = label, FontSize = 11, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) });
        ToolTip.SetTip(box, tip);
        box.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter)
            {
                e.Handled = true;
                if (set(box.Text ?? "") is { } problem)
                {
                    ToolTip.SetTip(box, problem);
                    ToolTip.SetIsOpen(box, true);
                    return;
                }
                ToolTip.SetTip(box, tip);
                _refocus();
                Show();
            }
            else if (e.Key == Key.Escape)
            {
                e.Handled = true;
                ToolTip.SetTip(box, tip);
                _refocus();
                Show();
            }
        };
        box.LostFocus += (_, _) =>
        {
            ToolTip.SetTip(box, tip);
            Show();
        };
        Children.Add(new Border { Classes = { "value-box", "editable" }, Child = box, VerticalAlignment = VerticalAlignment.Center });
    }

    void Show()
    {
        _showing = true;
        try
        {
            _normalized.IsChecked = _editor.CurvesNormalized;
            _valueSnap.IsChecked = _editor.ValueSnap;
            var curves = _editor.InfinityCurves.Count > 0;
            foreach (var (box, side) in (ReadOnlySpan<(ComboBox, InfinitySide)>)[(_pre, InfinitySide.Pre), (_post, InfinitySide.Post)])
            {
                box.IsEnabled = curves && !_editor.Document.InTransaction;
                box.SelectedIndex = _editor.Infinity(side) is { } mode ? (int)mode : -1;
            }
            // A box that is being typed in keeps its text.
            var keys = _editor.CurveKeys.Count > 0 && !_editor.Document.InTransaction;
            if (!_time.IsFocused)
            {
                _time.IsEnabled = keys;
                _time.Text = _editor.CurveKeyTime is { } t ? (_editor.ShowFrames ? $"{CutsceneTime.Frames(t, _editor.File.Rate)}f" : CutsceneTime.Timecode(t, _editor.File.Rate)) : "";
                _time.PlaceholderText = keys ? "—" : "";
            }
            if (!_value.IsFocused)
            {
                _value.IsEnabled = keys;
                _value.Text = _editor.CurveKeyValue is { } v ? CutsceneKeying.Format(v) : "";
                _value.PlaceholderText = keys ? "—" : "";
            }
        }
        finally
        {
            _showing = false;
        }
    }
}
