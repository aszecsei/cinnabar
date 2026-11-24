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
/// list, and a condition is a text box that completes the blackboard's keys. A node shows each field of its kind, as
/// <see cref="DecisionFields"/> lists them, whether the file writes it or not, then the fields that the file writes and
/// its kind does not take, then a behavior tree's decorators.
/// </summary>
sealed class DecisionNodeDetails : DetailsPanel
{
    // What an argument's list offers for a value that is not a key.
    const string Constant = "Constant";

    readonly EditorShell _shell;
    readonly DecisionEditor _editor;
    public DecisionNodeDetails(EditorShell shell, DecisionEditor editor)
    {
        _shell = shell;
        _editor = editor;
        Subscriptions
            .Add(() => _editor.SelectionChanged += Refresh, () => _editor.SelectionChanged -= Refresh)
            .Add(() => _editor.Changed += Refresh, () => _editor.Changed -= Refresh)
            .Add(() => _editor.CatalogChanged += Refresh, () => _editor.CatalogChanged -= Refresh)
            .Add(() => _editor.ProblemsChanged += Refresh, () => _editor.ProblemsChanged -= Refresh);
    }

    protected override string ShownKey()
    {
        var node = _editor.SelectedNode;
        return node == null
            ? "none"
            : $"{node.Id}|{node.Kind}|{string.Join(",", node.Fields.Where(f => f.Key != "position").Select(f => f.Key + "=" + f.Value))}"
                + $"|{string.Join(",", node.Writes.Select(w => w.Key + "=" + w.Value))}"
                + $"|{string.Join(",", _editor.Keys.Select(k => k.Name + k.Type))}|{string.Join(",", _editor.Actions.Select(a => a.Name + a.Params.Count))}"
                + $"|{string.Join("|", _editor.Problems.Where(p => p.Node == node.Id).Select(p => p.Text))}";
    }

    protected override void Fill()
    {
        var node = _editor.SelectedNode;
        if (node == null)
        {
            Rows.Add(Dim("Select a node to see its fields. On a canvas, a drag from a node's foot to a node makes it a child, and Space, Tab or a right click adds a node."));
            return;
        }
        Rows.Add(new TextBlock { Text = _editor.Label(node.Id), FontSize = 15, FontWeight = FontWeight.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
        Rows.Add(new TextBlock { Text = $"node {node.Id} · {node.Kind}", Classes = { "dim" }, FontSize = 11 });
        if (DecisionFields.Of(_editor.Technique, node.Kind) is { } fields)
        {
            var decorators = DecisionFields.DecoratorsOf(_editor.Technique);
            ShowFields(node, fields);
            ShowLooseFields(node, [.. fields.Select(f => f.Key), .. decorators.Select(f => f.Key)]);
            if (decorators.Count > 0)
            {
                Rows.Add(Heading("Decorators"));
                ShowFields(node, decorators);
            }
        }
        else
        {
            // A kind or a technique that the details do not know: each field as the file writes it.
            ShowLooseFields(node, []);
            foreach (var (key, value) in node.Writes)
            {
                Rows.Add(Row($"set {key}", new TextBlock { Text = value, VerticalAlignment = VerticalAlignment.Center }));
            }
        }
        AddProblems(_editor.Problems.Where(p => p.Node == node.Id));
    }

    void ShowFields(DecisionNode node, IEnumerable<DecisionField> fields)
    {
        foreach (var field in fields.Where(f => f.Shown?.Invoke(node) != false))
        {
            switch (field.Editor)
            {
                case DecisionEditorKind.Action:
                    ShowAction(node);
                    break;
                case DecisionEditorKind.Writes:
                    ShowWrites(node);
                    break;
                default:
                    Rows.Add(Row(field.Label, Editor(node, field)));
                    break;
            }
        }
    }

    // The fields that the file writes and that are not among the shown ones, which the cooker reports.
    void ShowLooseFields(DecisionNode node, IReadOnlyCollection<string> shown)
    {
        foreach (var (key, _) in node.Fields.Where(f => f.Key != "position" && !shown.Contains(f.Key)).DistinctBy(f => f.Key).ToList())
        {
            var field = DecisionFields.Loose(_editor.Technique, key);
            Rows.Add(Row(field.Label, Editor(node, field)));
        }
    }

    // The control that edits a field of a row, by its kind of editor.
    Control Editor(DecisionNode node, DecisionField field)
    {
        var id = node.Id;
        var key = field.Key;
        var value = node.Get(key);
        switch (field.Editor)
        {
            case DecisionEditorKind.Keys:
                var keys = _editor.Keys.Where(k => field.KeyTypes == null || field.KeyTypes.Contains(k.Type)).Select(k => k.Name);
                return KeyBox(value ?? "", field.Hint, keys, text => _editor.SetField(id, key, text));
            case DecisionEditorKind.Choice:
                var picked = value ?? field.Fallback;
                return Choice(field.Choices.Contains(picked) ? field.Choices : [.. field.Choices, picked], picked,
                    v => _editor.SetField(id, key, v == field.Fallback ? null : v));
            case DecisionEditorKind.Curve:
                var curve = value ?? "linear";
                return Choice(ResponseCurve.Kinds.Contains(curve) ? ResponseCurve.Kinds : [.. ResponseCurve.Kinds, curve], curve, v => _editor.SetCurveKind(id, v));
            case DecisionEditorKind.Ids:
                var ids = node.Ids(key);
                return new TextBlock
                {
                    Text = ids.Count == 0 ? field.Hint : string.Join(", ", ids.Select(c => $"{_editor.Label(c)} {c}")),
                    TextWrapping = TextWrapping.Wrap,
                    VerticalAlignment = VerticalAlignment.Center,
                };
            default:
                return ValueBox(value ?? "", field.Hint, text => _editor.SetField(id, key, text));
        }
    }

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
        CommitBox.Attach(box, typed =>
        {
            commit(typed);
            return Verdict.Took;
        });
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
            Rows.Add(Row("Action", ValueBox(text, "name(argument = value)", t => _editor.SetField(id, "action", t))));
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
        Rows.Add(Row("Action", Choice(names, name, picked =>
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
            Rows.Add(Dim("Neither the game nor a script defines this action, so the agent's decision fails to start it."));
        }
        var parameters = known?.Params ?? [];
        foreach (var (param, type) in parameters)
        {
            Rows.Add(Row(param, ArgumentField(id, reference, param, type)));
        }
        // An argument that the action has no parameter for is warned about at run time, so it shows, to be removed.
        foreach (var (arg, value) in reference.Arguments.Where(a => parameters.All(p => p.Name != a.Name)))
        {
            var remove = SmallButton("×", "Remove it", () => _editor.SetField(id, "action", reference.With(arg, null).Write()));
            Rows.Add(Row(arg, new TextBlock { Text = value, Classes = { "warning" }, VerticalAlignment = VerticalAlignment.Center }, remove));
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
        Rows.Add(Heading("Writes"));
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
            Rows.Add(row);
        }
        if (_editor.Keys.FirstOrDefault() is { } first)
        {
            Rows.Add(SmallButton("Add Write", "Write another key when the node runs", () =>
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
}
