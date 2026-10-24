using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// What a field's view does when the user edits it. The properties panel makes one for each field that the document
/// can change, turns each edit into an operation, and keeps the views read-only otherwise.
/// </summary>
interface IFieldEditor
{
    /// <summary>Text typed into a box: the whole value, or one of the three axes. False when it does not parse.</summary>
    bool Commit(int axis, string text);

    void SetFlag(bool value);

    /// <summary>An entity reference, by handle, or 0 for none.</summary>
    void SetEntity(ulong handle);

    /// <summary>An enum's names, as the panel shows them, for a choice.</summary>
    IReadOnlyList<string> Options { get; }

    void Choose(string option);

    /// <summary>A drag on a field's name or an axis marker: one undo entry from begin to end.</summary>
    void BeginScrub(int axis);

    /// <summary>The drag has moved this far from where it started, in pixels, with Shift for coarse and Ctrl for fine.</summary>
    void Scrub(int axis, double pixels, KeyModifiers modifiers);

    void EndScrub();
}

/// <summary>
/// Shows one field's value in the properties panel, and with an editor, edits it. The panel picks a view by the
/// field's <see cref="DisplayKind"/>, which never changes, and calls <see cref="Show"/> with each new value. A box
/// that has focus keeps what the user types until it commits, whatever the host sends meanwhile.
/// </summary>
abstract class FieldView
{
    public abstract Control Control { get; }

    public abstract void Show(FieldDisplay value);

    /// <summary>A view for a kind of value. An entity shows as its <paramref name="label"/>, such as its name.</summary>
    public static FieldView Create(DisplayKind kind, Action<ulong> select, Func<ulong, string> label, IFieldEditor? editor, bool isEnum = false) => kind switch
    {
        DisplayKind.Axes => new AxesView(editor),
        DisplayKind.Bool => new BoolView(editor),
        DisplayKind.Entity => new EntityView(select, label, editor),
        DisplayKind.Text when isEnum && editor != null => new ChoiceView(editor),
        DisplayKind.Number => new BoxView(numeric: true, editor),
        _ => new BoxView(numeric: false, editor),
    };

    protected static void SetTooltip(Control control, string? tooltip) => ToolTip.SetTip(control, tooltip);

    /// <summary>A box that edits on Enter or when it loses focus, and puts the value back on Escape.</summary>
    protected static TextBox EditBox(bool numeric, Func<string, bool> commit, Func<string> current)
    {
        var box = new TextBox
        {
            Classes = { "value-edit" },
            TextAlignment = numeric ? TextAlignment.Right : TextAlignment.Left,
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        void Commit()
        {
            if (box.Text is { } text && text != current() && !commit(text))
            {
                box.Text = current();
            }
        }
        box.KeyDown += (_, e) =>
        {
            switch (e.Key)
            {
                case Key.Enter:
                    Commit();
                    e.Handled = true;
                    break;
                case Key.Escape:
                    box.Text = current();
                    e.Handled = true;
                    break;
            }
        };
        box.LostFocus += (_, _) => Commit();
        return box;
    }

    /// <summary>Makes a control a drag handle for an editor's scrub, with a sideways cursor.</summary>
    public static void Scrubbable(Control handle, IFieldEditor editor, int axis)
    {
        Point? start = null;
        handle.Cursor = new Cursor(StandardCursorType.SizeWestEast);
        void End()
        {
            if (start != null)
            {
                start = null;
                editor.EndScrub();
            }
        }
        handle.PointerPressed += (_, e) =>
        {
            if (!e.GetCurrentPoint(handle).Properties.IsLeftButtonPressed)
            {
                return;
            }
            start = e.GetPosition(handle);
            e.Pointer.Capture(handle);
            editor.BeginScrub(axis);
            e.Handled = true;
        };
        handle.PointerMoved += (_, e) =>
        {
            if (start is { } origin)
            {
                editor.Scrub(axis, e.GetPosition(handle).X - origin.X, e.KeyModifiers);
            }
        };
        handle.PointerReleased += (_, e) =>
        {
            e.Pointer.Capture(null);
            End();
        };
        handle.PointerCaptureLost += (_, _) => End();
    }
}

/// <summary>A value in a box, numbers right-aligned so their digits line up down the panel.</summary>
sealed class BoxView : FieldView
{
    readonly TextBlock? _text;
    readonly TextBox? _edit;
    readonly Border _box;
    string _value = "…";

    public BoxView(bool numeric, IFieldEditor? editor)
    {
        if (editor != null)
        {
            _edit = EditBox(numeric, text => editor.Commit(-1, text), () => _value);
            _edit.Text = _value;
            _box = new Border { Classes = { "value-box", "editable" }, Child = _edit };
            return;
        }
        _text = new TextBlock
        {
            Text = _value,
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextAlignment = numeric ? TextAlignment.Right : TextAlignment.Left,
        };
        _box = new Border { Classes = { "value-box" }, Child = _text };
    }

    public override Control Control => _box;

    public override void Show(FieldDisplay value)
    {
        // A string shows with its quotes, and edits without them.
        _value = _edit != null && value.Kind == DisplayKind.Text && value.Text.Length >= 2 && value.Text[0] == '"' && value.Text[^1] == '"'
            ? value.Text[1..^1]
            : value.Text;
        if (_text != null)
        {
            _text.Text = _value;
        }
        else if (_edit is { IsFocused: false })
        {
            _edit.Text = _value;
        }
        SetTooltip(_box, value.Tooltip ?? value.Text);
    }
}

/// <summary>Three boxes, marked red, green and blue for x, y and z, as in most 3D tools. A marker drags its axis.</summary>
sealed class AxesView : FieldView
{
    readonly Grid _grid = new() { ColumnDefinitions = new ColumnDefinitions("*,*,*"), Classes = { "axes" } };
    readonly TextBlock?[] _parts = new TextBlock?[3];
    readonly TextBox?[] _edits = new TextBox?[3];
    readonly string[] _values = ["…", "…", "…"];

    public AxesView(IFieldEditor? editor)
    {
        string[] axes = ["axis-x", "axis-y", "axis-z"];
        for (var i = 0; i < 3; i++)
        {
            var axis = i;
            var marker = new Border { Classes = { "axis-marker", axes[i] } };
            DockPanel.SetDock(marker, Avalonia.Controls.Dock.Left);
            Control content;
            if (editor != null)
            {
                marker.Classes.Add("handle");
                Scrubbable(marker, editor, axis);
                var edit = EditBox(numeric: true, text => editor.Commit(axis, text), () => _values[axis]);
                edit.Text = _values[axis];
                content = _edits[i] = edit;
            }
            else
            {
                content = _parts[i] = new TextBlock { Text = "…", TextAlignment = TextAlignment.Right, TextTrimming = TextTrimming.CharacterEllipsis };
            }
            var box = new Border { Classes = { "value-box", "axis" }, Child = new DockPanel { Children = { marker, content } } };
            box.Classes.Set("editable", editor != null);
            Grid.SetColumn(box, i);
            _grid.Children.Add(box);
        }
    }

    public override Control Control => _grid;

    public override void Show(FieldDisplay value)
    {
        for (var i = 0; i < 3; i++)
        {
            _values[i] = i < value.Axes.Length ? value.Axes[i] : "";
            if (_parts[i] is { } part)
            {
                part.Text = _values[i];
            }
            else if (_edits[i] is { IsFocused: false } edit)
            {
                edit.Text = _values[i];
            }
        }
        SetTooltip(_grid, value.Tooltip ?? value.Text);
    }
}

/// <summary>A check box. With an editor, clicking it sets the field.</summary>
sealed class BoolView : FieldView
{
    readonly CheckBox _check = new()
    {
        MinHeight = 0,
        Padding = new Thickness(0),
        Classes = { "value-check" },
    };
    bool _showing;

    public BoolView(IFieldEditor? editor)
    {
        _check.IsHitTestVisible = editor != null;
        _check.Focusable = editor != null;
        _check.IsCheckedChanged += (_, _) =>
        {
            if (!_showing && editor != null)
            {
                editor.SetFlag(_check.IsChecked == true);
            }
        };
    }

    public override Control Control => _check;

    public override void Show(FieldDisplay value)
    {
        _showing = true;
        _check.IsChecked = value.Flag;
        _showing = false;
    }
}

/// <summary>An enum's value as a choice of its names.</summary>
sealed class ChoiceView : FieldView
{
    readonly ComboBox _combo = new() { Classes = { "value-choice" }, HorizontalAlignment = HorizontalAlignment.Stretch };
    bool _showing;

    public ChoiceView(IFieldEditor editor)
    {
        _combo.ItemsSource = editor.Options;
        _combo.SelectionChanged += (_, _) =>
        {
            if (!_showing && _combo.SelectedItem is string option)
            {
                editor.Choose(option);
            }
        };
    }

    public override Control Control => _combo;

    public override void Show(FieldDisplay value)
    {
        _showing = true;
        _combo.SelectedItem = value.Text;
        _showing = false;
        SetTooltip(_combo, value.Tooltip);
    }
}

/// <summary>
/// An entity reference, which selects its entity when clicked. With an editor, it takes an entity dragged from the
/// outliner, and a button clears it.
/// </summary>
sealed class EntityView : FieldView
{
    /// <summary>The drag format of an outliner row: the entity's handle, in decimal.</summary>
    public static readonly DataFormat<string> EntityFormat = DataFormat.CreateStringApplicationFormat("cinnabar-entity");

    readonly TextBlock _text = new() { Text = "…", TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
    readonly Control _control;
    readonly Func<ulong, string> _label;
    readonly Button? _clear;
    ulong _entity;

    public EntityView(Action<ulong> select, Func<ulong, string> label, IFieldEditor? editor = null)
    {
        _label = label;
        _text.PointerPressed += (_, e) =>
        {
            if (_entity != 0)
            {
                select(_entity);
                e.Handled = true;
            }
        };
        if (editor == null)
        {
            _control = _text;
            return;
        }
        _clear = new Button { Content = "×", Classes = { "field-button" }, VerticalAlignment = VerticalAlignment.Center };
        ToolTip.SetTip(_clear, "Clear the reference");
        _clear.Click += (_, _) => editor.SetEntity(0);
        DockPanel.SetDock(_clear, Avalonia.Controls.Dock.Right);
        var box = new Border { Classes = { "value-box", "editable" }, Child = new DockPanel { Children = { _clear, _text } } };
        DragDrop.SetAllowDrop(box, true);
        box.AddHandler(DragDrop.DragOverEvent, (_, e) => e.DragEffects = Dropped(e) != 0 ? DragDropEffects.Link : DragDropEffects.None);
        box.AddHandler(DragDrop.DropEvent, (_, e) =>
        {
            if (Dropped(e) is var handle and not 0)
            {
                editor.SetEntity(handle);
            }
        });
        ToolTip.SetTip(box, "Drag an entity here from the outliner");
        _control = box;
    }

    /// <summary>The entity that a drag carries, or 0.</summary>
    public static ulong Dropped(DragEventArgs e) =>
        e.DataTransfer.TryGetValue(EntityFormat) is { } text && ulong.TryParse(text, out var handle) ? handle : 0;

    public override Control Control => _control;

    public override void Show(FieldDisplay value)
    {
        _entity = value.Entity;
        _text.Text = _entity != 0 ? _label(_entity) : value.Text;
        SetTooltip(_text, _entity != 0 ? value.Text : null);
        _text.Classes.Set("link", _entity != 0);
        _text.Classes.Set("dim", _entity == 0);
        _text.Cursor = _entity != 0 ? new Cursor(StandardCursorType.Hand) : Cursor.Default;
        if (_clear != null)
        {
            _clear.IsVisible = _entity != 0;
        }
    }
}
