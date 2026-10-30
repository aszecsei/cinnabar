using Avalonia.Input;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// The state of a drag that scrubs a field's value: whether one is open, and ending it once, however the drag stops.
/// The editor opens the edit when the drag begins and previews it as the drag moves, and <paramref name="end"/> commits it.
/// </summary>
class ScrubSession(Action end)
{
    public bool Active { get; private set; }

    /// <summary>Opens the session.</summary>
    public void Begin() => Active = true;

    /// <summary>Closes the session and ends the edit, if one was open.</summary>
    public virtual void End()
    {
        if (Active)
        {
            Active = false;
            end();
        }
    }

    /// <summary>How far a drag moves a value for a pixel: ten times as far with Shift, a tenth as far with Ctrl.</summary>
    public static double Scale(KeyModifiers modifiers) =>
        modifiers.HasFlag(KeyModifiers.Shift) ? 10 : modifiers.HasFlag(KeyModifiers.Control) ? 0.1 : 1;
}

/// <summary>A scrub session that keeps what the field held when the drag began, so each move is from there.</summary>
sealed class ScrubSession<T>(Action end) : ScrubSession(end)
{
    public T? Start { get; private set; }

    public void Begin(T start)
    {
        Start = start;
        Begin();
    }

    public override void End()
    {
        Start = default;
        base.End();
    }
}
