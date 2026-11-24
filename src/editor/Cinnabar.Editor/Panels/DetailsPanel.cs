using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;

namespace Cinnabar.Editor.Panels;

/// <summary>A problem that a panel shows: its text, and whether it is an error or a warning.</summary>
interface IProblem
{
    string Text { get; }
    bool Error { get; }
}

/// <summary>
/// An editor's details (see docs/editor/shell-and-panels.md#details-panels): a column of rows about what is selected,
/// built again only when what they show changes, so that a box keeps its focus while a drag moves its node. A build runs
/// through a <see cref="RebuildGate"/>, so one that a box's commit asks for while the rows are cleared runs after the
/// one under way, and the rows are built once.
/// </summary>
abstract class DetailsPanel : ScrollViewer
{
    // A subclass takes ScrollViewer's template only by its style key.
    protected override Type StyleKeyOverride => typeof(ScrollViewer);

    readonly StackPanel _rows;
    readonly RebuildGate _gate;
    // The key of what the rows show, or null before they are built and after Rebuild.
    string? _shown;

    protected DetailsPanel(StackPanel? rows = null)
    {
        _rows = rows ?? new StackPanel { Margin = new Thickness(8), Spacing = 2 };
        _gate = new RebuildGate(Build);
        Content = _rows;
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        Subscriptions = new ViewSubscriptions(this, attached: Refresh);
    }

    /// <summary>What the panel listens to while it shows. Internal to the tests, which attach it without a window.</summary>
    internal ViewSubscriptions Subscriptions { get; }

    /// <summary>The rows that <see cref="Fill"/> adds to.</summary>
    protected Avalonia.Controls.Controls Rows => _rows.Children;

    /// <summary>What the rows depend on. The rows are built again when it changes.</summary>
    protected abstract string ShownKey();

    /// <summary>Adds the rows to the empty <see cref="Rows"/>, from the editor's state as it is now.</summary>
    protected abstract void Fill();

    /// <summary>Whether the rows stay as they are, as while a drag or a picker uses one of them.</summary>
    protected virtual bool Holds => false;

    /// <summary>Builds the rows again if what they show changed.</summary>
    protected void Refresh() => _gate.Run();

    /// <summary>Builds the rows again, as when what they show depends on something that the key does not have.</summary>
    protected void Rebuild()
    {
        _shown = null;
        Refresh();
    }

    /// <summary>A "Problems" heading and the problems, if there are any.</summary>
    protected void AddProblems(IEnumerable<IProblem> problems)
    {
        var heading = false;
        foreach (var p in problems)
        {
            if (!heading)
            {
                Rows.Add(Kit.Heading("Problems"));
                heading = true;
            }
            Rows.Add(Kit.ProblemText(p));
        }
    }

    // The key is kept before the rows are cleared: a box that the clear takes the focus from may commit, which changes
    // the key and asks for a build, and the gate runs that one after this one.
    void Build()
    {
        if (Holds)
        {
            return;
        }
        var shown = ShownKey();
        if (shown == _shown)
        {
            return;
        }
        _shown = shown;
        _rows.Children.Clear();
        Fill();
    }
}
