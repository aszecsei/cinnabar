using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using static Cinnabar.Editor.Panels.Kit;

namespace Cinnabar.Editor.AnimationGraphs;

/// <summary>
/// While the game runs, what the selected entity's Animator plays and its parameters, as the game has them (see
/// docs/editor/animation-graph-editor.md#live-view). A change here goes to the game as a script's would, so it lasts until
/// something sets the parameter again.
/// </summary>
sealed class AnimatorLivePanel : StackPanel
{
    readonly AnimationGraphEditor _editor;
    readonly TextBlock _state = new() { FontSize = 12, TextWrapping = Avalonia.Media.TextWrapping.Wrap };
    readonly StackPanel _rows = new() { Spacing = 2 };
    // What updates each row with the game's value, by the parameter's name.
    readonly Dictionary<string, Action<float>> _updates = [];
    string _shown = "";

    public AnimatorLivePanel(AnimationGraphEditor editor)
    {
        _editor = editor;
        Spacing = 2;
        Children.Add(Heading("Live"));
        Children.Add(_state);
        Children.Add(_rows);
        new ViewSubscriptions(this, attached: Show).Add(() => _editor.LiveChanged += Show, () => _editor.LiveChanged -= Show);
    }

    void Show()
    {
        var live = _editor.Live;
        var waiting = _editor.LiveWaiting;
        IsVisible = live != null || waiting != null;
        if (live == null)
        {
            _state.Text = waiting;
            _rows.Children.Clear();
            _updates.Clear();
            _shown = "";
            return;
        }
        _state.Text = StateText(live);
        // The rows build again only for other parameters, so a slider keeps its drag as the values come.
        var shown = $"{live.Entity}|{string.Join(",", live.Parameters.Select(p => $"{p.Name}:{p.Kind}"))}";
        if (shown != _shown)
        {
            _shown = shown;
            _rows.Children.Clear();
            _updates.Clear();
            foreach (var p in live.Parameters)
            {
                _rows.Children.Add(Row(p.Name, ParameterControl(p)));
            }
        }
        foreach (var p in live.Parameters)
        {
            if (_updates.TryGetValue(p.Name, out var update))
            {
                update(p.Value);
            }
        }
    }

    string StateText(AnimatorView view)
    {
        var text = $"{_editor.Label((int)view.State)}, {view.Progress:0.00} plays";
        var fade = AnimationGraphEditor.FadeOf(view);
        if (fade < 1)
        {
            var from = view.Source != 0 ? _editor.Label((int)view.Source) : "an interrupted fade";
            text += $"\nfading from {from}, {fade:P0}";
        }
        if (view.Transition != 0)
        {
            text += $"\nlast took {_editor.Label((int)view.Transition)}";
        }
        return text;
    }

    Control ParameterControl(AnimatorParameter p) => p.Kind switch
    {
        AnimatorParameterKind.Bool => BoolControl(p.Name),
        AnimatorParameterKind.Trigger => TriggerControl(p.Name),
        _ => FloatControl(p.Name, p.Value),
    };

    Control BoolControl(string name)
    {
        var box = new CheckBox { FontSize = 12 };
        var updating = false;
        box.IsCheckedChanged += (_, _) =>
        {
            if (!updating)
            {
                _editor.SetLiveParameter(name, box.IsChecked == true ? 1 : 0);
            }
        };
        _updates[name] = value =>
        {
            updating = true;
            box.IsChecked = value != 0;
            updating = false;
        };
        return box;
    }

    Control TriggerControl(string name)
    {
        var button = SmallButton("Pull", "Set it for the next tick. A tick clears it, whether a transition took it or not.", () => _editor.SetLiveParameter(name, 1));
        button.HorizontalAlignment = HorizontalAlignment.Left;
        // A trigger that waits for a tick, as while paused.
        _updates[name] = value => button.Content = value != 0 ? "Pulled" : "Pull";
        return button;
    }

    Control FloatControl(string name, float start)
    {
        var (min, max) = _editor.RangeOf(name, start);
        var slider = new Slider { Minimum = min, Maximum = max, Value = start, VerticalAlignment = VerticalAlignment.Center };
        ToolTip.SetTip(slider, "It lasts until something sets it again, such as a script every tick.");
        var label = new TextBlock { FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Width = 40, TextAlignment = Avalonia.Media.TextAlignment.Right };
        var updating = false;
        var dragging = false;
        // The game's values come back while the slider is held, and would pull it from under the mouse.
        slider.AddHandler(PointerPressedEvent, (_, _) => dragging = true, RoutingStrategies.Tunnel, handledEventsToo: true);
        slider.AddHandler(PointerReleasedEvent, (_, _) => dragging = false, RoutingStrategies.Tunnel, handledEventsToo: true);
        slider.AddHandler(PointerCaptureLostEvent, (_, _) => dragging = false, RoutingStrategies.Bubble, handledEventsToo: true);
        slider.ValueChanged += (_, e) =>
        {
            if (!updating)
            {
                _editor.SetLiveParameter(name, (float)e.NewValue);
            }
        };
        _updates[name] = value =>
        {
            label.Text = value.ToString("0.00", System.Globalization.CultureInfo.InvariantCulture);
            if (dragging)
            {
                return;
            }
            updating = true;
            var (low, high) = _editor.RangeOf(name, value);
            (slider.Minimum, slider.Maximum) = (low, high);
            slider.Value = value;
            updating = false;
        };
        var line = new DockPanel();
        DockPanel.SetDock(label, Avalonia.Controls.Dock.Right);
        line.Children.Add(label);
        line.Children.Add(slider);
        return line;
    }
}
