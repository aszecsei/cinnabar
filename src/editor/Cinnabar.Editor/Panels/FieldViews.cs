using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// Shows one field's value in the properties panel. The panel picks a view by the field's <see cref="DisplayKind"/>,
/// which never changes, and calls <see cref="Show"/> with each new value.
/// </summary>
abstract class FieldView
{
    public abstract Control Control { get; }

    public abstract void Show(FieldDisplay value);

    /// <summary>A view for a kind of value. An entity shows as its <paramref name="label"/>, such as its name.</summary>
    public static FieldView Create(DisplayKind kind, Action<ulong> select, Func<ulong, string> label) => kind switch
    {
        DisplayKind.Axes => new AxesView(),
        DisplayKind.Bool => new BoolView(),
        DisplayKind.Entity => new EntityView(select, label),
        DisplayKind.Number => new BoxView(numeric: true),
        _ => new BoxView(numeric: false),
    };

    protected static void SetTooltip(Control control, string? tooltip) => ToolTip.SetTip(control, tooltip);
}

/// <summary>A value in a box, numbers right-aligned so their digits line up down the panel.</summary>
sealed class BoxView : FieldView
{
    readonly TextBlock _text;
    readonly Border _box;

    public BoxView(bool numeric)
    {
        _text = new TextBlock
        {
            Text = "…",
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextAlignment = numeric ? TextAlignment.Right : TextAlignment.Left,
        };
        _box = new Border { Classes = { "value-box" }, Child = _text };
    }

    public override Control Control => _box;

    public override void Show(FieldDisplay value)
    {
        _text.Text = value.Text;
        SetTooltip(_box, value.Tooltip ?? value.Text);
    }
}

/// <summary>Three boxes, marked red, green and blue for x, y and z, as in most 3D tools.</summary>
sealed class AxesView : FieldView
{
    readonly Grid _grid = new() { ColumnDefinitions = new ColumnDefinitions("*,*,*"), Classes = { "axes" } };
    readonly TextBlock[] _parts = new TextBlock[3];

    public AxesView()
    {
        string[] axes = ["axis-x", "axis-y", "axis-z"];
        for (var i = 0; i < 3; i++)
        {
            _parts[i] = new TextBlock { Text = "…", TextAlignment = TextAlignment.Right, TextTrimming = TextTrimming.CharacterEllipsis };
            var marker = new Border { Classes = { "axis-marker", axes[i] } };
            DockPanel.SetDock(marker, Avalonia.Controls.Dock.Left);
            var box = new Border { Classes = { "value-box", "axis" }, Child = new DockPanel { Children = { marker, _parts[i] } } };
            Grid.SetColumn(box, i);
            _grid.Children.Add(box);
        }
    }

    public override Control Control => _grid;

    public override void Show(FieldDisplay value)
    {
        for (var i = 0; i < 3; i++)
        {
            _parts[i].Text = i < value.Axes.Length ? value.Axes[i] : "";
        }
        SetTooltip(_grid, value.Tooltip ?? value.Text);
    }
}

/// <summary>A check box that shows the value. Nothing can change it until editing.</summary>
sealed class BoolView : FieldView
{
    readonly CheckBox _check = new()
    {
        IsHitTestVisible = false,
        Focusable = false,
        MinHeight = 0,
        Padding = new Thickness(0),
        Classes = { "value-check" },
    };

    public override Control Control => _check;

    public override void Show(FieldDisplay value) => _check.IsChecked = value.Flag;
}

/// <summary>An entity reference, which selects its entity when clicked.</summary>
sealed class EntityView : FieldView
{
    readonly TextBlock _text = new() { Text = "…", TextTrimming = TextTrimming.CharacterEllipsis };
    readonly Func<ulong, string> _label;
    ulong _entity;

    public EntityView(Action<ulong> select, Func<ulong, string> label)
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
    }

    public override Control Control => _text;

    public override void Show(FieldDisplay value)
    {
        _entity = value.Entity;
        _text.Text = _entity != 0 ? _label(_entity) : value.Text;
        SetTooltip(_text, _entity != 0 ? value.Text : null);
        _text.Classes.Set("link", _entity != 0);
        _text.Classes.Set("dim", _entity == 0);
        _text.Cursor = _entity != 0 ? new Cursor(StandardCursorType.Hand) : Cursor.Default;
    }
}
