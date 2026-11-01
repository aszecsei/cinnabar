using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using static Cinnabar.Editor.Panels.Kit;

namespace Cinnabar.Editor.AnimationGraphs;

/// <summary>The animation graph editor's details: the selected state's, blend's or transition's fields, with its problems.</summary>
sealed class AnimationNodeDetails : ScrollViewer
{
    readonly EditorShell _shell;
    readonly AnimationGraphEditor _editor;
    readonly StackPanel _content = new() { Margin = new Thickness(8), Spacing = 2 };
    string _shown = "";

    public AnimationNodeDetails(EditorShell shell, AnimationGraphEditor editor)
    {
        _shell = shell;
        _editor = editor;
        Content = _content;
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        new ViewSubscriptions(this, attached: Refresh)
            .Add(() => _editor.SelectionChanged += Refresh, () => _editor.SelectionChanged -= Refresh)
            .Add(() => _editor.Changed += Refresh, () => _editor.Changed -= Refresh)
            .Add(() => _editor.ProblemsChanged += Refresh, () => _editor.ProblemsChanged -= Refresh);
    }

    AnimationGraphFile Graph => _editor.Document.Graph;

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
            : $"{node.Id}|{string.Join(",", node.Fields.Where(f => f.Key != "position").Select(f => f.Key + "=" + f.Value))}"
                + $"|{string.Join(",", Graph.Params.Select(p => p.Name + p.Type))}|{string.Join(",", Graph.Clips.Select(c => c.Name))}"
                + $"|{string.Join(",", _editor.StateNames)}|{string.Join(",", _editor.Siblings(node.Id).Select(n => n.Id))}"
                + $"|{string.Join(",", Graph.Nodes.Where(n => n.Kind == AnimationGraphNodeKind.Blend1D).Select(n => _editor.Label(n.Id)))}"
                + $"|{string.Join("|", _editor.Problems.Where(p => p.Node == node.Id).Select(p => p.Text))}";
        if (shown == _shown)
        {
            return;
        }
        _shown = shown;
        _content.Children.Clear();
        if (node == null)
        {
            _content.Children.Add(Dim("Select a state, a blend or a transition to see its fields. Drag from a state's handle to another state to add a transition."));
            return;
        }
        _content.Children.Add(new TextBlock { Text = _editor.Label(node.Id), FontSize = 15, FontWeight = FontWeight.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
        switch (node.Kind)
        {
            case AnimationGraphNodeKind.State:
                ShowState(node);
                break;
            case AnimationGraphNodeKind.Blend1D:
                ShowBlend(node);
                break;
            default:
                ShowTransition(node);
                break;
        }
        var problems = _editor.Problems.Where(p => p.Node == node.Id).ToList();
        if (problems.Count > 0)
        {
            _content.Children.Add(Heading("Problems"));
            foreach (var p in problems)
            {
                _content.Children.Add(AnimationGraphPanel.ProblemText(p));
            }
        }
    }

    Control TextField(AnimationGraphNode node, string key, string watermark) =>
        ValueBox(node.Get(key) ?? "", watermark, text => _editor.SetField(node.Id, key, text.Trim()));

    Control NumberField(AnimationGraphNode node, string key, string watermark)
    {
        var id = node.Id;
        return ValueBox(node.Get(key) ?? "", watermark, text =>
        {
            if (text.Trim() == "")
            {
                _editor.SetField(id, key, null);
            }
            else if (Numbers(text, 1) is { } n)
            {
                _editor.SetField(id, key, n.Write());
            }
            else
            {
                _shell.Console.Add(Model.LogLevel.Warning, $"animation graph: {key} is a number, such as {watermark}");
                Rebuild();
            }
        });
    }

    void ShowState(AnimationGraphNode state)
    {
        var id = state.Id;
        _content.Children.Add(Row("Name", ValueBox(state.Get("name") ?? "", "name", text =>
        {
            if (!_editor.RenameState(id, text.Trim()))
            {
                _shell.Console.Add(Model.LogLevel.Warning, $"animation graph: {text} is not a name for a state, or another state has it");
                Rebuild();
            }
        })));
        // A motion is a clip or a blend, which the menu names as its label does.
        var blends = Graph.Nodes.Where(n => n.Kind == AnimationGraphNodeKind.Blend1D).ToDictionary(n => $"{_editor.Label(n.Id)} (node {n.Id})", n => n.Id);
        var motion = state.Get("motion");
        var selected = GraphValue.Parse(motion ?? "") is GraphLink link && blends.FirstOrDefault(b => b.Value == link.Node) is { Key: not null } blend ? blend.Key : motion;
        var options = Graph.Clips.Select(c => c.Name).Concat(blends.Keys).ToList();
        if (selected != null && !options.Contains(selected))
        {
            options.Add(selected);
        }
        _content.Children.Add(Row("Motion", Choice(options, selected, picked =>
        {
            if (blends.TryGetValue(picked, out var blendId))
            {
                _editor.LinkBlend(blendId, id);
            }
            else
            {
                _editor.SetField(id, "motion", picked);
            }
        })));
        _content.Children.Add(Row("Speed", NumberField(state, "speed", "1")));
        var loop = new CheckBox { IsChecked = state.Get("loop") != "false", Content = "Loops", FontSize = 12 };
        loop.IsCheckedChanged += (_, _) => _editor.SetField(id, "loop", loop.IsChecked == true ? null : "false");
        _content.Children.Add(Row("Loop", loop));
        _content.Children.Add(Row("Enter event", TextField(state, "enter_event", "none")));
        _content.Children.Add(Row("Exit event", TextField(state, "exit_event", "none")));
    }

    void ShowBlend(AnimationGraphNode blend)
    {
        var id = blend.Id;
        _content.Children.Add(Row("Parameter", Choice(Graph.Params.Where(p => p.Type == "float").Select(p => p.Name), blend.Get("parameter"), p => _editor.SetField(id, "parameter", p))));
        var add = SmallButton("Add", "Add an input, a clip that the blend plays.", () => _editor.AddBlendInput(id));
        var header = new DockPanel { Margin = new Thickness(0, 6, 0, 0) };
        DockPanel.SetDock(add, Avalonia.Controls.Dock.Right);
        header.Children.Add(add);
        header.Children.Add(Heading("Inputs"));
        _content.Children.Add(header);
        foreach (var (index, clip, at) in AnimationGraphEditor.InputsOf(blend))
        {
            var line = new Grid { ColumnDefinitions = new ColumnDefinitions("*,60,Auto"), ColumnSpacing = 4, Margin = new Thickness(0, 1) };
            line.Children.Add(Choice(Graph.Clips.Select(c => c.Name), clip, picked => _editor.SetField(id, $"input.{index}", picked)));
            var value = ValueBox(at ?? "", "at", text =>
            {
                if (Numbers(text, 1) is { } n)
                {
                    _editor.SetField(id, $"at.{index}", n.Write());
                }
                else
                {
                    _shell.Console.Add(Model.LogLevel.Warning, "animation graph: an input's at is the parameter's value where it plays alone");
                    Rebuild();
                }
            });
            ToolTip.SetTip(value, "The parameter's value where this clip plays alone.");
            Grid.SetColumn(value, 1);
            line.Children.Add(value);
            var remove = SmallButton("×", "Remove it", () => _editor.RemoveBlendInput(id, index));
            Grid.SetColumn(remove, 2);
            line.Children.Add(remove);
            _content.Children.Add(line);
        }
    }

    void ShowTransition(AnimationGraphNode transition)
    {
        var id = transition.Id;
        _content.Children.Add(Row("From", Choice(_editor.StateNames.Append("any"), transition.Get("from"), from => _editor.SetTransitionFrom(id, from))));
        _content.Children.Add(Row("To", Choice(_editor.StateNames, transition.Get("to"), to => _editor.SetField(id, "to", to))));
        var when = TextField(transition, "when", "no condition");
        ToolTip.SetTip(when, "Conditions joined by and, such as speed > 0.1 and !grounded. A trigger is a condition alone.");
        _content.Children.Add(Row("When", when));
        if (transition.Get("from") != "any")
        {
            var exit = NumberField(transition, "exit_time", "none");
            ToolTip.SetTip(exit, "Plays of the from state's motion before it can leave.");
            _content.Children.Add(Row("Exit time", exit));
        }
        _content.Children.Add(Row("Duration", NumberField(transition, "duration", "0")));

        var siblings = _editor.Siblings(id);
        if (siblings.Count > 1)
        {
            var turn = siblings.ToList().FindIndex(n => n.Id == id);
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            var earlier = SmallButton("Earlier", "Try it before the one above", () => _editor.MoveTransition(id, -1));
            earlier.IsEnabled = turn > 0;
            var later = SmallButton("Later", "Try it after the one below", () => _editor.MoveTransition(id, 1));
            later.IsEnabled = turn < siblings.Count - 1;
            buttons.Children.Add(earlier);
            buttons.Children.Add(later);
            _content.Children.Add(Row($"Tried {turn + 1} of {siblings.Count}", buttons));
        }
    }
}
