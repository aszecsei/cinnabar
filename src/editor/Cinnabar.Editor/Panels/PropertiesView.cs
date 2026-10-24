using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// The properties panel (see docs/editor.md#properties): the selected entity's components and behaviours, read-only
/// for now. The editor watches the selected entity, and when only values change, each field's view shows the new
/// value, so the panel keeps its expanders and scroll position at twenty updates a second.
/// </summary>
public sealed class PropertiesView : ScrollViewer
{
    readonly WorldModel _world;
    readonly Selection _selection;
    readonly StackPanel _content = new() { Classes = { "properties" } };
    // The view of each field, by component ID or behaviour class, and field name.
    readonly Dictionary<(string Owner, string Field), FieldView> _views = [];
    // Groups that the user collapsed, by title, which stay collapsed across selections.
    readonly HashSet<string> _collapsed = [];
    string _structure = "";

    public PropertiesView(WorldModel world, Selection selection)
    {
        _world = world;
        _selection = selection;
        Content = _content;
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
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
        ShowValues();
    }

    void Rebuild()
    {
        _content.Children.Clear();
        _views.Clear();
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
        var tags = new List<string>();
        foreach (var id in node.Components)
        {
            var type = _world.Type(id);
            var title = FieldValues.Humanize(_world.TypeName(id));
            if (type == null || type.Fields.Length == 0)
            {
                // A tag, or a component whose fields the editor cannot show.
                tags.Add(title);
                continue;
            }
            var owner = id.ToString("x16");
            _content.Children.Add(Group(title, type.Fields.Select(f => (owner, f.Name, FieldValues.DisplayKindOf(f.Kind)))));
        }
        foreach (var behaviour in _world.Values(node.Handle)?.Behaviours ?? [])
        {
            var title = FieldValues.Humanize(behaviour.Class);
            var owner = "behaviour:" + behaviour.Class;
            _content.Children.Add(Group(title, behaviour.Fields.Select(f => (owner, f.Name, FieldValues.DisplayKindOf(f.Kind))),
                badge: "Script", disabled: !behaviour.Enabled));
        }
        if (tags.Count > 0)
        {
            _content.Children.Add(Tags(tags));
        }
        ShowValues();
    }

    void ShowValues()
    {
        var values = _world.Values(_selection.Entity);
        if (values == null)
        {
            return;
        }
        foreach (var component in values.Components)
        {
            var owner = component.Id.ToString("x16");
            foreach (var field in _world.Type(component.Id)?.Fields ?? [])
            {
                if (_views.TryGetValue((owner, field.Name), out var view))
                {
                    view.Show(FieldValues.Display(field, component.Data));
                }
            }
        }
        foreach (var behaviour in values.Behaviours)
        {
            foreach (var field in behaviour.Fields)
            {
                if (_views.TryGetValue(("behaviour:" + behaviour.Class, field.Name), out var view))
                {
                    view.Show(FieldValues.Display(field));
                }
            }
        }
    }

    // What decides the panel's controls: the entity, its components, its behaviours, and how each of their fields
    // shows. Values do not.
    string Structure()
    {
        var node = _world.Find(_selection.Entity);
        if (node == null)
        {
            return "";
        }
        var behaviours = _world.Values(node.Handle)?.Behaviours ?? [];
        return $"{node.Handle}|{node.Active}|{node.Parent}|{string.Join(",", node.Components)}|{_world.Types.Count}|" +
            string.Join(";", behaviours.Select(b =>
                $"{b.Class}:{b.Enabled}:{string.Join(",", b.Fields.Select(f => $"{f.Name}={FieldValues.DisplayKindOf(f.Kind)}"))}"));
    }

    Control Header(EntityNode node)
    {
        var title = new TextBlock { Text = node.ToString(), Classes = { "title" } };
        var state = new Border
        {
            Classes = { "badge", node.Active ? "active" : "inactive" },
            Child = new TextBlock { Text = node.Active ? "Active" : "Inactive" },
            VerticalAlignment = VerticalAlignment.Center,
        };
        var top = new DockPanel { Children = { state, title } };
        DockPanel.SetDock(state, Avalonia.Controls.Dock.Right);
        var header = new StackPanel { Classes = { "properties-header" }, Spacing = 4, Children = { top } };
        if (node.Parent != 0)
        {
            var parent = new EntityView(_selection.Select);
            parent.Show(new FieldDisplay(DisplayKind.Entity, EntityNode.Format(node.Parent), [], false, node.Parent, null));
            header.Children.Add(new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 6,
                Children = { new TextBlock { Text = "Parent", Classes = { "field-name" } }, parent.Control },
            });
        }
        return header;
    }

    Control Group(string title, IEnumerable<(string Owner, string Field, DisplayKind Kind)> fields, string? badge = null, bool disabled = false)
    {
        var rows = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), Classes = { "fields" } };
        var row = 0;
        foreach (var (owner, field, kind) in fields)
        {
            rows.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
            var name = new TextBlock
            {
                Text = FieldValues.Humanize(field),
                Classes = { "field-name" },
                TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center,
            };
            ToolTip.SetTip(name, field);
            var view = FieldView.Create(kind, _selection.Select);
            Grid.SetRow(name, row);
            Grid.SetRow(view.Control, row);
            Grid.SetColumn(view.Control, 1);
            rows.Children.Add(name);
            rows.Children.Add(view.Control);
            _views[(owner, field)] = view;
            row++;
        }

        var header = new DockPanel();
        if (badge != null)
        {
            var tag = new Border { Classes = { "badge", "script" }, Child = new TextBlock { Text = disabled ? $"{badge}, disabled" : badge } };
            DockPanel.SetDock(tag, Avalonia.Controls.Dock.Right);
            header.Children.Add(tag);
        }
        header.Children.Add(new TextBlock { Text = title, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center });

        var expander = new Expander
        {
            Header = header,
            Content = rows,
            IsExpanded = !_collapsed.Contains(title),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Classes = { "component" },
            Opacity = disabled ? 0.6 : 1,
        };
        expander.Expanded += (_, _) => _collapsed.Remove(title);
        expander.Collapsed += (_, _) => _collapsed.Add(title);
        return expander;
    }

    // Components without fields to show, such as tags, as a row of chips under the groups.
    static Control Tags(IEnumerable<string> names)
    {
        var panel = new WrapPanel { Classes = { "tags" } };
        foreach (var name in names)
        {
            panel.Children.Add(new Border { Classes = { "badge", "tag" }, Child = new TextBlock { Text = name } });
        }
        return panel;
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
