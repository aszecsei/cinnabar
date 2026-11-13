using Cinnabar.Editor.Document;
using Cinnabar.Editor.Graphs;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Maths;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Shell;

/// <summary>Where a GOAP decision's plan preview is (see DecisionEditor.PlanStatus).</summary>
public enum PlanPreviewStatus
{
    NoGoal,
    Pending,
    Refused,
    Answered,
}

/// <summary>A kind of node that a technique has, and what it does, for the add menu.</summary>
public sealed record DecisionKind(string Kind, string Label, string Description);

/// <summary>
/// An action that a decision can start: a native action that the game registered, or a script's. Each parameter's type
/// is a blackboard type's name, or <c>number</c> for a script's number, which a float or an int fits.
/// </summary>
public sealed record DecisionAction(string Name, IReadOnlyList<(string Name, string Type)> Params, bool Script);

/// <summary>
/// An open decision in its editor (see docs/editor/decision-editor.md#decision-editor): its document, the selected
/// nodes, the problems of the last check of its text, a GOAP decision's plan preview, and the selected agent's live view.
/// Every change of the decision sends the unsaved text to the cook daemon, a moment after the last change. The view
/// turns input into calls here, so tests can drive the editor without a window.
/// </summary>
public sealed class DecisionEditor : IGraphEditor, IGraphCanvasEditor
{
    /// <summary>The kinds of node of each technique, in the order that the add menu lists them.</summary>
    public static readonly IReadOnlyDictionary<string, IReadOnlyList<DecisionKind>> Kinds = new Dictionary<string, IReadOnlyList<DecisionKind>>
    {
        ["behavior_tree"] =
        [
            new("sequence", "Sequence", "Runs its children in order until one fails."),
            new("selector", "Selector", "Runs its children in order until one succeeds."),
            new("parallel", "Parallel", "Runs its children together, until one or all succeed."),
            new("action", "Action", "Starts an action, and runs until it ends."),
            new("wait", "Wait", "Runs for a time, and then succeeds."),
            new("set", "Set", "Writes keys of the blackboard, and succeeds."),
            new("condition", "Condition", "Succeeds when its condition holds."),
        ],
        ["utility"] =
        [
            new("option", "Option", "An action and how to score it."),
            new("consideration", "Consideration", "An input mapped through a curve to a score."),
        ],
        ["goap"] =
        [
            new("goal", "Goal", "A state that the agent wants."),
            new("action", "Action", "An action that a plan can hold."),
            new("consideration", "Consideration", "An input mapped through a curve to a score."),
        ],
        ["htn"] =
        [
            new("task", "Task", "A compound task, broken down by its methods."),
            new("method", "Method", "A way to do its task."),
            new("action", "Action", "A primitive task: an action that a plan holds."),
        ],
    };

    readonly EditorShell _shell;
    readonly HashSet<int> _selection = [];
    readonly List<GraphProblem> _problems = [];
    readonly PreviewCook _cook;
    // The blackboard that the keys were last read from: its GUID and text, and the keys.
    (string? Guid, string? Text, IReadOnlyList<BlackboardKey> Keys) _board = (null, null, []);
    // The plan preview's goal and the start state's values that the user set, by planning key, and the last answer, with
    // the query and the text that it answers.
    int? _planGoal;
    readonly Dictionary<string, int> _planValues = [];
    PlanAnswered? _planAnswered;

    /// <summary>The daemon's answer to a plan query, by the query's key (see QueryKey) and the text that it was asked about.</summary>
    sealed record PlanAnswered(string Query, string Text, PlanAnswer? Answer);

    internal DecisionEditor(EditorShell shell, DecisionDocument document)
    {
        _shell = shell;
        Document = document;
        _cook = new PreviewCook(() => _shell.PreviewCooker.Linked, () => Document.Text, Cook, ShowProblems);
        Document.Changed += OnDocumentChanged;
        _shell.Assets.Changed += OnAssetsChanged;
        _shell.World.AgentChanged += OnAgentChanged;
        _shell.World.ActionsChanged += OnAssetsChanged;
        _shell.BlackboardChanged += OnBlackboardChanged;
        _shell.Selection.Changed += OnSelectionChanged;
        _shell.ModeChanged += OnLiveChanged;
    }

    public DecisionDocument Document { get; }

    IGraphDocument IGraphEditor.Document => Document;

    public string Noun => "decision";

    public string Guid => Document.Guid;

    public IReadOnlyCollection<int> Selection => _selection;

    public IReadOnlyList<GraphProblem> Problems => _problems;

    /// <summary>The last check found an error, so the decision's blob stays as it last cooked.</summary>
    public string? CookError { get; private set; }

    /// <summary>The decision or its document's state changed.</summary>
    public event Action? Changed;

    public event Action? SelectionChanged;

    public event Action? ProblemsChanged;

    /// <summary>What the selected entity's Agent runs changed, or the selection or the mode did.</summary>
    public event Action? LiveChanged;

    /// <summary>The blackboard's keys or the actions that the game and the scripts have changed.</summary>
    public event Action? CatalogChanged;

    /// <summary>The plan preview's goal or start state changed, or its answer came.</summary>
    public event Action? PlanChanged;

    DecisionFile File => Document.Graph;

    public BehaviorTreeGeometry Geometry() => BehaviorTreeGeometry.Of(File);

    /// <summary>The technique, as the file names it.</summary>
    public string? Technique => File.Technique;

    /// <summary>The kinds of node that the decision's technique has, or none for a technique that the editor does not know.</summary>
    public IReadOnlyList<DecisionKind> NodeKinds => Kinds.GetValueOrDefault(Technique ?? "") ?? [];

    void OnDocumentChanged()
    {
        // A node that undo or a delete took is no longer selected.
        if (_selection.RemoveWhere(id => File.Find(id) == null) > 0)
        {
            SelectionChanged?.Invoke();
        }
        Changed?.Invoke();
        _shell.Commands.InvalidateAll();
        if (!Document.InTransaction)
        {
            _cook.Schedule();
        }
    }

    void OnAssetsChanged() => CatalogChanged?.Invoke();

    void OnBlackboardChanged(string guid)
    {
        if (guid == File.Blackboard)
        {
            CatalogChanged?.Invoke();
            // The start state takes the blackboard's defaults, so a change of one plans again.
            if (PlanQuery() is { } query && QueryKey(query) != _planAnswered?.Query)
            {
                PlanChanged?.Invoke();
                _cook.Schedule();
            }
        }
    }

    // Selection.

    public void Select(IEnumerable<int> ids, SelectMode mode = SelectMode.Replace)
    {
        if (mode == SelectMode.Replace)
        {
            _selection.Clear();
        }
        foreach (var id in ids)
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
    public DecisionNode? SelectedNode => _selection.Count == 1 ? File.Find(_selection.First()) : null;

    /// <summary>What a node is called on the canvas and in undo entries: its action's name, or its kind.</summary>
    public string Label(int id) => File.Find(id) switch
    {
        { } node when node.Get("action") is { } action => ActionReference.Parse(action)?.Name ?? action,
        { } node => NodeKinds.FirstOrDefault(k => k.Kind == node.Kind)?.Label ?? node.Kind,
        _ => "Node",
    };

    // Adding and deleting nodes.

    /// <summary>
    /// Adds a node of a kind at a point of the canvas, selected, as the last child of a node with children when one is
    /// given, or as the last consideration of an option or a goal. An action starts the action that is given.
    /// </summary>
    public int AddNode(string kind, double x, double y, string? action = null, int? parent = null)
    {
        var id = File.NextId();
        var label = action ?? NodeKinds.FirstOrDefault(k => k.Kind == kind)?.Label ?? kind;
        Document.Edit($"Add {label}", f =>
        {
            var node = f.AddNode(kind);
            node.SetPosition(x, y);
            switch (kind)
            {
                case "parallel":
                    node.Set("policy", "one");
                    break;
                case "wait":
                    node.Set("seconds", "1");
                    break;
                case "consideration":
                    node.Set("curve", "linear");
                    break;
            }
            if (action != null)
            {
                node.Set("action", action);
            }
            if (parent is { } p && f.Find(p) is { } owner && ListFor(owner, kind) is { } key)
            {
                owner.SetIds(key, [.. owner.Ids(key), id]);
            }
        });
        Select([id]);
        return id;
    }

    /// <summary>The field that lists a node's children in this technique, or null for a node without children (see BehaviorTreeGeometry.ChildrenKey).</summary>
    public string? ChildrenKey(DecisionNode node) => BehaviorTreeGeometry.ChildrenKey(Technique, node.Kind);

    // The list of a node that a new node of a kind joins: its children, when the kind can be one, or an option's or a
    // goal's considerations.
    string? ListFor(DecisionNode owner, string kind) => kind == "consideration" && owner.Kind is "option" or "goal"
        ? "considerations"
        : ChildrenKey(owner) is { } key && CanBeChild(key, kind) ? key : null;

    // Whether a node of a kind can be listed in a list of children: a task lists methods, and a method tasks and actions.
    static bool CanBeChild(string key, string kind) => key switch
    {
        "methods" => kind == "method",
        "subtasks" => kind is "task" or "action",
        _ => true,
    };

    /// <summary>The nodes that list a node among their children: a composite or a task, or the methods that list a subtask.</summary>
    public IEnumerable<DecisionNode> ParentsOf(int id) => File.Nodes.Where(n => ChildrenKey(n) is { } key && n.Ids(key).Contains(id));

    /// <summary>The first node that lists a node among its children, or null for a root.</summary>
    public DecisionNode? ParentOf(int id) => ParentsOf(id).FirstOrDefault();

    /// <summary>
    /// Makes a node a child, which is what a drag from a node's foot to it does: a composite's child, a task's method, or
    /// a method's subtask. It goes among its new siblings by their places from left to right. A behavior tree's child and
    /// a method leave their old parent, since each has one; a subtask may be several methods' and a task may recur, so
    /// they stay. It returns false, and changes nothing, when the node has no children, when the child cannot be one of
    /// them, or when a behavior tree's child is its parent or above it.
    /// </summary>
    public bool AddChild(int parent, int child)
    {
        if (File.Find(parent) is not { } owner || ChildrenKey(owner) is not { } key || File.Find(child) is not { } node || !CanBeChild(key, node.Kind))
        {
            return false;
        }
        if (key == "children")
        {
            for (int? above = parent; above is { } a; above = ParentOf(a)?.Id)
            {
                if (a == child)
                {
                    return false;
                }
            }
        }
        if (owner.Ids(key).Contains(child))
        {
            return true;
        }
        var geometry = Geometry();
        var shared = key == "subtasks";
        Document.Edit($"Add {Label(child)} to {Label(parent)}", f =>
        {
            if (!shared)
            {
                foreach (var old in f.Nodes.Where(n => n.Id != parent && n.Ids(key).Contains(child)).ToList())
                {
                    old.SetIds(key, old.Ids(key).Where(c => c != child));
                }
            }
            var p = f.Find(parent)!;
            p.SetIds(key, SortedByX([.. p.Ids(key), child], geometry));
        });
        return true;
    }

    /// <summary>Takes a child out of a node's children, or a consideration out of an option's or a goal's, and leaves the node, in one entry.</summary>
    public void RemoveFromList(int owner, string key, int id) =>
        Document.Edit($"Remove {Label(id)} from {Label(owner)}", f =>
        {
            if (f.Find(owner) is { } node)
            {
                node.SetIds(key, node.Ids(key).Where(c => c != id));
            }
        });

    /// <summary>Moves an ID of a list to another place in it, as the arrows of a list do, in one entry.</summary>
    public void MoveInList(int owner, string key, int from, int to)
    {
        if (File.Find(owner) is not { } node || node.Ids(key) is not { } ids || from < 0 || from >= ids.Count || to < 0 || to >= ids.Count || from == to)
        {
            return;
        }
        var moved = ids.ToList();
        var id = moved[from];
        moved.RemoveAt(from);
        moved.Insert(to, id);
        Document.Edit($"Move {Label(id)}", f => f.Find(owner)?.SetIds(key, moved));
    }

    /// <summary>Adds a linear consideration to an option or a goal, as its last, selected, in one entry.</summary>
    public int AddConsideration(int owner) => AddNode("consideration", 0, 0, parent: owner);

    /// <summary>Deletes a node, and takes it out of every list that names it, in one entry.</summary>
    public void Delete(int id)
    {
        Select([id]);
        DeleteSelected();
    }

    // Children in their order from left to right on the canvas, where two at the same place keep their order.
    static List<int> SortedByX(List<int> children, BehaviorTreeGeometry geometry) =>
        [.. children.Select((id, i) => (id, i)).OrderBy(c => geometry.Find(c.id)?.Bounds.X ?? double.MaxValue).ThenBy(c => c.i).Select(c => c.id)];

    /// <summary>Deletes the selected nodes, and takes them out of the lists of children and considerations that name them, in one entry.</summary>
    public void DeleteSelected()
    {
        var ids = _selection.Where(id => File.Find(id) != null).ToHashSet();
        if (ids.Count == 0)
        {
            return;
        }
        Document.Edit(ids.Count == 1 ? $"Delete {Label(ids.First())}" : $"Delete {ids.Count} Nodes", f =>
        {
            foreach (var id in ids)
            {
                f.Remove(f.Find(id)!);
            }
            foreach (var key in BehaviorTreeGeometry.ListKeys)
            {
                foreach (var node in f.Nodes.Where(n => n.Ids(key).Any(ids.Contains)).ToList())
                {
                    node.SetIds(key, node.Ids(key).Where(c => !ids.Contains(c)));
                }
            }
        });
    }

    // Moving nodes.

    public void BeginMove() => Document.Begin(_selection.Count == 1 ? $"Move {Label(_selection.First())}" : $"Move {_selection.Count} Nodes");

    /// <summary>Where the selected nodes' corners are now, which a drag's steps start from.</summary>
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
        }
        return starts;
    }

    public void MoveSelected(IReadOnlyDictionary<int, Vec2> starts, Vec2 offset) =>
        Document.Step(f =>
        {
            foreach (var (id, start) in starts)
            {
                f.Find(id)?.SetPosition(start.X + offset.X, start.Y + offset.Y);
            }
        });

    /// <summary>
    /// Ends a drag. The parents of the moved nodes order their children from left to right, as the tree runs them or a
    /// task tries its methods, in the drag's entry.
    /// </summary>
    public void EndMove(bool cancel = false)
    {
        if (cancel)
        {
            Document.Cancel();
            return;
        }
        if (!Document.InTransaction)
        {
            return;
        }
        var geometry = Geometry();
        var parents = _selection.SelectMany(ParentsOf).Select(p => (p.Id, Key: ChildrenKey(p)!)).Distinct().ToList();
        Document.Step(f =>
        {
            foreach (var (id, key) in parents)
            {
                if (f.Find(id) is { } parent)
                {
                    var children = parent.Ids(key).ToList();
                    var sorted = SortedByX(children, geometry);
                    if (!children.SequenceEqual(sorted))
                    {
                        parent.SetIds(key, sorted);
                    }
                }
            }
        });
        Document.Commit();
    }

    // Fields.

    /// <summary>Sets a field of a node, as the file writes it, or with null or "", removes it.</summary>
    public void SetField(int node, string key, string? value)
    {
        var words = key.Replace('_', ' ');
        var label = string.IsNullOrWhiteSpace(value) ? $"Reset {words}" : $"Set {words}";
        Document.Edit(label, f => f.Find(node)?.Set(key, string.IsNullOrWhiteSpace(value) ? null : value.Trim()));
    }

    /// <summary>Sets several fields of a node in one entry, as <see cref="SetField"/> does each.</summary>
    public void SetFields(int node, string label, IReadOnlyDictionary<string, string?> fields) =>
        Document.Edit(label, f => SetEach(f, node, fields));

    static void SetEach(DecisionFile f, int node, IReadOnlyDictionary<string, string?> fields)
    {
        if (f.Find(node) is { } n)
        {
            foreach (var (key, value) in fields)
            {
                n.Set(key, string.IsNullOrWhiteSpace(value) ? null : value.Trim());
            }
        }
    }

    /// <summary>
    /// Sets a consideration's curve, in one entry, with the fields that it takes: linear and step take no exponent, and
    /// only a table has points, which a new table starts with as a line from [0, 0] to [1, 1].
    /// </summary>
    public void SetCurveKind(int node, string kind)
    {
        var fields = new Dictionary<string, string?> { ["curve"] = kind };
        if (kind is "linear" or "step")
        {
            fields["exponent"] = null;
        }
        if (kind != "table")
        {
            fields["points"] = null;
        }
        else if (File.Find(node)?.Get("points") == null)
        {
            fields["points"] = "[0, 0], [1, 1]";
        }
        SetFields(node, $"Set curve {kind}", fields);
    }

    /// <summary>
    /// Begins a drag that changes a node's fields, such as a curve's handle's, which is one undo entry however it moves.
    /// It is false, and begins nothing, while another edit's entry is open, which the drag must not step into or end.
    /// </summary>
    public bool BeginFieldDrag(string label)
    {
        if (Document.InTransaction)
        {
            return false;
        }
        Document.Begin(label);
        return true;
    }

    /// <summary>A step of a drag of fields: the fields as they are at the drag's place now.</summary>
    public void DragFields(int node, IReadOnlyDictionary<string, string?> fields)
    {
        if (Document.InTransaction)
        {
            Document.Step(f => SetEach(f, node, fields));
        }
    }

    /// <summary>Ends a drag of fields, or with cancel puts them back.</summary>
    public void EndFieldDrag(bool cancel = false)
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

    /// <summary>Replaces a node's writes.</summary>
    public void SetWrites(int node, IReadOnlyList<(string Key, string Value)> writes) =>
        Document.Edit("Set writes", f => f.Find(node)?.SetWrites(writes));

    /// <summary>Sets a setting of the decision, such as a utility decision's <c>pick</c>, or with null or "", removes it so it has its default.</summary>
    public void SetSetting(string key, string? value)
    {
        var words = key.Replace('_', ' ');
        Document.Edit(string.IsNullOrWhiteSpace(value) ? $"Reset {words}" : $"Set {words}", f => f.SetSetting(key, string.IsNullOrWhiteSpace(value) ? null : value.Trim()));
    }

    /// <summary>Names the blackboard whose keys the decision reads.</summary>
    public void SetBlackboard(string guid) => Document.Edit("Set Blackboard", f => f.SetBlackboard(guid));

    /// <summary>Renames a blackboard key wherever the decision reads or writes it, in one entry. It returns whether the decision changed.</summary>
    public bool RenameKey(string name, string newName)
    {
        var before = Document.Text;
        Document.Edit($"Rename {name} to {newName}", f => f.RenameKey(name, newName));
        return Document.Text != before;
    }

    // The blackboard and the actions.

    /// <summary>The blackboards in the content, which the decision can name.</summary>
    public IReadOnlyList<Asset> Blackboards =>
        [.. _shell.Assets.Assets.Values.Where(a => a.Kind == AssetKind.Blackboard).OrderBy(Content.AssetIndex.DisplayName, StringComparer.OrdinalIgnoreCase)];

    /// <summary>The keys of the blackboard that the decision names, from its open editor or its file, or none.</summary>
    public IReadOnlyList<BlackboardKey> Keys
    {
        get
        {
            var guid = File.Blackboard;
            var text = guid == null ? null : _shell.BlackboardText(guid);
            if (guid != _board.Guid || text != _board.Text)
            {
                _board = (guid, text, text != null && BlackboardFile.Parse(text).File is { } board ? [.. board.Keys] : []);
            }
            return _board.Keys;
        }
    }

    /// <summary>The actions that the game registered and that scripts define, by name; a native action hides a script's of its name, as at run time.</summary>
    public IReadOnlyList<DecisionAction> Actions
    {
        get
        {
            var actions = new Dictionary<string, DecisionAction>();
            foreach (var a in _shell.World.NativeActions)
            {
                actions.TryAdd(a.Name, new DecisionAction(a.Name, [.. a.Params.Select(p => (p.Name, NativeType(p.Kind)))], false));
            }
            foreach (var asset in _shell.Assets.Assets.Values.Where(a => a.Action != ""))
            {
                actions.TryAdd(asset.Action, new DecisionAction(asset.Action, [.. asset.Params.Select(p => (p.Name, ScriptType(p.Kind)))], true));
            }
            return [.. actions.Values.OrderBy(a => a.Name, StringComparer.Ordinal)];
        }
    }

    static string NativeType(AgentKind kind) => kind.ToString().ToLowerInvariant();

    static string ScriptType(ActionParamKind kind) => kind switch
    {
        ActionParamKind.Number => "number",
        ActionParamKind.Boolean => "bool",
        _ => kind.ToString().ToLowerInvariant(),
    };

    /// <summary>Whether a key of a type fits a parameter of a type, as the runtime converts arguments.</summary>
    public static bool Fits(string parameter, string key) => parameter switch
    {
        "number" or "float" or "int" => key is "float" or "int",
        "position" => key is "position",
        "string" => key is "enum",
        _ => key == parameter,
    };

    // The start of the word at the end of a text, where a key's name would go.
    static int LastWordStart(string text)
    {
        var start = text.Length;
        while (start > 0 && (char.IsAsciiLetterOrDigit(text[start - 1]) || text[start - 1] == '_'))
        {
            start--;
        }
        return start;
    }

    /// <summary>Whether a key completes the word at the end of a text, as a condition's box offers it.</summary>
    public static bool Completes(string text, string key)
    {
        var word = text[LastWordStart(text)..];
        return word.Length > 0 && key.StartsWith(word, StringComparison.Ordinal) && key != word;
    }

    /// <summary>A text with the word at its end completed to a key.</summary>
    public static string Complete(string text, string key) => text[..LastWordStart(text)] + key;

    /// <summary>What the add menu offers: the technique's kinds, and an action node for each action.</summary>
    public IEnumerable<PickerEntry> Picks()
    {
        foreach (var kind in NodeKinds)
        {
            yield return new PickerEntry(kind.Kind, kind.Label, "Node", kind.Description);
        }
        if (ActionKind is { } actionKind)
        {
            foreach (var action in Actions)
            {
                var parameters = action.Params.Count == 0 ? "no parameters" : string.Join(", ", action.Params.Select(p => $"{p.Name}: {p.Type}"));
                yield return new PickerEntry($"{actionKind}:{action.Name}", action.Name, action.Script ? "Script action" : "Native action", parameters);
            }
        }
    }

    // The kind of node that names an action in the technique.
    string? ActionKind => Technique switch
    {
        "utility" => "option",
        "behavior_tree" or "goap" or "htn" => "action",
        _ => null,
    };

    /// <summary>Adds what the add menu picked: a node of a kind, or an action node for an action.</summary>
    public int AddPicked(string pick, Vec2 at, int? parent = null)
    {
        var colon = pick.IndexOf(':');
        return colon < 0 ? AddNode(pick, at.X, at.Y, parent: parent) : AddNode(pick[..colon], at.X, at.Y, pick[(colon + 1)..], parent);
    }

    // The plan preview: a GOAP decision's plan from a start state to a goal, as the cook daemon plans it.

    /// <summary>The planning keys that the decision names, in its order, with their blackboard keys, or null for a key that the blackboard does not have.</summary>
    public IReadOnlyList<(string Name, BlackboardKey? Key)> PlanningKeys =>
        [.. (File.Setting("keys") ?? "").Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .Distinct()
            .Select(name => (name, Keys.FirstOrDefault(k => k.Name == name)))];

    /// <summary>The goal that the plan preview plans for, when the decision has it.</summary>
    public int? PlanGoal => _planGoal is { } goal && File.Find(goal) is { Kind: "goal" } ? goal : null;

    /// <summary>A planning key's value in the plan preview's start state: the one that the user set, or the blackboard's default.</summary>
    public int PlanValue(string key)
    {
        if (_planValues.TryGetValue(key, out var value))
        {
            return value;
        }
        return Keys.FirstOrDefault(k => k.Name == key) is { } k ? DefaultPlanValue(k) : 0;
    }

    /// <summary>A key's default as a planning key's value: a bool is 0 or 1, an int is itself, and an enum is its index.</summary>
    public static int DefaultPlanValue(BlackboardKey key) => key.Type switch
    {
        "bool" => key.Default == "true" ? 1 : 0,
        "int" => int.TryParse(key.Default, System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out var v) ? v : 0,
        "enum" => Math.Max(0, key.Values.ToList().IndexOf(key.Default ?? "")),
        _ => 0,
    };

    /// <summary>Picks the goal of the plan preview, or none, and plans it.</summary>
    public void SetPlanGoal(int? goal)
    {
        _planGoal = goal;
        PlanSetupChanged();
    }

    /// <summary>Sets a planning key's value in the plan preview's start state, or with null its default, and plans it.</summary>
    public void SetPlanValue(string key, int? value)
    {
        if (value is { } v)
        {
            _planValues[key] = v;
        }
        else
        {
            _planValues.Remove(key);
        }
        PlanSetupChanged();
    }

    void PlanSetupChanged()
    {
        PlanChanged?.Invoke();
        _cook.Schedule();
    }

    /// <summary>
    /// The query that the next check sends, or null without a goal: the goal, and the value of each planning key of a
    /// type that plans, as <see cref="PlanValue"/> gives it, so the query holds everything that its answer depends on
    /// besides the text.
    /// </summary>
    public PlanQuery? PlanQuery()
    {
        if (Technique != "goap" || PlanGoal is not { } goal)
        {
            return null;
        }
        return new PlanQuery((uint)goal, [.. PlanningKeys.Where(k => k.Key?.Type is "bool" or "int" or "enum").Select(k => new PlanValue(k.Name, PlanValue(k.Name)))]);
    }

    // A query as a key that an answer is matched by.
    static string QueryKey(PlanQuery? query) =>
        query == null ? "" : $"{query.Goal}:{string.Join(",", query.State.Select(v => $"{v.Key}={v.Value}"))}";

    // The last answer, when it answers the query and the text as they are now.
    PlanAnswered? CurrentAnswer => _planAnswered is { } a && a.Query == QueryKey(PlanQuery()) && a.Text == Document.Text ? a : null;

    /// <summary>The plan preview's answer, for the goal, the start state and the text as they are, or null (see <see cref="PlanStatus"/>).</summary>
    public PlanAnswer? Plan => CurrentAnswer?.Answer;

    /// <summary>
    /// Where the plan preview is: without a goal, waiting for the answer to the query and the text as they are, refused
    /// when the daemon answered them without a plan, as for a decision with problems, or answered.
    /// </summary>
    public PlanPreviewStatus PlanStatus => PlanQuery() == null
        ? PlanPreviewStatus.NoGoal
        : CurrentAnswer switch
        {
            null => PlanPreviewStatus.Pending,
            { Answer: null } => PlanPreviewStatus.Refused,
            _ => PlanPreviewStatus.Answered,
        };

    // A check of a text, with the plan query as it is when the check is sent; the answer keeps the query and the text, so
    // a later setup or text does not show it.
    async Task<PreviewResult> Cook(string text)
    {
        var query = PlanQuery();
        var result = await _shell.PreviewCooker.CookPreview(Guid, text, query);
        _planAnswered = new PlanAnswered(QueryKey(query), text, query == null ? null : result.Plan.FirstOrDefault());
        return result;
    }

    // Problems.

    /// <summary>Sends the unsaved text to the cook daemon now, and shows the answer's problems.</summary>
    public Task CookNow() => _cook.CookNow();

    /// <summary>
    /// Shows the answer to a check of a text. An answer about another text is too late to name its lines: the decision
    /// changed since it was sent, so another check will come.
    /// </summary>
    public void ShowProblems(string text, PreviewResult result)
    {
        if (text != Document.Text)
        {
            return;
        }
        _problems.Clear();
        foreach (var p in result.Problems)
        {
            var mine = string.Equals(Path.GetFullPath(p.File == "" ? "." : p.File), Document.Path, StringComparison.OrdinalIgnoreCase);
            var node = mine && p.Line > 0 ? File.NodeAt((int)p.Line) : null;
            var where = mine || p.File == "" ? "" : $"{Path.GetFileName(p.File)}:{p.Line}: ";
            _problems.Add(new GraphProblem(node, where + p.Text, p.Error, mine ? (int)p.Line : 0));
        }
        CookError = result.Error == "" ? null : result.Error;
        ProblemsChanged?.Invoke();
        PlanChanged?.Invoke();
    }

    public void Dispose()
    {
        _cook.Dispose();
        Document.Changed -= OnDocumentChanged;
        _shell.Assets.Changed -= OnAssetsChanged;
        _shell.World.AgentChanged -= OnAgentChanged;
        _shell.World.ActionsChanged -= OnAssetsChanged;
        _shell.BlackboardChanged -= OnBlackboardChanged;
        _shell.Selection.Changed -= OnSelectionChanged;
        _shell.ModeChanged -= OnLiveChanged;
    }

    // The live view: what the selected entity's Agent runs while the game does.

    void OnAgentChanged(ulong entity)
    {
        if (entity == _shell.Selection.Entity)
        {
            OnLiveChanged();
        }
    }

    void OnSelectionChanged(IReadOnlyCollection<ulong> old, IReadOnlyCollection<ulong> entities) => OnLiveChanged();

    void OnLiveChanged() => LiveChanged?.Invoke();

    /// <summary>The selected entity's Agent, while the game runs, when it runs this decision.</summary>
    public AgentView? Live =>
        !_shell.IsEditing && _shell.World.Agent(_shell.Selection.Entity) is { } view && Convert.ToHexStringLower(view.Decision) == Guid ? view : null;

    /// <summary>The live agent's plan, a GOAP or an HTN decision's, or null.</summary>
    public AgentPlan? LivePlan => Live?.Plan.FirstOrDefault();

    /// <summary>
    /// The nodes of the live agent's run on the canvas: a behavior tree's nodes that run, or an HTN plan's path, each
    /// task that it broke down with the method that it chose and the plan's actions; and the node that runs now, a plan's
    /// action at its step.
    /// </summary>
    public (IReadOnlySet<int> Path, int? Running) LivePath()
    {
        if (Live is not { } view)
        {
            return (new HashSet<int>(), null);
        }
        if (view.Plan.FirstOrDefault() is not { } plan)
        {
            return (view.Nodes.Where(n => n.Running).Select(n => (int)n.Id).ToHashSet(), null);
        }
        var path = plan.Methods.SelectMany(m => new[] { (int)m.Task, (int)m.Method }).Concat(plan.Steps.Select(s => (int)s)).ToHashSet();
        int? running = plan.Step < plan.Steps.Length ? (int)plan.Steps[plan.Step] : null;
        return (path, running);
    }

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
                return "Select an entity whose Agent runs this decision.";
            }
            if (_shell.World.Agent(entity) is not { } view)
            {
                return $"{node.Name} has no Agent that is ready.";
            }
            var guid = Convert.ToHexStringLower(view.Decision);
            var decision = _shell.Assets.Find(guid) is { } asset ? Content.AssetIndex.DisplayName(asset) : guid;
            return $"{node.Name} runs {decision}.";
        }
    }
}
