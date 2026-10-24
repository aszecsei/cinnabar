using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// The properties panel (see docs/editor.md#properties): the selected entity's components and behaviours, read-only
/// for now. The editor watches the selected entity, and when only values change, their text changes in place, so
/// the panel keeps its expanders and scroll position at twenty updates a second.
/// </summary>
public sealed class PropertiesView : ScrollViewer
{
    const string Waiting = "…";

    readonly WorldModel _world;
    readonly Selection _selection;
    readonly StackPanel _content = new() { Classes = { "properties" } };
    // The value text of each field, by component ID or behaviour class, and field name.
    readonly Dictionary<(string Owner, string Field), TextBlock> _values = [];
    // Expanders that the user collapsed, by component or behaviour name, which stay collapsed across selections.
    readonly HashSet<string> _collapsed = [];
    string _structure = "";

    public PropertiesView(WorldModel world, Selection selection)
    {
        _world = world;
        _selection = selection;
        Content = _content;
        HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled;
        AttachedToVisualTree += (_, _) =>
        {
            _selection.Changed += OnSelectionChanged;
            _world.EntitiesChanged += Rebuild;
            _world.TypesChanged += Rebuild;
            _world.ValuesChanged += OnValuesChanged;
            Rebuild();
        };
        DetachedFromVisualTree += (_, _) =>
        {
            _selection.Changed -= OnSelectionChanged;
            _world.EntitiesChanged -= Rebuild;
            _world.TypesChanged -= Rebuild;
            _world.ValuesChanged -= OnValuesChanged;
        };
    }

    void OnSelectionChanged(ulong old, ulong entity) => Rebuild();

    void OnValuesChanged(ulong entity)
    {
        if (entity != _selection.Entity)
        {
            return;
        }
        // Behaviours come and go with values, so a new set of them builds the panel again.
        if (Structure() != _structure)
        {
            Rebuild();
            return;
        }
        FillValues();
    }

    void Rebuild()
    {
        _content.Children.Clear();
        _values.Clear();
        var node = _world.Find(_selection.Entity);
        _structure = Structure();
        if (node == null)
        {
            _content.Children.Add(Empty(_world.HasWorld
                ? "Select an entity in the outliner to see its components and behaviours."
                : "The selected entity's components and behaviours appear here."));
            return;
        }
        _content.Children.Add(Header(node));
        foreach (var id in node.Components)
        {
            var type = _world.Type(id);
            var name = _world.TypeName(id);
            if (type == null || type.Fields.Length == 0)
            {
                // A tag, or a component whose fields the editor cannot show.
                _content.Children.Add(new TextBlock { Text = name, Classes = { "component-tag" } });
                continue;
            }
            var rows = Rows(type.Fields.Select(f => (id.ToString("x16"), f.Name)));
            _content.Children.Add(Section(name, rows));
        }
        foreach (var behaviour in _world.Values(node.Handle)?.Behaviours ?? [])
        {
            var title = behaviour.Enabled ? behaviour.Class : $"{behaviour.Class} (disabled)";
            _content.Children.Add(Section(title, Rows(behaviour.Fields.Select(f => ("behaviour:" + behaviour.Class, f.Name)))));
        }
        FillValues();
    }

    void FillValues()
    {
        var values = _world.Values(_selection.Entity);
        if (values == null)
        {
            return;
        }
        foreach (var component in values.Components)
        {
            var type = _world.Type(component.Id);
            foreach (var field in type?.Fields ?? [])
            {
                if (_values.TryGetValue((component.Id.ToString("x16"), field.Name), out var text))
                {
                    text.Text = FieldValues.Format(field, component.Data) ?? "?";
                    SetLink(text, FieldValues.Entity(field, component.Data));
                }
            }
        }
        foreach (var behaviour in values.Behaviours)
        {
            foreach (var field in behaviour.Fields)
            {
                if (_values.TryGetValue(("behaviour:" + behaviour.Class, field.Name), out var text))
                {
                    text.Text = FieldValues.Format(field);
                    SetLink(text, field.Kind == BehaviourFieldKind.Entity ? field.Entity : 0);
                }
            }
        }
    }

    // What decides the panel's controls: the entity, its components, its behaviours and their fields. Values do not.
    string Structure()
    {
        var node = _world.Find(_selection.Entity);
        if (node == null)
        {
            return "";
        }
        var behaviours = _world.Values(node.Handle)?.Behaviours ?? [];
        return $"{node.Handle}|{string.Join(",", node.Components)}|{_world.Types.Count}|" +
            string.Join(";", behaviours.Select(b => $"{b.Class}:{b.Enabled}:{string.Join(",", b.Fields.Select(f => f.Name))}"));
    }

    Control Header(EntityNode node)
    {
        var header = new StackPanel { Classes = { "properties-header" }, Spacing = 2 };
        header.Children.Add(new TextBlock { Text = node.ToString(), Classes = { "title" } });
        var state = new TextBlock { Text = node.Active ? "Active" : "Inactive", Classes = { "dim" } };
        header.Children.Add(state);
        if (node.Parent != 0)
        {
            var parent = new TextBlock { Text = $"Parent: {EntityNode.Format(node.Parent)}" };
            SetLink(parent, node.Parent);
            header.Children.Add(parent);
        }
        return header;
    }

    Control Section(string title, Control rows)
    {
        var expander = new Expander
        {
            Header = title,
            Content = rows,
            IsExpanded = !_collapsed.Contains(title),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Classes = { "component" },
        };
        expander.Expanded += (_, _) => _collapsed.Remove(title);
        expander.Collapsed += (_, _) => _collapsed.Add(title);
        return expander;
    }

    Grid Rows(IEnumerable<(string Owner, string Field)> fields)
    {
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("2*,3*"), Classes = { "fields" } };
        var row = 0;
        foreach (var (owner, field) in fields)
        {
            grid.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
            var name = new TextBlock { Text = field, Classes = { "field-name" }, TextTrimming = TextTrimming.CharacterEllipsis };
            var value = new TextBlock { Text = Waiting, Classes = { "field-value" }, TextTrimming = TextTrimming.CharacterEllipsis };
            ToolTip.SetTip(name, field);
            Grid.SetRow(name, row);
            Grid.SetRow(value, row);
            Grid.SetColumn(value, 1);
            grid.Children.Add(name);
            grid.Children.Add(value);
            _values[(owner, field)] = value;
            row++;
        }
        return grid;
    }

    // An entity reference selects its entity when clicked.
    void SetLink(TextBlock text, ulong entity)
    {
        text.Tag = entity;
        if (entity != 0 && !text.Classes.Contains("link"))
        {
            text.Classes.Add("link");
            text.Cursor = new Cursor(StandardCursorType.Hand);
            text.PointerPressed += (_, e) =>
            {
                if (text.Tag is ulong target && target != 0)
                {
                    _selection.Select(target);
                    e.Handled = true;
                }
            };
        }
        else if (entity == 0 && text.Classes.Contains("link"))
        {
            text.Classes.Remove("link");
            text.Cursor = Cursor.Default;
        }
    }

    static TextBlock Empty(string message) => new()
    {
        Text = message,
        Classes = { "empty" },
        TextWrapping = TextWrapping.Wrap,
        TextAlignment = TextAlignment.Center,
        Margin = new Thickness(16, 40),
    };
}
