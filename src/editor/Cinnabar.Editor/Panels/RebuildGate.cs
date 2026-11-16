namespace Cinnabar.Editor.Panels;

/// <summary>
/// Runs a view's rebuild so that one never starts inside another. Clearing a view's rows runs its controls' handlers: a
/// focused box that leaves the tree loses the focus and commits its text, and that edit asks for a rebuild while the
/// first one has cleared the rows and not yet added the new ones. A rebuild that started there would add its rows, and
/// then the first would add its own after them. So a rebuild that is asked for during one waits, and runs once when
/// the one under way ends.
/// </summary>
sealed class RebuildGate(Action build)
{
    // A build that asks for another on every pass would never end. This many passes show the last state in any real case.
    const int MaxPasses = 4;

    enum State
    {
        Idle,
        Building,
        // Building, and what it shows changed since it started.
        Stale,
    }

    State _state;

    /// <summary>Builds now, or once more after the build that is under way.</summary>
    public void Run()
    {
        if (_state != State.Idle)
        {
            _state = State.Stale;
            return;
        }
        try
        {
            for (var pass = 0; pass < MaxPasses; pass++)
            {
                _state = State.Building;
                build();
                if (_state != State.Stale)
                {
                    break;
                }
            }
        }
        finally
        {
            _state = State.Idle;
        }
    }
}
