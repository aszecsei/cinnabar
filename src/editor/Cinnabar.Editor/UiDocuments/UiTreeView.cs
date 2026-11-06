using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using static Cinnabar.Editor.Panels.Kit;

namespace Cinnabar.Editor.UiDocuments;

/// <summary>
/// The UI editor's tree (see docs/editor/ui-editor.md#the-tree): the document's elements, then its templates, each row
/// indented by its depth. A click selects an element; a drag moves it before, after or into another, by where on the
/// row it is dropped. The buttons add an element from the palette, add a template, and duplicate and delete.
/// </summary>
sealed class UiTreeView : DockPanel
{
    static readonly DataFormat<string> NodeFormat = DataFormat.CreateStringApplicationFormat("cinnabar-ui-node");
    static readonly IBrush SelectedBrush = new SolidColorBrush(Color.FromArgb(0x50, Palette.Accent.R, Palette.Accent.G, Palette.Accent.B));
    static readonly IBrush DropBrush = new SolidColorBrush(Palette.Accent);

    readonly UiEditor _editor;
    readonly StackPanel _rows = new();
    // Each node's row, whose background a selection changes without building the rows again, so a press that selects a
    // row can still start a drag from it.
    readonly Dictionary<int, Border> _views = [];
    PointerPressedEventArgs? _press;
    int _pressed = -1;
    string _shown = "";

    public UiTreeView(EditorShell shell, UiEditor editor)
    {
        _editor = editor;
        var buttons = new WrapPanel { Margin = new Thickness(6, 4) };
        var add = new MenuFlyout();
        foreach (var (kind, text) in UiEditor.Palette)
        {
            var item = new MenuItem { Header = kind };
            item.Click += (_, _) => AddElement(text);
            add.Items.Add(item);
        }
        buttons.Children.Add(new Button { Content = "Add", Flyout = add, Classes = { "field-button" }, Margin = new Thickness(0, 0, 4, 0) });
        buttons.Children.Add(SmallButton("Template", "Add a template, which scripts copy with Ui.add", _editor.AddTemplate));
        buttons.Children.Add(SmallButton("Duplicate", "Copy the element after itself (Ctrl+D)", () =>
        {
            if (_editor.SelectedNode is { } n)
            {
                _editor.Duplicate(n);
            }
        }));
        buttons.Children.Add(SmallButton("Delete", "Delete the element (Delete)", () =>
        {
            if (_editor.SelectedNode is { } n)
            {
                _editor.Delete(n);
            }
        }));
        SetDock(buttons, Avalonia.Controls.Dock.Top);
        Children.Add(buttons);
        Children.Add(new ScrollViewer { Content = _rows, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled });
        Focusable = true;
        new ViewSubscriptions(this, attached: Refresh)
            .Add(() => _editor.Changed += Refresh, () => _editor.Changed -= Refresh)
            .Add(() => _editor.SelectionChanged += ShowSelection, () => _editor.SelectionChanged -= ShowSelection)
            .Add(() => _editor.ProblemsChanged += Rebuild, () => _editor.ProblemsChanged -= Rebuild);
    }

    // A new element goes into the selected one if it holds elements, or after it, or last in the root.
    void AddElement(string text)
    {
        var file = _editor.File;
        if (file.Nodes.Count == 0)
        {
            return;
        }
        if (_editor.SelectedNode is not { } n)
        {
            _editor.Add(text, 0);
        }
        else if (_editor.Holds(n))
        {
            _editor.Add(text, n);
        }
        else if (file.Nodes[n] is { Parent: >= 0 } node && !node.ButtonText)
        {
            _editor.Add(text, node.Parent, _editor.IndexOf(n) + 1);
        }
    }

    void Rebuild()
    {
        _shown = "";
        Refresh();
    }

    void Refresh()
    {
        var file = _editor.File;
        var shown = $"{file.Text.GetHashCode()}:{_editor.Problems.Count}";
        if (shown == _shown)
        {
            ShowSelection();
            return;
        }
        _shown = shown;
        _rows.Children.Clear();
        _views.Clear();
        if (file.Nodes.Count == 0)
        {
            _rows.Children.Add(Dim("The document has no <ui>."));
            return;
        }
        var templates = false;
        Add(0, 0);
        foreach (var child in file.Nodes[0].Children)
        {
            if (file.Nodes[child].Kind == "template")
            {
                if (!templates)
                {
                    _rows.Children.Add(new TextBlock { Text = "Templates", FontSize = 11, FontWeight = FontWeight.SemiBold, Margin = new Thickness(8, 8, 0, 2), Classes = { "field-name" } });
                    templates = true;
                }
                Add(child, 0);
            }
        }

        void Add(int node, int depth)
        {
            _rows.Children.Add(Row(file.Nodes[node], depth));
            foreach (var child in file.Nodes[node].Children)
            {
                if (node != 0 || file.Nodes[child].Kind != "template")
                {
                    Add(child, depth + 1);
                }
            }
        }
    }

    void ShowSelection()
    {
        foreach (var (index, view) in _views)
        {
            view.Background = index == _editor.SelectedNode ? SelectedBrush : Brushes.Transparent;
        }
    }

    Control Row(UiNode node, int depth)
    {
        var label = UiCascade.Label(node);
        var summary = node.Kind is "text" or "button" && node.Element.Text != "" ? node.Element.Text : node.Element.Get("text") ?? "";
        var text = new TextBlock { Text = label, FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        content.Children.Add(text);
        if (summary != "" && !node.ButtonText)
        {
            content.Children.Add(new TextBlock { Text = summary, FontSize = 11, Classes = { "empty" }, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
        }
        else if (node.ButtonText)
        {
            content.Children.Add(new TextBlock { Text = summary == "" ? node.Element.Text : summary, FontSize = 11, Classes = { "empty" }, VerticalAlignment = VerticalAlignment.Center });
        }
        var problems = _editor.Problems.Where(p => p.Node == node.Index).ToList();
        if (problems.Count > 0)
        {
            var mark = new TextBlock { Text = "●", FontSize = 10, VerticalAlignment = VerticalAlignment.Center, Foreground = problems.Any(p => p.Error) ? Palette.ErrorBrush : Palette.WarningBrush };
            ToolTip.SetTip(mark, string.Join("\n", problems.Select(p => p.Text)));
            content.Children.Add(mark);
        }
        var view = new Border
        {
            Child = content,
            Padding = new Thickness(8 + depth * 14, 2, 4, 2),
            Background = node.Index == _editor.SelectedNode ? SelectedBrush : Brushes.Transparent,
            BorderThickness = new Thickness(0, 1),
            BorderBrush = Brushes.Transparent,
        };
        _views[node.Index] = view;
        view.PointerPressed += (_, e) =>
        {
            if (!e.GetCurrentPoint(view).Properties.IsLeftButtonPressed)
            {
                return;
            }
            Focus();
            _editor.Select(node.Index);
            _press = e;
            _pressed = node.Index;
        };
        view.PointerMoved += async (_, e) =>
        {
            if (_press is not { } press || _pressed != node.Index || !Gestures.MovedPastAcrossAndDown(e.GetPosition(view) - press.GetPosition(view)))
            {
                return;
            }
            _press = null;
            var data = new DataTransfer();
            data.Add(DataTransferItem.Create(NodeFormat, node.Index.ToString(System.Globalization.CultureInfo.InvariantCulture)));
            await DragDrop.DoDragDropAsync(press, data, DragDropEffects.Move);
        };
        view.PointerReleased += (_, _) => _press = null;
        DragDrop.SetAllowDrop(view, true);
        view.AddHandler(DragDrop.DragOverEvent, (_, e) =>
        {
            var target = Target(e, view, node);
            e.DragEffects = target != null ? DragDropEffects.Move : DragDropEffects.None;
            view.BorderBrush = Brushes.Transparent;
            view.BorderThickness = new Thickness(0, 1);
            if (target is { } t)
            {
                view.BorderBrush = DropBrush;
                view.BorderThickness = t.Where switch { Place.Before => new Thickness(0, 2, 0, 0), Place.After => new Thickness(0, 0, 0, 2), _ => new Thickness(2) };
            }
            e.Handled = true;
        });
        view.AddHandler(DragDrop.DragLeaveEvent, (_, _) =>
        {
            view.BorderBrush = Brushes.Transparent;
            view.BorderThickness = new Thickness(0, 1);
        });
        view.AddHandler(DragDrop.DropEvent, (_, e) =>
        {
            if (Target(e, view, node) is { } t && Dragged(e) is { } dragged)
            {
                _editor.Move(dragged, t.Parent, t.Index);
            }
            e.Handled = true;
        });
        return view;
    }

    enum Place
    {
        Before,
        Inside,
        After,
    }

    static int? Dragged(DragEventArgs e) =>
        e.DataTransfer.TryGetValue(NodeFormat) is { } text && int.TryParse(text, out var n) ? n : null;

    // Where a drop on a row puts what it drags: before the row's element or after it near its edges, and into it in its
    // middle if it holds elements.
    (int Parent, int Index, Place Where)? Target(DragEventArgs e, Control row, UiNode node)
    {
        if (Dragged(e) is not { } dragged || dragged >= _editor.File.Nodes.Count || node.ButtonText)
        {
            return null;
        }
        var y = e.GetPosition(row).Y / Math.Max(row.Bounds.Height, 1);
        var holds = _editor.Holds(node.Index);
        var where = node.Parent < 0 ? Place.Inside : holds ? (y < 0.25 ? Place.Before : y > 0.75 ? Place.After : Place.Inside) : (y < 0.5 ? Place.Before : Place.After);
        var (parent, index) = where switch
        {
            Place.Inside => (node.Index, node.Element.Children.Count),
            Place.Before => (node.Parent, _editor.IndexOf(node.Index)),
            _ => (node.Parent, _editor.IndexOf(node.Index) + 1),
        };
        return dragged != node.Index && _editor.CanMove(dragged, parent) ? (parent, index, where) : null;
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (_editor.SelectedNode is not { } n)
        {
            return;
        }
        if (e.Key == Key.Delete)
        {
            _editor.Delete(n);
            e.Handled = true;
        }
        else if (e.Key == Key.D && e.KeyModifiers == KeyModifiers.Control)
        {
            _editor.Duplicate(n);
            e.Handled = true;
        }
    }
}
