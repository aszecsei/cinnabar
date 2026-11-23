using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.VisualTree;
using Cinnabar.Editor.Ribbon;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Cutscenes;

/// <summary>
/// Tells a cutscene's editor when the keyboard is in one of its panes, the timeline or the curve editor, while the pane
/// is in a window: the timeline's commands act then, and F and Delete act on that pane. The command palette that a
/// pane opened keeps the keyboard there. Another pane taking the keyboard is that pane's to say, so a pane that loses it
/// lets go only when it still holds it.
/// </summary>
sealed class CutscenePaneFocus : IDisposable
{
    readonly Control _pane;
    readonly CutsceneEditor _editor;
    readonly CutscenePane _which;
    // The window whose focus the pane follows, kept so that Dispose takes the handlers off the same window.
    readonly TopLevel? _window;

    public CutscenePaneFocus(Control pane, CutsceneEditor editor, CutscenePane which)
    {
        _pane = pane;
        _editor = editor;
        _which = which;
        _window = TopLevel.GetTopLevel(pane);
        _window?.AddHandler(InputElement.GotFocusEvent, OnFocusChanged, RoutingStrategies.Bubble, handledEventsToo: true);
        if (_window is Window window)
        {
            window.Deactivated += OnDeactivated;
            window.Activated += OnActivated;
        }
    }

    void OnFocusChanged(object? sender, RoutedEventArgs e)
    {
        if (e.Source is not Visual focused)
        {
            return;
        }
        if (focused == _pane || focused.GetVisualAncestors().Contains(_pane))
        {
            _editor.SetKeyboardPane(_which);
        }
        else if (!focused.GetVisualAncestors().OfType<CommandPalette>().Any() && focused is not CommandPalette)
        {
            _editor.LeaveKeyboardPane(_which);
        }
    }

    // Another window, such as a floating panel, has the keyboard: the pane's keys are that window's.
    void OnDeactivated(object? sender, EventArgs e) => _editor.LeaveKeyboardPane(_which);

    // Back in this window, the keys are the pane's when the focus is in it.
    void OnActivated(object? sender, EventArgs e)
    {
        if (_pane.IsKeyboardFocusWithin)
        {
            _editor.SetKeyboardPane(_which);
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
        _editor.LeaveKeyboardPane(_which);
    }
}
