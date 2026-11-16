using Avalonia.Controls;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// The events a view listens to while it is on screen: each pair of subscribe and unsubscribe actions runs when the
/// view joins the visual tree and when it leaves, so a view that is not shown does not rebuild on the document's changes.
/// </summary>
sealed class ViewSubscriptions
{
    readonly List<(Action Subscribe, Action Unsubscribe)> _pairs = [];
    readonly Action? _attached;
    readonly Action? _detached;

    /// <summary>
    /// Hooks the view's attach and detach. <paramref name="attached"/> runs after the subscriptions, to show what
    /// changed while the view was away, and <paramref name="detached"/> after the unsubscriptions.
    /// </summary>
    public ViewSubscriptions(Control view, Action? attached = null, Action? detached = null)
    {
        _attached = attached;
        _detached = detached;
        view.AttachedToVisualTree += (_, _) => Attach();
        view.DetachedFromVisualTree += (_, _) => Detach();
    }

    public ViewSubscriptions Add(Action subscribe, Action unsubscribe)
    {
        _pairs.Add((subscribe, unsubscribe));
        return this;
    }

    /// <summary>What the view's attach does. Internal to the tests, which have no visual tree to attach a view to.</summary>
    internal void Attach()
    {
        foreach (var (subscribe, _) in _pairs)
        {
            subscribe();
        }
        _attached?.Invoke();
    }

    /// <summary>What the view's detach does.</summary>
    internal void Detach()
    {
        foreach (var (_, unsubscribe) in _pairs)
        {
            unsubscribe();
        }
        _detached?.Invoke();
    }
}
