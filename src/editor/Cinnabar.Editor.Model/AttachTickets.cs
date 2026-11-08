namespace Cinnabar.Editor.Model;

/// <summary>
/// Tickets for a control's attaches, whose setup finishes after an await. Each attach takes a new ticket, and a detach
/// ends it, so setup that resumes for an attach that a detach or a later attach overtook sees that its ticket is no
/// longer current, and builds nothing.
/// </summary>
public sealed class AttachTickets
{
    int _current;

    /// <summary>Whether the control is attached now.</summary>
    public bool Attached { get; private set; }

    /// <summary>The control attached: its ticket, which its setup checks after each await.</summary>
    public int Attach()
    {
        Attached = true;
        return ++_current;
    }

    /// <summary>The control detached: the current ticket ends.</summary>
    public void Detach()
    {
        Attached = false;
        _current++;
    }

    /// <summary>Whether the setup of an attach may go on: the control is attached by that attach, and no later one.</summary>
    public bool IsCurrent(int ticket) => Attached && ticket == _current;
}
