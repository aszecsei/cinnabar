using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// The properties panel (see docs/editor.md#properties): the selected entity's components and behaviours, with an
/// editor for each field that the scene can set. The editor watches the selected entity, and when only values change,
/// each field's view shows the new value, so the panel keeps its expanders, its scroll position and the box being
/// typed in at twenty updates a second. Values come from the host; edits go to the document, which sends them on.
/// </summary>
public sealed class PropertiesView : ScrollViewer
{
    // The components that come from the entity's own keys or from the world. The header shows the parent, the name
    // and the active state, and the behaviours have groups of their own, so these do not show as components.
    static readonly HashSet<ulong> Derived = [3, 6, 7, 8, 16];
    // Previous_Transform marks an entity that interpolates. The world writes its values, and an edit of the
    // Transform sets them too, so it is removable and read-only.
    static readonly HashSet<ulong> WorldWritten = [SceneEdits.PreviousTransformId];

    readonly EditorShell _shell;
    readonly WorldModel _world;
    readonly Selection _selection;
    readonly StackPanel _content = new() { Classes = { "properties" } };
    // The view and the editor of each field, by component ID or behaviour class, and field name.
    readonly Dictionary<(string Owner, string Field), FieldView> _views = [];
    readonly Dictionary<(string Owner, string Field), FieldEditor> _editors = [];
    // Each reset button, with whether its field is set in the document, which edits change without a rebuild.
    readonly List<(Control Button, Func<bool> IsSet)> _resets = [];
    // Groups that the user collapsed, by title, which stay collapsed across selections.
    readonly HashSet<string> _collapsed = [];
    string _structure = "";

    public PropertiesView(EditorShell shell)
    {
        _shell = shell;
        _world = shell.World;
        _selection = shell.Selection;
        Content = _content;
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        AttachedToVisualTree += (_, _) =>
        {
            _selection.Changed += OnSelectionChanged;
            _world.EntitiesChanged += Rebuild;
            _world.TypesChanged += Rebuild;
            _world.ValuesChanged += OnValuesChanged;
            _shell.SceneChanged += OnSceneChanged;
            _shell.ProblemsChanged += Rebuild;
            Rebuild();
        };
        DetachedFromVisualTree += (_, _) =>
        {
            _selection.Changed -= OnSelectionChanged;
            _world.EntitiesChanged -= Rebuild;
            _world.TypesChanged -= Rebuild;
            _world.ValuesChanged -= OnValuesChanged;
            _shell.SceneChanged -= OnSceneChanged;
            _shell.ProblemsChanged -= Rebuild;
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

    // An edit can add a component to the document or set a field, which changes what the panel offers.
    void OnSceneChanged()
    {
        if (Structure() != _structure)
        {
            Rebuild();
            return;
        }
        foreach (var (button, isSet) in _resets)
        {
            button.IsVisible = isSet();
        }
    }

    void Rebuild()
    {
        _content.Children.Clear();
        _views.Clear();
        _editors.Clear();
        _resets.Clear();
        var node = _world.Find(_selection.Entity);
        _structure = Structure();
        if (node == null)
        {
            _content.Children.Add(Empty(_world.HasWorld
                ? "Select an entity in the outliner to see its components and behaviours."
                : "The selected entity's components and behaviours appear here."));
            return;
        }
        var document = _shell.SelectedSceneEntity;
        _content.Children.Add(Header(node, document));
        var tags = new List<(string Title, Action? Remove)>();
        foreach (var id in node.Components.Where(id => !Derived.Contains(id)))
        {
            var type = _world.Type(id);
            var title = FieldValues.Humanize(_world.TypeName(id));
            var inDocument = document?.Components.Find(c => c.Id == id);
            var removable = document != null && inDocument != null && !Derived.Contains(id);
            if (type == null || type.Fields.Length == 0)
            {
                // A tag, or a component whose fields the editor cannot show.
                tags.Add((title, removable ? () => _shell.Edit($"Remove {title}", new RemoveComponent(document!.Id, id)) : null));
                continue;
            }
            // A child's Transform is what propagation writes from its Local_Transform, so only the latter edits.
            var editable = inDocument != null && !WorldWritten.Contains(id) && !(id == SceneEdits.TransformId && node.Parent != 0);
            var owner = id.ToString("x16");
            var fields = type.Fields.Select(f => new FieldRow(owner, f.Name, FieldValues.DisplayKindOf(f.Kind), f.Kind == Link.Protocol.FieldKind.Enum,
                editable ? FieldEditor.ForComponent(_shell, document!.Id, id, f) : null,
                editable && !f.ReadOnly ? () => inDocument!.Fields.Any(x => x.Name == f.Name) : null,
                () => _shell.Edit($"Reset {FieldValues.Humanize(f.Name)}", new SetField(document!.Id, id, f.Name, null))));
            var note = id == SceneEdits.TransformId && node.Parent != 0 ? "Propagation writes a child's Transform from its Local Transform." : null;
            _content.Children.Add(Group(title, fields,
                remove: removable ? () => _shell.Edit($"Remove {title}", new RemoveComponent(document!.Id, id)) : null, note: note));
        }
        foreach (var behaviour in _world.Values(node.Handle)?.Behaviours ?? [])
        {
            var title = FieldValues.Humanize(behaviour.Class);
            var owner = "behaviour:" + behaviour.Class;
            var script = Convert.ToHexStringLower(behaviour.Script);
            var inDocument = document?.Behaviours.Find(b => b.Script == script);
            var fields = behaviour.Fields.Select(f => new FieldRow(owner, f.Name, FieldValues.DisplayKindOf(f.Kind), false,
                inDocument != null ? FieldEditor.ForBehaviour(_shell, document!.Id, script, f) : null,
                inDocument != null ? () => inDocument.Fields.Any(x => x.Name == f.Name) : null,
                () => _shell.Edit($"Reset {FieldValues.Humanize(f.Name)}", new SetBehaviourField(document!.Id, script, f.Name, null))));
            _content.Children.Add(Group(title, fields, badge: "Script", disabled: !behaviour.Enabled,
                remove: inDocument != null ? () => _shell.Edit($"Remove {title}", new RemoveBehaviour(document!.Id, script)) : null));
        }
        if (document != null)
        {
            foreach (var missing in document.Components.Where(c => !node.Components.Contains(c.Id) && !Derived.Contains(c.Id)))
            {
                _content.Children.Add(Kept(document, missing));
            }
        }
        if (tags.Count > 0)
        {
            _content.Children.Add(Tags(tags));
        }
        if (document != null)
        {
            _content.Children.Add(AddComponentButton(node, document));
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
        ulong SceneIdOf(ulong handle) => _world.Find(handle)?.SceneId ?? 0;
        foreach (var component in values.Components)
        {
            var owner = component.Id.ToString("x16");
            foreach (var field in _world.Type(component.Id)?.Fields ?? [])
            {
                if (_editors.TryGetValue((owner, field.Name), out var editor))
                {
                    editor.Current = FieldEditor.Read(field, component.Data, SceneIdOf);
                }
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
                var key = ("behaviour:" + behaviour.Class, field.Name);
                if (_editors.TryGetValue(key, out var editor))
                {
                    editor.Current = FieldEditor.Read(field, SceneIdOf);
                }
                if (_views.TryGetValue(key, out var view))
                {
                    view.Show(FieldValues.Display(field));
                }
            }
        }
    }

    // What decides the panel's controls: the entity, its components, its behaviours, how each of their fields shows,
    // what the document has of them, and the host's problems with it. Values do not.
    string Structure()
    {
        var node = _world.Find(_selection.Entity);
        if (node == null)
        {
            return "";
        }
        var behaviours = _world.Values(node.Handle)?.Behaviours ?? [];
        var document = _shell.SelectedSceneEntity;
        var inDocument = document == null
            ? "-"
            : $"{string.Join(",", document.Components.Select(c => c.Id))}|{string.Join(",", document.Behaviours.Select(b => b.Script))}";
        return $"{node.Handle}|{node.Name}|{node.Active}|{node.Parent}|{string.Join(",", node.Components)}|{_world.Types.Count}|{inDocument}|" +
            $"{_shell.ProblemsOf(node.SceneId).Count}|" +
            string.Join(";", behaviours.Select(b =>
                $"{b.Class}:{b.Enabled}:{string.Join(",", b.Fields.Select(f => $"{f.Name}={FieldValues.DisplayKindOf(f.Kind)}"))}"));
    }

    // An entity that the world does not know shows as the engine prints it.
    string Label(ulong entity) => _world.Find(entity)?.Label ?? EntityNode.Format(entity);

    Control Header(EntityNode node, SceneEntity? document)
    {
        Control title;
        if (document != null)
        {
            var name = new TextBox { Text = document.Name, PlaceholderText = "Name", Classes = { "title-edit" } };
            void Commit()
            {
                if (name.Text != document.Name)
                {
                    _shell.Edit("Rename", new Rename(document.Id, name.Text ?? ""));
                }
            }
            name.KeyDown += (_, e) =>
            {
                if (e.Key == Key.Enter)
                {
                    Commit();
                    e.Handled = true;
                }
                else if (e.Key == Key.Escape)
                {
                    name.Text = document.Name;
                    e.Handled = true;
                }
            };
            name.LostFocus += (_, _) => Commit();
            title = name;
        }
        else
        {
            title = new TextBlock { Text = node.Label, Classes = { "title" } };
            ToolTip.SetTip(title, node.SceneId == 0 ? "The game spawned this entity, so the scene cannot edit it." : null);
        }
        if (node.SceneId != 0)
        {
            ToolTip.SetTip(title, $"Scene ID {node.SceneId:x16}");
        }
        var stateText = new TextBlock { Text = node.Active ? "Active" : "Inactive" };
        Control state;
        if (document != null)
        {
            var toggle = new Button { Classes = { "badge-button", node.Active ? "active" : "inactive" }, Content = stateText, VerticalAlignment = VerticalAlignment.Center };
            ToolTip.SetTip(toggle, document.Active ? "Deactivate the entity" : "Activate the entity");
            toggle.Click += (_, _) => _shell.Edit(document.Active ? "Deactivate" : "Activate", new SetActive(document.Id, !document.Active));
            state = toggle;
        }
        else
        {
            state = new Border { Classes = { "badge", node.Active ? "active" : "inactive" }, Child = stateText, VerticalAlignment = VerticalAlignment.Center };
        }
        var top = new DockPanel { Children = { state, title } };
        DockPanel.SetDock(state, Avalonia.Controls.Dock.Right);
        var header = new StackPanel { Classes = { "properties-header" }, Spacing = 4, Children = { top } };
        if (node.Parent != 0)
        {
            var parent = new EntityView(_selection.Select, Label);
            parent.Show(new FieldDisplay(DisplayKind.Entity, EntityNode.Format(node.Parent), [], false, node.Parent, null));
            header.Children.Add(new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 6,
                Children = { new TextBlock { Text = "Parent", Classes = { "field-name" } }, parent.Control },
            });
        }
        var problems = _shell.ProblemsOf(node.SceneId);
        if (problems.Count > 0)
        {
            header.Children.Add(new Border
            {
                Classes = { "problems" },
                Child = new StackPanel
                {
                    Spacing = 2,
                    Children =
                    {
                        new TextBlock { Text = "The game could not apply all of this entity:", FontWeight = FontWeight.SemiBold },
                        new TextBlock { Text = string.Join("\n", problems), TextWrapping = TextWrapping.Wrap },
                    },
                },
            });
        }
        return header;
    }

    sealed record FieldRow(string Owner, string Field, DisplayKind Kind, bool IsEnum, FieldEditor? Editor, Func<bool>? IsSet, Action Reset);

    Control Group(string title, IEnumerable<FieldRow> fields, string? badge = null, bool disabled = false, Action? remove = null, string? note = null)
    {
        var rows = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), Classes = { "fields" } };
        var row = 0;
        foreach (var field in fields)
        {
            rows.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
            var name = new TextBlock
            {
                Text = FieldValues.Humanize(field.Field),
                Classes = { "field-name" },
                TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center,
            };
            ToolTip.SetTip(name, field.Editor != null && field.Kind == DisplayKind.Number ? $"{field.Field}. Drag to change it." : field.Field);
            if (field.Editor != null && field.Kind == DisplayKind.Number)
            {
                FieldView.Scrubbable(name, field.Editor, 0);
            }
            var view = FieldView.Create(field.Kind, _selection.Select, Label, field.Editor, field.IsEnum);
            Grid.SetRow(name, row);
            Grid.SetRow(view.Control, row);
            Grid.SetColumn(view.Control, 1);
            rows.Children.Add(name);
            rows.Children.Add(view.Control);
            if (field.IsSet != null)
            {
                var reset = new Button { Content = "↺", Classes = { "field-button" }, IsVisible = field.IsSet(), VerticalAlignment = VerticalAlignment.Center };
                ToolTip.SetTip(reset, "Reset to the default");
                reset.Click += (_, _) => field.Reset();
                Grid.SetRow(reset, row);
                Grid.SetColumn(reset, 2);
                rows.Children.Add(reset);
                _resets.Add((reset, field.IsSet));
            }
            _views[(field.Owner, field.Field)] = view;
            if (field.Editor != null)
            {
                _editors[(field.Owner, field.Field)] = field.Editor;
            }
            row++;
        }
        Control content = rows;
        if (note != null)
        {
            content = new StackPanel { Spacing = 4, Children = { new TextBlock { Text = note, Classes = { "dim" }, TextWrapping = TextWrapping.Wrap }, rows } };
        }
        return Expander(title, content, badge, disabled, remove);
    }

    // A component that the document has and the game does not: the scene keeps it, and the panel shows its values.
    Control Kept(SceneEntity document, SceneComponent component)
    {
        var title = FieldValues.Humanize(component.Name.Length > 0 ? component.Name : component.Id.ToString());
        var rows = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), Classes = { "fields" } };
        for (var i = 0; i < component.Fields.Count; i++)
        {
            rows.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
            var name = new TextBlock { Text = FieldValues.Humanize(component.Fields[i].Name), Classes = { "field-name" } };
            var value = new TextBlock { Text = SceneFile.FormatValue(component.Fields[i].Value), Classes = { "dim" }, TextTrimming = TextTrimming.CharacterEllipsis };
            Grid.SetRow(name, i);
            Grid.SetRow(value, i);
            Grid.SetColumn(value, 1);
            rows.Children.Add(name);
            rows.Children.Add(value);
        }
        var content = new StackPanel
        {
            Spacing = 4,
            Children = { new TextBlock { Text = "The game has no such component. The scene keeps it as it is.", Classes = { "dim" }, TextWrapping = TextWrapping.Wrap }, rows },
        };
        return Expander(title, content, "Not in game", disabled: true,
            remove: () => _shell.Edit($"Remove {title}", new RemoveComponent(document.Id, component.Id)));
    }

    Control Expander(string title, Control content, string? badge, bool disabled, Action? remove)
    {
        var header = new DockPanel();
        if (remove != null)
        {
            var button = new Button { Content = "×", Classes = { "field-button" }, VerticalAlignment = VerticalAlignment.Center };
            ToolTip.SetTip(button, $"Remove {title}");
            button.Click += (_, e) =>
            {
                remove();
                e.Handled = true;
            };
            DockPanel.SetDock(button, Avalonia.Controls.Dock.Right);
            header.Children.Add(button);
        }
        if (badge != null)
        {
            var tag = new Border { Classes = { "badge", "script" }, Child = new TextBlock { Text = disabled && badge == "Script" ? $"{badge}, disabled" : badge } };
            DockPanel.SetDock(tag, Avalonia.Controls.Dock.Right);
            header.Children.Add(tag);
        }
        header.Children.Add(new TextBlock { Text = title, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center });

        var expander = new Expander
        {
            Header = header,
            Content = content,
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

    // The component types that the game registers and the entity lacks, in a menu.
    Control AddComponentButton(EntityNode node, SceneEntity document)
    {
        var menu = new MenuFlyout();
        foreach (var type in _world.Types.Values.Where(t => !node.Components.Contains(t.Id) && !Derived.Contains(t.Id)).OrderBy(t => FieldValues.Humanize(t.Name)))
        {
            var item = new MenuItem { Header = FieldValues.Humanize(type.Name) };
            item.Click += (_, _) => _shell.Edit($"Add {FieldValues.Humanize(type.Name)}",
                new AddComponent(document.Id, new SceneComponent(type.Id, type.Name, DefaultFields(type.Id))));
            menu.Items.Add(item);
        }
        return new Button
        {
            Content = "Add Component",
            Flyout = menu,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Center,
            Classes = { "add-component" },
            IsEnabled = menu.Items.Count > 0,
        };
    }

    // Zero is no rotation and no size, so the pose components start as the identity.
    static List<SceneField> DefaultFields(ulong id) => id switch
    {
        SceneEdits.TransformId or SceneEdits.PreviousTransformId => [new("rotation", SceneEdits.Floats(0, 0, 0, 1)), new("scale", SceneEdits.Floats(1, 1, 1))],
        SceneEdits.LocalTransformId => [new("rotation", SceneEdits.Floats(0, 0, 0, 1)), new("scale", SceneEdits.Floats(1, 1, 1))],
        _ => [],
    };

    // Components without fields to show, such as tags, as a row of chips under the groups.
    static Control Tags(IEnumerable<(string Title, Action? Remove)> tags)
    {
        var panel = new WrapPanel { Classes = { "tags" } };
        foreach (var (title, remove) in tags)
        {
            var chip = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Children = { new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center } } };
            if (remove != null)
            {
                var button = new Button { Content = "×", Classes = { "field-button" } };
                ToolTip.SetTip(button, $"Remove {title}");
                button.Click += (_, _) => remove();
                chip.Children.Add(button);
            }
            panel.Children.Add(new Border { Classes = { "badge", "tag" }, Child = chip });
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
