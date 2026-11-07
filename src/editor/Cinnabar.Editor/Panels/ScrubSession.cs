using Avalonia.Input;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Panels;

static class ScrubSession
{
    /// <summary>How far a drag moves a value for a pixel: ten times as far with Shift, a tenth as far with Ctrl.</summary>
    public static double Scale(KeyModifiers modifiers) =>
        modifiers.HasFlag(KeyModifiers.Shift) ? 10 : modifiers.HasFlag(KeyModifiers.Control) ? 0.1 : 1;
}

/// <summary>
/// A drag that scrubs a field's value: the edit it previews in, and what the field held when it began, so each move
/// is from there. It starts only with an edit of its own, and it is over once the edit ends, by the drag or by the shell.
/// </summary>
sealed class ScrubSession<T>
{
    (SceneEdit Edit, T Start)? _open;

    /// <summary>The drag's edit and start, or null when no drag is under way.</summary>
    public (SceneEdit Edit, T Start)? Open => _open;

    /// <summary>Starts the drag in an edit, or with null, as when another edit is open, does not.</summary>
    public bool Begin(SceneEdit? edit, T start)
    {
        if (edit == null)
        {
            return false;
        }
        _open = (edit, start);
        edit.Ended += _ =>
        {
            if (_open?.Edit == edit)
            {
                _open = null;
            }
        };
        return true;
    }

    /// <summary>Ends the drag and commits its edit, however the drag stops. Nothing when none is under way.</summary>
    public void End() => _open?.Edit.Commit();
}
