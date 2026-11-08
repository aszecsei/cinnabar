using Cinnabar.Editor.Link.Cook;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The preview cook of an open document (see docs/editor/material-editor.md#material-editor): a moment after the last
/// change, or now, the daemon cooks the unsaved text. Only one cook runs at a time, and a change during it cooks again
/// after it. Disposing it cancels a cook that waits, and drops the answer of one that runs, so a closed editor does
/// nothing with it.
/// </summary>
internal sealed class PreviewCook(Func<bool> ready, Func<string> text, Func<string, Task<PreviewResult>> cook, Action<string, PreviewResult> cooked)
    : IDisposable
{
    /// <summary>The cook waits this long after the last change, so typing or a drag cooks once.</summary>
    public static readonly TimeSpan Delay = TimeSpan.FromMilliseconds(250);

    enum Phase
    {
        Idle,
        Cooking,
        // A change came while a cook ran, so another follows it.
        CookingAgain,
        Closed,
    }

    readonly CancellationTokenSource _closed = new();
    Phase _phase;
    // The newest delayed cook: an older one that ends does nothing.
    int _version;

    /// <summary>Cooks a moment after the last call.</summary>
    public void Schedule()
    {
        if (_phase == Phase.Closed)
        {
            return;
        }
        var version = ++_version;
        _ = Task.Delay(Delay, _closed.Token).ContinueWith(_ =>
        {
            if (version == _version)
            {
                _ = CookNow();
            }
        }, _closed.Token, TaskContinuationOptions.OnlyOnRanToCompletion, Scheduler());
    }

    // The UI thread's scheduler in the editor, or the default one in tests, which have no synchronization context.
    static TaskScheduler Scheduler() => SynchronizationContext.Current == null ? TaskScheduler.Default : TaskScheduler.FromCurrentSynchronizationContext();

    /// <summary>Cooks now, or after the cook that runs. Without the cook link, it does nothing.</summary>
    public async Task CookNow()
    {
        if (_phase == Phase.Closed || !ready())
        {
            return;
        }
        if (_phase != Phase.Idle)
        {
            _phase = Phase.CookingAgain;
            return;
        }
        try
        {
            do
            {
                _phase = Phase.Cooking;
                var sent = text();
                var result = await cook(sent);
                if (_phase == Phase.Closed)
                {
                    return;
                }
                cooked(sent, result);
            }
            while (_phase == Phase.CookingAgain);
        }
        finally
        {
            if (_phase != Phase.Closed)
            {
                _phase = Phase.Idle;
            }
        }
    }

    public void Dispose()
    {
        if (_phase == Phase.Closed)
        {
            return;
        }
        _phase = Phase.Closed;
        _closed.Cancel();
        _closed.Dispose();
    }
}
