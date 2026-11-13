using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using static Cinnabar.Editor.Panels.Kit;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.Decisions;

/// <summary>
/// The decision editor's details (see docs/editor/decision-editor.md#the-canvas): the selected node's fields, its
/// decorators and its problems. An action's arguments are each a constant or a key of the blackboard, picked from a
/// list, and a condition is a text box that completes the blackboard's keys. A utility, GOAP or HTN node shows each
/// field of its kind, whether the file writes it or not.
/// </summary>
sealed class DecisionNodeDetails : ScrollViewer
{
    // A subclass takes ScrollViewer's template only by its style key.
    protected override Type StyleKeyOverride => typeof(ScrollViewer);

    // What an argument's list offers for a value that is not a key.
    const string Constant = "Constant";

    readonly EditorShell _shell;
    readonly DecisionEditor _editor;
    readonly StackPanel _content = new() { Margin = new Thickness(8), Spacing = 2 };
    string _shown = "";

    public DecisionNodeDetails(EditorShell shell, DecisionEditor editor)
    {
        _shell = shell;
        _editor = editor;
        Content = _content;
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        new ViewSubscriptions(this, attached: Refresh)
            .Add(() => _editor.SelectionChanged += Refresh, () => _editor.SelectionChanged -= Refresh)
            .Add(() => _editor.Changed += Refresh, () => _editor.Changed -= Refresh)
            .Add(() => _editor.CatalogChanged += Refresh, () => _editor.CatalogChanged -= Refresh)
            .Add(() => _editor.ProblemsChanged += Refresh, () => _editor.ProblemsChanged -= Refresh);
    }

    void Rebuild()
    {
        _shown = "";
        Refresh();
    }

    // The panel builds again only when what it shows changed, so a box keeps its focus while a drag moves the node.
    void Refresh()
    {
        var node = _editor.SelectedNode;
        var shown = node == null
            ? "none"
            : $"{node.Id}|{node.Kind}|{string.Join(",", node.Fields.Where(f => f.Key != "position").Select(f => f.Key + "=" + f.Value))}"
                + $"|{string.Join(",", node.Writes.Select(w => w.Key + "=" + w.Value))}"
                + $"|{string.Join(",", _editor.Keys.Select(k => k.Name + k.Type))}|{string.Join(",", _editor.Actions.Select(a => a.Name + a.Params.Count))}"
                + $"|{string.Join("|", _editor.Problems.Where(p => p.Node == node.Id).Select(p => p.Text))}";
        if (shown == _shown)
        {
            return;
        }
        _shown = shown;
        _content.Children.Clear();
        if (node == null)
        {
            _content.Children.Add(Dim("Select a node to see its fields. On a canvas, a drag from a node's foot to a node makes it a child, and Space, Tab or a right click adds a node."));
            return;
        }
        _content.Children.Add(new TextBlock { Text = _editor.Label(node.Id), FontSize = 15, FontWeight = FontWeight.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
        _content.Children.Add(new TextBlock { Text = $"node {node.Id} · {node.Kind}", Classes = { "dim" }, FontSize = 11 });
        if (_editor.Technique == "behavior_tree")
        {
            ShowTreeNode(node);
        }
        else if (FieldsOf(_editor.Technique, node.Kind) is { } fields)
        {
            ShowTechniqueNode(node, fields);
        }
        else
        {
            ShowFields(node);
        }
        var problems = _editor.Problems.Where(p => p.Node == node.Id).ToList();
        if (problems.Count > 0)
        {
            _content.Children.Add(Heading("Problems"));
            foreach (var p in problems)
            {
                _content.Children.Add(AnimationGraphs.AnimationGraphPanel.ProblemText(p));
            }
        }
    }

    Control TextField(DecisionNode node, string key, string watermark) =>
        ValueBox(node.Get(key) ?? "", watermark, text => _editor.SetField(node.Id, key, text));

    Control ChoiceField(DecisionNode node, string key, IReadOnlyList<string> options, string fallback)
    {
        var value = node.Get(key) ?? fallback;
        var choices = options.Contains(value) ? options : [.. options, value];
        var id = node.Id;
        return Choice(choices, value, v => _editor.SetField(id, key, v == fallback ? null : v));
    }

    void ShowTreeNode(DecisionNode node)
    {
        switch (BehaviorTreeGeometry.ShapeOf(node.Kind))
        {
            case TreeShape.Composite:
                var children = node.Ids("children");
                _content.Children.Add(Row("Children", new TextBlock
                {
                    Text = children.Count == 0 ? "None: drag from its foot to a node" : string.Join(", ", children.Select(_editor.Label)),
                    TextWrapping = TextWrapping.Wrap,
                    VerticalAlignment = VerticalAlignment.Center,
                }));
                if (node.Kind == "parallel")
                {
                    _content.Children.Add(Row("Policy", ChoiceField(node, "policy", ["one", "all"], "")));
                }
                break;
            case TreeShape.Action:
                ShowAction(node);
                break;
            case TreeShape.Wait:
                _content.Children.Add(Row("Seconds", TimeField(node, "seconds")));
                break;
            case TreeShape.Set:
                ShowWrites(node);
                break;
            case TreeShape.Condition:
                _content.Children.Add(Row("Condition", ConditionField(node, "condition")));
                break;
            default:
                ShowFields(node);
                return;
        }
        _content.Children.Add(Heading("Decorators"));
        _content.Children.Add(Row("When", ConditionField(node, "when")));
        _content.Children.Add(Row("Abort", ChoiceField(node, "abort", ["none", "self", "lower", "both"], "none")));
        _content.Children.Add(Row("Cooldown", TimeField(node, "cooldown")));
        _content.Children.Add(Row("Time limit", TimeField(node, "time_limit")));
        _content.Children.Add(Row("Repeat", TextField(node, "repeat", "a count, or forever")));
        _content.Children.Add(Row("Invert", ChoiceField(node, "invert", ["false", "true"], "false")));
        _content.Children.Add(Row("Force", ChoiceField(node, "force", ["", "succeed", "fail"], "")));
    }

    // A time is seconds, or a float or an int key, which the box completes.
    Control TimeField(DecisionNode node, string key) =>
        KeyBox(node.Get(key) ?? "", "seconds, or a key", _editor.Keys.Where(k => k.Type is "float" or "int").Select(k => k.Name), text => _editor.SetField(node.Id, key, text));

    Control ConditionField(DecisionNode node, string key) =>
        KeyBox(node.Get(key) ?? "", "a condition, such as health < 0.3", _editor.Keys.Select(k => k.Name), text => _editor.SetField(node.Id, key, text));

    /// <summary>A box that edits text and completes the word under its end from a list of keys, as a condition's.</summary>
    internal static Control KeyBox(string text, string watermark, IEnumerable<string> keys, Action<string> commit)
    {
        var box = new AutoCompleteBox
        {
            Text = text,
            PlaceholderText = watermark,
            ItemsSource = keys.ToList(),
            FilterMode = AutoCompleteFilterMode.Custom,
            TextFilter = (search, item) => DecisionEditor.Completes(search ?? "", item ?? ""),
            TextSelector = (search, item) => DecisionEditor.Complete(search ?? "", item ?? ""),
            MinimumPrefixLength = 1,
            Classes = { "value-edit" },
        };
        var committed = text;
        void Commit()
        {
            if (box.Text != committed)
            {
                committed = box.Text ?? "";
                commit(committed);
            }
        }
        box.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter && !box.IsDropDownOpen)
            {
                Commit();
                e.Handled = true;
            }
            else if (e.Key == Key.Escape && !box.IsDropDownOpen)
            {
                box.Text = committed;
                e.Handled = true;
            }
        };
        box.LostFocus += (_, _) => Commit();
        return new Border { Classes = { "value-box", "editable" }, Child = box };
    }

    void ShowAction(DecisionNode node)
    {
        var id = node.Id;
        var text = node.Get("action") ?? "";
        var reference = ActionReference.Parse(text);
        var actions = _editor.Actions;
        if (reference == null)
        {
            // Text that is not a reference stays as it is, to be mended by hand.
            _content.Children.Add(Row("Action", ValueBox(text, "name(argument = value)", t => _editor.SetField(id, "action", t))));
            if (text != "")
            {
                return;
            }
        }
        var names = actions.Select(a => a.Name).ToList();
        var name = reference?.Name;
        if (name != null && !names.Contains(name))
        {
            names.Add(name);
        }
        _content.Children.Add(Row("Action", Choice(names, name, picked =>
        {
            // Another action keeps the arguments that it has parameters for.
            var action = actions.FirstOrDefault(a => a.Name == picked);
            var kept = reference?.Arguments.Where(a => action == null || action.Params.Any(p => p.Name == a.Name)).ToList() ?? [];
            _editor.SetField(id, "action", new ActionReference(picked, kept).Write());
        })));
        if (reference == null)
        {
            return;
        }
        var known = actions.FirstOrDefault(a => a.Name == reference.Name);
        if (known == null)
        {
            _content.Children.Add(Dim("Neither the game nor a script defines this action, so the agent's decision fails to start it."));
        }
        var parameters = known?.Params ?? [];
        foreach (var (param, type) in parameters)
        {
            _content.Children.Add(Row(param, ArgumentField(id, reference, param, type)));
        }
        // An argument that the action has no parameter for is warned about at run time, so it shows, to be removed.
        foreach (var (arg, value) in reference.Arguments.Where(a => parameters.All(p => p.Name != a.Name)))
        {
            var remove = SmallButton("×", "Remove it", () => _editor.SetField(id, "action", reference.With(arg, null).Write()));
            _content.Children.Add(Row(arg, new TextBlock { Text = value, Classes = { "warning" }, VerticalAlignment = VerticalAlignment.Center }, remove));
        }
    }

    // An argument: a key of a type that fits the parameter, picked from a list, or a constant, typed in.
    Control ArgumentField(int id, ActionReference reference, string param, string type)
    {
        var value = reference.Get(param);
        var keys = _editor.Keys.Where(k => DecisionEditor.Fits(type, k.Type)).Select(k => k.Name).ToList();
        if (type == "entity")
        {
            keys.Insert(0, "self");
        }
        var isKey = value != null && keys.Contains(value);
        var panel = new DockPanel();
        var choice = Choice([Constant, .. keys], isKey ? value : Constant, picked =>
            _editor.SetField(id, "action", reference.With(param, picked == Constant ? null : picked).Write()));
        choice.Width = 110;
        DockPanel.SetDock(choice, DockSide.Right);
        panel.Children.Add(choice);
        if (!isKey)
        {
            var watermark = type switch
            {
                "number" or "float" or "int" => "0",
                "bool" => "true",
                "string" => "\"text\"",
                "vector" or "position" => "[0, 0, 0]",
                "entity" => "none",
                _ => "",
            };
            panel.Children.Add(ValueBox(value ?? "", $"default, or {watermark}", t => _editor.SetField(id, "action", reference.With(param, t).Write())));
        }
        return panel;
    }

    void ShowWrites(DecisionNode node)
    {
        var id = node.Id;
        var writes = node.Writes.ToList();
        var keys = _editor.Keys.Select(k => k.Name).ToList();
        _content.Children.Add(Heading("Writes"));
        for (var i = 0; i < writes.Count; i++)
        {
            var at = i;
            var (key, value) = writes[i];
            var choice = Choice(keys.Contains(key) ? keys : [.. keys, key], key, picked =>
            {
                var changed = writes.ToList();
                changed[at] = (picked, value);
                _editor.SetWrites(id, changed);
            });
            choice.Width = 110;
            var box = ValueBox(value, "a value, a key or self", text =>
            {
                var changed = writes.ToList();
                changed[at] = (key, text.Trim());
                _editor.SetWrites(id, changed);
            });
            var remove = SmallButton("×", "Remove it", () => _editor.SetWrites(id, [.. writes.Where((_, j) => j != at)]));
            var row = new DockPanel();
            DockPanel.SetDock(choice, DockSide.Left);
            DockPanel.SetDock(remove, DockSide.Right);
            row.Children.Add(choice);
            row.Children.Add(remove);
            row.Children.Add(box);
            _content.Children.Add(row);
        }
        if (_editor.Keys.FirstOrDefault() is { } first)
        {
            _content.Children.Add(SmallButton("Add Write", "Write another key when the node runs", () =>
                _editor.SetWrites(id, [.. writes, (first.Name, first.Default ?? DefaultOf(first.Type, first.Values))])));
        }
    }

    static string DefaultOf(string type, IReadOnlyList<string> values) => type switch
    {
        "bool" => "false",
        "enum" => values.FirstOrDefault() ?? "",
        "entity" => "none",
        "position" or "vector" => "[0, 0, 0]",
        _ => "0",
    };

    /// <summary>
    /// The fields of a kind of node of a technique, in the order that the details show them, as
    /// docs/content/kinds/decisions.md lists them; <c>set</c> is its writes. Null for a kind that the editor does not know.
    /// </summary>
    internal static IReadOnlyList<string>? FieldsOf(string? technique, string kind) => (technique, kind) switch
    {
        ("utility", "option") => ["action", "weight", "when", "considerations", "target", "target_tag", "cooldown", "set"],
        ("utility" or "goap", "consideration") => ["input", "range", "curve", "slope", "exponent", "x_shift", "y_shift", "points"],
        ("goap", "goal") => ["desired", "priority", "when", "considerations"],
        ("goap", "action") => ["action", "preconditions", "effects", "cost", "when", "set"],
        ("htn", "task") => ["methods"],
        ("htn", "method") => ["when", "preconditions", "subtasks"],
        ("htn", "action") => ["action", "preconditions", "effects", "when", "set"],
        _ => null,
    };

    // What a field's empty box says it takes.
    static string Hint(string key) => key switch
    {
        "weight" or "priority" or "slope" or "exponent" => "1",
        "x_shift" or "y_shift" => "0",
        "range" => "[0, 1]",
        "points" => "[x, y], [x, y], ...",
        "when" => "always",
        "preconditions" => "none, or tests such as armed and ammo > 0",
        "effects" => "key = value, key += n",
        "desired" => "tests, such as down",
        "cost" => "1, or a float or an int key",
        "cooldown" => "seconds, or a key",
        "input" => "a key, distance(self, target) or since(key)",
        "target" => "an entity key",
        "target_tag" => "a tag",
        _ => key,
    };

    // A utility, GOAP or HTN node: its action, picked as a tree's is, its technique's fields, and any other that the file
    // writes, which the cooker reports.
    void ShowTechniqueNode(DecisionNode node, IReadOnlyList<string> fields)
    {
        var id = node.Id;
        foreach (var key in fields)
        {
            switch (key)
            {
                case "action":
                    ShowAction(node);
                    break;
                case "considerations" or "methods" or "subtasks":
                    var ids = node.Ids(key);
                    var none = key switch
                    {
                        "considerations" => "None",
                        "methods" => "None: drag from its foot to a method",
                        _ => "None: drag from its foot to a task or an action",
                    };
                    _content.Children.Add(Row(key, new TextBlock
                    {
                        Text = ids.Count == 0 ? none : string.Join(", ", ids.Select(c => $"{_editor.Label(c)} {c}")),
                        TextWrapping = TextWrapping.Wrap,
                        VerticalAlignment = VerticalAlignment.Center,
                    }));
                    break;
                case "curve":
                    var curve = node.Get("curve") ?? "linear";
                    var kinds = ResponseCurve.Kinds.Contains(curve) ? ResponseCurve.Kinds : [.. ResponseCurve.Kinds, curve];
                    _content.Children.Add(Row("curve", Choice(kinds, curve, picked => _editor.SetCurveKind(id, picked))));
                    break;
                case "exponent" when node.Get("curve") is "linear" or "step" or null:
                case "points" when node.Get("curve") != "table":
                    break;
                case "set":
                    ShowWrites(node);
                    break;
                default:
                    _content.Children.Add(Row(key.Replace('_', ' '), DecisionKeysField(node, key)));
                    break;
            }
        }
        foreach (var (key, _) in node.Fields.Where(f => f.Key != "position" && !fields.Contains(f.Key)).DistinctBy(f => f.Key).ToList())
        {
            _content.Children.Add(Row(key.Replace('_', ' '), DecisionKeysField(node, key)));
        }
    }

    // Another technique's node: each field as the file writes it.
    void ShowFields(DecisionNode node)
    {
        foreach (var (key, _) in node.Fields.Where(f => f.Key != "position").DistinctBy(f => f.Key).ToList())
        {
            _content.Children.Add(Row(key.Replace('_', ' '), DecisionKeysField(node, key)));
        }
        foreach (var (key, value) in node.Writes)
        {
            _content.Children.Add(Row($"set {key}", new TextBlock { Text = value, VerticalAlignment = VerticalAlignment.Center }));
        }
    }

    // A field that may name keys completes them; a number, a range or points is a plain box.
    Control DecisionKeysField(DecisionNode node, string key) =>
        key is "when" or "condition" or "input" or "desired" or "preconditions" or "effects" or "cost" or "cooldown" or "target"
            ? KeyBox(node.Get(key) ?? "", Hint(key), _editor.Keys.Select(k => k.Name), text => _editor.SetField(node.Id, key, text))
            : TextField(node, key, Hint(key));
}
