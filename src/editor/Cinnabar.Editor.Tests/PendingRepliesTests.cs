using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Tests;

public class PendingRepliesTests
{
    [Fact]
    public void IdsCountFromOneAndAReplyTakesItsPendingOnce()
    {
        var replies = new PendingReplies<string>();
        var first = replies.Add("a");
        var second = replies.Add("b");
        Assert.Equal(1u, first);
        Assert.Equal(2u, second);
        Assert.True(replies.TryTake(second, out var taken));
        Assert.Equal("b", taken);
        Assert.False(replies.TryTake(second, out _));
        Assert.Equal(1, replies.Count);
    }

    [Fact]
    public void DiscardForgetsAndAnUnknownIdIsNotTaken()
    {
        var replies = new PendingReplies<string>();
        var id = replies.Add("a");
        replies.Discard(id);
        Assert.False(replies.TryTake(id, out _));
        Assert.False(replies.TryTake(99, out _));
    }

    [Fact]
    public void FailAllCallsEachPendingThenDropsThem()
    {
        var replies = new PendingReplies<string>();
        replies.Add("a");
        replies.Add("b");
        var failed = new List<string>();
        replies.FailAll(failed.Add);
        Assert.Equal(["a", "b"], failed.Order());
        Assert.Equal(0, replies.Count);
    }

    [Fact]
    public void ClearDropsEverythingWithoutCalling()
    {
        var replies = new PendingReplies<string>();
        replies.Add("a");
        replies.Clear();
        Assert.Equal(0, replies.Count);
    }

    [Fact]
    public void RepliesShareACountWhenTheyShareIds()
    {
        var ids = new ReplyIds();
        var a = new PendingReplies<string>(ids);
        var b = new PendingReplies<int>(ids);
        Assert.Equal(1u, a.Add("x"));
        Assert.Equal(2u, b.Add(7));
    }
}
