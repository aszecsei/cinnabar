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
/// With more than one entity selected, it shows the components that all of them have, a field whose values differ as
/// mixed, and an edit sets the field of each.
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
    // The override check box of each volume setting, which the host's values tick.
    readonly Dictionary<(string Owner, string Field), OverrideRow> _overrides = [];
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
        // A script that defines a behaviour drags in from the content browser, and adds it to the selected entities.
        DragDrop.SetAllowDrop(this, true);
        AddHandler(DragDrop.DragOverEvent, (_, e) =>
            e.DragEffects = ContentBrowserView.Dropped(e) is { } script && _shell.CanAddBehaviour(SelectedSceneIds(), script)
                ? DragDropEffects.Link : DragDropEffects.None);
        AddHandler(DragDrop.DropEvent, (_, e) =>
        {
            if (ContentBrowserView.Dropped(e) is { } script)
            {
                _shell.AddBehaviour(SelectedSceneIds(), script);
            }
        });
        AttachedToVisualTree += (_, _) =>
        {
            _selection.Changed += OnSelectionChanged;
            _world.EntitiesChanged += Rebuild;
            _world.TypesChanged += Rebuild;
            _world.ValuesChanged += OnValuesChanged;
            _shell.SceneChanged += OnSceneChanged;
            _shell.ProblemsChanged += Rebuild;
            _shell.ModeChanged += Rebuild;
            _shell.Assets.Changed += OnSceneChanged;
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
            _shell.ModeChanged -= Rebuild;
            _shell.Assets.Changed -= OnSceneChanged;
        };
    }

    // A script that the content does not have: deleted, or moved outside the editor without its .meta file. The game
    // keeps a module that it has loaded, so its behaviour stays in the world until the game restarts. Without the cook
    // link, the index may be old, so no script is missing.
    bool ScriptMissing(string script) => _shell.Assets.Linked && _shell.Assets.Find(script) == null;

    void OnSelectionChanged(IReadOnlyList<ulong> old, IReadOnlyList<ulong> entities) => Rebuild();

    IEnumerable<ulong> SelectedSceneIds() => _selection.Entities.Select(e => _world.Find(e)?.SceneId ?? 0).Where(id => id != 0);

    void OnValuesChanged(ulong entity)
    {
        if (!_selection.Contains(entity))
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

    // An edit can add a component to the document or set a field, and the content can lose or regain a script, which
    // changes what the panel offers.
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
        _overrides.Clear();
        var node = _world.Find(_selection.Entity);
        _structure = Structure();
        if (node != null && _selection.Count > 1)
        {
            RebuildMany();
            return;
        }
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
            var fields = type.Fields.Select(f => FieldRow.Of(owner, f,
                editable ? FieldEditor.ForComponent(_shell, document!.Id, id, f) : null,
                editable && !f.ReadOnly ? () => inDocument!.Fields.Any(x => x.Name == f.Name) : null,
                () => _shell.Edit($"Reset {FieldValues.Humanize(f.Name)}", new SetField(document!.Id, id, f.Name, null))));
            var note = id == SceneEdits.TransformId && node.Parent != 0 ? "Propagation writes a child's Transform from its Local Transform." : null;
            _content.Children.Add(Group(title, fields,
                remove: removable ? () => _shell.Edit($"Remove {title}", new RemoveComponent(document!.Id, id)) : null, note: note));
        }
        var attached = new HashSet<string>();
        foreach (var behaviour in _world.Values(node.Handle)?.Behaviours ?? [])
        {
            var title = FieldValues.Humanize(behaviour.Class);
            var owner = "behaviour:" + behaviour.Class;
            var script = Convert.ToHexStringLower(behaviour.Script);
            var inDocument = document?.Behaviours.Find(b => b.Script == script);
            attached.Add(script);
            if (ScriptMissing(script))
            {
                _content.Children.Add(Unattached(document, script, inDocument, title));
                continue;
            }
            var fields = behaviour.Fields.Select(f => new FieldRow(owner, f.Name, FieldValues.DisplayKindOf(f.Kind), false,
                inDocument != null ? FieldEditor.ForBehaviour(_shell, document!.Id, script, f) : null,
                inDocument != null ? () => inDocument.Fields.Any(x => x.Name == f.Name) : null,
                () => _shell.Edit($"Reset {FieldValues.Humanize(f.Name)}", new SetBehaviourField(document!.Id, script, f.Name, null))));
            _content.Children.Add(Group(title, fields, badge: "Script", disabled: !behaviour.Enabled,
                remove: inDocument != null ? () => _shell.Edit($"Remove {title}", new RemoveBehaviour(document!.Id, script)) : null));
        }
        if (document != null)
        {
            foreach (var missing in document.Behaviours.Where(b => !attached.Contains(b.Script)))
            {
                _content.Children.Add(Unattached(document, missing.Script, missing, null));
            }
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
            _content.Children.Add(AddBehaviourButton(document));
        }
        ShowValues();
    }

    void ShowValues()
    {
        if (_selection.Count > 1)
        {
            ShowManyValues();
            return;
        }
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
                if (field.HasOverride && field.OverrideOffset < component.Data.Length)
                {
                    ShowOverride((owner, field.Name), component.Data[(int)field.OverrideOffset] != 0);
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
        if (_selection.Count > 1)
        {
            var documents = _shell.SelectedSceneEntities;
            return string.Join(";", _selection.Entities.Select(e => _world.Find(e) is { } n ? $"{n.Handle}|{n.Active}|{n.Parent}|{string.Join(",", n.Components)}" : "-")) +
                $"|{_world.Types.Count}|" + string.Join(";", documents.Select(d => $"{d.Id}:{string.Join(",", d.Components.Select(c => c.Id))}"));
        }
        var behaviours = _world.Values(node.Handle)?.Behaviours ?? [];
        var document = _shell.SelectedSceneEntity;
        var inDocument = document == null
            ? "-"
            : $"{string.Join(",", document.Components.Select(c => c.Id))}|{string.Join(",", document.Behaviours.Select(b => b.Script))}";
        var scripts = behaviours.Select(b => Convert.ToHexStringLower(b.Script)).Concat(document?.Behaviours.Select(b => b.Script) ?? []);
        return $"{node.Handle}|{node.Name}|{node.Active}|{node.Parent}|{string.Join(",", node.Components)}|{_world.Types.Count}|{inDocument}|" +
            $"{_shell.ProblemsOf(node.SceneId).Count}|{string.Join(",", scripts.Where(ScriptMissing))}|" +
            string.Join(";", behaviours.Select(b =>
                $"{b.Class}:{b.Enabled}:{string.Join(",", b.Fields.Select(f => $"{f.Name}={FieldValues.DisplayKindOf(f.Kind)}"))}"));
    }

    // The components that every selected entity has, with an editor for each field when the document has all of them.
    void RebuildMany()
    {
        var nodes = _selection.Entities.Select(_world.Find).OfType<EntityNode>().ToList();
        var documents = _shell.SelectedSceneEntities;
        // Only when the document has every selected entity can an edit set them all.
        var all = documents.Count == nodes.Count ? documents : null;
        var ids = all?.Select(d => d.Id).ToArray();
        _content.Children.Add(ManyHeader(nodes, all));
        var common = nodes.Skip(1).Aggregate(nodes[0].Components.AsEnumerable(), (shared, n) => shared.Intersect(n.Components))
            .Where(id => !Derived.Contains(id)).ToList();
        var tags = new List<(string Title, Action? Remove)>();
        foreach (var id in common)
        {
            var type = _world.Type(id);
            var title = FieldValues.Humanize(_world.TypeName(id));
            var inDocument = all?.Select(d => d.Components.Find(c => c.Id == id)).ToList();
            var everywhere = inDocument != null && inDocument.All(c => c != null);
            Action? remove = everywhere ? () => _shell.Edit($"Remove {title}", [.. ids!.Select(e => new RemoveComponent(e, id))]) : null;
            if (type == null || type.Fields.Length == 0)
            {
                tags.Add((title, remove));
                continue;
            }
            var editable = everywhere && !WorldWritten.Contains(id) && !(id == SceneEdits.TransformId && nodes.Any(n => n.Parent != 0));
            var owner = id.ToString("x16");
            var fields = type.Fields.Select(f =>
            {
                var editor = editable ? FieldEditor.ForComponent(_shell, ids!, id, f) : null;
                return FieldRow.Of(owner, f, editor,
                    editor != null ? () => inDocument!.Any(c => c!.Fields.Any(x => x.Name == f.Name)) : null,
                    () => editor?.Reset());
            });
            _content.Children.Add(Group(title, fields, remove: remove));
        }
        if (tags.Count > 0)
        {
            _content.Children.Add(Tags(tags));
        }
        if (all != null)
        {
            _content.Children.Add(AddComponentToMany(nodes, all));
        }
        ShowValues();
    }

    void ShowManyValues()
    {
        var values = _selection.Entities.Select(_world.Values).ToList();
        if (values.Any(v => v == null))
        {
            return;
        }
        ulong SceneIdOf(ulong handle) => _world.Find(handle)?.SceneId ?? 0;
        foreach (var (key, view) in _views)
        {
            if (key.Owner.StartsWith("behaviour:", StringComparison.Ordinal) || !ulong.TryParse(key.Owner, System.Globalization.NumberStyles.HexNumber, null, out var id)
                || _world.Type(id)?.Fields.FirstOrDefault(f => f.Name == key.Field) is not { } field)
            {
                continue;
            }
            var data = values.Select(v => v!.Components.FirstOrDefault(c => c.Id == id)?.Data).ToList();
            if (data.Any(d => d == null))
            {
                continue;
            }
            if (_editors.TryGetValue(key, out var editor))
            {
                for (var i = 0; i < data.Count; i++)
                {
                    editor.SetCurrent(i, FieldEditor.Read(field, data[i], SceneIdOf));
                }
            }
            view.Show(Mixed([.. data.Select(d => FieldValues.Display(field, d))]));
            if (field.HasOverride && data.All(d => field.OverrideOffset < d!.Length))
            {
                var flags = data.Select(d => d![(int)field.OverrideOffset] != 0).Distinct().ToList();
                ShowOverride(key, flags.Count == 1 ? flags[0] : null);
            }
        }
    }

    // The primary entity's display, with "—" where the entities differ.
    static FieldDisplay Mixed(List<FieldDisplay> displays)
    {
        var first = displays[^1];
        if (displays.All(d => d.Text == first.Text))
        {
            return first;
        }
        var axes = first.Axes.Select((a, i) => displays.All(d => i < d.Axes.Length && d.Axes[i] == a) ? a : "—").ToArray();
        return first with { Text = "—", Axes = axes, Tooltip = "The selected entities differ." };
    }

    Control ManyHeader(List<EntityNode> nodes, IReadOnlyList<SceneEntity>? documents)
    {
        var title = new TextBlock { Text = $"{nodes.Count} entities", Classes = { "title" } };
        ToolTip.SetTip(title, string.Join("\n", nodes.Select(n => n.Label)));
        var active = nodes.All(n => n.Active);
        var mixed = !active && nodes.Any(n => n.Active);
        var stateText = new TextBlock { Text = mixed ? "Mixed" : active ? "Active" : "Inactive" };
        Control state;
        if (documents != null)
        {
            var toggle = new Button { Classes = { "badge-button", active ? "active" : "inactive" }, Content = stateText, VerticalAlignment = VerticalAlignment.Center };
            ToolTip.SetTip(toggle, active ? "Deactivate the entities" : "Activate the entities");
            toggle.Click += (_, _) => _shell.Edit(active ? "Deactivate" : "Activate", [.. documents.Select(d => new SetActive(d.Id, !active))]);
            state = toggle;
        }
        else
        {
            state = new Border { Classes = { "badge", active ? "active" : "inactive" }, Child = stateText, VerticalAlignment = VerticalAlignment.Center };
        }
        var top = new DockPanel { Children = { state, title } };
        DockPanel.SetDock(state, Avalonia.Controls.Dock.Right);
        var header = new StackPanel { Classes = { "properties-header" }, Spacing = 4, Children = { top } };
        if (documents == null)
        {
            header.Children.Add(new TextBlock { Text = "The game spawned some of these entities, so the scene cannot edit them.", Classes = { "dim" }, TextWrapping = TextWrapping.Wrap });
        }
        return header;
    }

    // The component types that some selected entity lacks. Adding one gives it to each entity that lacks it.
    Control AddComponentToMany(List<EntityNode> nodes, IReadOnlyList<SceneEntity> documents)
    {
        var menu = new MenuFlyout();
        foreach (var type in _world.Types.Values.Where(t => nodes.Any(n => !n.Components.Contains(t.Id)) && !Derived.Contains(t.Id)).OrderBy(t => FieldValues.Humanize(t.Name)))
        {
            var item = new MenuItem { Header = FieldValues.Humanize(type.Name) };
            item.Click += (_, _) => _shell.Edit($"Add {FieldValues.Humanize(type.Name)}",
                [.. documents.Where((d, i) => !nodes[i].Components.Contains(type.Id))
                    .Select(d => new AddComponent(d.Id, new SceneComponent(type.Id, type.Name, DefaultFields(type.Id))))]);
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

    sealed record FieldRow(string Owner, string Field, DisplayKind Kind, bool IsEnum, FieldEditor? Editor, Func<bool>? IsSet, Action Reset)
    {
        /// <summary>For an asset field, the kind of asset that it takes ("" for any).</summary>
        public string AssetKind { get; init; } = "";

        /// <summary>For an Axes field, its number of boxes.</summary>
        public int Axes { get; init; } = 3;

        /// <summary>For a number, the range of its slider, from the game's editor:"range=min,max" tag.</summary>
        public (double Min, double Max)? Range { get; init; }

        /// <summary>A volume's setting: a check box says whether the volume overrides it, in place of the reset button.</summary>
        public bool HasOverride { get; init; }

        /// <summary>A component field's row, with what its field info says of how it shows.</summary>
        public static FieldRow Of(string owner, Link.Protocol.FieldInfo f, FieldEditor? editor, Func<bool>? isSet, Action reset) =>
            new(owner, f.Name, FieldValues.DisplayKindOf(f), f.Kind == Link.Protocol.FieldKind.Enum, editor, f.HasOverride ? null : isSet, reset)
            {
                AssetKind = f.AssetKind,
                Axes = f.Kind == Link.Protocol.FieldKind.Vector2 ? 2 : 3,
                Range = f.HasRange ? (f.RangeMin, f.RangeMax) : null,
                HasOverride = f.HasOverride,
            };
    }

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
            var view = FieldView.Create(field.Kind, _selection.Select, Label, field.Editor, field.IsEnum, new AssetContext(_shell.Assets, field.AssetKind, _shell.RevealAsset), field.Axes, field.Range);
            Control label = name;
            if (field.HasOverride)
            {
                label = OverrideLabel(field, name, view);
            }
            Grid.SetRow(label, row);
            Grid.SetRow(view.Control, row);
            Grid.SetColumn(view.Control, 1);
            rows.Children.Add(label);
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

    // A volume's setting: a check box before its name, ticked when the volume overrides it. Ticking it sets the field to
    // the value that shows, and clearing it resets the field, so the volumes below it give it. A setting that is not
    // overridden is dim.
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
                field.Editor.Reset();
            }
        };
        _overrides[(field.Owner, field.Field)] = entry;
        return new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Children = { check, name } };
    }

    // Shows whether a volume overrides a setting: null when the selected entities differ.
    void ShowOverride((string Owner, string Field) key, bool? overridden)
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

    // A behaviour that the scene names and the game does not run as it is: its script is gone from the content, or the
    // game did not attach it. The scene keeps it, with its values, so restoring the script brings it back.
    Control Unattached(SceneEntity? document, string script, SceneBehaviour? behaviour, string? worldTitle)
    {
        var missing = ScriptMissing(script);
        var asset = _shell.Assets.Find(script);
        var title = asset is { Behaviour: not "" } ? FieldValues.Humanize(asset.Behaviour) : worldTitle ?? "Missing Script";
        var text = missing
            ? $"Its script, {script}, is not in the content: it was deleted, or moved without its .meta file. Restore it, or remove the behaviour. A running game keeps it until the host restarts."
            : "The game did not attach it. The console says why.";
        var rows = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), Classes = { "fields" } };
        var fields = behaviour?.Fields ?? [];
        for (var i = 0; i < fields.Count; i++)
        {
            rows.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
            var name = new TextBlock { Text = FieldValues.Humanize(fields[i].Name), Classes = { "field-name" } };
            var value = new TextBlock { Text = SceneFile.FormatValue(fields[i].Value), Classes = { "dim" }, TextTrimming = TextTrimming.CharacterEllipsis };
            Grid.SetRow(name, i);
            Grid.SetRow(value, i);
            Grid.SetColumn(value, 1);
            rows.Children.Add(name);
            rows.Children.Add(value);
        }
        var content = new StackPanel
        {
            Spacing = 4,
            Children = { new TextBlock { Text = text, Classes = { "dim" }, TextWrapping = TextWrapping.Wrap }, rows },
        };
        return Expander(title, content, missing ? "Missing script" : "Not in game", disabled: true,
            remove: document != null && behaviour != null ? () => _shell.Edit($"Remove {title}", new RemoveBehaviour(document.Id, script)) : null);
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

    // The scripts that define a behaviour and that the entity lacks, from the cook daemon's index, in a menu that is
    // filled when it opens, so it has the scripts of the latest cook.
    Control AddBehaviourButton(SceneEntity document)
    {
        var menu = new MenuFlyout();
        menu.Opening += (_, _) =>
        {
            menu.Items.Clear();
            foreach (var script in _shell.Assets.Behaviours.Where(a => !document.Behaviours.Any(b => b.Script == a.Guid)))
            {
                var item = new MenuItem { Header = FieldValues.Humanize(script.Behaviour) };
                ToolTip.SetTip(item, $"{script.Root}/{script.Path}");
                var guid = script.Guid;
                item.Click += (_, _) => _shell.AddBehaviour([document.Id], guid);
                menu.Items.Add(item);
            }
            if (menu.Items.Count == 0)
            {
                var why = _shell.Assets.Roots.Count == 0 ? "The cook daemon lists the scripts once it runs" : "No other script defines a behaviour";
                menu.Items.Add(new MenuItem { Header = why, IsEnabled = false });
            }
        };
        return new Button
        {
            Content = "Add Behaviour",
            Flyout = menu,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Center,
            Classes = { "add-component" },
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
