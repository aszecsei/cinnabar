namespace Cinnabar.Editor.Link;

/// <summary>
/// The log lines that a link receives, on its own thread, on their way to the UI thread: they wait here, and one post
/// takes all that came since the last, so a process that logs thousands of lines a second costs one post a batch and
/// not one a line. At most <c>capacity</c> lines wait; past that, the oldest go, and the batch says how many.
/// </summary>
public sealed class LogQueue<T>(int capacity, Action<Action> post, Action<IReadOnlyList<T>, int> deliver)
{
    readonly Lock _lock = new();
    Queue<T> _pending = new();
    int _dropped;
    bool _posted;

    /// <summary>Adds a line, from any thread. The first line after a delivery posts the next one.</summary>
    public void Add(T line)
    {
        lock (_lock)
        {
            if (_pending.Count == capacity)
            {
                _pending.Dequeue();
                _dropped++;
            }
            _pending.Enqueue(line);
            if (_posted)
            {
                return;
            }
            _posted = true;
        }
        post(Deliver);
    }

    // On the thread that post runs on: gives every waiting line, and how many were dropped, in one call.
    void Deliver()
    {
        Queue<T> lines;
        int dropped;
        lock (_lock)
        {
            (lines, _pending) = (_pending, new Queue<T>());
            (dropped, _dropped) = (_dropped, 0);
            _posted = false;
        }
        if (lines.Count > 0 || dropped > 0)
        {
            deliver([.. lines], dropped);
        }
    }
}
