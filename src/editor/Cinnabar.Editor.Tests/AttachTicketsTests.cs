using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Tests;

/// <summary>The viewport's attach tickets, without a compositor: setup that resumes for an overtaken attach builds nothing.</summary>
public sealed class AttachTicketsTests
{
    [Fact]
    public void ASetupOvertakenByADetachAndAnAttachIsNotCurrent()
    {
        var tickets = new AttachTickets();
        // An attach starts its setup, which awaits the compositor; a docking move detaches and attaches again meanwhile.
        var first = tickets.Attach();
        Assert.True(tickets.IsCurrent(first));
        tickets.Detach();
        Assert.False(tickets.Attached);
        Assert.False(tickets.IsCurrent(first));
        var second = tickets.Attach();

        // When the first setup resumes, it is no longer current, so only the second builds a surface.
        Assert.False(tickets.IsCurrent(first));
        Assert.True(tickets.IsCurrent(second));
        Assert.True(tickets.Attached);

        // A detach ends the second too.
        tickets.Detach();
        Assert.False(tickets.IsCurrent(second));
    }
}
