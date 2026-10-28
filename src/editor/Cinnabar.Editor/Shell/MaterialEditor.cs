using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Tools;
using Cinnabar.Editor.Viewport;
using ClosePreviewMessage = Cinnabar.Editor.Link.Protocol.ClosePreview;
using OpenPreviewMessage = Cinnabar.Editor.Link.Protocol.OpenPreview;
using PreviewAcknowledged = Cinnabar.Editor.Link.Protocol.PreviewAcknowledged;
using PreviewMesh = Cinnabar.Editor.Link.Protocol.PreviewMesh;
using PreviewSettings = Cinnabar.Editor.Link.Protocol.PreviewSettings;

namespace Cinnabar.Editor.Shell;

/// <summary>A problem of the preview's cook, on a node of the graph or, with no node, on the material.</summary>
public sealed record GraphProblem(int? Node, string Text, bool Error);

/// <summary>
/// An open material or material function in the material editor (see docs/editor/material-editor.md#material-editor): its document, the
/// selected nodes, the problems of its last preview cook, and for a material, its preview. Every change of the graph
/// cooks the unsaved text again for the preview, a moment after the last change. The view turns input into calls here,
/// so tests can drive the editor without a window.
/// </summary>
public sealed class MaterialEditor : IPreviewOwner, IDisposable
{
    // The preview cooks this long after the last change, so typing or a drag cooks once.
    static readonly TimeSpan CookDelay = TimeSpan.FromMilliseconds(250);
    // The preview's camera starts here, and its pitch stays short of looking straight down or up.
    const float StartYaw = 0.6f;
    const float StartPitch = 0.35f;
    const float StartDistance = 1.9f;
    const float MaxPitch = 1.45f;

    readonly EditorShell _shell;
    readonly HashSet<int> _selection = [];
    readonly List<GraphProblem> _problems = [];
    int _cookVersion;
    bool _cooking;
    bool _cookAgain;

    internal MaterialEditor(EditorShell shell, MaterialDocument document, int? previewId)
    {
        _shell = shell;
        Document = document;
        PreviewId = previewId;
        Document.Changed += OnDocumentChanged;
        if (previewId != null)
        {
            Preview = new ViewportSession();
            Preview.SizeRequested += size =>
            {
                Size = (Math.Clamp(size.Width, 16, 1024), Math.Clamp(size.Height, 16, 1024));
                SendSettings();
            };
            Preview.FrameCopied += (generation, frame) => _shell.Host.Send(new PreviewAcknowledged((uint)previewId, generation, frame));
            Preview.Failed += message => _shell.Console.Add(Panels.LogLevel.Warning, message);
        }
    }

    public MaterialDocument Document { get; }

    public string Guid => Document.Guid;

    /// <summary>The preview's ID, or null for a material function, or when every preview is in use.</summary>
    public int? PreviewId { get; }

    /// <summary>The preview's frames, or null without a preview.</summary>
    public ViewportSession? Preview { get; }

    public PreviewMesh Mesh { get; private set; } = PreviewMesh.Sphere;

    public bool PicksMesh => true;

    public string Waiting => "The preview draws once the material cooks.";
    public float Yaw { get; private set; } = StartYaw;
    public float Pitch { get; private set; } = StartPitch;
    public float Distance { get; private set; } = StartDistance;
    public (int Width, int Height) Size { get; private set; } = (256, 256);

    /// <summary>The preview shows the unsaved graph, which the daemon cooked into the cache's preview area.</summary>
    public bool ShowsUnsaved { get; private set; }

    public IReadOnlyCollection<int> Selection => _selection;

    public IReadOnlyList<GraphProblem> Problems => _problems;

    /// <summary>The last preview cook failed, so the preview shows the last graph that cooked.</summary>
    public string? CookError { get; private set; }

    /// <summary>The graph or its document's state changed.</summary>
    public event Action? Changed;

    public event Action? SelectionChanged;

    /// <summary>A preview cook finished, with its problems.</summary>
    public event Action? ProblemsChanged;

    public MaterialCatalog Catalog => _shell.MaterialCatalog;

    public GraphGeometry Geometry() => GraphGeometry.Of(Document.Graph, Catalog);

    void OnDocumentChanged()
    {
        // A node that undo or a delete took is no longer selected.
        if (_selection.RemoveWhere(id => Document.Graph.Find(id) == null) > 0)
        {
            SelectionChanged?.Invoke();
        }
        Changed?.Invoke();
        _shell.Commands.InvalidateAll();
        if (!Document.InTransaction)
        {
            ScheduleCook();
        }
    }

    public void Select(IEnumerable<int> nodes, SelectMode mode = SelectMode.Replace)
    {
        if (mode == SelectMode.Replace)
        {
            _selection.Clear();
        }
        foreach (var id in nodes)
        {
            if (mode == SelectMode.Toggle && !_selection.Add(id))
            {
                _selection.Remove(id);
            }
            else
            {
                _selection.Add(id);
            }
        }
        SelectionChanged?.Invoke();
    }

    /// <summary>The selected node, when exactly one is.</summary>
    public GraphNode? SelectedNode => _selection.Count == 1 ? Document.Graph.Find(_selection.First()) : null;

    /// <summary>Adds a node of a kind at a point of the canvas, selected. A parameter node can name its parameter.</summary>
    public int AddNode(string kind, double x, double y, string? parameter = null)
    {
        var id = Document.Graph.NextId();
        var label = Catalog.Kind(kind)?.Label ?? kind;
        Document.Edit($"Add {label}", g =>
        {
            var node = new GraphNode(id, kind) { X = Math.Round(x), Y = Math.Round(y) };
            if (parameter != null)
            {
                node.Set("name", new GraphText(parameter));
            }
            g.Nodes.Add(node);
        });
        Select([id]);
        return id;
    }

    /// <summary>Deletes the selected nodes and their links. A material's output node stays.</summary>
    public void DeleteSelected()
    {
        var ids = _selection.Where(id => Document.Graph.Find(id) is { Kind: not "output" }).ToList();
        if (ids.Count == 0)
        {
            return;
        }
        Document.Edit(ids.Count == 1 ? $"Delete {Label(ids[0])}" : $"Delete {ids.Count} Nodes", g => ids.ForEach(g.Remove));
    }

    /// <summary>Copies the selected nodes, with the links between them, beside them, and selects the copies.</summary>
    public void DuplicateSelected()
    {
        var originals = _selection.Select(Document.Graph.Find).OfType<GraphNode>().Where(n => n.Kind != "output").ToList();
        if (originals.Count == 0)
        {
            return;
        }
        var copies = new List<int>();
        Document.Edit(originals.Count == 1 ? $"Duplicate {Label(originals[0].Id)}" : $"Duplicate {originals.Count} Nodes", g =>
        {
            var next = g.NextId();
            var ids = originals.ToDictionary(n => n.Id, _ => next++);
            foreach (var n in originals)
            {
                var copy = new GraphNode(ids[n.Id], n.Kind) { X = n.X + 40, Y = n.Y + 40 };
                foreach (var (name, value) in n.Fields)
                {
                    copy.Set(name, value is GraphLink link && ids.TryGetValue(link.Node, out var to) ? link with { Node = to } : value);
                }
                g.Nodes.Add(copy);
                copies.Add(copy.Id);
            }
        });
        Select(copies);
    }

    /// <summary>A drag of the selected nodes: begin, a move per step by the drag's offset from its start, then end.</summary>
    public void BeginMove() => Document.Begin(_selection.Count == 1 ? $"Move {Label(_selection.First())}" : $"Move {_selection.Count} Nodes");

    public void MoveSelected(IReadOnlyDictionary<int, Vec2> starts, Vec2 offset) =>
        Document.Step(g =>
        {
            foreach (var (id, start) in starts)
            {
                if (g.Find(id) is { } node)
                {
                    (node.X, node.Y) = (start.X + offset.X, start.Y + offset.Y);
                }
            }
        });

    public void EndMove(bool cancel = false)
    {
        if (cancel)
        {
            Document.Cancel();
        }
        else if (Document.InTransaction)
        {
            Document.Commit();
        }
    }

    /// <summary>Links an output to an input, which replaces what the input had. A link that would loop is refused.</summary>
    public bool Link(int from, string output, int to, string input)
    {
        if (from == to || Reaches(from, to))
        {
            return false;
        }
        Document.Edit($"Link {Label(from)} to {Label(to)}", g => g.Find(to)?.Set(input, new GraphLink(from, output)));
        return true;
    }

    /// <summary>Moves a link off one input onto another, as a drag of it does, in one undo entry.</summary>
    public void MoveLink(int oldTo, string oldInput, int from, string output, int to, string input)
    {
        if (from == to || Reaches(from, to))
        {
            SetField(oldTo, oldInput, null);
            return;
        }
        Document.Edit($"Link {Label(from)} to {Label(to)}", g =>
        {
            g.Find(oldTo)?.Set(oldInput, null);
            g.Find(to)?.Set(input, new GraphLink(from, output));
        });
    }

    // Whether a node's inputs reach another node: linking the other's output to it would make a loop.
    bool Reaches(int start, int target)
    {
        var seen = new HashSet<int>();
        var todo = new Stack<int>([start]);
        while (todo.Count > 0)
        {
            var id = todo.Pop();
            if (id == target)
            {
                return true;
            }
            if (!seen.Add(id) || Document.Graph.Find(id) is not { } node)
            {
                continue;
            }
            foreach (var (_, value) in node.Fields)
            {
                if (value is GraphLink link)
                {
                    todo.Push(link.Node);
                }
            }
        }
        return false;
    }

    /// <summary>Sets an input or a property of a node, or with null, gives it its default.</summary>
    public void SetField(int node, string name, GraphValue? value)
    {
        var label = value == null ? $"Reset {Humanize(name)}" : $"Set {Humanize(name)}";
        Document.Edit(label, g => g.Find(node)?.Set(name, value));
    }

    public void SetSettings(string label, Action<MaterialGraph> edit) => Document.Edit(label, edit);

    /// <summary>Adds a parameter of a type with a name that no parameter or switch has.</summary>
    public string AddParam(string type)
    {
        var name = FreeName(type == "texture" ? "texture" : "param");
        var value = type switch
        {
            "float" => "0",
            "float2" => "[0, 0]",
            "float3" => "[0, 0, 0]",
            "texture" => "white",
            _ => "[1, 1, 1, 1]",
        };
        Document.Edit($"Add {name}", g => g.Params.Add(new MaterialParam(name, type, value)));
        return name;
    }

    /// <summary>Changes a parameter. A new name also renames it in the parameter nodes that read it.</summary>
    public void SetParam(string name, MaterialParam changed)
    {
        Document.Edit($"Set {changed.Name}", g =>
        {
            var at = g.Params.FindIndex(p => p.Name == name);
            if (at < 0)
            {
                return;
            }
            g.Params[at] = changed;
            if (changed.Name != name)
            {
                foreach (var n in g.Nodes.Where(n => n.Kind == "parameter" && (n.Get("name") as GraphText)?.Text == name))
                {
                    n.Set("name", new GraphText(changed.Name));
                }
            }
        });
    }

    public void RemoveParam(string name) => Document.Edit($"Remove {name}", g => g.Params.RemoveAll(p => p.Name == name));

    public string AddSwitch()
    {
        var name = FreeName("switch");
        Document.Edit($"Add {name}", g => g.Switches.Add(new MaterialSwitch(name, false)));
        return name;
    }

    public void SetSwitch(string name, MaterialSwitch changed)
    {
        Document.Edit($"Set {changed.Name}", g =>
        {
            var at = g.Switches.FindIndex(s => s.Name == name);
            if (at < 0)
            {
                return;
            }
            g.Switches[at] = changed;
            if (changed.Name != name)
            {
                foreach (var n in g.Nodes.Where(n => n.Kind == "switch" && (n.Get("switch") as GraphText)?.Text == name))
                {
                    n.Set("switch", new GraphText(changed.Name));
                }
            }
        });
    }

    public void RemoveSwitch(string name) => Document.Edit($"Remove {name}", g => g.Switches.RemoveAll(s => s.Name == name));

    string FreeName(string stem)
    {
        for (var n = 1; ; n++)
        {
            var name = $"{stem}{n}";
            if (!Document.Graph.NameTaken(name))
            {
                return name;
            }
        }
    }

    /// <summary>What a node is called on the canvas and in undo entries: a parameter's name, or its kind's label.</summary>
    public string Label(int id)
    {
        if (Document.Graph.Find(id) is not { } node)
        {
            return "Node";
        }
        return node.Kind switch
        {
            "parameter" when node.Get("name") is GraphText name => name.Text,
            "function_input" or "function_output" when node.Get("name") is GraphText name => name.Text,
            "function" when node.Get("function") is GraphAsset asset && _shell.Assets.Find(asset.Guid) is { } f => Content.AssetIndex.DisplayName(f).Split('.')[0],
            _ => Catalog.Kind(node.Kind)?.Label ?? node.Kind,
        };
    }

    /// <summary>A pin's or a property's name as words. A name of one or two letters, such as uv, is a symbol, and shows in capitals.</summary>
    public static string Humanize(string name) => name.Length <= 2 ? name.ToUpperInvariant() : Model.FieldValues.Humanize(name);

    // The preview.

    public void SetMesh(PreviewMesh mesh)
    {
        Mesh = mesh;
        SendSettings();
        Changed?.Invoke();
    }

    /// <summary>Turns the preview's camera by pixels of mouse movement.</summary>
    public void Orbit(double dx, double dy)
    {
        Yaw += (float)(dx * 0.01);
        Pitch = Math.Clamp(Pitch + (float)(dy * 0.01), -MaxPitch, MaxPitch);
        SendSettings();
    }

    /// <summary>Moves the preview's camera nearer or farther by wheel notches.</summary>
    public void Zoom(double notches)
    {
        Distance = Math.Clamp(Distance * (float)Math.Pow(0.9, notches), 0.6f, 20f);
        SendSettings();
    }

    /// <summary>Tells the game what the preview shows, as when the host links.</summary>
    internal void SendPreview()
    {
        if (PreviewId is not { } id)
        {
            return;
        }
        _shell.Host.Send(new OpenPreviewMessage((uint)id, Convert.FromHexString(Guid), ShowsUnsaved));
        SendSettings();
    }

    void SendSettings()
    {
        if (PreviewId is { } id)
        {
            _shell.Host.Send(new PreviewSettings((uint)id, Mesh, new byte[16], Yaw, Pitch, Distance, Size.Width, Size.Height));
        }
    }

    internal void ClosePreview()
    {
        if (PreviewId is { } id)
        {
            _shell.Host.Send(new ClosePreviewMessage((uint)id));
            Preview?.Disconnect();
        }
    }

    // The preview's cook: a moment after the last change, the daemon cooks the unsaved text. Only one cook runs at a
    // time, and a change during it cooks again after it.

    void ScheduleCook()
    {
        if (PreviewId == null)
        {
            return;
        }
        var version = ++_cookVersion;
        _ = Task.Delay(CookDelay).ContinueWith(_ =>
        {
            if (version == _cookVersion)
            {
                _ = CookNow();
            }
        }, Scheduler());
    }

    // The UI thread's scheduler in the editor, or the default one in tests, which have no synchronization context.
    static TaskScheduler Scheduler() => SynchronizationContext.Current == null ? TaskScheduler.Default : TaskScheduler.FromCurrentSynchronizationContext();

    /// <summary>Cooks the graph for the preview now, and shows the result's problems on their nodes.</summary>
    public async Task CookNow()
    {
        // Without the cook link, the editor cooks when the link comes up.
        if (PreviewId == null || _shell.Cook.State != Content.CookState.Linked)
        {
            return;
        }
        if (_cooking)
        {
            _cookAgain = true;
            return;
        }
        _cooking = true;
        try
        {
            do
            {
                _cookAgain = false;
                var result = await _shell.Cook.CookPreview(Guid, Document.Text);
                if (result.Error == "" && !ShowsUnsaved)
                {
                    ShowsUnsaved = true;
                    SendPreview();
                }
                ShowProblems(result);
            }
            while (_cookAgain);
        }
        finally
        {
            _cooking = false;
        }
    }

    void ShowProblems(PreviewResult result)
    {
        _problems.Clear();
        foreach (var p in result.Problems)
        {
            var mine = string.Equals(Path.GetFullPath(p.File == "" ? "." : p.File), Document.Path, StringComparison.OrdinalIgnoreCase);
            var node = mine && p.Line > 0 ? Document.NodeAt((int)p.Line) : null;
            var where = mine || p.File == "" ? "" : $"{Path.GetFileName(p.File)}:{p.Line}: ";
            _problems.Add(new GraphProblem(node, where + p.Text, p.Error));
        }
        CookError = result.Error == "" ? null : result.Error;
        ProblemsChanged?.Invoke();
    }

    public void Dispose()
    {
        Document.Changed -= OnDocumentChanged;
        Preview?.Dispose();
    }
}
