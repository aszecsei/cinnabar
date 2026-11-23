using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Cutscenes;

/// <summary>
/// The curve editor's toolbar, above its curves (see docs/editor/cutscene-editor.md#curves): the normalized view, and
/// what the curves do before their first key and after their last. It shows the editor's state and writes through its
/// methods, so it keeps no state of its own.
/// </summary>
public sealed class CutsceneCurveBar : StackPanel
{
    /// <summary>The infinity modes' labels, in <see cref="CurveInfinity"/>'s order.</summary>
    static readonly string[] InfinityLabels = ["Constant", "Linear", "Cycle", "Cycle with offset", "Oscillate"];

    readonly CutsceneEditor _editor;
    readonly ToggleButton _normalized = new() { Content = "Normalized", Classes = { "viewport-tool" }, FontSize = 11, Focusable = false };
    readonly ComboBox _pre = InfinityBox();
    readonly ComboBox _post = InfinityBox();
    // True while Show sets the controls, so their events do not write back what they show.
    bool _showing;

    public CutsceneCurveBar(CutsceneEditor editor)
    {
        _editor = editor;
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
        AddInfinity("Before", _pre, InfinitySide.Pre, "What the curves of the selected keys, or the shown curves, do before their first key (8)");
        AddInfinity("After", _post, InfinitySide.Post, "What the curves of the selected keys, or the shown curves, do after their last key (9)");
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

    void Show()
    {
        _showing = true;
        try
        {
            _normalized.IsChecked = _editor.CurvesNormalized;
            var curves = _editor.InfinityCurves.Count > 0;
            foreach (var (box, side) in (ReadOnlySpan<(ComboBox, InfinitySide)>)[(_pre, InfinitySide.Pre), (_post, InfinitySide.Post)])
            {
                box.IsEnabled = curves && !_editor.Document.InTransaction;
                box.SelectedIndex = _editor.Infinity(side) is { } mode ? (int)mode : -1;
            }
        }
        finally
        {
            _showing = false;
        }
    }
}
