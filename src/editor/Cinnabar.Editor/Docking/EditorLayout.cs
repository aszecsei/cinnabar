using Avalonia.Threading;
using Dock.Model.Controls;
using Dock.Model.Core;
using Dock.Model.Mvvm;
using Dock.Model.Mvvm.Controls;

namespace Cinnabar.Editor.Docking;

/// <summary>
/// The dock layout of the panels (see docs/editor/shell-and-panels.md#shell): the default layout, showing and closing panels by ID,
/// and saving and restoring the layout as a <see cref="LayoutFile"/>.
/// </summary>
public sealed class EditorLayout
{
    public const string LeftDock = "dock.left";
    public const string RightDock = "dock.right";
    public const string BottomDock = "dock.bottom";
    const string DocumentDockId = "dock.documents";
    const double DocumentDockProportion = 0.72;

    // Panels that a later editor renamed, by their old IDs, so a saved layout keeps them.
    static readonly Dictionary<string, string> Renamed = new() { ["assetBrowser"] = "contentBrowser" };

    readonly IReadOnlyDictionary<string, PanelTool> _panels;
    readonly ViewportDocument _scene;
    readonly ViewportDocument _game;
    readonly IReadOnlyDictionary<string, ViewportDocument> _viewportsById;

    public Factory Factory { get; } = new();

    public IRootDock Root { get; private set; }

    /// <summary>The root was replaced: a reset or a restore.</summary>
    public event Action? RootChanged;

    /// <summary>A panel opened, closed or moved.</summary>
    public event Action? Changed;

    /// <summary>A document dock's active document changed: a viewport or a material editor.</summary>
    public event Action<IDockable?>? ActiveDocumentChanged;

    /// <summary>Asks whether a document may close. A document that it refuses stays open.</summary>
    public Func<IDockable, bool>? DocumentClosing { get; set; }

    /// <summary>A document closed.</summary>
    public event Action<IDockable>? DocumentClosed;

    public IEnumerable<PanelTool> Panels => _panels.Values;

    /// <param name="panels">Every panel, each of which exists once.</param>
    /// <param name="scene">The Scene document, which holds the scene views.</param>
    /// <param name="game">The Game document, which holds the Game view.</param>
    public EditorLayout(IEnumerable<PanelTool> panels, ViewportDocument scene, ViewportDocument game)
    {
        _panels = panels.ToDictionary(p => p.Id);
        _scene = scene;
        _game = game;
        _viewportsById = new[] { scene, game }.ToDictionary(v => v.Id);
        Root = CreateDefault();
        Factory.DockableAdded += (_, _) => Changed?.Invoke();
        Factory.DockableRemoved += (_, _) => Changed?.Invoke();
        Factory.DockableClosed += (_, _) => Changed?.Invoke();
        Factory.DockableMoved += (_, _) => Changed?.Invoke();
        // Closing a floating window goes WindowClosing, DockableRemoved for its panels, WindowRemoved, then DockableClosed
        // for them, and raises no WindowClosed. So its panels are noted first, and go back once Dock has finished.
        Factory.WindowClosing += (_, e) => _closingPanels = e.Window?.Layout == null ? [] : [.. Walk(e.Window.Layout).OfType<PanelTool>()];
        Factory.WindowRemoved += (_, _) =>
        {
            if (_closingPanels.Count > 0)
            {
                Dispatcher.UIThread.Post(DockBackClosing);
            }
            Changed?.Invoke();
        };
        Factory.ActiveDockableChanged += (_, e) =>
        {
            if (e.Dockable is ViewportDocument or EditorDocument)
            {
                ActiveDocumentChanged?.Invoke(e.Dockable);
            }
        };
        Factory.DockableClosing += (_, e) =>
        {
            if (e.Dockable is EditorDocument && DocumentClosing?.Invoke(e.Dockable) == false)
            {
                e.Cancel = true;
            }
        };
        Factory.DockableClosed += (_, e) =>
        {
            if (e.Dockable is EditorDocument document)
            {
                DocumentClosed?.Invoke(document);
                // A viewport is the document again once the last editor's document closes.
                if (DocumentHost()?.ActiveDockable is not EditorDocument)
                {
                    ActiveDocumentChanged?.Invoke(DocumentHost()?.ActiveDockable);
                }
            }
        };
    }

    // The document dock that new documents go into, beside the viewports: the one that holds the first open viewport, or
    // else the first document dock.
    IDocumentDock? DocumentHost()
    {
        var docks = Walk(Root).OfType<IDocumentDock>().ToList();
        return _viewportsById.Values.Where(v => IsOpen(v.Id)).OrderBy(v => v == _scene ? 0 : 1).Select(v => v.Owner).OfType<IDocumentDock>().FirstOrDefault(docks.Contains) ?? docks.FirstOrDefault();
    }

    /// <summary>Adds a material editor's or an effect preview's document beside the viewports, and shows it.</summary>
    public void OpenDocument(EditorDocument document)
    {
        if (DocumentHost() is not { } dock)
        {
            return;
        }
        Factory.AddDockable(dock, document);
        Factory.SetActiveDockable(document);
        Factory.SetFocusedDockable(dock, document);
        ActiveDocumentChanged?.Invoke(document);
    }

    /// <summary>Shows a material editor's or an effect preview's open document.</summary>
    public void ShowDocument(object editor)
    {
        if (FindDocument(editor) is { Owner: IDock dock } document)
        {
            Factory.SetActiveDockable(document);
            Factory.SetFocusedDockable(dock, document);
            ActiveDocumentChanged?.Invoke(document);
        }
    }

    public void CloseDocument(object editor)
    {
        if (FindDocument(editor) is { } document)
        {
            Factory.CloseDockable(document);
        }
    }

    EditorDocument? FindDocument(object editor) =>
        Walk(Root).OfType<EditorDocument>().FirstOrDefault(d => d.Shows == editor);

    /// <summary>Whether the Scene or the Game document (by <see cref="ViewportDocument.SceneId"/> or <see cref="ViewportDocument.GameId"/>) is in the layout, as a tab that may be behind another.</summary>
    public bool IsViewportOpen(string id) => IsOpen(id);

    /// <summary>
    /// Shows the Scene or the Game document: it opens in the document dock that holds the other one, unless it is open
    /// already, and becomes its dock's active tab.
    /// </summary>
    public void ShowViewport(string id)
    {
        var document = _viewportsById[id];
        if (!IsOpen(document.Id))
        {
            if (DocumentHost() is not { } dock)
            {
                return;
            }
            Factory.AddDockable(dock, document);
        }
        Factory.SetActiveDockable(document);
        if (document.Owner is IDock owner)
        {
            Factory.SetFocusedDockable(owner, document);
        }
        ActiveDocumentChanged?.Invoke(document);
        Changed?.Invoke();
    }

    /// <summary>Closes the Scene or the Game document. Its viewports keep their cameras and settings for the next time.</summary>
    public void CloseViewport(string id)
    {
        if (IsViewportOpen(id))
        {
            Factory.CloseDockable(_viewportsById[id]);
            Changed?.Invoke();
        }
    }

    /// <summary>The outliner on the left, the Scene and the Game in the middle, the properties on the right, and the console below.</summary>
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
                NewDocumentDock(DocumentDockId, DocumentDockProportion, [_scene, _game], _scene.Id),
                new ProportionalDockSplitter(),
                Tools(BottomDock, Alignment.Bottom, 0.28, "console", "contentBrowser", "resourceMonitor", "profiler")),
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
                Tools(RightDock, Alignment.Right, 0.20, "properties", "faceEditor", "undoHistory", "atmosphere", "weather")),
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
        var dockIds = new HashSet<string>();
        var root = Root.VisibleDockables?.FirstOrDefault(d => d is not IProportionalDockSplitter);
        var node = root == null ? null : SaveNode(root, docked, dockIds);
        var floating = _panels.Keys.Where(id => IsOpen(id) && !docked.Contains(id)).Order().ToList();
        var windows = new List<FloatingWindow>();
        foreach (var id in floating)
        {
            if (FloatingWindowOf(id) is { } host)
            {
                host.GetPosition(out var x, out var y);
                host.GetSize(out var width, out var height);
                windows.Add(new FloatingWindow(id, x, y, width, height));
            }
        }
        return new LayoutFile(LayoutFile.CurrentVersion, node ?? new DocumentsNode(DocumentDockId, null, [], null), floating, windows.Count > 0 ? windows : null);
    }

    /// <summary>Restores a saved layout, and returns false and keeps the current one if it has no document dock.</summary>
    public bool Restore(LayoutFile file)
    {
        var used = new HashSet<string>();
        var dockIds = new HashSet<string>();
        var documentDocks = 0;
        var main = RestoreNode(file.Root, used, dockIds, ref documentDocks);
        if (main == null || documentDocks == 0)
        {
            return false;
        }
        SetRoot(NewRoot(main));
        foreach (var id in file.Floating.Select(CurrentId).Where(id => _panels.ContainsKey(id) && !used.Contains(id)))
        {
            Show(id);
        }
        PendingWindows = [.. (file.Windows ?? []).Where(w => _panels.ContainsKey(CurrentId(w.Panel))).Select(w => w with { Panel = CurrentId(w.Panel) })];
        return true;
    }

    static string CurrentId(string id) => Renamed.GetValueOrDefault(id, id);

    // A dock that the user split off has no ID of its own yet, and two docks never share one.
    static string UniqueId(string? id, string fallback, HashSet<string> taken)
    {
        var chosen = string.IsNullOrEmpty(id) || taken.Contains(id) ? fallback : id;
        for (var n = 2; taken.Contains(chosen); n++)
        {
            chosen = $"{fallback}.{n}";
        }
        taken.Add(chosen);
        return chosen;
    }

    LayoutNode? SaveNode(IDockable dockable, HashSet<string> docked, HashSet<string> dockIds)
    {
        var proportion = double.IsNaN(dockable.Proportion) ? (double?)null : dockable.Proportion;
        switch (dockable)
        {
            case IProportionalDock split:
                var children = (split.VisibleDockables ?? [])
                    .Where(d => d is not IProportionalDockSplitter)
                    .Select(d => SaveNode(d, docked, dockIds))
                    .OfType<LayoutNode>()
                    .ToList();
                return children.Count == 0 ? null
                    : new SplitNode(split.Id, proportion, split.Orientation == Orientation.Vertical, children);
            case IToolDock tools:
                var panels = (tools.VisibleDockables ?? []).OfType<PanelTool>().Select(p => p.Id).ToList();
                docked.UnionWith(panels);
                return panels.Count == 0 ? null
                    : new ToolsNode(tools.Id, proportion, tools.Alignment.ToString(), panels, tools.ActiveDockable?.Id);
            case IDocumentDock documents:
                var viewports = (documents.VisibleDockables ?? []).OfType<ViewportDocument>().Select(v => v.Id).ToList();
                return new DocumentsNode(UniqueId(dockable.Id, DocumentDockId, dockIds), proportion, viewports, (documents.ActiveDockable as ViewportDocument)?.Id);
            default:
                return null;
        }
    }

    IDockable? RestoreNode(LayoutNode node, HashSet<string> used, HashSet<string> dockIds, ref int documentDocks)
    {
        IDockable? dockable;
        switch (node)
        {
            case SplitNode split:
                var children = new List<IDockable>();
                foreach (var child in split.Children)
                {
                    if (RestoreNode(child, used, dockIds, ref documentDocks) is { } restored)
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
                var panels = tools.Panels.Select(CurrentId).Where(id => _panels.ContainsKey(id) && used.Add(id)).Select(id => _panels[id]).ToList();
                dockable = panels.Count == 0 ? null : NewToolDock(tools.Id,
                    Enum.TryParse<Alignment>(tools.Alignment, out var alignment) ? alignment : Alignment.Unset,
                    double.NaN, panels, tools.Active == null ? null : CurrentId(tools.Active));
                break;
            case DocumentsNode documents:
                documentDocks++;
                // A file from an editor with one viewport lists no documents, and had the scene view and the Game view's place.
                var wanted = documents.Documents ?? [_scene.Id, _game.Id];
                var placed = wanted.Where(id => _viewportsById.ContainsKey(id) && used.Add(id)).Select(id => _viewportsById[id]).ToList();
                dockable = NewDocumentDock(UniqueId(documents.Id, DocumentDockId, dockIds), double.NaN, placed, documents.Active);
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

    DocumentDock NewDocumentDock(string id, double proportion, IReadOnlyList<ViewportDocument> documents, string? active) =>
        new()
        {
            Id = id,
            Proportion = proportion,
            IsCollapsable = false,
            CanCreateDocument = false,
            VisibleDockables = Factory.CreateList<IDockable>(documents.ToArray()),
            ActiveDockable = documents.FirstOrDefault(d => d.Id == active) ?? documents.FirstOrDefault(),
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

    List<PanelTool> _closingPanels = [];
    const double PopOutWidth = 1100;
    const double PopOutHeight = 700;

    /// <summary>The windows to pop out once the main window is open, as a floating window needs one to float from.</summary>
    public IReadOnlyList<FloatingWindow> PendingWindows { get; private set; } = [];

    /// <summary>The editor is closing, so a window that closes with it does not dock its panels again.</summary>
    public bool Closing { get; set; }

    /// <summary>Whether a panel is in a window of its own.</summary>
    public bool IsFloating(string id) => FloatingDockWindowOf(id) != null;

    /// <summary>Puts a panel in a window of its own, opening it first, unless it is in one already.</summary>
    public void PopOut(string id)
    {
        Show(id);
        if (!IsFloating(id))
        {
            Factory.FloatDockable(_panels[id]);
            // A docked panel is often short and wide, which is why it is popping out.
            FloatingWindowOf(id)?.SetSize(PopOutWidth, PopOutHeight);
            Changed?.Invoke();
        }
    }

    /// <summary>Puts a floating panel back in its default dock, and closes a window that it leaves empty.</summary>
    public void DockBack(string id)
    {
        if (FloatingDockWindowOf(id) is not { } window)
        {
            return;
        }
        Factory.RemoveDockable(_panels[id], true);
        Show(id);
        if (window.Layout == null || !Walk(window.Layout).OfType<PanelTool>().Any())
        {
            window.Exit();
        }
        Changed?.Invoke();
    }

    /// <summary>Places the windows that the saved layout kept, on the screens that there are now.</summary>
    public void RestoreWindows(IReadOnlyList<(double X, double Y, double Width, double Height)> screens)
    {
        var pending = PendingWindows;
        PendingWindows = [];
        foreach (var saved in pending)
        {
            var placed = saved.OnScreen(screens);
            PopOut(placed.Panel);
            if (FloatingWindowOf(placed.Panel) is { } host)
            {
                host.SetPosition(placed.X, placed.Y);
                host.SetSize(placed.Width, placed.Height);
            }
        }
    }

    // A panel in a window that closed is not lost: it goes back to its default dock, where the user can find it.
    void DockBackClosing()
    {
        var panels = _closingPanels;
        _closingPanels = [];
        if (Closing)
        {
            return;
        }
        foreach (var panel in panels)
        {
            Show(panel.Id);
        }
    }

    IDockWindow? FloatingDockWindowOf(string id) =>
        Root.Windows?.FirstOrDefault(w => w.Layout != null && Walk(w.Layout).Any(d => d.Id == id));

    /// <summary>The floating window that holds a panel, or null when the panel is in the main window or closed.</summary>
    public IHostWindow? FloatingWindowOf(string id) =>
        FloatingDockWindowOf(id)?.Host;

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
