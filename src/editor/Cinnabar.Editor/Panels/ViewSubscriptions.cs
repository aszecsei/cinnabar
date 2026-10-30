using Avalonia.Controls;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// The events a view listens to while it is on screen: each pair of subscribe and unsubscribe actions runs when the
/// view joins the visual tree and when it leaves, so a view that is not shown does not rebuild on the document's changes.
/// </summary>
sealed class ViewSubscriptions
{
    readonly List<(Action Subscribe, Action Unsubscribe)> _pairs = [];

    /// <summary>
    /// Hooks the view's attach and detach. <paramref name="attached"/> runs after the subscriptions, to show what
    /// changed while the view was away, and <paramref name="detached"/> after the unsubscriptions.
    /// </summary>
    public ViewSubscriptions(Control view, Action? attached = null, Action? detached = null)
    {
        view.AttachedToVisualTree += (_, _) =>
        {
            foreach (var (subscribe, _) in _pairs)
            {
                subscribe();
            }
            attached?.Invoke();
        };
        view.DetachedFromVisualTree += (_, _) =>
        {
            foreach (var (_, unsubscribe) in _pairs)
            {
                unsubscribe();
            }
            detached?.Invoke();
        };
    }

    public ViewSubscriptions Add(Action subscribe, Action unsubscribe)
    {
        _pairs.Add((subscribe, unsubscribe));
        return this;
    }
}
