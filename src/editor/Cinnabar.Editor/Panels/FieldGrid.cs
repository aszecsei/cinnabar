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

    /// <summary>For a field of a bound entity, its key button and menu (see docs/editor/cutscene-editor.md#keying).</summary>
    public FieldKey? Key { get; init; }

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
/// A field's key button and its menu's actions: its state at the playhead, or null when it has none now, and keying the
/// field, adding its track, removing its keys at the playhead and showing its track.
/// </summary>
sealed record FieldKey(Func<KeyButton?> State, Action Key, Action AddTrack, Action RemoveKey, Func<bool> CanRemoveKey, Action GoToTrack);

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
    // Each field name, with its tooltip, which a mark for an override's hold adds to.
    readonly Dictionary<(string Owner, string Field), (TextBlock Name, string Tip)> _names = [];
    // Each key button, with its field's key, which the playhead and the cutscene change without a rebuild.
    readonly Dictionary<(string Owner, string Field), (Button Button, FieldKey Key, Action ShowItems)> _keys = [];

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
        _names.Clear();
        _keys.Clear();
    }

    static readonly string[] KeyClasses = ["key-none", "key-track", "key-keyed", "key-differs"];

    /// <summary>The key button of each field that has one, by its owner and its field's name.</summary>
    public IEnumerable<KeyValuePair<(string Owner, string Field), Button>> KeyButtons =>
        _keys.Select(k => KeyValuePair.Create(k.Key, k.Value.Button));

    /// <summary>Shows each key button's state at the playhead: hidden with none, its look, its tooltip, and whether it keys now.</summary>
    public void ShowKeys()
    {
        foreach (var (button, key, showItems) in _keys.Values)
        {
            showItems();
            var state = key.State();
            button.IsVisible = state != null;
            if (state == null)
            {
                continue;
            }
            var name = KeyClasses[(int)state.State];
            foreach (var c in KeyClasses)
            {
                button.Classes.Set(c, c == name);
            }
            button.Content = state.State is Document.KeyState.Keyed or Document.KeyState.Differs ? "\u25C6" : "\u25C7";
            button.IsEnabled = state.Refusal == null;
            ToolTip.SetTip(button, state.Tip);
        }
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
            var tip = field.Editor != null && field.Kind == DisplayKind.Number ? $"{field.Field}. Drag to change it." : field.Field;
            ToolTip.SetTip(name, tip);
            _names[(field.Owner, field.Field)] = (name, tip);
            if (field.Editor != null && field.Kind == DisplayKind.Number)
            {
                FieldView.Scrubbable(name, field.Editor, 0);
            }
            var view = FieldView.Create(field.Kind, shell.Selection.Select, Label, field.Editor, field.IsEnum, new AssetContext(shell.Assets, field.AssetKind, shell.Content.RevealAsset), field.Axes, field.Range);
            Control label = name;
            ContextMenu? menu = null;
            if (field.Overridden is { } overridden)
            {
                name.FontWeight = overridden() ? FontWeight.Bold : FontWeight.Normal;
                _bold.Add((name, overridden));
                // An override's menu carries it to the prefab, or drops it.
                var apply = new MenuItem { Header = "Apply to Prefab", Command = new RelayCommand(() => field.Apply?.Invoke()) };
                var revert = new MenuItem { Header = "Revert", Command = new RelayCommand(field.Reset) };
                menu = new ContextMenu { Items = { apply, revert } };
                menu.Opening += (_, _) => apply.IsEnabled = revert.IsEnabled = overridden();
                name.ContextMenu = menu;
            }
            Button? keyButton = null;
            if (field.Key is { } key)
            {
                keyButton = Kit.SmallButton("\u25C7", "", key.Key);
                menu ??= new ContextMenu();
                _keys[(field.Owner, field.Field)] = (keyButton, key, AddKeyItems(menu, key));
                name.ContextMenu = menu;
                keyButton.ContextMenu = menu;
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
            rows.Add(label, view.Control, keyButton == null ? reset : Pair(keyButton, reset));
            Views[(field.Owner, field.Field)] = view;
            if (field.Editor != null)
            {
                Editors[(field.Owner, field.Field)] = field.Editor;
            }
        }
        return rows.Grid;
    }

    // The reset button and the key button after a field, in one cell.
    static StackPanel Pair(Button key, Button? reset)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        if (reset != null)
        {
            panel.Children.Add(reset);
        }
        panel.Children.Add(key);
        return panel;
    }

    // A key's items at the end of a field's menu, each enabled as the field's state at the playhead lets it.
    static Action AddKeyItems(ContextMenu menu, FieldKey key)
    {
        var addTrack = new MenuItem { Header = "Add Track", Command = new RelayCommand(key.AddTrack) };
        var keyItem = new MenuItem { Header = "Key", Command = new RelayCommand(key.Key) };
        var removeKey = new MenuItem { Header = "Remove Key", Command = new RelayCommand(key.RemoveKey) };
        var goToTrack = new MenuItem { Header = "Go to Track", Command = new RelayCommand(key.GoToTrack) };
        var separator = new Separator();
        if (menu.Items.Count > 0)
        {
            menu.Items.Add(separator);
        }
        foreach (var item in new[] { addTrack, keyItem, removeKey, goToTrack })
        {
            menu.Items.Add(item);
        }
        void Show() => ShowKeyItems(key, separator, addTrack, keyItem, removeKey, goToTrack);
        menu.Opening += (_, _) => Show();
        return Show;
    }

    // Shows a key's menu items as the field's state lets them act: hidden with no state, and each enabled when it can act.
    static void ShowKeyItems(FieldKey key, Control separator, MenuItem addTrack, MenuItem keyItem, MenuItem removeKey, MenuItem goToTrack)
    {
        var state = key.State();
        foreach (var item in new Control[] { separator, addTrack, keyItem, removeKey, goToTrack })
        {
            item.IsVisible = state != null;
        }
        if (state == null)
        {
            return;
        }
        addTrack.IsEnabled = state.State == Document.KeyState.None && state.Refusal == null;
        keyItem.IsEnabled = state.Refusal == null;
        removeKey.IsEnabled = key.CanRemoveKey();
        goToTrack.IsEnabled = state.State != Document.KeyState.None;
    }

    /// <summary>
    /// Marks the fields of an owner that an override holds in the game's world (see docs/editor/link.md#overrides). Their
    /// rows show the document's value, and the world shows another.
    /// </summary>
    public void ShowHeld(string owner, Link.Protocol.ComponentType type, Func<Link.Protocol.FieldInfo, bool> isHeld)
    {
        foreach (var field in type.Fields)
        {
            if (_names.TryGetValue((owner, field.Name), out var name))
            {
                var held = isHeld(field);
                name.Name.Classes.Set("held", held);
                ToolTip.SetTip(name.Name, held ? $"{name.Tip}\nA preview holds this field in the world, which shows another value. This is the scene's." : name.Tip);
            }
        }
    }

    /// <summary>Shows a component's values from the host in the rows of an owner, and gives their editors the values.</summary>
    public void ShowComponent(string owner, Link.Protocol.ComponentType type, byte[] data, Func<ulong, Document.SceneValue> referenceOf)
    {
        foreach (var field in type.Fields)
        {
            if (Editors.TryGetValue((owner, field.Name), out var editor))
            {
                editor.Current = FieldEditor.Read(field, data, referenceOf);
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
