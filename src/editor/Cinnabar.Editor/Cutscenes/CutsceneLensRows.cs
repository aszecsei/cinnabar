using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using static Cinnabar.Editor.Panels.Kit;

namespace Cinnabar.Editor.Cutscenes;

/// <summary>
/// The lens of a camera binding in the details strip (see docs/editor/cutscene-editor.md#lens): the focal length with
/// its field of view, the sensor, the focus, the aperture and the focus offset, each with a key button, Focus On, and
/// Pick Focus. The rows are built once for a binding and show new values in place, so a scrub keeps its handle while the
/// values that it sets change.
/// </summary>
sealed class CutsceneLensRows : StackPanel
{
    readonly CutsceneEditor _editor;
    readonly int _binding;
    readonly List<Action> _shows = [];

    // A number row's field, its label, its unit and how far a pixel of a scrub moves it.
    static readonly (string Field, string Label, string Unit, double Step)[] Numbers =
    [
        ("focal_length", "Focal length", "mm", 0.1),
        ("focus_distance", "Focus", "m", 0.01),
        ("aperture", "Aperture", "f/", 0.1),
        ("focus_offset", "Focus offset", "m", 0.01),
    ];

    public CutsceneLensRows(CutsceneEditor editor, int binding)
    {
        _editor = editor;
        _binding = binding;
        Spacing = 2;
        Children.Add(Heading("Lens"));
        if (editor.LensTargetOf(binding) is LensTarget.Refused refused)
        {
            Children.Add(Dim(refused.Why));
            return;
        }
        foreach (var (field, label, unit, step) in Numbers)
        {
            Children.Add(NumberRow(field, label, unit, step));
            if (field == "focal_length")
            {
                Children.Add(SensorRow());
            }
        }
        Children.Add(FocusOnRow());
        Children.Add(PickRow());
        var shell = editor.Shell;
        new ViewSubscriptions(this, attached: Show)
            .Add(() => editor.PlayheadChanged += Show, () => editor.PlayheadChanged -= Show)
            .Add(() => editor.LooksChanged += Show, () => editor.LooksChanged -= Show)
            .Add(() => shell.PreviewValues.Changed += Show, () => shell.PreviewValues.Changed -= Show)
            .Add(() => shell.Keying.Changed += Show, () => shell.Keying.Changed -= Show);
    }

    /// <summary>Shows the values, the key buttons and the focus at the playhead, in place.</summary>
    public void Show()
    {
        foreach (var show in _shows)
        {
            show();
        }
    }

    static string Format(double value) => value.ToString("0.###", CultureInfo.InvariantCulture);

    Control NumberRow(string field, string label, string unit, double step)
    {
        var box = new TextBox { Classes = { "value-edit" }, MinHeight = 20, PlaceholderText = unit };
        var shown = "";
        box.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter)
            {
                Commit();
                e.Handled = true;
            }
            else if (e.Key == Key.Escape)
            {
                box.Text = shown;
                e.Handled = true;
            }
        };
        box.LostFocus += (_, _) => Commit();
        void Commit()
        {
            var text = (box.Text ?? "").Trim();
            if (text == shown)
            {
                return;
            }
            if (!double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var value) || !double.IsFinite(value))
            {
                box.Text = shown;
                return;
            }
            Refuse(_editor.SetLens(_binding, [(field, value)], $"Set {label}"));
            Show();
        }
        var note = new TextBlock { Classes = { "empty" }, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 0, 0) };
        var value = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 0 };
        var holder = new Border { Classes = { "value-box", "editable" }, Child = box, MinWidth = 90 };
        value.Children.Add(holder);
        value.Children.Add(note);
        var key = SmallButton("◇", "", () => _editor.KeyLens(_binding, field));
        var menu = new ContextMenu();
        var showItems = FieldGrid.AddKeyItems(menu, new FieldKey(() => _editor.LensKey(_binding, field), () => _editor.KeyLens(_binding, field),
            () => _editor.AddLensTrack(_binding, field), () => _editor.RemoveLensKey(_binding, field),
            () => _editor.CanRemoveLensKey(_binding, field), () => _editor.GoToLensTrack(_binding, field)));
        key.ContextMenu = menu;
        var row = Row(label, value, key);
        var name = row.Children[0];
        name.ContextMenu = menu;
        name.Focusable = true;
        name.PointerPressed += (_, _) => name.Focus();
        ToolTip.SetTip(name, $"{field}. Drag to change it.");
        FieldView.Scrubbable(name, new LensScrub(this, field, label, step), 0);
        _shows.Add(() =>
        {
            showItems();
            FieldGrid.ShowKey(key, _editor.LensKey(_binding, field));
            var raw = _editor.LensValue(_binding, field);
            if (!box.IsFocused)
            {
                shown = raw is { } v ? Format(v) : "";
                box.Text = shown;
            }
            note.Text = field switch
            {
                "focal_length" when raw is { } f => $"{Format(Math.Round(Tools.Lens.VerticalFov(f, _editor.LensValue(_binding, "sensor_height") ?? 0) * 180 / Math.PI, 1))}° vertical"
                    + (f <= 0 ? $" (0 is {Format(Tools.Lens.DefaultFocalLength)} mm)" : ""),
                "focus_distance" when _editor.FocusedOn(_binding) is { } on => $"Focus On {NameOf(on)} sets it",
                "focus_distance" when raw is <= 0 => $"0 is {Format(Tools.Lens.DefaultFocusDistance)} m",
                "aperture" when raw is <= 0 => "0 is no depth of field",
                "focus_offset" when _editor.FocusedOn(_binding) == null => "with Focus On",
                _ => "",
            };
        });
        return row;
    }

    Control SensorRow()
    {
        var names = CinematicCameraText.SensorPresets.Select(p => p.Name).ToList();
        var choice = new ComboBox { ItemsSource = names, Classes = { "value-choice" }, HorizontalAlignment = HorizontalAlignment.Stretch };
        var showing = false;
        choice.SelectionChanged += (_, _) =>
        {
            if (showing || choice.SelectedItem is not string name || CinematicCameraText.SensorPresets.FirstOrDefault(p => p.Name == name) is not { Name: not null } preset)
            {
                return;
            }
            Refuse(_editor.SetLens(_binding, [("sensor_width", preset.Width), ("sensor_height", preset.Height)], "Set Sensor"));
            Show();
        };
        var size = new TextBlock { Classes = { "empty" }, FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
        _shows.Add(() =>
        {
            var width = CutsceneEditor.EffectiveLens("sensor_width", _editor.LensValue(_binding, "sensor_width") ?? 0);
            var height = CutsceneEditor.EffectiveLens("sensor_height", _editor.LensValue(_binding, "sensor_height") ?? 0);
            showing = true;
            choice.SelectedItem = CinematicCameraText.SensorName(width, height);
            showing = false;
            size.Text = $"{Format(width)} × {Format(height)} mm";
        });
        return Row("Sensor", choice, size);
    }

    Control FocusOnRow()
    {
        const string none = "None";
        List<(int? Id, string Name)> Options() =>
            [(null, none), .. _editor.File.Bindings.Where(b => b.Id is { } id && id != _binding).Select(b => ((int?)b.Id, b.Name ?? $"Binding {b.Id}"))];
        var choice = new ComboBox { Classes = { "value-choice" }, HorizontalAlignment = HorizontalAlignment.Stretch };
        var showing = false;
        choice.SelectionChanged += (_, _) =>
        {
            if (showing || choice.SelectedIndex < 0)
            {
                return;
            }
            var options = Options();
            if (choice.SelectedIndex < options.Count)
            {
                _editor.SetFocusOn(_binding, options[choice.SelectedIndex].Id);
            }
        };
        ToolTip.SetTip(choice, "Keep the focus on a binding's entity: the focus is its distance along the camera's axis, plus the focus offset.");
        _shows.Add(() =>
        {
            var options = Options();
            showing = true;
            choice.ItemsSource = options.Select(o => o.Name).ToList();
            choice.SelectedIndex = options.FindIndex(o => o.Id == _editor.FocusOn(_binding));
            showing = false;
        });
        return Row("Focus On", choice);
    }

    Control PickRow()
    {
        var pick = SmallButton("Pick Focus", "", () => Refuse(_editor.ArmFocusPick(_binding)));
        pick.HorizontalAlignment = HorizontalAlignment.Left;
        var why = new TextBlock { Classes = { "empty" }, FontSize = 12, TextWrapping = Avalonia.Media.TextWrapping.Wrap };
        _shows.Add(() =>
        {
            var armed = _editor.FocusArmed == _binding;
            pick.Content = armed ? "Cancel Pick" : "Pick Focus";
            ToolTip.SetTip(pick, armed
                ? "Click in the view that looks through the camera to set the focus there. Esc cancels."
                : "Set the focus distance to the depth of what the next click hits in a view that looks through the camera. Ctrl+click there does it at once.");
            var refusal = _editor.FocusedOn(_binding) is { } on ? $"Focus On {NameOf(on)} sets the focus." : null;
            pick.IsEnabled = armed || refusal == null;
            why.Text = armed ? "Click in the view that looks through the camera." : refusal ?? "";
            why.IsVisible = why.Text.Length > 0;
        });
        var panel = new StackPanel { Spacing = 2 };
        panel.Children.Add(Row("", pick));
        panel.Children.Add(why);
        return panel;
    }

    string NameOf(int binding) => _editor.File.Bindings.FirstOrDefault(b => b.Id == binding)?.Name ?? $"binding {binding}";

    void Refuse(string? why)
    {
        if (why != null)
        {
            _editor.Shell.Console.Add(Model.LogLevel.Warning, $"lens: {why}");
        }
    }

    // A drag on a lens field's name: a step a pixel, ten with Shift and a tenth with Ctrl, as one undo entry with
    // auto-key, and Esc cancels it.
    sealed class LensScrub(CutsceneLensRows rows, string field, string label, double step) : IFieldEditor
    {
        (ILensDrag Drag, double Start)? _open;

        public bool Commit(int axis, string text) => false;

        public void BeginScrub(int axis)
        {
            var editor = rows._editor;
            if (editor.LensValue(rows._binding, field) is not { } start)
            {
                return;
            }
            if (editor.BeginLensDrag(rows._binding, field, $"Drag {label}", out var why) is not { } drag)
            {
                rows.Refuse(why);
                return;
            }
            _open = (drag, start);
        }

        public void Scrub(int axis, double pixels, KeyModifiers modifiers)
        {
            if (_open is not var (drag, start))
            {
                return;
            }
            var value = Math.Round(start + pixels * step * ScrubSession.Scale(modifiers), 4);
            if (field is "focal_length" or "focus_distance" or "aperture")
            {
                value = Math.Max(value, 0);
            }
            drag.Step(value);
            rows.Show();
        }

        public void EndScrub()
        {
            if (_open is not var (drag, _))
            {
                return;
            }
            _open = null;
            drag.End(cancel: false);
            rows.Show();
        }
    }
}
