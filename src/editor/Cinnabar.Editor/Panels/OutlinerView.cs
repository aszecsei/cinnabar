using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using CommunityToolkit.Mvvm.Input;
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
/// hides it in the viewport and one that locks it against picking, which apply to its descendants too.
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
    readonly TextBlock _empty;
    // Rows start expanded. The set holds the ones that the user collapsed.
    readonly HashSet<ulong> _collapsed = [];
    bool _syncing;
    // The press that may start a drag, and the row it is on.
    PointerPressedEventArgs? _press;
    OutlinerRow? _pressedRow;

    public OutlinerView(EditorShell shell)
    {
        _shell = shell;
        _world = shell.World;
        _selection = shell.Selection;
        SetDock(_filter, DockSide.Top);
        Children.Add(_filter);
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
        _list.AddHandler(DragDrop.DragOverEvent, (_, e) => e.DragEffects = DroppedPrefab(e) != null ? DragDropEffects.Copy : CanDrop(e, 0) ? DragDropEffects.Move : DragDropEffects.None);
        _list.AddHandler(DragDrop.DropEvent, (_, e) =>
        {
            if (DroppedPrefab(e) is { } prefab)
            {
                _shell.CreateInstance(prefab, 0);
                return;
            }
            Drop(e, 0);
        });

        _list.ItemTemplate = new FuncDataTemplate<OutlinerRow>((row, _) => row == null ? new Control() : RowView(row));
        // The rows that a click adds come last, so the one clicked is the primary entity. Entities that the filter hides
        // stay selected.
        _list.SelectionChanged += (_, e) =>
        {
            if (_syncing)
            {
                return;
            }
            var removed = e.RemovedItems.OfType<OutlinerRow>().Select(r => r.Node.Handle).ToList();
            var added = e.AddedItems.OfType<OutlinerRow>().Select(r => r.Node.Handle).ToList();
            _selection.Set([.. _selection.Entities.Except(removed).Except(added), .. added]);
        };
        _filter.TextChanged += (_, _) => Rebuild();

        new ViewSubscriptions(this, attached: Rebuild)
            .Add(() => _world.EntitiesChanged += Rebuild, () => _world.EntitiesChanged -= Rebuild)
            .Add(() => _world.TypesChanged += Rebuild, () => _world.TypesChanged -= Rebuild)
            .Add(() => _selection.Changed += OnSelectionChanged, () => _selection.Changed -= OnSelectionChanged)
            .Add(() => _shell.ProblemsChanged += Rebuild, () => _shell.ProblemsChanged -= Rebuild)
            .Add(() => _shell.VisibilityChanged += Rebuild, () => _shell.VisibilityChanged -= Rebuild);
    }

    void Rebuild()
    {
        _empty.IsVisible = !_world.HasWorld;
        var filter = _filter.Text?.Trim() ?? "";
        var rows = new List<OutlinerRow>();
        foreach (var root in _world.Roots)
        {
            Add(rows, root, 0, filter);
        }
        _syncing = true;
        _list.ItemsSource = rows;
        _syncing = false;
        ShowSelection(false);
    }

    void ShowSelection(bool scroll)
    {
        if (_list.ItemsSource is not List<OutlinerRow> rows || _list.SelectedItems is not { } selected)
        {
            return;
        }
        _syncing = true;
        selected.Clear();
        foreach (var row in rows.Where(r => _selection.Contains(r.Node.Handle)))
        {
            selected.Add(row);
        }
        _syncing = false;
        if (scroll && rows.FirstOrDefault(r => r.Node.Handle == _selection.Entity) is { } primary)
        {
            _list.ScrollIntoView(primary);
        }
    }

    // Adds a node and its visible descendants, and returns whether the node or one of them matches the filter. With a
    // filter, a match shows with its ancestors, expanded or not.
    bool Add(List<OutlinerRow> rows, EntityNode node, int depth, string filter)
    {
        var summary = string.Join(", ", node.Components.Select(_world.TypeName).Where(n => !Structural.Contains(n)).Select(FieldValues.Humanize));
        var label = node.Label;
        var row = new OutlinerRow(node, depth, label, summary, node.Children.Count > 0, !_collapsed.Contains(node.Handle));
        var at = rows.Count;
        rows.Add(row);
        var matches = filter.Length == 0
            || label.Contains(filter, StringComparison.OrdinalIgnoreCase)
            || node.ToString().Contains(filter, StringComparison.OrdinalIgnoreCase)
            || summary.Contains(filter, StringComparison.OrdinalIgnoreCase)
            || _shell.InstanceOf(node.SceneId) is { Prefab: not "" } instance && _shell.PrefabName(instance.Prefab).Contains(filter, StringComparison.OrdinalIgnoreCase);
        var childMatches = false;
        if (row.Expanded || filter.Length > 0)
        {
            foreach (var child in node.Children)
            {
                childMatches |= Add(rows, child, depth + 1, filter);
            }
        }
        if (filter.Length > 0 && !matches && !childMatches)
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
                if (!_collapsed.Remove(row.Node.Handle))
                {
                    _collapsed.Add(row.Node.Handle);
                }
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
        var view = new DockPanel { Background = Brushes.Transparent };
        if (row.Node.SceneId != 0)
        {
            var id = row.Node.SceneId;
            var lockButton = Toggle(_shell.IsLocked(id), "locked", "unlocked",
                _shell.IsLocked(id) ? "Let the viewport select this entity" : "Stop the viewport from selecting this entity and its children",
                () => _shell.SetLocked([id], !_shell.IsLocked(id)));
            var eyeButton = Toggle(_shell.IsHidden(id), "hidden", "visible",
                _shell.IsHidden(id) ? "Show this entity in the viewport" : "Hide this entity and its children in the viewport",
                () => _shell.SetHidden([id], !_shell.IsHidden(id)));
            SetDock(lockButton, DockSide.Right);
            SetDock(eyeButton, DockSide.Right);
            view.Children.Add(lockButton);
            view.Children.Add(eyeButton);
        }
        view.Children.Add(content);
        Mark(content, row.Node.SceneId);
        if (_shell.ProblemsOf(row.Node.SceneId) is { Count: > 0 } problems)
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
            if (DroppedPrefab(e) != null)
            {
                e.DragEffects = row.Node.SceneId != 0 ? DragDropEffects.Copy : DragDropEffects.None;
            }
            else if (ContentBrowserView.Dropped(e) is { } script)
            {
                e.DragEffects = _shell.CanAddBehaviour([row.Node.SceneId], script) ? DragDropEffects.Link : DragDropEffects.None;
            }
            else
            {
                e.DragEffects = CanDrop(e, row.Node.SceneId) ? DragDropEffects.Move : DragDropEffects.None;
            }
            e.Handled = true;
        });
        view.AddHandler(DragDrop.DropEvent, (_, e) =>
        {
            if (DroppedPrefab(e) is { } prefab)
            {
                _shell.CreateInstance(prefab, row.Node.SceneId);
            }
            else if (ContentBrowserView.Dropped(e) is { } script)
            {
                _shell.AddBehaviour([row.Node.SceneId], script);
            }
            else
            {
                Drop(e, row.Node.SceneId);
            }
            e.Handled = true;
        });
        view.ContextMenu = RowMenu(row);
        return view;
    }

    string? DroppedPrefab(DragEventArgs e) =>
        _shell.IsEditing && _shell.Scene != null && ContentBrowserView.Dropped(e) is { } guid && _shell.IsPrefab(guid) ? guid : null;

    // An entity can go under any scene entity that is not itself or one of its descendants, or to the root.
    bool CanDrop(DragEventArgs e, ulong parent)
    {
        var dragged = _world.Find(EntityView.Dropped(e));
        if (dragged is not { SceneId: not 0 } || _shell.Scene == null || !_shell.IsEditing || (parent == 0 ? dragged.Parent == 0 : parent == dragged.SceneId))
        {
            return false;
        }
        for (var p = _world.FindScene(parent); p != null; p = p.Parent == 0 ? null : _world.Find(p.Parent))
        {
            if (p.SceneId == dragged.SceneId)
            {
                return false;
            }
        }
        return parent == 0 || _world.FindScene(parent) != null;
    }

    void Drop(DragEventArgs e, ulong parent)
    {
        if (CanDrop(e, parent) && _world.Find(EntityView.Dropped(e)) is { } dragged)
        {
            _shell.Reparent(dragged.SceneId, parent);
        }
    }

    // An instance's root has the prefab's icon before its name; an entity of an instance with overrides a dot after
    // it; and one that the scene added to an instance a plus.
    void Mark(StackPanel content, ulong id)
    {
        if (id == 0)
        {
            return;
        }
        var instance = _shell.InstanceOf(id);
        if (instance is { Prefab: not "" } && CommandViews.Icon("prefab", 12) is { } icon)
        {
            icon.Classes.Add("prefab");
            ToolTip.SetTip(icon, $"An instance of {_shell.PrefabName(instance.Prefab)}");
            content.Children.Insert(1, icon);
        }
        TextBlock? mark = null;
        if (instance is { IsInstanceRoot: false } && _shell.IsOverridden(id))
        {
            mark = new TextBlock { Text = "•", Classes = { "prefab" } };
            ToolTip.SetTip(mark, "Overrides its prefab");
        }
        else if (instance == null && _shell.IsAddedToInstance(id))
        {
            mark = new TextBlock { Text = "+", Classes = { "prefab" } };
            ToolTip.SetTip(mark, "Added to the instance, not in its prefab");
        }
        if (mark != null)
        {
            var name = content.Children.OfType<TextBlock>().First(t => t.Text != "" && !t.Classes.Contains("dim"));
            content.Children.Insert(content.Children.IndexOf(name) + 1, mark);
        }
    }

    ContextMenu? RowMenu(OutlinerRow row)
    {
        if (row.Node.SceneId == 0)
        {
            return null;
        }
        MenuItem Item(string header, string command) => new()
        {
            Header = header,
            Command = new RelayCommand(() =>
            {
                // A row's menu acts on the selection when the row is in it, and on the row alone otherwise.
                if (!_selection.Contains(row.Node.Handle))
                {
                    _selection.Select(row.Node.Handle);
                }
                _shell.Commands.Get(command).Execute();
            }),
        };
        var menu = new ContextMenu
        {
            Items =
            {
                Item("Duplicate", EditorCommands.DuplicateEntity),
                Item("Delete", EditorCommands.DeleteEntity),
                new Separator(),
                Item("New Entity", EditorCommands.CreateEntity),
            },
        };
        if (row.Node.Parent != 0)
        {
            menu.Items.Add(new MenuItem { Header = "Move to Root", Command = new RelayCommand(() => _shell.Reparent(row.Node.SceneId, 0)) });
        }
        menu.Items.Add(new Separator());
        if (_shell.InstanceOf(row.Node.SceneId) is { } instance)
        {
            menu.Items.Add(Item("Open Prefab", EditorCommands.OpenPrefab));
            menu.Items.Add(Item("Select Prefab Asset", EditorCommands.SelectPrefabAsset));
            menu.Items.Add(Item("Apply All", EditorCommands.ApplyAllPrefab));
            menu.Items.Add(Item("Revert All", EditorCommands.RevertAllPrefab));
            if (instance.IsInstanceRoot)
            {
                menu.Items.Add(Item("Make Variant", EditorCommands.MakeVariant));
                menu.Items.Add(Item("Unpack", EditorCommands.UnpackPrefab));
                menu.Items.Add(Item("Unpack Completely", EditorCommands.UnpackPrefabCompletely));
            }
        }
        else
        {
            menu.Items.Add(Item("Make Prefab", EditorCommands.MakePrefab));
        }
        menu.Items.Insert(0, Item("Focus", EditorCommands.FrameSelected));
        menu.Items.Insert(1, new Separator());
        menu.Items.Add(new Separator());
        menu.Items.Add(Item("Hide or Show", EditorCommands.HideSelected));
        menu.Items.Add(Item("Lock or Unlock", EditorCommands.LockSelected));
        return menu;
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
