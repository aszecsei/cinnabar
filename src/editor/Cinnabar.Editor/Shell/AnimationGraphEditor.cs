using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Tools;
using Asset = Cinnabar.Editor.Link.Cook.Asset;
using PreviewMesh = Cinnabar.Editor.Link.Protocol.PreviewMesh;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// An open animation graph in its editor (see docs/editor/animation-graph-editor.md#animation-graph-editor): its document, the
/// selected nodes, the problems of the last check of its text, and its preview, which plays it on a mesh apart from the
/// world. Every change of the graph sends the unsaved text to the cook daemon, a moment after the last change. The view
/// turns input into calls here, so tests can drive the editor without a window.
/// </summary>
public sealed class AnimationGraphEditor : PreviewOwner, IGraphEditor
{
    // The preview's camera starts here, for a model of a meter or two.
    const float StartYaw = 2.4f;
    const float StartPitch = 0.2f;
    const float StartDistance = 3f;
    const float MaxDistance = 40f;

    readonly HashSet<int> _selection = [];
    readonly List<GraphProblem> _checked = [];
    readonly List<GraphProblem> _problems = [];
    readonly PreviewCook _cook;

    // The mesh that the user picked, and whether the game has been told that the daemon cooked the unsaved text.
    string? _pickedMesh;
    string? _sentMesh;
    bool _showsUnsaved;

    internal AnimationGraphEditor(EditorShell shell, AnimationGraphDocument document, int? previewId = null)
        : base(shell, previewId, StartYaw, StartPitch, StartDistance, MaxDistance)
    {
        Document = document;
        _cook = new PreviewCook(() => _shell.PreviewCooker.Linked, () => Document.Text, text => _shell.PreviewCooker.CookPreview(Guid, text), OnCooked);
        Document.Changed += OnDocumentChanged;
        _shell.Assets.Changed += GatherProblems;
        _shell.World.AnimatorChanged += OnAnimatorChanged;
        _shell.Selection.Changed += OnSelectionChanged;
        _shell.ModeChanged += OnLiveChanged;
        GatherProblems();
    }

    public AnimationGraphDocument Document { get; }

    IGraphDocument IGraphEditor.Document => Document;

    public string Noun => "animation graph";

    public override string Guid => Document.Guid;

    public override bool PicksMesh => false;

    public override PreviewMesh Mesh => PreviewMesh.Asset;

    public override string Waiting => "The preview draws once the graph cooks and a mesh is picked.";

    protected override bool ShowsUnsavedText => _showsUnsaved;

    protected override byte[] MeshAsset => MeshGuid is { } guid ? Convert.FromHexString(guid) : new byte[16];

    public override void SetMesh(PreviewMesh mesh)
    {
    }

    public IReadOnlyCollection<int> Selection => _selection;

    public IReadOnlyList<GraphProblem> Problems => _problems;

    /// <summary>The last check found an error, so the graph's blob stays as it last cooked.</summary>
    public string? CookError { get; private set; }

    /// <summary>The graph or its document's state changed.</summary>
    public event Action? Changed;

    public event Action? SelectionChanged;

    public event Action? ProblemsChanged;

    /// <summary>What the selected entity's Animator plays changed, or the selection or the mode did.</summary>
    public event Action? LiveChanged;

    public AnimationGraphGeometry Geometry() => AnimationGraphGeometry.Of(Document.Graph);

    AnimationGraphFile File => Document.Graph;

    void OnDocumentChanged()
    {
        // A node that undo or a delete took is no longer selected.
        if (_selection.RemoveWhere(id => File.Find(id) == null) > 0)
        {
            SelectionChanged?.Invoke();
        }
        GatherProblems();
        Changed?.Invoke();
        _shell.Commands.InvalidateAll();
        if (!Document.InTransaction)
        {
            _cook.Schedule();
        }
    }

    // Selection.

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
    public AnimationGraphNode? SelectedNode => _selection.Count == 1 ? File.Find(_selection.First()) : null;

    /// <summary>What a node is called on the canvas and in undo entries.</summary>
    public string Label(int id) => File.Find(id) switch
    {
        { Kind: AnimationGraphNodeKind.State } state => state.Get("name") ?? $"State {id}",
        { Kind: AnimationGraphNodeKind.Blend1D } blend => blend.Get("parameter") is { } parameter ? $"Blend by {parameter}" : $"Blend {id}",
        { Kind: AnimationGraphNodeKind.Transition } t => $"{t.Get("from") ?? "?"} → {t.Get("to") ?? "?"}",
        _ => "Node",
    };

    // Names.

    /// <summary>The states' names, in the file's order.</summary>
    public IEnumerable<string> StateNames => File.Nodes.Where(n => n.Kind == AnimationGraphNodeKind.State).Select(n => n.Get("name")).OfType<string>();

    string FreeName(string stem, IEnumerable<string> taken)
    {
        var names = taken.ToHashSet();
        for (var n = 1; ; n++)
        {
            if (!names.Contains($"{stem}{n}"))
            {
                return $"{stem}{n}";
            }
        }
    }

    // Adding and deleting nodes.

    /// <summary>Adds a state at a point of the canvas, selected, playing the first clip if the graph has one.</summary>
    public int AddState(double x, double y)
    {
        var id = File.NextId();
        var name = FreeName("state", StateNames);
        Document.Edit("Add State", g =>
        {
            var node = g.AddNode(AnimationGraphNodeKind.State);
            node.SetPosition(x, y);
            node.Set("name", name);
            if (g.Clips.FirstOrDefault() is { } clip)
            {
                node.Set("motion", clip.Name);
            }
        });
        Select([id]);
        return id;
    }

    /// <summary>Adds a blend at a point of the canvas, selected, by the first float parameter if the graph has one.</summary>
    public int AddBlend(double x, double y)
    {
        var id = File.NextId();
        Document.Edit("Add Blend", g =>
        {
            var node = g.AddNode(AnimationGraphNodeKind.Blend1D);
            node.SetPosition(x, y);
            if (g.Params.FirstOrDefault(p => p.Type == "float") is { } parameter)
            {
                node.Set("parameter", parameter.Name);
            }
        });
        Select([id]);
        return id;
    }

    /// <summary>Adds a transition between two states, selected, which leaves when the from state has played once. It returns null without two named states.</summary>
    public int? AddTransition(int from, int to)
    {
        if (from == to || File.Find(from)?.Get("name") is not { } fromName || File.Find(to)?.Get("name") is not { } toName)
        {
            return null;
        }
        var id = File.NextId();
        Document.Edit($"Add {fromName} → {toName}", g =>
        {
            var node = g.AddNode(AnimationGraphNodeKind.Transition);
            node.Set("from", fromName);
            node.Set("to", toName);
            node.Set("exit_time", "1");
            node.Set("duration", "0.25");
        });
        Select([id]);
        return id;
    }

    /// <summary>Makes a state play a blend, which is what dragging the blend's output to the state does.</summary>
    public void LinkBlend(int blend, int state) => SetField(state, "motion", new GraphLink(blend, "pose").Write());

    /// <summary>
    /// Ends a drag of a blend's link: it links the blend to the state that it ended on, and takes it off the state that
    /// it came off, in one entry. One that ends on no state and came off one is gone.
    /// </summary>
    public void MoveBlendLink(int blend, int? cameOff, int? to)
    {
        if (cameOff == to || (cameOff == null && to == null))
        {
            return;
        }
        Document.Edit($"Link {Label(blend)}", g =>
        {
            if (cameOff is { } old)
            {
                g.Find(old)?.Set("motion", null);
            }
            if (to is { } state)
            {
                g.Find(state)?.Set("motion", new GraphLink(blend, "pose").Write());
            }
        });
    }

    /// <summary>
    /// Deletes the selected nodes. A state takes the transitions from it and to it with it, and a blend leaves the
    /// states that played it without a motion, which the cooker reports.
    /// </summary>
    public void DeleteSelected()
    {
        var nodes = _selection.Select(File.Find).OfType<AnimationGraphNode>().ToList();
        if (nodes.Count == 0)
        {
            return;
        }
        Document.Edit(nodes.Count == 1 ? $"Delete {Label(nodes[0].Id)}" : $"Delete {nodes.Count} Nodes", g =>
        {
            foreach (var node in nodes)
            {
                if (node.Kind == AnimationGraphNodeKind.State && node.Get("name") is { } name)
                {
                    foreach (var t in g.Nodes.Where(n => n.Kind == AnimationGraphNodeKind.Transition && (n.Get("from") == name || n.Get("to") == name)).ToList())
                    {
                        g.Remove(t);
                    }
                }
                if (node.Kind == AnimationGraphNodeKind.Blend1D)
                {
                    foreach (var state in g.Nodes.Where(n => GraphValue.Parse(n.Get("motion") ?? "") is GraphLink link && link.Node == node.Id).ToList())
                    {
                        state.Set("motion", null);
                    }
                }
                g.Remove(node);
            }
        });
    }

    // Moving nodes.

    /// <summary>A drag of the selected nodes: begin, a move per step by the drag's offset from its start, then end.</summary>
    public void BeginMove() => Document.Begin(_selection.Count == 1 ? $"Move {Label(_selection.First())}" : $"Move {_selection.Count} Nodes");

    /// <summary>Where the selected nodes are now, which a drag's steps start from: a transition's middle, or a node's corner.</summary>
    public Dictionary<int, Vec2> MoveStarts()
    {
        var geometry = Geometry();
        var starts = new Dictionary<int, Vec2>();
        foreach (var id in _selection)
        {
            if (geometry.Find(id) is { } node)
            {
                starts[id] = new Vec2(node.Bounds.X, node.Bounds.Y);
            }
            else if (geometry.FindTransition(id) is { } transition)
            {
                starts[id] = transition.Middle;
            }
        }
        return starts;
    }

    public void MoveSelected(IReadOnlyDictionary<int, Vec2> starts, Vec2 offset) =>
        Document.Step(g =>
        {
            foreach (var (id, start) in starts)
            {
                g.Find(id)?.SetPosition(start.X + offset.X, start.Y + offset.Y);
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

    // Fields.

    /// <summary>Sets a field of a node, as the file writes it, or with null or "", removes it.</summary>
    public void SetField(int node, string key, string? value)
    {
        var words = key.Replace('_', ' ');
        var label = string.IsNullOrEmpty(value) ? $"Reset {words}" : $"Set {words}";
        Document.Edit(label, g => g.Find(node)?.Set(key, string.IsNullOrEmpty(value) ? null : value));
    }

    /// <summary>Renames a state, and in the transitions and the entry that name it. It returns false for a name that a state cannot have.</summary>
    public bool RenameState(int id, string name)
    {
        if (File.Find(id) is not { Kind: AnimationGraphNodeKind.State } state)
        {
            return false;
        }
        var old = state.Get("name");
        if (name == old)
        {
            return true;
        }
        if (name == "any" || !MaterialFile.IsIdentifier(name) || StateNames.Contains(name))
        {
            return false;
        }
        Document.Edit($"Rename {old ?? "state"} to {name}", g =>
        {
            g.Find(id)?.Set("name", name);
            if (old == null)
            {
                return;
            }
            foreach (var t in g.Nodes.Where(n => n.Kind == AnimationGraphNodeKind.Transition))
            {
                if (t.Get("from") == old)
                {
                    t.Set("from", name);
                }
                if (t.Get("to") == old)
                {
                    t.Set("to", name);
                }
            }
            if (g.Entry == old)
            {
                g.SetEntry(name);
            }
        });
        return true;
    }

    /// <summary>Sets what a transition comes from. From any state, it has no exit time, as the cooker requires.</summary>
    public void SetTransitionFrom(int id, string from) =>
        Document.Edit("Set from", g =>
        {
            if (g.Find(id) is { } t)
            {
                t.Set("from", from);
                if (from == "any")
                {
                    t.Set("exit_time", null);
                }
            }
        });

    /// <summary>The transitions that the graph tries in turn with this one: those with its from, in the file's order.</summary>
    public IReadOnlyList<AnimationGraphNode> Siblings(int id)
    {
        var from = File.Find(id)?.Get("from");
        return [.. File.Nodes.Where(n => n.Kind == AnimationGraphNodeKind.Transition && n.Get("from") == from)];
    }

    /// <summary>Tries a transition one earlier or one later among those with its from: their order in the file is the graph's.</summary>
    public void MoveTransition(int id, int by)
    {
        var siblings = Siblings(id);
        var at = siblings.ToList().FindIndex(n => n.Id == id);
        if (at < 0 || at + by < 0 || at + by >= siblings.Count)
        {
            return;
        }
        var other = siblings[at + by].Id;
        Document.Edit(by < 0 ? "Try Earlier" : "Try Later", g => g.Swap(g.Find(id)!, g.Find(other)!));
    }

    /// <summary>A blend's inputs in their order, each a clip's name and the parameter's value where it plays alone.</summary>
    public static IReadOnlyList<(int Index, string? Clip, string? At)> InputsOf(AnimationGraphNode blend)
    {
        var indices = blend.Fields.Where(f => f.Key.StartsWith("input.", StringComparison.Ordinal) || f.Key.StartsWith("at.", StringComparison.Ordinal))
            .Select(f => int.TryParse(f.Key[(f.Key.IndexOf('.') + 1)..], out var n) ? n : -1).Where(n => n >= 0).Distinct().Order();
        return [.. indices.Select(n => (n, blend.Get($"input.{n}"), blend.Get($"at.{n}")))];
    }

    /// <summary>Adds an input to a blend, after its last, playing the first clip.</summary>
    public void AddBlendInput(int id)
    {
        if (File.Find(id) is not { Kind: AnimationGraphNodeKind.Blend1D } blend)
        {
            return;
        }
        var inputs = InputsOf(blend);
        var index = inputs.Count == 0 ? 0 : inputs[^1].Index + 1;
        var at = inputs.Count > 0 && GraphNumbers.TryParse(inputs[^1].At ?? "") is { Values: [var last] } ? last + 1 : 0;
        var clip = File.Clips.FirstOrDefault()?.Name;
        Document.Edit("Add Input", g =>
        {
            var node = g.Find(id)!;
            if (clip != null)
            {
                node.Set($"input.{index}", clip);
            }
            node.Set($"at.{index}", GraphNumbers.Format(at));
        });
    }

    /// <summary>Removes a blend's input. Those after it move up one, since a blend's inputs are numbered from 0 without a gap.</summary>
    public void RemoveBlendInput(int id, int index)
    {
        if (File.Find(id) is not { Kind: AnimationGraphNodeKind.Blend1D } blend)
        {
            return;
        }
        var later = InputsOf(blend).Where(i => i.Index > index).Select(i => i.Index).ToList();
        Document.Edit("Remove Input", g =>
        {
            var node = g.Find(id)!;
            node.Set($"input.{index}", null);
            node.Set($"at.{index}", null);
            foreach (var n in later)
            {
                node.RenameField($"input.{n}", $"input.{n - 1}");
                node.RenameField($"at.{n}", $"at.{n - 1}");
            }
        });
    }

    // The graph's settings, parameters and clips.

    public void SetEntry(string state) => Document.Edit("Set Entry", g => g.SetEntry(state));

    public void SetRootMotion(string joint) => Document.Edit("Set Root Motion", g => g.SetRootMotion(joint));

    /// <summary>Adds a parameter of a type with a name that no parameter has.</summary>
    public string AddParam(string type)
    {
        var name = FreeName(type, File.Params.Select(p => p.Name));
        Document.Edit($"Add {name}", g => g.AddParam(name, type, type == "float" ? "0" : type == "bool" ? "false" : null));
        return name;
    }

    /// <summary>Changes a parameter. A new name also renames it in the blends and the conditions that read it. It returns false for a name that it cannot have.</summary>
    public bool SetParam(string name, string newName, string type, string? value)
    {
        if (newName != name && (!MaterialFile.IsIdentifier(newName) || File.Params.Any(p => p.Name == newName)))
        {
            return false;
        }
        Document.Edit($"Set {newName}", g =>
        {
            if (g.Params.FirstOrDefault(p => p.Name == name) is not { } param)
            {
                return;
            }
            AnimationGraphFile.SetParam(param, newName, type, value);
            if (newName == name)
            {
                return;
            }
            foreach (var node in g.Nodes)
            {
                if (node.Kind == AnimationGraphNodeKind.Blend1D && node.Get("parameter") == name)
                {
                    node.Set("parameter", newName);
                }
                if (node.Kind == AnimationGraphNodeKind.Transition && node.Get("when") is { } when)
                {
                    node.Set("when", RenameInCondition(when, name, newName));
                }
            }
        });
        return true;
    }

    /// <summary>
    /// A condition with a parameter's new name: the first word of each term, joined by <c>and</c>, keeping a <c>!</c>.
    /// A condition that does not read it comes back as it was.
    /// </summary>
    public static string RenameInCondition(string when, string name, string newName)
    {
        var words = when.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        var changed = false;
        var first = true;
        for (var i = 0; i < words.Length; i++)
        {
            if (first)
            {
                var negated = words[i].StartsWith('!');
                if ((negated ? words[i][1..] : words[i]) == name)
                {
                    words[i] = (negated ? "!" : "") + newName;
                    changed = true;
                }
            }
            first = words[i] == "and";
        }
        return changed ? string.Join(' ', words) : when;
    }

    public void RemoveParam(string name) =>
        Document.Edit($"Remove {name}", g =>
        {
            if (g.Params.FirstOrDefault(p => p.Name == name) is { } param)
            {
                g.Remove(param);
            }
        });

    /// <summary>Adds a clip with a name that no clip has and no animation yet.</summary>
    public string AddClip()
    {
        var name = FreeName("clip", File.Clips.Select(c => c.Name));
        Document.Edit($"Add {name}", g => g.AddClip(name, new string('0', 32)));
        return name;
    }

    /// <summary>Changes a clip. A new name also renames it in the states and the blends that play it. It returns false for a name that it cannot have.</summary>
    public bool SetClip(string name, string newName, string guid)
    {
        if (newName != name && (!MaterialFile.IsIdentifier(newName) || File.Clips.Any(c => c.Name == newName)))
        {
            return false;
        }
        Document.Edit($"Set {newName}", g =>
        {
            if (g.Clips.FirstOrDefault(c => c.Name == name) is not { } clip)
            {
                return;
            }
            AnimationGraphFile.SetClip(clip, newName, guid);
            if (newName == name)
            {
                return;
            }
            foreach (var node in g.Nodes)
            {
                if (node.Kind == AnimationGraphNodeKind.State && node.Get("motion") == name)
                {
                    node.Set("motion", newName);
                }
                if (node.Kind == AnimationGraphNodeKind.Blend1D)
                {
                    foreach (var (key, value) in node.Fields.ToList())
                    {
                        if (key.StartsWith("input.", StringComparison.Ordinal) && value == name)
                        {
                            node.Set(key, newName);
                        }
                    }
                }
            }
        });
        return true;
    }

    public void RemoveClip(string name) =>
        Document.Edit($"Remove {name}", g =>
        {
            if (g.Clips.FirstOrDefault(c => c.Name == name) is { } clip)
            {
                g.Remove(clip);
            }
        });

    /// <summary>Sends the unsaved text to the cook daemon now, and shows the answer's problems.</summary>
    public Task CookNow() => _cook.CookNow();

    void OnCooked(string text, PreviewResult result)
    {
        // From the first text that cooks, the preview plays what the daemon cooks and not the saved one.
        if (result.Error == "" && !_showsUnsaved)
        {
            _showsUnsaved = true;
            SendPreview();
        }
        ShowProblems(text, result);
    }

    /// <summary>
    /// Shows the answer to a check of a text. An answer about another text is too late to name its lines: the graph
    /// changed since it was sent, so another check will come.
    /// </summary>
    public void ShowProblems(string text, PreviewResult result)
    {
        if (text != Document.Text)
        {
            return;
        }
        _checked.Clear();
        foreach (var p in result.Problems)
        {
            var mine = string.Equals(Path.GetFullPath(p.File == "" ? "." : p.File), Document.Path, StringComparison.OrdinalIgnoreCase);
            var node = mine && p.Line > 0 ? File.NodeAt((int)p.Line) : null;
            var where = mine || p.File == "" ? "" : $"{Path.GetFileName(p.File)}:{p.Line}: ";
            _checked.Add(new GraphProblem(node, where + p.Text, p.Error, mine ? (int)p.Line : 0));
        }
        CookError = result.Error == "" ? null : result.Error;
        GatherProblems();
    }

    // The check's problems and the clips', which the cooker does not look up: it depends on any GUID that a graph names.
    void GatherProblems()
    {
        FollowDefaultMesh();
        _problems.Clear();
        _problems.AddRange(_checked);
        if (_shell.Assets.Linked)
        {
            foreach (var clip in File.Clips)
            {
                var line = File.LineOf(clip);
                if (clip.Guid.All(c => c == '0'))
                {
                    _problems.Add(new GraphProblem(null, $"the clip {clip.Name} has no animation", false, line));
                }
                else if (_shell.Assets.Find(clip.Guid)?.Kind != AssetKind.Animation)
                {
                    _problems.Add(new GraphProblem(null, $"the clip {clip.Name} names no animation in the content", false, line));
                }
            }
        }
        ProblemsChanged?.Invoke();
    }

    public override void Dispose()
    {
        _cook.Dispose();
        base.Dispose();
        Document.Changed -= OnDocumentChanged;
        _shell.Assets.Changed -= GatherProblems;
        _shell.World.AnimatorChanged -= OnAnimatorChanged;
        _shell.Selection.Changed -= OnSelectionChanged;
        _shell.ModeChanged -= OnLiveChanged;
    }

    // The live view: what the selected entity's Animator plays while the game runs.

    void OnAnimatorChanged(ulong entity)
    {
        if (entity == _shell.Selection.Entity)
        {
            OnLiveChanged();
        }
    }

    void OnSelectionChanged(IReadOnlyCollection<ulong> old, IReadOnlyCollection<ulong> entities) => OnLiveChanged();

    void OnLiveChanged() => LiveChanged?.Invoke();

    /// <summary>The selected entity's Animator, while the game runs, when it plays this graph.</summary>
    public AnimatorView? Live =>
        !_shell.IsEditing && _shell.World.Animator(_shell.Selection.Entity) is { } view && Convert.ToHexStringLower(view.Graph) == Guid ? view : null;

    /// <summary>Why there is no live view while the game runs, or null in Edit or with one.</summary>
    public string? LiveWaiting
    {
        get
        {
            if (_shell.IsEditing || Live != null)
            {
                return null;
            }
            var entity = _shell.Selection.Entity;
            if (entity == 0 || _shell.World.Find(entity) is not { } node)
            {
                return "Select an entity whose Animator plays this graph.";
            }
            if (_shell.World.Animator(entity) is not { } view)
            {
                return $"{node.Name} has no Animator whose graph is ready.";
            }
            var guid = Convert.ToHexStringLower(view.Graph);
            var graph = _shell.Assets.Find(guid) is { } asset ? Content.AssetIndex.DisplayName(asset) : guid;
            return $"{node.Name} plays {graph}.";
        }
    }

    /// <summary>How far a live view's fade is, from 0 to 1, which is 1 when it is over.</summary>
    public static double FadeOf(AnimatorView view) =>
        view.FadeDuration > 0 && view.Fade < view.FadeDuration ? Math.Clamp(view.Fade / view.FadeDuration, 0, 1) : 1;

    // The preview.

    /// <summary>What the preview plays, once it has started.</summary>
    public AnimatorView? PreviewView { get; private set; }

    /// <summary>What the canvas shows: the selected entity's Animator while the game plays this graph on it, and otherwise the preview.</summary>
    public AnimatorView? ShownView => Live ?? PreviewView;

    /// <summary>The game says what the preview plays.</summary>
    internal void OnPreviewView(AnimatorView view)
    {
        PreviewView = view;
        OnLiveChanged();
    }

    /// <summary>Sets a parameter of what the preview plays. It changes nothing in the game.</summary>
    public void SetPreviewParameter(string name, float value)
    {
        if (PreviewId is { } id)
        {
            _shell.Host.Send(new SetPreviewParameter((uint)id, name, value));
        }
    }

    /// <summary>Starts the preview again in the entry state, with the parameters at their defaults.</summary>
    public void RestartPreview()
    {
        if (PreviewId is { } id)
        {
            _shell.Host.Send(new RestartPreview((uint)id));
        }
    }

    /// <summary>The meshes that the preview can show, by name.</summary>
    public IReadOnlyList<Asset> MeshChoices =>
        [.. _shell.Assets.Assets.Values.Where(a => a.Kind == AssetKind.Mesh).OrderBy(MeshName, StringComparer.OrdinalIgnoreCase)];

    /// <summary>What the panel calls a mesh: its name, and the file that has it when it is a sub-asset.</summary>
    public static string MeshName(Asset mesh) =>
        Content.AssetIndex.IsSubasset(mesh) ? $"{Path.GetFileNameWithoutExtension(mesh.Path)} / {Content.AssetIndex.DisplayName(mesh)}" : Content.AssetIndex.DisplayName(mesh);

    /// <summary>The mesh that the preview shows: the one picked, or else the first of the model that the graph's first clip comes from.</summary>
    public string? MeshGuid => _pickedMesh ?? DefaultMesh();

    string? DefaultMesh()
    {
        foreach (var clip in File.Clips)
        {
            if (_shell.Assets.Find(clip.Guid) is { Parent: not "" } animation)
            {
                return _shell.Assets.Assets.Values.Where(a => a.Kind == AssetKind.Mesh && a.Parent == animation.Parent)
                    .OrderBy(a => a.Subasset, StringComparer.Ordinal).FirstOrDefault()?.Guid;
            }
        }
        return null;
    }

    public void SetPreviewMesh(string guid)
    {
        _pickedMesh = guid;
        FollowDefaultMesh();
    }

    // The game hears of the mesh when it changes, as when the index comes or a clip's animation does.
    void FollowDefaultMesh()
    {
        var mesh = MeshGuid;
        if (mesh != _sentMesh)
        {
            _sentMesh = mesh;
            SendSettings();
            OnLiveChanged();
        }
    }

    /// <summary>
    /// The range that a parameter's slider covers: what the graph compares it with, what its blends' inputs are at, and
    /// what it holds now, from 0 to 1 at the least.
    /// </summary>
    public (double Min, double Max) RangeOf(string parameter, double value)
    {
        var numbers = new List<double> { 0, 1, value };
        foreach (var node in File.Nodes)
        {
            if (node.Kind == AnimationGraphNodeKind.Blend1D && node.Get("parameter") == parameter)
            {
                numbers.AddRange(InputsOf(node).Select(i => GraphNumbers.TryParse(i.At ?? "") is { Values: [var at] } ? at : 0));
            }
            if (node.Kind == AnimationGraphNodeKind.Transition && node.Get("when") is { } when)
            {
                var words = when.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
                for (var i = 0; i + 2 < words.Length; i++)
                {
                    if (words[i] == parameter && GraphNumbers.TryParse(words[i + 2]) is { Values: [var compared] })
                    {
                        numbers.Add(compared);
                    }
                }
            }
        }
        return (numbers.Min(), numbers.Max());
    }
}
