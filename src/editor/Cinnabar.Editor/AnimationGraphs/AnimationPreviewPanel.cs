using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using static Cinnabar.Editor.Panels.Kit;

namespace Cinnabar.Editor.AnimationGraphs;

/// <summary>
/// Under the preview (see docs/editor/animation-graph-editor.md#preview): the mesh that it shows, what it plays and its
/// parameters, which change nothing in the game. While the game runs, what the selected entity's Animator plays too
/// (see docs/editor/animation-graph-editor.md#live-view).
/// </summary>
sealed class AnimationPreviewPanel : StackPanel
{
    readonly EditorShell _shell;
    readonly AnimationGraphEditor _editor;
    readonly StackPanel _meshRow = new();
    readonly TextBlock _state = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap };
    readonly StackPanel _rows = new() { Spacing = 2 };
    readonly TextBlock _gameHeading = Heading("In the game");
    readonly TextBlock _game = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap };
    // What updates each row with the preview's value, by the parameter's name.
    readonly Dictionary<string, Action<float>> _updates = [];
    string _shownMeshes = "";
    string _shownRows = "";

    public AnimationPreviewPanel(EditorShell shell, AnimationGraphEditor editor)
    {
        _shell = shell;
        _editor = editor;
        Spacing = 2;
        var restart = SmallButton("Restart", "Start again in the entry state, with the parameters at their defaults.", editor.RestartPreview);
        var heading = new DockPanel();
        DockPanel.SetDock(restart, Avalonia.Controls.Dock.Right);
        heading.Children.Add(restart);
        heading.Children.Add(Heading("Preview"));
        Children.Add(heading);
        Children.Add(_meshRow);
        Children.Add(_state);
        Children.Add(_rows);
        Children.Add(_gameHeading);
        Children.Add(_game);
        new ViewSubscriptions(this, attached: Show)
            .Add(() => _editor.LiveChanged += Show, () => _editor.LiveChanged -= Show)
            .Add(() => _shell.Assets.Changed += Show, () => _shell.Assets.Changed -= Show);
    }

    void Show()
    {
        ShowMeshes();
        ShowPreview();
        var live = _editor.Live;
        var waiting = _editor.LiveWaiting;
        _gameHeading.IsVisible = _game.IsVisible = live != null || waiting != null;
        _game.Text = live != null ? StateText(live) : waiting;
    }

    void ShowMeshes()
    {
        var meshes = _editor.MeshChoices;
        var current = _editor.MeshGuid;
        var shown = $"{current}|{string.Join(",", meshes.Select(m => m.Guid))}";
        if (shown == _shownMeshes)
        {
            return;
        }
        _shownMeshes = shown;
        var names = meshes.Select(AnimationGraphEditor.MeshName).ToList();
        var selected = meshes.ToList().FindIndex(m => m.Guid == current);
        _meshRow.Children.Clear();
        _meshRow.Children.Add(Row("Mesh", Choice(names, selected >= 0 ? names[selected] : null, picked => _editor.SetPreviewMesh(meshes[names.IndexOf(picked)].Guid))));
    }

    void ShowPreview()
    {
        var view = _editor.PreviewView;
        if (view == null)
        {
            _state.Text = _editor.PreviewId == null ? "Every preview is in use." : "It plays once the graph, its clips and a mesh have loaded.";
            _rows.Children.Clear();
            _updates.Clear();
            _shownRows = "";
            return;
        }
        _state.Text = StateText(view);
        // The rows build again only for other parameters, so a slider keeps its drag as the values come.
        var shown = string.Join(",", view.Parameters.Select(p => $"{p.Name}:{p.Kind}"));
        if (shown != _shownRows)
        {
            _shownRows = shown;
            _rows.Children.Clear();
            _updates.Clear();
            foreach (var p in view.Parameters)
            {
                _rows.Children.Add(Row(p.Name, ParameterControl(p)));
            }
        }
        foreach (var p in view.Parameters)
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
                _editor.SetPreviewParameter(name, box.IsChecked == true ? 1 : 0);
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
        var button = SmallButton("Pull", "Set it for the next tick. A tick clears it, whether a transition took it or not.", () => _editor.SetPreviewParameter(name, 1));
        button.HorizontalAlignment = HorizontalAlignment.Left;
        return button;
    }

    Control FloatControl(string name, float start)
    {
        var (min, max) = _editor.RangeOf(name, start);
        var slider = new Slider { Minimum = min, Maximum = max, Value = start, VerticalAlignment = VerticalAlignment.Center };
        var label = new TextBlock { FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Width = 40, TextAlignment = TextAlignment.Right };
        var updating = false;
        var dragging = false;
        // The preview's values come back while the slider is held, and would pull it from under the mouse.
        slider.AddHandler(PointerPressedEvent, (_, _) => dragging = true, RoutingStrategies.Tunnel, handledEventsToo: true);
        slider.AddHandler(PointerReleasedEvent, (_, _) => dragging = false, RoutingStrategies.Tunnel, handledEventsToo: true);
        slider.AddHandler(PointerCaptureLostEvent, (_, _) => dragging = false, RoutingStrategies.Bubble, handledEventsToo: true);
        slider.ValueChanged += (_, e) =>
        {
            if (!updating)
            {
                _editor.SetPreviewParameter(name, (float)e.NewValue);
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
