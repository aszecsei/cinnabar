using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using static Cinnabar.Editor.Panels.Kit;
using DockSide = Avalonia.Controls.Dock;

namespace Cinnabar.Editor.Decisions;

/// <summary>
/// The cards of the decision editor's utility and GOAP views: a node's frame, which a click selects, and which marks the
/// selection, a problem and the live view.
/// </summary>
static class DecisionCards
{
    static readonly IBrush Body = new SolidColorBrush(Color.Parse("#26262A"));
    static readonly IBrush Border = new SolidColorBrush(Color.Parse("#3C3C42"));
    static readonly IBrush Selected = new SolidColorBrush(Palette.Accent);
    static readonly IBrush Error = new SolidColorBrush(Palette.Error);

    /// <summary>The live view's green, of what the agent runs.</summary>
    public static readonly IBrush Live = new SolidColorBrush(Color.Parse("#5BC47F"));

    public static Border Card(DecisionEditor editor, Control child, int id)
    {
        var card = new Border
        {
            Background = Body,
            BorderBrush = Border,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(4),
            Padding = new Thickness(8),
            Child = child,
        };
        card.PointerPressed += (_, e) =>
        {
            if (e.GetCurrentPoint(card).Properties.IsLeftButtonPressed)
            {
                editor.Select([id]);
                e.Handled = true;
            }
        };
        return card;
    }

    /// <summary>Marks a card: the selection over a problem over the live view.</summary>
    public static void Mark(Border card, bool selected, bool error, bool live)
    {
        card.BorderBrush = selected ? Selected : error ? Error : live ? Live : Border;
        card.BorderThickness = new Thickness(selected || error || live ? 2 : 1);
    }

    /// <summary>A score as the views show it, with up to three decimals.</summary>
    public static string Number(double v) => v.ToString("0.###", CultureInfo.InvariantCulture);
}

/// <summary>
/// The considerations of an option or a goal as cards (see docs/editor/decision-editor.md#utility): each its input, its
/// curve's kind and its graph, and a button that adds one. The live view puts each one's input on its curve.
/// </summary>
sealed class ConsiderationStrip : WrapPanel
{
    readonly DecisionEditor _editor;
    readonly Dictionary<int, (Border Card, CurveGraph Graph, TextBlock Score)> _cards = [];

    /// <summary>The considerations that an owner lists, or with no owner, those of a list of IDs that nothing lists.</summary>
    public ConsiderationStrip(DecisionEditor editor, DecisionFile file, IEnumerable<int> ids, int? owner)
    {
        _editor = editor;
        Margin = new Thickness(0, 6, 0, 0);
        foreach (var id in ids)
        {
            if (file.Find(id) is { Kind: "consideration" } c)
            {
                Children.Add(Card(c, owner));
            }
            else
            {
                Children.Add(new TextBlock { Text = $"{id} is not a consideration", Classes = { "warning" }, Margin = new Thickness(4), VerticalAlignment = VerticalAlignment.Center });
            }
        }
        if (owner is { } o)
        {
            var add = SmallButton("+ Consideration", "Score it by another input", () => _editor.AddConsideration(o), handled: true);
            add.Margin = new Thickness(4);
            Children.Add(add);
        }
    }

    Border Card(DecisionNode c, int? owner)
    {
        var id = c.Id;
        var top = new DockPanel();
        if (owner is { } o)
        {
            var remove = SmallButton("×", "Take it out, and delete it unless another lists it", () => Remove(o, id), handled: true);
            DockPanel.SetDock(remove, DockSide.Right);
            top.Children.Add(remove);
        }
        var score = new TextBlock { FontSize = 11, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4, 0), Foreground = DecisionCards.Live };
        DockPanel.SetDock(score, DockSide.Right);
        top.Children.Add(score);
        top.Children.Add(new TextBlock
        {
            Text = c.Get("input") ?? "No input",
            FontSize = 12,
            FontWeight = FontWeight.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        });
        var graph = new CurveGraph(_editor, id) { Margin = new Thickness(0, 4) };
        var curve = c.Get("curve") ?? "linear";
        var kinds = ResponseCurve.Kinds.Contains(curve) ? ResponseCurve.Kinds : [.. ResponseCurve.Kinds, curve];
        var kind = Choice(kinds, curve, picked => _editor.SetCurveKind(id, picked));
        var card = DecisionCards.Card(_editor, new StackPanel { Width = 220, Spacing = 2, Children = { top, graph, kind } }, id);
        card.Margin = new Thickness(4);
        _cards[id] = (card, graph, score);
        return card;
    }

    void Remove(int owner, int id)
    {
        if (_editor.Document.Graph.Nodes.Any(n => n.Id != owner && n.Ids("considerations").Contains(id)))
        {
            _editor.RemoveFromList(owner, "considerations", id);
        }
        else
        {
            _editor.Delete(id);
        }
    }

    /// <summary>Draws the curves again, after a change of their fields.</summary>
    public void Redraw()
    {
        foreach (var (_, graph, _) in _cards.Values)
        {
            graph.InvalidateVisual();
        }
    }

    /// <summary>Marks the cards, and puts the live view's inputs on their curves.</summary>
    public void Mark(IReadOnlyCollection<int> selection, IReadOnlySet<int> problems, IEnumerable<AgentConsideration> live)
    {
        var scored = live.GroupBy(c => (int)c.Id).ToDictionary(g => g.Key, g => g.First());
        foreach (var (id, (card, graph, score)) in _cards)
        {
            DecisionCards.Mark(card, selection.Contains(id), problems.Contains(id), false);
            var at = scored.GetValueOrDefault(id);
            graph.Live = at == null ? null : (at.Input, at.Score);
            score.Text = at == null ? "" : DecisionCards.Number(at.Score);
            graph.InvalidateVisual();
        }
    }
}
