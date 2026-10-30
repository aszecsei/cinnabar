using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using CommunityToolkit.Mvvm.Input;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Panels;

/// <summary>A field's row in a <see cref="FieldGrid"/>: its name, how it shows, and the editor that sets it, if any.</summary>
sealed record FieldRow(string Owner, string Field, DisplayKind Kind, bool IsEnum, FieldEditor? Editor, Func<bool>? IsSet, Action Reset)
{
    /// <summary>For an instance's entity, whether its block overrides the field, which shows it in bold.</summary>
    public Func<bool>? Overridden { get; init; }

    /// <summary>For an instance's entity, applies the field's override to its prefab.</summary>
    public Action? Apply { get; init; }

    /// <summary>For an asset field, the kind of asset that it takes ("" for any).</summary>
    public string AssetKind { get; init; } = "";

    /// <summary>For an Axes field, its number of boxes.</summary>
    public int Axes { get; init; } = 3;

    /// <summary>For a number, the range of its slider, from the game's editor:"range=min,max" tag.</summary>
    public (double Min, double Max)? Range { get; init; }

    /// <summary>A volume's setting: a check box before its name says whether the volume overrides it.</summary>
    public bool HasOverride { get; init; }

    /// <summary>The name that the row shows, the field's own humanized by default.</summary>
    public string? Label { get; init; }

    /// <summary>A component field's row, with what its field info says of how it shows.</summary>
    public static FieldRow Of(string owner, Link.Protocol.FieldInfo f, FieldEditor? editor, Func<bool>? isSet, Action reset) =>
        new(owner, f.Name, FieldValues.DisplayKindOf(f), f.Kind == Link.Protocol.FieldKind.Enum, editor, isSet, reset)
        {
            AssetKind = f.AssetKind,
            Axes = f.Kind == Link.Protocol.FieldKind.Vector2 ? 2 : 3,
            Range = f.HasRange ? (f.RangeMin, f.RangeMax) : null,
            HasOverride = f.HasOverride,
        };
}

/// <summary>
/// The rows of fields that the properties and atmosphere panels show (see docs/editor/shell-and-panels.md#properties):
/// each field's name, which a number's drag scrubs, its view, a volume setting's override check box, and a reset
/// button while the scene sets it. It keeps each row's view and editor by owner and field, so new values show in place.
/// </summary>
sealed class FieldGrid(EditorShell shell)
{
    readonly Dictionary<(string Owner, string Field), OverrideRow> _overrides = [];
    // Each reset button, with whether its field is set in the document, which edits change without a rebuild.
    readonly List<(Control Button, Func<bool> IsSet)> _resets = [];
    // Each field name of an instance's entity, with whether its block overrides the field, which shows it in bold.
    readonly List<(TextBlock Name, Func<bool> IsOverridden)> _bold = [];

    /// <summary>The view and the editor of each row, by its owner, such as a component's ID, and its field's name.</summary>
    public Dictionary<(string Owner, string Field), FieldView> Views { get; } = [];

    public Dictionary<(string Owner, string Field), FieldEditor> Editors { get; } = [];

    public void Clear()
    {
        Views.Clear();
        Editors.Clear();
        _resets.Clear();
        _bold.Clear();
        _overrides.Clear();
    }

    /// <summary>Shows again what the document sets: each reset button, and each name that an instance overrides.</summary>
    public void ShowDocument()
    {
        foreach (var (button, isSet) in _resets)
        {
            button.IsVisible = isSet();
        }
        foreach (var (name, overridden) in _bold)
        {
            name.FontWeight = overridden() ? FontWeight.Bold : FontWeight.Normal;
        }
    }

    string Label(ulong entity) => shell.World.Find(entity)?.Label ?? EntityNode.Format(entity);

    /// <summary>A grid of rows, one for each field.</summary>
    public Grid Rows(IEnumerable<FieldRow> fields)
    {
        var rows = new FieldRows("Auto,*,Auto");
        foreach (var field in fields)
        {
            var name = new TextBlock
            {
                Text = field.Label ?? FieldValues.Humanize(field.Field),
                Classes = { "field-name" },
                TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center,
            };
            ToolTip.SetTip(name, field.Editor != null && field.Kind == DisplayKind.Number ? $"{field.Field}. Drag to change it." : field.Field);
            if (field.Editor != null && field.Kind == DisplayKind.Number)
            {
                FieldView.Scrubbable(name, field.Editor, 0);
            }
            var view = FieldView.Create(field.Kind, shell.Selection.Select, Label, field.Editor, field.IsEnum, new AssetContext(shell.Assets, field.AssetKind, shell.RevealAsset), field.Axes, field.Range);
            Control label = name;
            if (field.Overridden is { } overridden)
            {
                name.FontWeight = overridden() ? FontWeight.Bold : FontWeight.Normal;
                _bold.Add((name, overridden));
                // An override's menu carries it to the prefab, or drops it.
                var apply = new MenuItem { Header = "Apply to Prefab", Command = new RelayCommand(() => field.Apply?.Invoke()) };
                var revert = new MenuItem { Header = "Revert", Command = new RelayCommand(field.Reset) };
                var menu = new ContextMenu { Items = { apply, revert } };
                menu.Opening += (_, _) => apply.IsEnabled = revert.IsEnabled = overridden();
                name.ContextMenu = menu;
            }
            if (field.HasOverride)
            {
                label = OverrideLabel(field, name, view);
            }
            Button? reset = null;
            if (field.IsSet != null)
            {
                reset = Kit.SmallButton("↺", field.Overridden != null ? "Revert to the prefab's value" : "Reset to the default", field.Reset);
                reset.IsVisible = field.IsSet();
                _resets.Add((reset, field.IsSet));
            }
            rows.Add(label, view.Control, reset);
            Views[(field.Owner, field.Field)] = view;
            if (field.Editor != null)
            {
                Editors[(field.Owner, field.Field)] = field.Editor;
            }
        }
        return rows.Grid;
    }

    /// <summary>Shows a component's values from the host in the rows of an owner, and gives their editors the values.</summary>
    public void ShowComponent(string owner, Link.Protocol.ComponentType type, byte[] data, Func<ulong, ulong> sceneIdOf)
    {
        foreach (var field in type.Fields)
        {
            if (Editors.TryGetValue((owner, field.Name), out var editor))
            {
                editor.Current = FieldEditor.Read(field, data, sceneIdOf);
            }
            if (Views.TryGetValue((owner, field.Name), out var view))
            {
                view.Show(FieldValues.Display(field, data));
            }
            if (field.HasOverride && field.OverrideOffset < data.Length)
            {
                ShowOverride((owner, field.Name), data[(int)field.OverrideOffset] != 0);
            }
        }
    }

    // A volume's setting: a check box before its name, ticked when the volume overrides it. Ticking it overrides with the
    // value that shows, and clearing it leaves the setting to the volumes below it but keeps the value, so the two can be
    // compared. A setting that is not overridden is dim, and the reset button sets it back to its default.
    Control OverrideLabel(FieldRow field, TextBlock name, FieldView view)
    {
        var check = new CheckBox { MinHeight = 0, Padding = new Thickness(0), Classes = { "value-check" }, VerticalAlignment = VerticalAlignment.Center };
        check.IsHitTestVisible = check.Focusable = field.Editor != null;
        ToolTip.SetTip(check, "Override: the volume sets this, over the volumes below it");
        var entry = new OverrideRow(check, view.Control);
        check.IsCheckedChanged += (_, _) =>
        {
            if (entry.Showing || field.Editor == null)
            {
                return;
            }
            if (check.IsChecked == true)
            {
                field.Editor.Override();
            }
            else
            {
                field.Editor.StopOverriding();
            }
        };
        _overrides[(field.Owner, field.Field)] = entry;
        return new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Children = { check, name } };
    }

    /// <summary>Shows whether a volume overrides a setting: null when the selected entities differ.</summary>
    public void ShowOverride((string Owner, string Field) key, bool? overridden)
    {
        if (!_overrides.TryGetValue(key, out var entry))
        {
            return;
        }
        entry.Showing = true;
        entry.Check.IsChecked = overridden;
        entry.Showing = false;
        entry.Value.Opacity = overridden == false ? 0.5 : 1;
    }

    sealed class OverrideRow(CheckBox check, Control value)
    {
        public CheckBox Check { get; } = check;
        public Control Value { get; } = value;
        public bool Showing { get; set; }
    }
}
