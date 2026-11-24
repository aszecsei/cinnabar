using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Decisions;

/// <summary>How the decision details edit a field.</summary>
enum DecisionEditorKind
{
    /// <summary>A box of text.</summary>
    Text,

    /// <summary>A box that completes the blackboard's keys, only those of the field's key types when it has them.</summary>
    Keys,

    /// <summary>A list of the field's choices. Its fallback is what the node does without the field, and picking it removes the field.</summary>
    Choice,

    /// <summary>The nodes that the field lists, by their labels and IDs. A drag on the canvas, or the technique's view, changes them.</summary>
    Ids,

    /// <summary>A consideration's curve: a change of its kind removes the fields that the new kind does not take.</summary>
    Curve,

    /// <summary>An action reference: the action, picked from the actions, and each of its arguments.</summary>
    Action,

    /// <summary>The node's <c>set</c> lines, each a key and a value.</summary>
    Writes,
}

/// <summary>
/// A field of a kind of decision node, as the details show it. <see cref="Hint"/> is what its empty box says it takes,
/// and, for <see cref="DecisionEditorKind.Ids"/>, what an empty list says. <see cref="Shown"/>, when it is set, hides
/// the field from a node that does not take it, such as an exponent from a linear curve.
/// </summary>
sealed record DecisionField(string Key, DecisionEditorKind Editor, string Hint = "")
{
    public IReadOnlyList<string> Choices { get; init; } = [];

    public string Fallback { get; init; } = "";

    /// <summary>The types of the keys that a <see cref="DecisionEditorKind.Keys"/> box completes; null for every key.</summary>
    public IReadOnlyList<string>? KeyTypes { get; init; }

    public Func<DecisionNode, bool>? Shown { get; init; }

    /// <summary>The row's name: the key, with a capital and spaces.</summary>
    public string Label => Key.Length == 0 ? "" : char.ToUpperInvariant(Key[0]) + Key[1..].Replace('_', ' ');
}

/// <summary>
/// The fields of each kind of decision node that the details know, which are those that
/// docs/content/kinds/decisions.md lists, in the order that the details show them, and the behavior tree's decorators,
/// which every kind of its nodes takes.
/// <c>set</c> stands for the node's writes. To add a field, add its row here.
/// </summary>
static class DecisionFields
{
    const string BehaviorTree = "behavior_tree";
    static readonly string[] Numbers = ["float", "int"];
    static readonly string[] Entities = ["entity"];

    static readonly DecisionField Action = new("action", DecisionEditorKind.Action);
    static readonly DecisionField Writes = new("set", DecisionEditorKind.Writes);

    // A time or a cost: a number, or a float or an int key.
    static DecisionField Number(string key, string hint) => Keys(key, hint) with { KeyTypes = Numbers };

    static DecisionField Keys(string key, string hint) => new(key, DecisionEditorKind.Keys, hint);

    static DecisionField Text(string key, string hint) => new(key, DecisionEditorKind.Text, hint);

    static DecisionField Ids(string key, string none) => new(key, DecisionEditorKind.Ids, none);

    static DecisionField Choice(string key, IReadOnlyList<string> choices, string fallback) =>
        new(key, DecisionEditorKind.Choice) { Choices = choices, Fallback = fallback };

    static readonly DecisionField[] Consideration =
    [
        Keys("input", "a key, distance(self, target) or since(key)"),
        Text("range", "[0, 1]"),
        new("curve", DecisionEditorKind.Curve),
        Text("slope", "1"),
        Text("exponent", "1") with { Shown = n => n.Get("curve") is not ("linear" or "step" or null) },
        Text("x_shift", "0"),
        Text("y_shift", "0"),
        Text("points", "[x, y], [x, y], ...") with { Shown = n => n.Get("curve") == "table" },
    ];

    static readonly DecisionField[] Children = [Ids("children", "None: drag from its foot to a node")];

    static readonly Dictionary<(string Technique, string Kind), DecisionField[]> Kinds = new()
    {
        [(BehaviorTree, "sequence")] = Children,
        [(BehaviorTree, "selector")] = Children,
        [(BehaviorTree, "parallel")] = [.. Children, Choice("policy", ["one", "all"], "")],
        [(BehaviorTree, "action")] = [Action],
        [(BehaviorTree, "wait")] = [Number("seconds", "seconds, or a key")],
        [(BehaviorTree, "set")] = [Writes],
        [(BehaviorTree, "condition")] = [Keys("condition", "a condition, such as health < 0.3")],
        [("utility", "option")] =
        [
            Action,
            Text("weight", "1"),
            Keys("when", "always"),
            Ids("considerations", "None"),
            new("target", DecisionEditorKind.Keys, "an entity key") { KeyTypes = Entities },
            Text("target_tag", "a tag"),
            Number("cooldown", "seconds, or a key"),
            Writes,
        ],
        [("utility", "consideration")] = Consideration,
        [("goap", "consideration")] = Consideration,
        [("goap", "goal")] =
        [
            Keys("desired", "tests, such as down"),
            Text("priority", "1"),
            Keys("when", "always"),
            Ids("considerations", "None"),
        ],
        [("goap", "action")] =
        [
            Action,
            Keys("preconditions", "none, or tests such as armed and ammo > 0"),
            Keys("effects", "key = value, key += n"),
            Number("cost", "1, or a float or an int key"),
            Keys("when", "always"),
            Writes,
        ],
        [("htn", "task")] = [Ids("methods", "None: drag from its foot to a method")],
        [("htn", "method")] =
        [
            Keys("when", "always"),
            Keys("preconditions", "none, or tests such as armed and ammo > 0"),
            Ids("subtasks", "None: drag from its foot to a task or an action"),
        ],
        [("htn", "action")] =
        [
            Action,
            Keys("preconditions", "none, or tests such as armed and ammo > 0"),
            Keys("effects", "key = value, key += n"),
            Keys("when", "always"),
            Writes,
        ],
    };

    static readonly DecisionField[] TreeDecorators =
    [
        Keys("when", "a condition, such as health < 0.3"),
        Choice("abort", ["none", "self", "lower", "both"], "none"),
        Number("cooldown", "seconds, or a key"),
        Number("time_limit", "seconds, or a key"),
        Text("repeat", "a count, or forever"),
        Choice("invert", ["false", "true"], "false"),
        Choice("force", ["", "succeed", "fail"], ""),
    ];

    /// <summary>The (technique, kind) pairs that the table knows.</summary>
    internal static IEnumerable<(string Technique, string Kind)> Known => Kinds.Keys;

    /// <summary>The fields of a kind of node of a technique, or null for a kind that the details do not know.</summary>
    public static IReadOnlyList<DecisionField>? Of(string? technique, string kind) =>
        technique != null && Kinds.TryGetValue((technique, kind), out var fields) ? fields : null;

    /// <summary>The decorators that every known kind of node of a technique takes: a behavior tree's, and none for another.</summary>
    public static IReadOnlyList<DecisionField> DecoratorsOf(string? technique) => technique == BehaviorTree ? TreeDecorators : [];

    /// <summary>
    /// A field that the node's kind does not take, or that the details do not know, which the file writes and the cooker
    /// reports: a box, which completes keys as the field does where it is known.
    /// </summary>
    public static DecisionField Loose(string? technique, string key)
    {
        var known = Kinds.Where(k => k.Key.Technique == technique).SelectMany(k => k.Value).Concat(DecoratorsOf(technique))
            .Concat(Kinds.Values.SelectMany(f => f)).Concat(TreeDecorators)
            .FirstOrDefault(f => f.Key == key);
        return known switch
        {
            { Editor: DecisionEditorKind.Keys } => known with { Shown = null },
            { Editor: DecisionEditorKind.Text, Hint: { Length: > 0 } hint } => Text(key, hint),
            _ => Text(key, key),
        };
    }
}
