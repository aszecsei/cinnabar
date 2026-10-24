using Dock.Model.Controls;
using Dock.Model.Core;
using Dock.Model.Mvvm;
using Dock.Model.Mvvm.Controls;

namespace Cinnabar.Editor.Docking;

/// <summary>
/// The dock layout of the panels (see docs/editor.md#shell): the default layout, showing and closing panels by ID,
/// and saving and restoring the layout as a <see cref="LayoutFile"/>.
/// </summary>
public sealed class EditorLayout
{
    public const string LeftDock = "dock.left";
    public const string RightDock = "dock.right";
    public const string BottomDock = "dock.bottom";
    const string DocumentDockId = "dock.documents";

    readonly IReadOnlyDictionary<string, PanelTool> _panels;
    readonly ViewportDocument _viewport;

    public Factory Factory { get; } = new();

    public IRootDock Root { get; private set; }

    /// <summary>The root was replaced: a reset or a restore.</summary>
    public event Action? RootChanged;

    /// <summary>A panel opened, closed or moved.</summary>
    public event Action? Changed;

    public IEnumerable<PanelTool> Panels => _panels.Values;

    public EditorLayout(IEnumerable<PanelTool> panels, ViewportDocument viewport)
    {
        _panels = panels.ToDictionary(p => p.Id);
        _viewport = viewport;
        Root = CreateDefault();
        Factory.DockableAdded += (_, _) => Changed?.Invoke();
        Factory.DockableRemoved += (_, _) => Changed?.Invoke();
        Factory.DockableClosed += (_, _) => Changed?.Invoke();
        Factory.DockableMoved += (_, _) => Changed?.Invoke();
        Factory.WindowClosed += (_, _) => Changed?.Invoke();
    }

    /// <summary>The outliner on the left, the viewport in the middle, the properties on the right, and the console below.</summary>
    IRootDock CreateDefault()
    {
        IDockable Tools(string id, Alignment alignment, double proportion, params string[] panels) =>
            NewToolDock(id, alignment, proportion, panels.Select(p => _panels[p]).ToList());

        var center = new ProportionalDock
        {
            Id = "dock.center",
            Orientation = Orientation.Vertical,
            Proportion = 0.64,
            VisibleDockables = Factory.CreateList<IDockable>(
                NewDocumentDock(0.72),
                new ProportionalDockSplitter(),
                Tools(BottomDock, Alignment.Bottom, 0.28, "console", "assetBrowser", "resourceMonitor")),
        };
        var main = new ProportionalDock
        {
            Id = "dock.main",
            Orientation = Orientation.Horizontal,
            VisibleDockables = Factory.CreateList<IDockable>(
                Tools(LeftDock, Alignment.Left, 0.16, "outliner"),
                new ProportionalDockSplitter(),
                center,
                new ProportionalDockSplitter(),
                Tools(RightDock, Alignment.Right, 0.20, "properties", "undoHistory")),
        };
        return NewRoot(main);
    }

    public void Reset() => SetRoot(CreateDefault());

    public bool IsOpen(string id) => Walk(Root).Any(d => d.Id == id);

    public void Toggle(string id)
    {
        if (IsOpen(id))
        {
            Close(id);
        }
        else
        {
            Show(id);
        }
    }

    public void Show(string id)
    {
        var panel = _panels[id];
        if (!IsOpen(id))
        {
            var dock = Walk(Root).OfType<IToolDock>().FirstOrDefault(d => d.Id == panel.DefaultDock)
                ?? Walk(Root).OfType<IToolDock>().FirstOrDefault()
                ?? AddToolDock(panel);
            Factory.AddDockable(dock, panel);
        }
        Factory.SetActiveDockable(panel);
        if (panel.Owner is IDock owner)
        {
            Factory.SetFocusedDockable(owner, panel);
        }
        Changed?.Invoke();
    }

    public void Close(string id)
    {
        if (IsOpen(id))
        {
            Factory.CloseDockable(_panels[id]);
            Changed?.Invoke();
        }
    }

    public LayoutFile Save()
    {
        var docked = new HashSet<string>();
        var root = Root.VisibleDockables?.FirstOrDefault(d => d is not IProportionalDockSplitter);
        var node = root == null ? null : SaveNode(root, docked);
        var floating = _panels.Keys.Where(id => IsOpen(id) && !docked.Contains(id)).Order().ToList();
        return new LayoutFile(LayoutFile.CurrentVersion, node ?? new DocumentsNode(DocumentDockId, null), floating);
    }

    /// <summary>Restores a saved layout, and returns false and keeps the current one if it has no viewport.</summary>
    public bool Restore(LayoutFile file)
    {
        var used = new HashSet<string>();
        var viewportPlaced = false;
        var main = RestoreNode(file.Root, used, ref viewportPlaced);
        if (main == null || !viewportPlaced)
        {
            return false;
        }
        SetRoot(NewRoot(main));
        foreach (var id in file.Floating.Where(id => _panels.ContainsKey(id) && !used.Contains(id)))
        {
            Show(id);
        }
        return true;
    }

    LayoutNode? SaveNode(IDockable dockable, HashSet<string> docked)
    {
        var proportion = double.IsNaN(dockable.Proportion) ? (double?)null : dockable.Proportion;
        switch (dockable)
        {
            case IProportionalDock split:
                var children = (split.VisibleDockables ?? [])
                    .Where(d => d is not IProportionalDockSplitter)
                    .Select(d => SaveNode(d, docked))
                    .OfType<LayoutNode>()
                    .ToList();
                return children.Count == 0 ? null
                    : new SplitNode(split.Id, proportion, split.Orientation == Orientation.Vertical, children);
            case IToolDock tools:
                var panels = (tools.VisibleDockables ?? []).OfType<PanelTool>().Select(p => p.Id).ToList();
                docked.UnionWith(panels);
                return panels.Count == 0 ? null
                    : new ToolsNode(tools.Id, proportion, tools.Alignment.ToString(), panels, tools.ActiveDockable?.Id);
            case IDocumentDock:
                return new DocumentsNode(dockable.Id, proportion);
            default:
                return null;
        }
    }

    IDockable? RestoreNode(LayoutNode node, HashSet<string> used, ref bool viewportPlaced)
    {
        IDockable? dockable;
        switch (node)
        {
            case SplitNode split:
                var children = new List<IDockable>();
                foreach (var child in split.Children)
                {
                    if (RestoreNode(child, used, ref viewportPlaced) is { } restored)
                    {
                        if (children.Count > 0)
                        {
                            children.Add(new ProportionalDockSplitter());
                        }
                        children.Add(restored);
                    }
                }
                dockable = children.Count == 0 ? null : new ProportionalDock
                {
                    Id = split.Id,
                    Orientation = split.Vertical ? Orientation.Vertical : Orientation.Horizontal,
                    VisibleDockables = Factory.CreateList(children.ToArray()),
                };
                break;
            case ToolsNode tools:
                // A panel that this editor no longer has, or that is already placed, is left out.
                var panels = tools.Panels.Where(id => _panels.ContainsKey(id) && used.Add(id)).Select(id => _panels[id]).ToList();
                dockable = panels.Count == 0 ? null : NewToolDock(tools.Id,
                    Enum.TryParse<Alignment>(tools.Alignment, out var alignment) ? alignment : Alignment.Unset,
                    double.NaN, panels, tools.Active);
                break;
            case DocumentsNode when !viewportPlaced:
                viewportPlaced = true;
                dockable = NewDocumentDock(double.NaN);
                break;
            default:
                dockable = null;
                break;
        }
        if (dockable != null)
        {
            dockable.Proportion = node.Proportion ?? double.NaN;
        }
        return dockable;
    }

    ToolDock NewToolDock(string id, Alignment alignment, double proportion, IReadOnlyList<PanelTool> panels, string? active = null) =>
        new()
        {
            Id = id,
            Alignment = alignment,
            Proportion = proportion,
            VisibleDockables = Factory.CreateList<IDockable>(panels.ToArray()),
            ActiveDockable = panels.FirstOrDefault(p => p.Id == active) ?? panels.FirstOrDefault(),
        };

    DocumentDock NewDocumentDock(double proportion) =>
        new()
        {
            Id = DocumentDockId,
            Proportion = proportion,
            IsCollapsable = false,
            CanCreateDocument = false,
            VisibleDockables = Factory.CreateList<IDockable>(_viewport),
            ActiveDockable = _viewport,
        };

    IRootDock NewRoot(IDockable main)
    {
        var root = Factory.CreateRootDock();
        root.Id = "root";
        root.VisibleDockables = Factory.CreateList(main);
        root.DefaultDockable = main;
        root.ActiveDockable = main;
        Factory.InitLayout(root);
        return root;
    }

    void SetRoot(IRootDock root)
    {
        Root = root;
        RootChanged?.Invoke();
        Changed?.Invoke();
    }

    // Every dock had its default dock collapsed away, so the panel gets a new dock at the right edge.
    IToolDock AddToolDock(PanelTool panel)
    {
        var dock = NewToolDock(panel.DefaultDock, Alignment.Right, double.NaN, []);
        var main = Root.VisibleDockables?.OfType<IDock>().FirstOrDefault() ?? Root;
        Factory.AddDockable(main, new ProportionalDockSplitter());
        Factory.AddDockable(main, dock);
        return dock;
    }

    /// <summary>Every dockable under <paramref name="dockable"/>, including the layouts of floating windows.</summary>
    static IEnumerable<IDockable> Walk(IDockable dockable)
    {
        yield return dockable;
        if (dockable is IDock dock)
        {
            foreach (var child in dock.VisibleDockables ?? [])
            {
                foreach (var d in Walk(child))
                {
                    yield return d;
                }
            }
        }
        if (dockable is IRootDock root)
        {
            foreach (var window in root.Windows ?? [])
            {
                if (window.Layout != null)
                {
                    foreach (var d in Walk(window.Layout))
                    {
                        yield return d;
                    }
                }
            }
        }
    }
}
