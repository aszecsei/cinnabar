namespace Cinnabar.Editor.Model;

/// <summary>Counts request IDs. Replies to different kinds of request can share one count.</summary>
public sealed class ReplyIds(bool skipZero = false)
{
    uint _last;

    /// <summary>The next ID. With <c>skipZero</c> it is never 0, which a protocol can keep for a message that wants no reply.</summary>
    public uint Next()
    {
        var id = ++_last;
        return id == 0 && skipZero ? ++_last : id;
    }
}

/// <summary>What waits for the replies to requests: each request's ID, and what completes with its reply.</summary>
public sealed class PendingReplies<T>(ReplyIds? ids = null)
{
    readonly ReplyIds _ids = ids ?? new();
    readonly Dictionary<uint, T> _waiting = [];

    public int Count => _waiting.Count;

    /// <summary>Takes a new ID and holds <paramref name="pending"/> for it.</summary>
    public uint Add(T pending)
    {
        var id = _ids.Next();
        _waiting[id] = pending;
        return id;
    }

    /// <summary>Takes the pending thing of a reply's ID, which then waits no more. False for an ID that nothing waits for.</summary>
    public bool TryTake(uint id, out T pending) => _waiting.Remove(id, out pending!);

    /// <summary>Forgets the pending thing of an ID, as a request that gave up.</summary>
    public void Discard(uint id) => _waiting.Remove(id);

    /// <summary>Drops every pending thing.</summary>
    public void Clear() => _waiting.Clear();

    /// <summary>Calls <paramref name="fail"/> on every pending thing, then drops them all.</summary>
    public void FailAll(Action<T> fail)
    {
        var all = _waiting.Values.ToList();
        _waiting.Clear();
        foreach (var pending in all)
        {
            fail(pending);
        }
    }
}
