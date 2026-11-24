using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using CommunityToolkit.Mvvm.Input;
using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Ribbon;
using Cinnabar.Editor.Shell;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// The outliner (see docs/editor/shell-and-panels.md#outliner): the entity hierarchy as a virtualized list of the visible rows,
/// indented by depth. A tree control with one item per entity would not scale to a large world. Dragging a row onto
/// another reparents it, and onto the empty space below the rows makes it a root. A row also drags onto an entity
/// field in the properties panel, and a script from the content browser drags onto a row to add its behaviour. Ctrl and Shift select more than one row. Each row of a scene entity has a toggle that
/// hides it in the viewport and one that locks it against picking, which apply to its descendants too. A row has an
/// icon for what its entity is, by its components, and the button beside the filter adds an entity of a common kind.
/// With several scenes open, each scene's entities are under a heading of their own, which makes the scene the active
/// one when clicked (see docs/editor/document-and-scenes.md#several-scenes).
/// </summary>
public sealed class OutlinerView : DockPanel
{
    // The components that the tree itself shows: the hierarchy, and activity by dimming.
    static readonly HashSet<string> Structural = ["Parent", "Previous_Transform", "Inactive", "Disabled", "Name", "Scene_Entity"];
    const double Indent = 14;

    readonly EditorShell _shell;
    readonly WorldModel _world;
    readonly Selection _selection;
    readonly TextBox _filter = new() { PlaceholderText = "Filter by name, entity or component", Classes = { "outliner-filter" } };
    readonly ListBox _list = new() { Classes = { "outliner" }, SelectionMode = SelectionMode.Multiple };
    readonly ComboBox _sublevel = new() { MinWidth = 70, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4, 0, 0, 0) };
    bool _syncingSublevels;
    readonly TextBlock _empty;
    bool _syncing;
    // The modifiers of the press or the key that last reached the list: with neither Ctrl nor Shift, a click or an
    // arrow replaces the selection.
    KeyModifiers _modifiers;
    // The press that may start a drag, and the row it is on.
    PointerPressedEventArgs? _press;
    OutlinerRow? _pressedRow;

    internal ViewSubscriptions Subscriptions { get; }

    /// <summary>The rows that the list shows: entities' rows, and with several scenes open, the scenes' headings.</summary>
    internal IReadOnlyList<object> Rows => _list.ItemsSource as List<object> ?? [];

    public OutlinerView(EditorShell shell)
    {
        _shell = shell;
        _world = shell.World;
        _selection = shell.Selection;
        // The Add menu (see docs/editor/shell-and-panels.md#add), which reads each kind's state as it opens.
        var addMenu = new LiveMenu();
        MenuBuilder.Build(addMenu.Items, DefaultRibbon.AddMenu(), _shell.Commands, _shell.KeyBindings, addMenu);
        var add = new Button { Content = CommandViews.Icon("add", 14), Classes = { "outliner-add" }, Flyout = addMenu.Flyout, VerticalAlignment = VerticalAlignment.Center };
        ToolTip.SetTip(add, "Add\nAdd an entity of a common kind, ready to use: a light, a camera, a volume, a sound.");
        Avalonia.Automation.AutomationProperties.SetName(add, "Add");
        var top = new DockPanel();
        SetDock(add, DockSide.Right);
        top.Children.Add(add);
        // The sublevel that the rows show (see docs/editor/shell-and-panels.md#outliner).
        ToolTip.SetTip(_sublevel, "Show the entities of one sublevel, or of the base, with their ancestors");
        Avalonia.Automation.AutomationProperties.SetName(_sublevel, "Sublevel");
        _sublevel.SelectionChanged += (_, _) =>
        {
            if (!_syncingSublevels)
            {
                _shell.Outliner.Sublevel = _sublevel.SelectedItem is SublevelChoice choice ? choice.Sublevel : null;
                Rebuild();
            }
        };
        SetDock(_sublevel, DockSide.Right);
        top.Children.Add(_sublevel);
        top.Children.Add(_filter);
        SetDock(top, DockSide.Top);
        Children.Add(top);
        _empty = new TextBlock
        {
            Text = "The world's entities appear here when the editor link connects to the host.",
            Classes = { "empty" },
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = TextAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            MaxWidth = 240,
            Margin = new Thickness(16),
        };
        Children.Add(new Panel { Children = { _list, _empty } });
        // A drop below the rows, on the list itself, makes the entity a root.
        DragDrop.SetAllowDrop(_list, true);
        // A prefab from the content browser dropped there makes an instance at the root.
        _list.AddHandler(DragDrop.DragOverEvent, (_, e) => e.DragEffects = DroppedPrefabs(e).Count > 0 ? DragDropEffects.Copy : CanDrop(e, null) ? DragDropEffects.Move : DragDropEffects.None);
        _list.AddHandler(DragDrop.DropEvent, (_, e) =>
        {
            if (DroppedPrefabs(e) is { Count: > 0 } prefabs)
            {
                CreateInstances(prefabs, 0, e);
                return;
            }
            Drop(e, null);
        });

        _list.ItemTemplate = new FuncDataTemplate<object>((item, _) => item switch
        {
            OutlinerRow row => RowView(row),
            OutlinerHeading heading => HeadingView(heading),
            OutlinerDocumentRow unloaded => UnloadedView(unloaded),
            _ => new Control(),
        });
        _list.AddHandler(PointerPressedEvent, (_, e) => _modifiers = e.KeyModifiers, Avalonia.Interactivity.RoutingStrategies.Tunnel, handledEventsToo: true);
        _list.AddHandler(KeyDownEvent, (_, e) => _modifiers = e.KeyModifiers, Avalonia.Interactivity.RoutingStrategies.Tunnel, handledEventsToo: true);
        // The rows that a click adds come last, so the one clicked is the primary entity. With Ctrl or Shift, the
        // selected entities that have no row, which a filter or a collapsed parent hides, stay selected. Without, the
        // rows that the list has selected are the selection: a plain click on a row selects that row alone, as it
        // looks, and nothing that does not show stays for Delete to take.
        _list.SelectionChanged += (_, e) =>
        {
            if (_syncing)
            {
                return;
            }
            // A scene's heading is not an entity: a click on it makes its scene the active one, and it does not stay
            // selected.
            if (e.AddedItems.OfType<OutlinerHeading>().LastOrDefault() is { } heading)
            {
                _syncing = true;
                foreach (var h in _list.SelectedItems?.OfType<OutlinerHeading>().ToList() ?? [])
                {
                    _list.SelectedItems!.Remove(h);
                }
                _syncing = false;
                _shell.ActivateScene(heading.Scene);
                if ((_modifiers & (KeyModifiers.Control | KeyModifiers.Shift)) == 0)
                {
                    _selection.Set([]);
                }
                return;
            }
            // An entity of a sublevel that is not loaded has no handle to select.
            if (e.AddedItems.OfType<OutlinerDocumentRow>().Any())
            {
                _syncing = true;
                foreach (var u in _list.SelectedItems?.OfType<OutlinerDocumentRow>().ToList() ?? [])
                {
                    _list.SelectedItems!.Remove(u);
                }
                _syncing = false;
                return;
            }
            var removed = e.RemovedItems.OfType<OutlinerRow>().Select(r => r.Node.Handle).ToList();
            var added = e.AddedItems.OfType<OutlinerRow>().Select(r => r.Node.Handle).ToList();
            if ((_modifiers & (KeyModifiers.Control | KeyModifiers.Shift)) == 0)
            {
                var rows = (_list.SelectedItems?.OfType<OutlinerRow>() ?? []).Select(r => r.Node.Handle).ToList();
                _selection.Set([.. rows.Except(added), .. added]);
                return;
            }
            _selection.Set([.. _selection.Entities.Except(removed).Except(added), .. added]);
        };
        _filter.TextChanged += (_, _) => Rebuild();

        Subscriptions = new ViewSubscriptions(this, attached: Rebuild)
            .Add(() => _world.EntitiesChanged += Rebuild, () => _world.EntitiesChanged -= Rebuild)
            .Add(() => _world.TypesChanged += Rebuild, () => _world.TypesChanged -= Rebuild)
            .Add(() => _selection.Changed += OnSelectionChanged, () => _selection.Changed -= OnSelectionChanged)
            .Add(() => _shell.ProblemsChanged += Rebuild, () => _shell.ProblemsChanged -= Rebuild)
            .Add(() => _shell.VisibilityChanged += Rebuild, () => _shell.VisibilityChanged -= Rebuild)
            .Add(() => _shell.SceneChanged += OnScenesChanged, () => _shell.SceneChanged -= OnScenesChanged)
            .Add(() => _shell.SublevelsChanged += Rebuild, () => _shell.SublevelsChanged -= Rebuild)
            .Add(() => _world.OverriddenChanged += Rebuild, () => _world.OverriddenChanged -= Rebuild);
    }

    // The headings show which scene is active and which are dirty, which edits change without a change of the world.
    string _scenesShown = "";

    void OnScenesChanged()
    {
        var shown = ScenesShown();
        if (shown != _scenesShown)
        {
            Rebuild();
        }
    }

    void Rebuild()
    {
        _empty.IsVisible = !_world.HasWorld;
        var filter = _filter.Text?.Trim() ?? "";
        var rows = new List<object>();
        var scenes = _shell.Scenes;
        _scenesShown = ScenesShown();
        SyncSublevelChoices();
        var sublevel = _shell.Outliner.Sublevel;
        if (scenes.Count > 1)
        {
            // Each open scene's entities under its heading, then what no open scene made, as the game's own.
            foreach (var scene in scenes)
            {
                var collapsed = _shell.Outliner.IsCollapsed(scene);
                rows.Add(new OutlinerHeading(scene, scene == _shell.Scene, !collapsed));
                if (collapsed && filter.Length == 0)
                {
                    continue;
                }
                foreach (var root in _world.Roots.Where(r => r.SceneId != 0 && r.Scene == scene.Number))
                {
                    Add(rows, root, 0, filter, sublevel);
                }
                AddUnloaded(rows, scene, filter, sublevel);
            }
            foreach (var root in _world.Roots.Where(r => r.SceneId == 0 || _shell.SceneOf(r) == null))
            {
                Add(rows, root, 0, filter, sublevel);
            }
        }
        else
        {
            foreach (var root in _world.Roots)
            {
                Add(rows, root, 0, filter, sublevel);
            }
            if (scenes.Count == 1)
            {
                AddUnloaded(rows, scenes[0], filter, sublevel);
            }
        }
        _syncing = true;
        _list.ItemsSource = rows;
        _syncing = false;
        ShowSelection(false);
    }

    void ShowSelection(bool scroll)
    {
        if (_list.ItemsSource is not List<object> items || _list.SelectedItems is not { } selected)
        {
            return;
        }
        var rows = items.OfType<OutlinerRow>().ToList();
        // When the list's rows are the selection's already, as after a change that the list made itself, they stay as
        // they are: selecting them again would move the list's anchor to the last of them, and the next Shift click
        // would range from there and not from the row that the user clicked first.
        var wanted = rows.Where(r => _selection.Contains(r.Node.Handle)).ToList();
        if (!wanted.Cast<object>().ToHashSet().SetEquals(selected.OfType<object>()))
        {
            _syncing = true;
            selected.Clear();
            foreach (var row in wanted)
            {
                selected.Add(row);
            }
            _syncing = false;
        }
        if (scroll && rows.FirstOrDefault(r => r.Node.Handle == _selection.Entity) is { } primary)
        {
            _list.ScrollIntoView(primary);
        }
    }

    // What the scenes' headings and the dimmed rows show, which edits change without a change of the world: an
    // assignment to a sublevel that is not loaded takes an entity out of the world and adds a dimmed row.
    string ScenesShown() => string.Join("|", _shell.Scenes.Select(s => $"{s.Number}:{s.Title}:{s.IsDirty}:{s == _shell.Scene}:{s.Position}"));

    // The sublevel box's choices: every sublevel, the base, and each sublevel that the project declares or the open
    // scenes use. A chosen sublevel that is gone goes back to every sublevel.
    void SyncSublevelChoices()
    {
        var choices = new List<SublevelChoice> { new("All sublevels", null), new("Base", "") };
        choices.AddRange(_shell.KnownSublevels().Select(name => new SublevelChoice(name, name)));
        if (choices.All(c => c.Sublevel != _shell.Outliner.Sublevel))
        {
            _shell.Outliner.Sublevel = null;
        }
        _syncingSublevels = true;
        if (_sublevel.ItemsSource is not List<SublevelChoice> shown || !shown.SequenceEqual(choices))
        {
            _sublevel.ItemsSource = choices;
        }
        _sublevel.SelectedItem = ((List<SublevelChoice>)_sublevel.ItemsSource!).First(c => c.Sublevel == _shell.Outliner.Sublevel);
        _syncingSublevels = false;
    }

    // Adds the entities of a scene that are in a sublevel that the game's world does not have, dimmed, after the
    // scene's other rows. They have no handle, so they are not selected and the viewport does not pick them.
    void AddUnloaded(List<object> rows, SceneDocument scene, string filter, string? sublevel)
    {
        var flat = scene.Expanded.Flat;
        var children = flat.Entities.Where(e => e.Parent != 0).ToLookup(e => e.Parent);
        foreach (var root in flat.Entities.Where(e => e.Parent == 0 && !_shell.IsSublevelLoaded(flat.SublevelOf(e))))
        {
            AddUnloaded(rows, scene, children, root, flat.SublevelOf(root), 0, filter, sublevel);
        }
    }

    bool AddUnloaded(List<object> rows, SceneDocument scene, ILookup<ulong, SceneEntity> children, SceneEntity entity, string inSublevel, int depth, string filter, string? sublevel)
    {
        var label = entity.Name.Length > 0 ? entity.Name : $"{entity.Id:x16}";
        var summary = string.Join(", ", entity.Components.Select(c => c.Name).Where(n => !Structural.Contains(n)).Select(FieldValues.Humanize));
        var hasChildren = children[entity.Id].Any();
        var row = new OutlinerDocumentRow(scene, entity, depth, label, summary, inSublevel, hasChildren, !_shell.Outliner.IsCollapsed(scene.Number, entity.Id));
        var at = rows.Count;
        rows.Add(row);
        var filtering = filter.Length > 0 || sublevel != null;
        var matches = (sublevel == null || sublevel == inSublevel)
            && (filter.Length == 0 || label.Contains(filter, StringComparison.OrdinalIgnoreCase) || summary.Contains(filter, StringComparison.OrdinalIgnoreCase));
        var childMatches = false;
        if (row.Expanded || filtering)
        {
            foreach (var child in children[entity.Id])
            {
                childMatches |= AddUnloaded(rows, scene, children, child, inSublevel, depth + 1, filter, sublevel);
            }
        }
        if (filtering && !matches && !childMatches)
        {
            rows.RemoveAt(at);
        }
        return matches || childMatches;
    }

    // Adds a node and its visible descendants, and returns whether the node or one of them matches the filter and the
    // sublevel. With either, a match shows with its ancestors, expanded or not.
    bool Add(List<object> rows, EntityNode node, int depth, string filter, string? sublevel)
    {
        var summary = string.Join(", ", node.Components.Select(_world.TypeName).Where(n => !Structural.Contains(n)).Select(FieldValues.Humanize));
        var label = node.Label;
        var row = new OutlinerRow(node, depth, label, summary, node.Children.Count > 0, !_shell.Outliner.IsCollapsed(node));
        var at = rows.Count;
        rows.Add(row);
        var filtering = filter.Length > 0 || sublevel != null;
        var matches = (sublevel == null || _shell.SublevelOf(node) == sublevel) && (filter.Length == 0
            || label.Contains(filter, StringComparison.OrdinalIgnoreCase)
            || node.ToString().Contains(filter, StringComparison.OrdinalIgnoreCase)
            || summary.Contains(filter, StringComparison.OrdinalIgnoreCase)
            || _shell.InstanceOf(node) is { Prefab: not "" } instance && _shell.PrefabName(instance.Prefab).Contains(filter, StringComparison.OrdinalIgnoreCase));
        var childMatches = false;
        if (row.Expanded || filtering)
        {
            foreach (var child in node.Children)
            {
                childMatches |= Add(rows, child, depth + 1, filter, sublevel);
            }
        }
        if (filtering && !matches && !childMatches)
        {
            rows.RemoveAt(at);
        }
        return matches || childMatches;
    }

    void OnSelectionChanged(IReadOnlyList<ulong> old, IReadOnlyList<ulong> entities) => ShowSelection(true);

    Control RowView(OutlinerRow row)
    {
        var expander = new TextBlock
        {
            Text = row.HasChildren ? (row.Expanded ? "▾" : "▸") : "",
            Width = 14,
            Classes = { "dim" },
            Cursor = row.HasChildren ? new Cursor(StandardCursorType.Hand) : Cursor.Default,
        };
        if (row.HasChildren)
        {
            expander.PointerPressed += (_, e) =>
            {
                _shell.Outliner.Toggle(row.Node);
                e.Handled = true;
                Rebuild();
            };
        }
        var hiddenInTree = _shell.IsHiddenInTree(row.Node.Handle);
        var content = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(row.Depth * Indent, 0, 0, 0),
            Spacing = 6,
            Opacity = row.Node.Active && !hiddenInTree ? 1 : 0.45,
            // A long summary ends under the toggles, not over them.
            ClipToBounds = true,
            Children =
            {
                expander,
                new TextBlock { Text = row.Label },
                new TextBlock { Text = row.Summary, Classes = { "dim" } },
            },
        };
        // What the entity is, by its components, so that a light or a camera is found in a long list at a glance.
        Control kind = new Control { Width = 13 };
        if (CommandViews.Icon(EntityIcons.For(row.Node.Components.Select(_world.TypeName)), 13) is { } icon)
        {
            icon.Opacity = 0.75;
            kind = icon;
        }
        content.Children.Insert(1, kind);
        var view = new DockPanel { Background = Brushes.Transparent };
        if (row.Node.SceneId != 0)
        {
            var node = row.Node;
            var lockButton = Toggle(_shell.IsLocked(node), "locked", "unlocked",
                _shell.IsLocked(node) ? "Let the viewport select this entity" : "Stop the viewport from selecting this entity and its children",
                () => _shell.SetLocked(node, !_shell.IsLocked(node)));
            var eyeButton = Toggle(_shell.IsHidden(node), "hidden", "visible",
                _shell.IsHidden(node) ? "Show this entity in the viewport" : "Hide this entity and its children in the viewport",
                () => _shell.SetHidden(node, !_shell.IsHidden(node)));
            SetDock(lockButton, DockSide.Right);
            SetDock(eyeButton, DockSide.Right);
            view.Children.Add(lockButton);
            view.Children.Add(eyeButton);
        }
        view.Children.Add(content);
        Mark(content, row.Node);
        if (OverrideMark(row.Node) is { } held)
        {
            content.Children.Add(held);
        }
        if (_shell.ProblemsOf(row.Node) is { Count: > 0 } problems)
        {
            var warning = new TextBlock { Text = "⚠", Classes = { "warning" } };
            ToolTip.SetTip(warning, string.Join("\n", problems));
            content.Children.Insert(1, warning);
        }
        view.PointerPressed += (_, e) =>
        {
            if (e.GetCurrentPoint(view).Properties.IsLeftButtonPressed && row.Node.SceneId != 0)
            {
                _press = e;
                _pressedRow = row;
            }
        };
        view.PointerMoved += async (_, e) =>
        {
            if (_press is not { } press || _pressedRow != row)
            {
                return;
            }
            var moved = e.GetPosition(view) - press.GetPosition(view);
            if (!Gestures.MovedPastAcrossAndDown(moved))
            {
                return;
            }
            _press = null;
            var data = new DataTransfer();
            data.Add(DataTransferItem.Create(EntityView.EntityFormat, row.Node.Handle.ToString()));
            await DragDrop.DoDragDropAsync(press, data, DragDropEffects.Move | DragDropEffects.Link);
        };
        view.PointerReleased += (_, _) => _press = null;
        // A double click frames the entity in the viewport. The first click selected it.
        view.DoubleTapped += (_, e) =>
        {
            _press = null;
            if (!_selection.Contains(row.Node.Handle))
            {
                _selection.Select(row.Node.Handle);
            }
            _shell.Commands.Get(EditorCommands.FrameSelected).Execute();
            e.Handled = true;
        };
        DragDrop.SetAllowDrop(view, true);
        view.AddHandler(DragDrop.DragOverEvent, (_, e) =>
        {
            // A prefab from the content browser makes an instance under the entity; a script adds its behaviour.
            if (DroppedPrefabs(e).Count > 0)
            {
                e.DragEffects = row.Node.SceneId != 0 ? DragDropEffects.Copy : DragDropEffects.None;
            }
            else if (ContentBrowserView.Dropped(e) is { } script)
            {
                // Another scene's row becomes active at the drop, which then checks the behaviour.
                e.DragEffects = !_shell.InActiveScene(row.Node) && row.Node.SceneId != 0 || _shell.CanAddBehaviour([row.Node.SceneId], script)
                    ? DragDropEffects.Link : DragDropEffects.None;
            }
            else
            {
                e.DragEffects = CanDrop(e, row.Node) ? DragDropEffects.Move : DragDropEffects.None;
            }
            e.Handled = true;
        });
        view.AddHandler(DragDrop.DropEvent, (_, e) =>
        {
            // A drop edits the row's scene, which becomes the active one.
            if (_shell.SceneOf(row.Node) is { } scene && (DroppedPrefabs(e).Count > 0 || ContentBrowserView.Dropped(e) != null))
            {
                _shell.ActivateScene(scene);
            }
            if (DroppedPrefabs(e) is { Count: > 0 } prefabs)
            {
                CreateInstances(prefabs, row.Node.SceneId, e);
            }
            else if (ContentBrowserView.Dropped(e) is { } script)
            {
                _shell.AddBehaviour([row.Node.SceneId], script);
            }
            else
            {
                Drop(e, row.Node);
            }
            e.Handled = true;
        });
        view.ContextMenu = RowMenu(row);
        return view;
    }

    // What a drag can place: the parts of prefabs that it holds, or the prefab of the asset that it holds first.
    IReadOnlyList<(string Prefab, ulong Node)> DroppedPrefabs(DragEventArgs e)
    {
        if (!_shell.IsEditing || _shell.Scene == null)
        {
            return [];
        }
        if (ContentBrowserView.DroppedParts(e) is { Count: > 0 } parts)
        {
            return parts;
        }
        return ContentBrowserView.Dropped(e) is { } guid && _shell.PrefabToPlace(guid) is { } prefab ? [(prefab, 0)] : [];
    }

    // Alt makes plain entities of what the drag places.
    void CreateInstances(IReadOnlyList<(string Prefab, ulong Node)> prefabs, ulong parent, DragEventArgs e)
    {
        foreach (var (prefab, node) in prefabs)
        {
            _shell.CreateInstance(prefab, parent, node, e.KeyModifiers.HasFlag(KeyModifiers.Alt));
        }
    }

    // An entity of the active scene can go under any entity of its scene that is not itself or one of its descendants,
    // or to the root, which is no target. An entity does not move to another scene.
    bool CanDrop(DragEventArgs e, EntityNode? target) =>
        _world.Find(EntityView.Dropped(e)) is { } dragged && _shell.CanReparent(dragged, target, out _);

    void Drop(DragEventArgs e, EntityNode? target)
    {
        if (_world.Find(EntityView.Dropped(e)) is not { } dragged)
        {
            return;
        }
        if (_shell.CanReparent(dragged, target, out var reason))
        {
            _shell.Reparent(dragged.SceneId, target?.SceneId ?? 0);
        }
        else if (reason != "")
        {
            _shell.Console.Add(LogLevel.Warning, $"edit: {reason}");
        }
    }

    // An entity that an override writes, or spawned, has a mark after its name (see docs/editor/link.md#overrides).
    internal TextBlock? OverrideMark(EntityNode node)
    {
        if (!_world.IsOverridden(node.Handle))
        {
            return null;
        }
        var mark = new TextBlock { Text = "◆", Classes = { "held" } };
        ToolTip.SetTip(mark, node.SceneId == 0 ? "A preview spawned this entity in the world" : "A preview writes over this entity in the world, which shows other values than the scene's");
        return mark;
    }

    // An instance's root has the prefab's icon before its name; an entity of an instance with overrides a dot after
    // it; and one that the scene added to an instance a plus. Each entity is its own scene's.
    void Mark(StackPanel content, EntityNode node)
    {
        if (_shell.SceneOf(node) is not { } scene)
        {
            return;
        }
        var id = node.SceneId;
        var instance = scene.Expanded.InstanceOf(id);
        if (instance is { Prefab: not "" } && CommandViews.Icon("prefab", 12) is { } icon)
        {
            icon.Classes.Add("prefab");
            ToolTip.SetTip(icon, $"{(scene.Scene.Find(id)?.Node is not (null or 0) ? "A part of" : "An instance of")} {_shell.PrefabName(instance.Prefab)}");
            content.Children.Insert(1, icon);
        }
        TextBlock? mark = null;
        if (instance is { IsInstanceRoot: false } && EditorShell.IsOverridden(scene, id))
        {
            mark = new TextBlock { Text = "•", Classes = { "prefab" } };
            ToolTip.SetTip(mark, "Overrides its prefab");
        }
        else if (instance == null && EditorShell.IsAddedToInstance(scene, id))
        {
            mark = new TextBlock { Text = "+", Classes = { "prefab" } };
            ToolTip.SetTip(mark, "Added to the instance, not in its prefab");
        }
        if (mark != null)
        {
            var name = content.Children.OfType<TextBlock>().First(t => t.Text != "" && !t.Classes.Contains("dim"));
            content.Children.Insert(content.Children.IndexOf(name) + 1, mark);
        }
        if (SublevelTag(scene.Expanded.Flat, id) is { } tag)
        {
            content.Children.Insert(content.Children.Count - 1, tag);
        }
    }

    // A root in a sublevel has the sublevel's name as a tag. Its descendants are in it too, so they have none.
    static Border? SublevelTag(Scene flat, ulong id)
    {
        if (flat.Find(id) is not { } entity || flat.SublevelOf(entity) is not { Length: > 0 } sublevel
            || entity.Parent != 0 && flat.Find(entity.Parent) is { } parent && flat.SublevelOf(parent) == sublevel)
        {
            return null;
        }
        var tag = new Border { Classes = { "badge", "tag" }, VerticalAlignment = VerticalAlignment.Center, Child = new TextBlock { Text = sublevel, FontSize = 10 } };
        ToolTip.SetTip(tag, $"In the {sublevel} sublevel, with its descendants");
        return tag;
    }

    // An entity of a sublevel that the game's world does not have: dimmed, with no toggles, and a menu that loads it.
    Control UnloadedView(OutlinerDocumentRow row)
    {
        var expander = new TextBlock
        {
            Text = row.HasChildren ? (row.Expanded ? "▾" : "▸") : "",
            Width = 14,
            Classes = { "dim" },
            Cursor = row.HasChildren ? new Cursor(StandardCursorType.Hand) : Cursor.Default,
        };
        if (row.HasChildren)
        {
            expander.PointerPressed += (_, e) =>
            {
                _shell.Outliner.Toggle(row.Scene.Number, row.Entity.Id);
                e.Handled = true;
                Rebuild();
            };
        }
        var content = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(row.Depth * Indent, 0, 0, 0),
            Spacing = 6,
            Opacity = 0.45,
            ClipToBounds = true,
            Background = Brushes.Transparent,
            Children = { expander, new Control { Width = 13 }, new TextBlock { Text = row.Label }, new TextBlock { Text = row.Summary, Classes = { "dim" } } },
        };
        if (SublevelTag(row.Scene.Expanded.Flat, row.Entity.Id) is { } tag)
        {
            content.Children.Insert(3, tag);
        }
        ToolTip.SetTip(content, _shell.IsEditing
            ? $"In {row.Sublevel}, which Edit does not load. Load it to select or edit this entity."
            : $"In {row.Sublevel}, which the project's active set does not have, so Play has not loaded it.");
        var menu = new ContextMenu();
        menu.Items.Add(new MenuItem
        {
            Header = $"Load {row.Sublevel}",
            IsEnabled = _shell.IsEditing,
            Command = new RelayCommand(() => _shell.SetSublevelLoaded(row.Sublevel, true)),
        });
        content.ContextMenu = menu;
        return content;
    }

    // A row's menu, which fills as it opens: a list realizes many rows, and few of their menus ever show.
    ContextMenu? RowMenu(OutlinerRow row)
    {
        if (row.Node.SceneId == 0)
        {
            return null;
        }
        var menu = new ContextMenu();
        menu.Opening += (_, _) =>
        {
            // A right click does not move the keyboard, so the menu takes it to the outliner: its Delete and Duplicate
            // then act on the entities, not on a graph or a timeline that had the keyboard (see
            // docs/editor/shell-and-panels.md#commands).
            _list.Focus();
            // A row's menu acts on the selection when the row is in it, and on the row alone otherwise, so a row that
            // is not selected becomes the selection as its menu opens, and the items show what they can do to it.
            if (!_selection.Contains(row.Node.Handle))
            {
                _selection.Select(row.Node.Handle);
            }
            menu.Items.Clear();
            FillRowMenu(menu, row);
        };
        // An empty menu does not open, so it has a first item before it ever does.
        menu.Items.Add(new MenuItem { Header = "Focus" });
        return menu;
    }

    void FillRowMenu(ContextMenu menu, OutlinerRow row)
    {
        void Commands(params MenuEntry[] entries) =>
            MenuBuilder.Build(menu.Items, entries, _shell.Commands, _shell.KeyBindings, MenuBinding.Snapshot);
        Commands(
            new MenuCommand(EditorCommands.FrameSelected, Label: "Focus"),
            new MenuSeparator(),
            EditorCommands.DuplicateEntity,
            EditorCommands.DeleteEntity,
            new MenuSeparator());
        // The kinds of the Add menu, each of which goes where this row's entity is: the row alone is selected first,
        // since a new entity goes where the primary entity of the selection is.
        var add = new MenuItem { Header = "Add Here", Icon = CommandViews.Icon("add", 14) };
        MenuBuilder.Build(add.Items, DefaultRibbon.AddMenu(), _shell.Commands, _shell.KeyBindings, MenuBinding.Snapshot,
            () => _selection.Select(row.Node.Handle));
        menu.Items.Add(add);
        if (row.Node.Parent != 0)
        {
            menu.Items.Add(new MenuItem
            {
                Header = "Move to Root",
                Command = new RelayCommand(() => _shell.Reparent(row.Node.SceneId, 0)),
            });
        }
        // The sublevels that the selection can go to, with the row's own checked (see docs/editor/shell-and-panels.md#sublevels).
        var current = _shell.SublevelOf(row.Node);
        var sublevels = new MenuItem { Header = "Sublevel", IsEnabled = _shell.IsEditing };
        foreach (var name in _shell.KnownSublevels().Prepend(""))
        {
            sublevels.Items.Add(new MenuItem
            {
                Header = name == "" ? "Base" : name,
                ToggleType = MenuItemToggleType.Radio,
                IsChecked = name == current,
                Command = new RelayCommand(() => _shell.AssignSublevel(name)),
            });
        }
        menu.Items.Add(sublevels);
        menu.Items.Add(new Separator());
        if (_shell.InstanceOf(row.Node) is { } instance)
        {
            Commands(
                EditorCommands.OpenPrefab,
                EditorCommands.SelectPrefabAsset,
                EditorCommands.ApplyAllPrefab,
                EditorCommands.RevertAllPrefab);
            if (instance.IsInstanceRoot)
            {
                Commands(
                    EditorCommands.MakeVariant,
                    EditorCommands.UnpackPrefab,
                    EditorCommands.UnpackPrefabCompletely);
            }
        }
        else
        {
            Commands(EditorCommands.MakePrefab);
        }
        Commands(
            new MenuSeparator(),
            new MenuCommand(EditorCommands.HideSelected, Label: "Hide or Show"),
            new MenuCommand(EditorCommands.LockSelected, Label: "Lock or Unlock"));
    }

    // A scene's heading, with several scenes open: its file's name, a dot while it is dirty, and the active scene in
    // bold. Its menu makes it active, saves it or closes it.
    Control HeadingView(OutlinerHeading heading)
    {
        var scene = heading.Scene;
        var expander = new TextBlock { Text = heading.Expanded ? "▾" : "▸", Width = 14, Classes = { "dim" }, Cursor = new Cursor(StandardCursorType.Hand) };
        expander.PointerPressed += (_, e) =>
        {
            _shell.Outliner.Toggle(scene);
            e.Handled = true;
            Rebuild();
        };
        var title = new TextBlock
        {
            Text = scene.Title + (scene.IsDirty ? " •" : ""),
            FontWeight = heading.Active ? FontWeight.Bold : FontWeight.Normal,
        };
        var view = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            Background = Brushes.Transparent,
            Children = { expander, title },
        };
        if (heading.Active)
        {
            view.Children.Add(new TextBlock { Text = "active", Classes = { "dim" } });
        }
        ToolTip.SetTip(view, heading.Active
            ? $"{scene.Path}\nThe active scene: edits, undo and save act on it."
            : $"{scene.Path}\nClick to make it the active scene, which edits, undo and save act on.");
        var menu = new ContextMenu();
        menu.Items.Add(new MenuItem { Header = "Make Active", IsEnabled = !heading.Active, Command = new RelayCommand(() => _shell.ActivateScene(scene)) });
        menu.Items.Add(new MenuItem
        {
            Header = "Save",
            IsEnabled = _shell.OpenEdit == null,
            Command = new RelayCommand(() => _shell.SaveScene(scene)),
        });
        // Save is this scene's, not the Save command's, which the active editor's tab takes first.
        MenuBuilder.Build(menu.Items, [new MenuCommand(EditorCommands.CloseScene, () => _shell.ActivateScene(scene))],
            _shell.Commands, _shell.KeyBindings, MenuBinding.Snapshot);
        view.ContextMenu = menu;
        return view;
    }

    // A row's toggle: bright while it is on, and faint while it is off, so the rows that are hidden or locked stand out.
    static Button Toggle(bool on, string onIcon, string offIcon, string tip, Action toggle)
    {
        var button = new Button
        {
            Content = CommandViews.Icon(on ? onIcon : offIcon, 14),
            Classes = { "outliner-toggle" },
            Opacity = on ? 1 : 0.3,
            Focusable = false,
            VerticalAlignment = VerticalAlignment.Center,
        };
        ToolTip.SetTip(button, tip);
        button.Click += (_, e) =>
        {
            toggle();
            e.Handled = true;
        };
        return button;
    }
}

public sealed record OutlinerRow(EntityNode Node, int Depth, string Label, string Summary, bool HasChildren, bool Expanded);

/// <summary>
/// An entity of an open scene in a sublevel that the game's world does not have, from the document, as the outliner
/// shows it dimmed: it has no handle.
/// </summary>
public sealed record OutlinerDocumentRow(SceneDocument Scene, SceneEntity Entity, int Depth, string Label, string Summary, string Sublevel, bool HasChildren, bool Expanded);

/// <summary>A choice of the outliner's sublevel box: null shows every sublevel, and "" the base.</summary>
public sealed record SublevelChoice(string Label, string? Sublevel)
{
    public override string ToString() => Label;
}

/// <summary>An open scene's heading in the outliner, with several scenes open.</summary>
public sealed record OutlinerHeading(SceneDocument Scene, bool Active, bool Expanded);
