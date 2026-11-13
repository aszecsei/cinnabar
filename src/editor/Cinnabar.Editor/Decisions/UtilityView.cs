using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Panels;
using Cinnabar.Editor.Shell;
using static Cinnabar.Editor.Panels.Kit;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.Decisions;

/// <summary>
/// A utility decision's view (see docs/editor/decision-editor.md#utility): its settings, and its options as a list, each
/// with its considerations as cards, each card with its curve in a small graph whose handles a drag moves. A click
/// selects an option or a consideration, which the details show with every field. The live view shows each option's
/// last score, marks the one that the agent runs, and puts each consideration's input on its curve.
/// </summary>
sealed class UtilityView : ScrollViewer
{
    protected override Type StyleKeyOverride => typeof(ScrollViewer);

    readonly DecisionEditor _editor;
    readonly StackPanel _content = new() { Margin = new Thickness(12), Spacing = 10 };
    readonly Dictionary<int, (Border Card, TextBlock Score)> _options = [];
    readonly List<ConsiderationStrip> _strips = [];
    string _shown = "";

    public UtilityView(DecisionEditor editor)
    {
        _editor = editor;
        Content = _content;
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        new ViewSubscriptions(this, attached: Refresh)
            .Add(() => _editor.Changed += Refresh, () => _editor.Changed -= Refresh)
            .Add(() => _editor.ProblemsChanged += Mark, () => _editor.ProblemsChanged -= Mark)
            .Add(() => _editor.SelectionChanged += Mark, () => _editor.SelectionChanged -= Mark)
            .Add(() => _editor.LiveChanged += Mark, () => _editor.LiveChanged -= Mark);
    }

    // The fields that a curve's graph shows, which its handles change, and a node's place, which this view does not use.
    static readonly HashSet<string> Drawn = ["position", "slope", "exponent", "x_shift", "y_shift", "points"];

    /// <summary>
    /// What the view shows of the decision, besides the curves' shapes: it builds again only when this changes, so a
    /// drag of a handle, which changes only a shape, keeps its graph.
    /// </summary>
    internal static string Shown(DecisionFile file) =>
        string.Join("|", file.Settings.Select(s => s.Key + "=" + s.Value))
        + "#" + string.Join("|", file.Nodes.Select(n => $"{n.Id} {n.Kind} " + string.Join(",", n.Fields.Where(f => !Drawn.Contains(f.Key)).Select(f => f.Key + "=" + f.Value))));

    void Refresh()
    {
        var file = _editor.Document.Graph;
        var shown = Shown(file);
        if (shown != _shown)
        {
            _shown = shown;
            Build(file);
        }
        foreach (var strip in _strips)
        {
            strip.Redraw();
        }
        Mark();
    }

    void Build(DecisionFile file)
    {
        _content.Children.Clear();
        _options.Clear();
        _strips.Clear();
        var settings = new WrapPanel { Orientation = Orientation.Horizontal };
        settings.Children.Add(Setting("Pick", Choice(["best", "weighted"], file.Setting("pick") ?? "best", v => _editor.SetSetting("pick", v == "best" ? null : v))));
        settings.Children.Add(Setting("Within", ValueBox(file.Setting("within") ?? "", "0.1", v => _editor.SetSetting("within", v))));
        settings.Children.Add(Setting("Momentum", ValueBox(file.Setting("momentum") ?? "", "0.25", v => _editor.SetSetting("momentum", v))));
        _content.Children.Add(settings);

        var options = file.Nodes.Where(n => n.Kind == "option").ToList();
        foreach (var option in options)
        {
            _content.Children.Add(OptionCard(file, option));
        }
        if (options.Count == 0)
        {
            _content.Children.Add(Dim("No options yet. An option is an action and the considerations that score it."));
        }
        _content.Children.Add(SmallButton("Add Option", "Add an option, whose action the details pick", () => _editor.AddNode("option", 0, 0)));

        // Considerations that no option lists score nothing, which the cooker reports; they show so they can be used or deleted.
        var listed = options.SelectMany(o => o.Ids("considerations")).ToHashSet();
        var loose = file.Nodes.Where(n => n.Kind == "consideration" && !listed.Contains(n.Id)).Select(n => n.Id).ToList();
        if (loose.Count > 0)
        {
            _content.Children.Add(Heading("Considerations of no option"));
            var strip = new ConsiderationStrip(_editor, file, loose, null);
            _strips.Add(strip);
            _content.Children.Add(strip);
        }
    }

    internal static Control Setting(string name, Control value, double width = 110)
    {
        value.Width = width;
        return new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            Margin = new Thickness(0, 0, 16, 0),
            Children = { new TextBlock { Text = name, Classes = { "field-name" }, VerticalAlignment = VerticalAlignment.Center, FontSize = 12 }, value },
        };
    }

    Border OptionCard(DecisionFile file, DecisionNode option)
    {
        var header = new DockPanel();
        var score = new TextBlock { FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0), Foreground = DecisionCards.Live };
        var remove = SmallButton("×", "Delete the option", () => _editor.Delete(option.Id), handled: true);
        DockPanel.SetDock(remove, DockSide.Right);
        DockPanel.SetDock(score, DockSide.Right);
        header.Children.Add(remove);
        header.Children.Add(score);
        var facts = new List<string> { $"weight {option.Get("weight") ?? "1"}" };
        if (option.Get("when") is { } when)
        {
            facts.Add($"when {when}");
        }
        if (option.Get("target") is { } target)
        {
            facts.Add($"for each {option.Get("target_tag") ?? "perceived"} {target}");
        }
        if (option.Get("cooldown") is { } cooldown)
        {
            facts.Add($"cooldown {cooldown}");
        }
        header.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            Children =
            {
                new TextBlock { Text = _editor.Label(option.Id), FontSize = 14, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center },
                new TextBlock { Text = string.Join("  ·  ", facts), Classes = { "dim" }, FontSize = 11, VerticalAlignment = VerticalAlignment.Center },
            },
        });
        var strip = new ConsiderationStrip(_editor, file, option.Ids("considerations"), option.Id);
        _strips.Add(strip);
        var card = DecisionCards.Card(_editor, new StackPanel { Children = { header, strip } }, option.Id);
        _options[option.Id] = (card, score);
        return card;
    }

    // The selection, the problems and the live view, on the cards that there are.
    void Mark()
    {
        var problems = _editor.Problems.Where(p => p.Error && p.Node != null).Select(p => p.Node!.Value).ToHashSet();
        var options = _editor.Live?.Options ?? [];
        foreach (var (id, (card, score)) in _options)
        {
            var live = options.FirstOrDefault(o => o.Id == id);
            DecisionCards.Mark(card, _editor.Selection.Contains(id), problems.Contains(id), live?.Chosen == true);
            score.Text = live == null ? "" : (live.Chosen ? "▶ runs  ·  " : "") + "score " + DecisionCards.Number(live.Score);
        }
        foreach (var strip in _strips)
        {
            strip.Mark(_editor.Selection, problems, options.SelectMany(o => o.Considerations));
        }
    }
}
