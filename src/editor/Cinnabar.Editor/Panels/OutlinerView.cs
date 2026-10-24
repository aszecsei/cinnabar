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
/// The outliner (see docs/editor.md#outliner): the entity hierarchy as a virtualized list of the visible rows,
/// indented by depth. A tree control with one item per entity would not scale to a large world. Dragging a row onto
/// another reparents it, and onto the empty space below the rows makes it a root. A row also drags onto an entity
/// field in the properties panel. Ctrl and Shift select more than one row. Each row of a scene entity has a toggle that
/// hides it in the viewport and one that locks it against picking, which apply to its descendants too.
/// </summary>
public sealed class OutlinerView : DockPanel
{
    // The components that the tree itself shows: the hierarchy, and activity by dimming.
    static readonly HashSet<string> Structural = ["Parent", "Previous_Transform", "Inactive", "Disabled", "Name", "Scene_Entity"];
    const double Indent = 14;

    // A press must move this far, in pixels, before it starts a drag.
    const double DragThreshold = 4;

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
        _list.AddHandler(DragDrop.DragOverEvent, (_, e) => e.DragEffects = CanDrop(e, 0) ? DragDropEffects.Move : DragDropEffects.None);
        _list.AddHandler(DragDrop.DropEvent, (_, e) => Drop(e, 0));

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

        AttachedToVisualTree += (_, _) =>
        {
            _world.EntitiesChanged += Rebuild;
            _world.TypesChanged += Rebuild;
            _selection.Changed += OnSelectionChanged;
            _shell.ProblemsChanged += Rebuild;
            _shell.VisibilityChanged += Rebuild;
            Rebuild();
        };
        DetachedFromVisualTree += (_, _) =>
        {
            _world.EntitiesChanged -= Rebuild;
            _world.TypesChanged -= Rebuild;
            _selection.Changed -= OnSelectionChanged;
            _shell.ProblemsChanged -= Rebuild;
            _shell.VisibilityChanged -= Rebuild;
        };
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
            || summary.Contains(filter, StringComparison.OrdinalIgnoreCase);
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
            if (Math.Abs(moved.X) + Math.Abs(moved.Y) < DragThreshold)
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
            e.DragEffects = CanDrop(e, row.Node.SceneId) ? DragDropEffects.Move : DragDropEffects.None;
            e.Handled = true;
        });
        view.AddHandler(DragDrop.DropEvent, (_, e) =>
        {
            Drop(e, row.Node.SceneId);
            e.Handled = true;
        });
        view.ContextMenu = RowMenu(row);
        return view;
    }

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
