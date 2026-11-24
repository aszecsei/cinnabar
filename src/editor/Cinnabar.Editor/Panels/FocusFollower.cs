using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.VisualTree;
using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Ribbon;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// Tells an owner when the keyboard moves into a control and out of it, while the control is in a window: a cutscene's
/// pane, whose commands act then, or a command scope (see docs/editor/shell-and-panels.md#commands). The command palette
/// that the control opened keeps the keyboard there. The ribbon's buttons take no keyboard, so a press on one leaves it
/// where it is. Another control taking the keyboard is that control's to say, so the owner of one that loses it lets go
/// only when it still holds it.
/// </summary>
sealed class FocusFollower : IDisposable
{
    readonly Control _pane;
    readonly Action _enter;
    readonly Action _leave;
    // The window whose focus the pane follows, kept so that Dispose takes the handlers off the same window.
    readonly TopLevel? _window;

    FocusFollower(Control pane, Action enter, Action leave)
    {
        _pane = pane;
        _enter = enter;
        _leave = leave;
        _window = TopLevel.GetTopLevel(pane);
        _window?.AddHandler(InputElement.GotFocusEvent, OnFocusChanged, RoutingStrategies.Bubble, handledEventsToo: true);
        if (_window is Window window)
        {
            window.Deactivated += OnDeactivated;
            window.Activated += OnActivated;
        }
    }

    /// <summary>
    /// Follows the keyboard in a control from each time it joins a window until it leaves: <paramref name="enter"/> when
    /// the keyboard moves into it, and <paramref name="leave"/> when it moves out, its window goes to the back, or the
    /// control leaves the window.
    /// </summary>
    public static void Follow(Control pane, Action enter, Action leave)
    {
        FocusFollower? follower = null;
        pane.AttachedToVisualTree += (_, _) => follower = new FocusFollower(pane, enter, leave);
        pane.DetachedFromVisualTree += (_, _) =>
        {
            follower?.Dispose();
            follower = null;
        };
    }

    /// <summary>A command scope that is the registry's focused scope while the keyboard is in its control.</summary>
    public static void Scope(Control pane, CommandRegistry commands, ICommandScope scope) =>
        Follow(pane, () => commands.Focus(scope), () => commands.Leave(scope));

    void OnFocusChanged(object? sender, RoutedEventArgs e)
    {
        if (e.Source is not Visual focused)
        {
            return;
        }
        if (focused == _pane || focused.GetVisualAncestors().Contains(_pane))
        {
            _enter();
        }
        else if (!focused.GetVisualAncestors().OfType<CommandPalette>().Any() && focused is not CommandPalette)
        {
            _leave();
        }
    }

    // Another window, such as a floating panel, has the keyboard: the control's keys are that window's.
    void OnDeactivated(object? sender, EventArgs e) => _leave();

    // Back in this window, the keys are the control's when the focus is in it.
    void OnActivated(object? sender, EventArgs e)
    {
        if (_pane.IsKeyboardFocusWithin)
        {
            _enter();
        }
    }

    public void Dispose()
    {
        _window?.RemoveHandler(InputElement.GotFocusEvent, OnFocusChanged);
        if (_window is Window window)
        {
            window.Deactivated -= OnDeactivated;
            window.Activated -= OnActivated;
        }
        _leave();
    }
}
