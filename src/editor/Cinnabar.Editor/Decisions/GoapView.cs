using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using static Cinnabar.Editor.Panels.Kit;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.Decisions;

/// <summary>
/// A GOAP decision's view (see docs/editor/decision-editor.md#goap): its settings, its goals as cards with their
/// desired states, priorities and considerations, its actions as a table of preconditions, effects and costs, and the
/// plan preview, a start state and a goal that the cook daemon plans, as a chain of actions. The live view marks the
/// agent's current goal, with each goal's priority, and shows its plan with the step that runs.
/// </summary>
sealed class GoapView : ScrollViewer
{
    protected override Type StyleKeyOverride => typeof(ScrollViewer);

    static readonly IBrush ChipBody = new SolidColorBrush(Color.Parse("#2F4A3A"));
    static readonly IBrush ChipBorder = new SolidColorBrush(Color.Parse("#3C5C48"));
    static readonly IBrush RowBody = new SolidColorBrush(Color.Parse("#26262A"));

    readonly EditorShell _shell;
    readonly DecisionEditor _editor;
    readonly StackPanel _domain = new() { Spacing = 8 };
    readonly StackPanel _preview = new() { Spacing = 4 };
    readonly StackPanel _live = new() { Spacing = 4 };
    readonly Dictionary<int, (Border Card, TextBlock Priority)> _goals = [];
    readonly Dictionary<int, Border> _actions = [];
    readonly List<ConsiderationStrip> _strips = [];
    string _shown = "";
    string _previewShown = "";

    public GoapView(EditorShell shell, DecisionEditor editor)
    {
        _shell = shell;
        _editor = editor;
        Content = new StackPanel
        {
            Margin = new Thickness(12),
            Spacing = 10,
            Children = { _domain, _preview, _live },
        };
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        new ViewSubscriptions(this, attached: Refresh)
            .Add(() => _editor.Changed += Refresh, () => _editor.Changed -= Refresh)
            .Add(() => _editor.CatalogChanged += Refresh, () => _editor.CatalogChanged -= Refresh)
            .Add(() => _editor.ProblemsChanged += Mark, () => _editor.ProblemsChanged -= Mark)
            .Add(() => _editor.SelectionChanged += Mark, () => _editor.SelectionChanged -= Mark)
            .Add(() => _editor.LiveChanged += Mark, () => _editor.LiveChanged -= Mark)
            .Add(() => _editor.PlanChanged += ShowPreview, () => _editor.PlanChanged -= ShowPreview)
            .Add(() => _shell.Cook.StateChanged += ShowPreview, () => _shell.Cook.StateChanged -= ShowPreview);
    }

    void Refresh()
    {
        var file = _editor.Document.Graph;
        var shown = UtilityView.Shown(file) + "#" + string.Join(",", _editor.Keys.Select(k => k.Name + k.Type));
        if (shown != _shown)
        {
            _shown = shown;
            Build(file);
        }
        foreach (var strip in _strips)
        {
            strip.Redraw();
        }
        ShowPreview();
        Mark();
    }

    void Build(DecisionFile file)
    {
        _domain.Children.Clear();
        _goals.Clear();
        _actions.Clear();
        _strips.Clear();
        var keys = _editor.Keys.Select(k => k.Name).ToList();
        var settings = new WrapPanel { Orientation = Orientation.Horizontal };
        var planning = DecisionNodeDetails.KeyBox(file.Setting("keys") ?? "", "bool, int or enum keys", keys, v => _editor.SetSetting("keys", v));
        settings.Children.Add(UtilityView.Setting("Keys", planning, 260));
        settings.Children.Add(UtilityView.Setting("Max nodes", ValueBox(file.Setting("max_nodes") ?? "", "64", v => _editor.SetSetting("max_nodes", v))));
        settings.Children.Add(UtilityView.Setting("Max plan", ValueBox(file.Setting("max_plan") ?? "", "8", v => _editor.SetSetting("max_plan", v))));
        _domain.Children.Add(settings);

        _domain.Children.Add(Heading("Goals"));
        var goals = file.Nodes.Where(n => n.Kind == "goal").ToList();
        foreach (var goal in goals)
        {
            _domain.Children.Add(GoalCard(file, goal, keys));
        }
        if (goals.Count == 0)
        {
            _domain.Children.Add(Dim("No goals yet. A goal is a desired state, which the agent plans to reach."));
        }
        _domain.Children.Add(SmallButton("Add Goal", "Add a goal, with its desired state", () => _editor.AddNode("goal", 0, 0)));

        _domain.Children.Add(Heading("Actions"));
        _domain.Children.Add(ActionTable(file, keys));
        _domain.Children.Add(SmallButton("Add Action", "Add an action, whose action the details pick", () => _editor.AddNode("action", 0, 0)));
    }

    /// <summary>What the views call a goal: its ID and its desired state.</summary>
    internal static string GoalName(DecisionNode goal) => $"Goal {goal.Id}: {goal.Get("desired") ?? "no desired state"}";

    Border GoalCard(DecisionFile file, DecisionNode goal, List<string> keys)
    {
        var id = goal.Id;
        var header = new DockPanel();
        var priority = new TextBlock { FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0), Foreground = DecisionCards.Live };
        var remove = SmallButton("×", "Delete the goal", () => _editor.Delete(id), handled: true);
        DockPanel.SetDock(remove, DockSide.Right);
        DockPanel.SetDock(priority, DockSide.Right);
        header.Children.Add(remove);
        header.Children.Add(priority);
        header.Children.Add(new TextBlock { Text = $"Goal {id}", FontSize = 14, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        var fields = new StackPanel { Spacing = 2, Margin = new Thickness(0, 4, 0, 0) };
        fields.Children.Add(Row("Desired", DecisionNodeDetails.KeyBox(goal.Get("desired") ?? "", "tests, such as armed and ammo > 0", keys, v => _editor.SetField(id, "desired", v))));
        fields.Children.Add(Row("Priority", ValueBox(goal.Get("priority") ?? "", "1", v => _editor.SetField(id, "priority", v))));
        fields.Children.Add(Row("When", DecisionNodeDetails.KeyBox(goal.Get("when") ?? "", "a condition, or always", keys, v => _editor.SetField(id, "when", v))));
        var strip = new ConsiderationStrip(_editor, file, goal.Ids("considerations"), id);
        _strips.Add(strip);
        var card = DecisionCards.Card(_editor, new StackPanel { Children = { header, fields, strip } }, id);
        _goals[id] = (card, priority);
        return card;
    }

    // The actions as a table, a row each, whose cells edit their fields. A click on a row's action selects it, and the
    // details pick its action and its arguments.
    Control ActionTable(DecisionFile file, List<string> keys)
    {
        var table = new StackPanel { Spacing = 2 };
        const string columns = "150,*,*,70,*,Auto";
        var head = new Grid { ColumnDefinitions = new ColumnDefinitions(columns), ColumnSpacing = 6, Margin = new Thickness(8, 0) };
        string[] names = ["Action", "Preconditions", "Effects", "Cost", "When"];
        for (var i = 0; i < names.Length; i++)
        {
            var name = new TextBlock { Text = names[i], Classes = { "field-name" }, FontSize = 11 };
            Grid.SetColumn(name, i);
            head.Children.Add(name);
        }
        table.Children.Add(head);
        foreach (var action in file.Nodes.Where(n => n.Kind == "action"))
        {
            var id = action.Id;
            var row = new Grid { ColumnDefinitions = new ColumnDefinitions(columns), ColumnSpacing = 6 };
            Control Cell(Control c, int column)
            {
                Grid.SetColumn(c, column);
                row.Children.Add(c);
                return c;
            }
            Cell(new TextBlock { Text = _editor.Label(id), FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis }, 0);
            Cell(DecisionNodeDetails.KeyBox(action.Get("preconditions") ?? "", "always", keys, v => _editor.SetField(id, "preconditions", v)), 1);
            Cell(DecisionNodeDetails.KeyBox(action.Get("effects") ?? "", "key = value, key += n", keys, v => _editor.SetField(id, "effects", v)), 2);
            Cell(DecisionNodeDetails.KeyBox(action.Get("cost") ?? "", "1", _editor.Keys.Where(k => k.Type is "float" or "int").Select(k => k.Name), v => _editor.SetField(id, "cost", v)), 3);
            Cell(DecisionNodeDetails.KeyBox(action.Get("when") ?? "", "always", keys, v => _editor.SetField(id, "when", v)), 4);
            Cell(SmallButton("×", "Delete the action", () => _editor.Delete(id), handled: true), 5);
            var card = DecisionCards.Card(_editor, row, id);
            card.Padding = new Thickness(8, 4);
            card.Background = RowBody;
            _actions[id] = card;
            table.Children.Add(card);
        }
        return table;
    }

    // The plan preview: the start state and the goal, and the daemon's answer.
    void ShowPreview()
    {
        var file = _editor.Document.Graph;
        var goals = file.Nodes.Where(n => n.Kind == "goal").ToList();
        var planning = _editor.PlanningKeys;
        var shown = $"{_editor.PlanGoal}|{string.Join(",", goals.Select(GoalName))}|{string.Join(",", planning.Select(k => $"{k.Name}={_editor.PlanValue(k.Name)}{k.Key?.Type}"))}"
            + $"|{_shell.Cook.Linked}|{_editor.PlanStatus}|{Describe(_editor.Plan)}";
        if (shown == _previewShown)
        {
            return;
        }
        _previewShown = shown;
        _preview.Children.Clear();
        _preview.Children.Add(Heading("Plan Preview"));
        _preview.Children.Add(Dim("The cook daemon plans from this start state to the goal as an agent would, with every action usable and each cost key at its default."));
        var none = "None";
        var names = goals.Select(GoalName).ToList();
        var current = _editor.PlanGoal is { } g && file.Find(g) is { } goal ? GoalName(goal) : none;
        _preview.Children.Add(Row("Goal", Choice([none, .. names], current, picked =>
            _editor.SetPlanGoal(picked == none ? null : goals[names.IndexOf(picked)].Id))));
        foreach (var (name, key) in planning)
        {
            _preview.Children.Add(Row(name, StateField(name, key), SmallButton("↺", "Back to the blackboard's default", () => _editor.SetPlanValue(name, null))));
        }
        if (planning.Count == 0)
        {
            _preview.Children.Add(Dim("The decision names no planning keys."));
        }
        _preview.Children.Add(Answer());
    }

    static string Describe(PlanAnswer? answer) =>
        answer == null ? "none" : $"{answer.Outcome} {answer.Nodes} {string.Join(",", answer.Steps.Select(s => s.Id))} {string.Join(",", answer.Unmet)}";

    // A planning key's value in the start state, by its type: a bool's box, an int's number, an enum's names.
    Control StateField(string name, Document.BlackboardKey? key)
    {
        var value = _editor.PlanValue(name);
        switch (key?.Type)
        {
            case "bool":
                var box = new CheckBox { IsChecked = value != 0, VerticalAlignment = VerticalAlignment.Center };
                box.IsCheckedChanged += (_, _) => _editor.SetPlanValue(name, box.IsChecked == true ? 1 : 0);
                return box;
            case "int":
                return ValueBox(value.ToString(System.Globalization.CultureInfo.InvariantCulture), "0", text =>
                {
                    if (int.TryParse(text.Trim(), System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out var v))
                    {
                        _editor.SetPlanValue(name, v);
                    }
                });
            case "enum":
                var values = key.Values.ToList();
                return Choice(values, value >= 0 && value < values.Count ? values[value] : null, picked => _editor.SetPlanValue(name, values.IndexOf(picked)));
            default:
                return new TextBlock { Text = key == null ? "not a key of the blackboard" : $"a {key.Type} does not plan", Classes = { "warning" }, VerticalAlignment = VerticalAlignment.Center };
        }
    }

    Control Answer()
    {
        if (_editor.PlanStatus == PlanPreviewStatus.NoGoal)
        {
            return Dim("Pick a goal to plan for.");
        }
        if (!_shell.Cook.Linked)
        {
            return Dim("Waiting for the cook daemon.");
        }
        if (_editor.PlanStatus == PlanPreviewStatus.Refused)
        {
            return Dim("The decision or the start state has problems, which the daemon does not plan.");
        }
        if (_editor.Plan is not { } answer)
        {
            return Dim("Planning…");
        }
        var panel = new StackPanel { Spacing = 4 };
        var nodes = answer.Nodes == 1 ? "1 node" : $"{answer.Nodes} nodes";
        if (answer.Outcome == PlanOutcome.Closest)
        {
            var lacks = answer.Unmet.Length == 0 ? "" : $", which lacks {string.Join(", ", answer.Unmet)}";
            panel.Children.Add(new TextBlock { Text = $"No plan reaches the goal. The closest search{lacks}, in {nodes}:", Classes = { "warning" }, TextWrapping = TextWrapping.Wrap });
        }
        else if (answer.Steps.Length == 0)
        {
            panel.Children.Add(Dim($"The goal holds in the start state, so the plan has no actions ({nodes})."));
            return panel;
        }
        else
        {
            panel.Children.Add(Dim($"The plan, in {nodes}:"));
        }
        panel.Children.Add(Chain(answer.Steps.Select(s => ((int)s.Id, s.Action)).ToList(), null));
        return panel;
    }

    // A plan as a chain of its actions, each a chip that selects its node, with the step that runs, if one does, lit.
    Control Chain(IReadOnlyList<(int Id, string Action)> steps, int? running)
    {
        var chain = new WrapPanel { Orientation = Orientation.Horizontal };
        for (var i = 0; i < steps.Count; i++)
        {
            if (i > 0)
            {
                chain.Children.Add(new TextBlock { Text = "→", Margin = new Thickness(4, 0), VerticalAlignment = VerticalAlignment.Center });
            }
            var (id, action) = steps[i];
            var chip = new Border
            {
                Background = ChipBody,
                BorderBrush = i == running ? DecisionCards.Live : ChipBorder,
                BorderThickness = new Thickness(i == running ? 2 : 1),
                CornerRadius = new CornerRadius(10),
                Padding = new Thickness(8, 2),
                Margin = new Thickness(0, 2),
                Opacity = running is { } r && i < r ? 0.5 : 1,
                Child = new TextBlock { Text = $"{i + 1}  {action}", FontSize = 12 },
            };
            ToolTip.SetTip(chip, $"node {id}");
            chip.PointerPressed += (_, e) =>
            {
                _editor.Select([id]);
                e.Handled = true;
            };
            chain.Children.Add(chip);
        }
        return chain;
    }

    // The selection, the problems and the live view.
    void Mark()
    {
        var problems = _editor.Problems.Where(p => p.Error && p.Node != null).Select(p => p.Node!.Value).ToHashSet();
        var plan = _editor.LivePlan;
        foreach (var (id, (card, priority)) in _goals)
        {
            var current = plan != null && plan.Goal == id;
            DecisionCards.Mark(card, _editor.Selection.Contains(id), problems.Contains(id), current);
            var live = plan?.Goals.FirstOrDefault(g => g.Id == id);
            priority.Text = live == null ? "" : (current ? "▶ current  ·  " : "") + "priority " + DecisionCards.Number(live.Priority);
        }
        int? step = plan != null && plan.Step < plan.Steps.Length ? (int)plan.Steps[plan.Step] : null;
        foreach (var (id, card) in _actions)
        {
            DecisionCards.Mark(card, _editor.Selection.Contains(id), problems.Contains(id), step == id);
        }
        foreach (var strip in _strips)
        {
            strip.Mark(_editor.Selection, problems, []);
        }
        _live.Children.Clear();
        if (_shell.IsEditing)
        {
            return;
        }
        _live.Children.Add(Heading("Live Plan"));
        if (plan == null)
        {
            _live.Children.Add(Dim(_editor.LiveWaiting ?? "The agent has no plan."));
            return;
        }
        var file = _editor.Document.Graph;
        var goal = plan.Goal != 0 && file.Find((int)plan.Goal) is { } g ? GoalName(g) : "no goal";
        _live.Children.Add(Dim(plan.Searching ? $"Searching for a plan for {goal}." : $"For {goal}:"));
        if (plan.Steps.Length > 0)
        {
            _live.Children.Add(Chain([.. plan.Steps.Select(s => ((int)s, _editor.Label((int)s)))], (int)plan.Step));
        }
    }
}
