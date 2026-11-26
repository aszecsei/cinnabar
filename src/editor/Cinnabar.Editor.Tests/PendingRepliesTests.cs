using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Tests;

public class PendingRepliesTests
{
    [Fact]
    public void AReplyTakesItsOwnPendingOnceAndRepliesThatShareIdsShareACount()
    {
        var replies = new PendingReplies<string>();
        var first = replies.Add("a");
        var second = replies.Add("b");
        Assert.Equal(1u, first);
        Assert.Equal(2u, second);
        Assert.True(replies.TryTake(second, out var taken));
        Assert.Equal("b", taken);
        Assert.False(replies.TryTake(second, out _));
        Assert.False(replies.TryTake(99, out _));
        replies.Discard(first);
        Assert.False(replies.TryTake(first, out _));

        var ids = new ReplyIds();
        Assert.Equal(1u, new PendingReplies<string>(ids).Add("x"));
        Assert.Equal(2u, new PendingReplies<int>(ids).Add(7));
    }

    [Fact]
    public void FailAllCallsEachPendingThenDropsThemAndClearCallsNone()
    {
        var replies = new PendingReplies<string>();
        replies.Add("a");
        replies.Add("b");
        var failed = new List<string>();
        replies.FailAll(failed.Add);
        Assert.Equal(["a", "b"], failed.Order());
        Assert.Equal(0, replies.Count);

        replies.Add("c");
        replies.Clear();
        replies.FailAll(failed.Add);
        Assert.Equal(2, failed.Count);
    }
}
