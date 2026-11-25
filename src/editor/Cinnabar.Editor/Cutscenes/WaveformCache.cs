using Avalonia.Threading;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Cutscenes;

/// <summary>
/// The sounds' peak files that the cutscene timelines draw (see docs/editor/cutscene-editor.md#waveforms). A file reads
/// off the UI thread, two at a time, so a timeline of many sounds never waits for the disk, and a section draws plain
/// until its file is in. A file's name holds a key of its sound's blob, so what is cached for a path never goes stale.
/// The cache keeps up to <see cref="Capacity"/> files, the least recently asked for going first.
/// </summary>
public sealed class WaveformCache
{
    /// <summary>A screen shows far fewer sounds than this, so a draw never evicts what it draws next.</summary>
    public const int Capacity = 256;

    public static WaveformCache Shared { get; } = new(post: a => Dispatcher.UIThread.Post(a));

    // A file's one state: reading, read, or failed, which stays so the draws do not read it again each frame.
    abstract record State;

    sealed record Reading : State;

    sealed record Read(PeakFile Peaks) : State;

    sealed record Failed : State;

    readonly Dictionary<string, (State State, LinkedListNode<string> Use)> _files = [];
    // The paths, the least recently asked for first.
    readonly LinkedList<string> _uses = [];
    readonly SemaphoreSlim _readers = new(2);
    readonly Action<Action> _post;
    readonly Func<string, byte[]> _readFile;

    /// <param name="post">Runs an action on the thread that asks, where the states change.</param>
    /// <param name="readFile">Reads a file, which tests replace.</param>
    public WaveformCache(Action<Action> post, Func<string, byte[]>? readFile = null)
    {
        _post = post;
        _readFile = readFile ?? File.ReadAllBytes;
    }

    /// <summary>A file finished reading, or failed to. Raised on the thread that asks.</summary>
    public event Action<string>? Loaded;

    /// <summary>
    /// A peak file, when it is read: null while it reads, which this starts, and for a file that cannot be read. Call
    /// it on the thread that the cache posts to.
    /// </summary>
    public PeakFile? Get(string path)
    {
        if (_files.TryGetValue(path, out var entry))
        {
            _uses.Remove(entry.Use);
            _uses.AddLast(entry.Use);
            return entry.State is Read read ? read.Peaks : null;
        }
        Set(path, new Reading());
        _ = Task.Run(() => ReadAsync(path));
        return null;
    }

    // The one writer of a file's state.
    void Set(string path, State state)
    {
        if (_files.TryGetValue(path, out var entry))
        {
            if (entry.State is not Reading)
            {
                return;
            }
            _files[path] = (state, entry.Use);
            return;
        }
        if (state is not Reading)
        {
            // Evicted while it read: what it read goes.
            return;
        }
        _files[path] = (state, _uses.AddLast(path));
        while (_uses.Count > Capacity && _uses.First is { } oldest)
        {
            _uses.RemoveFirst();
            _files.Remove(oldest.Value);
        }
    }

    async Task ReadAsync(string path)
    {
        State state;
        await _readers.WaitAsync();
        try
        {
            state = PeakFile.Parse(_readFile(path)) is { } peaks ? new Read(peaks) : new Failed();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            state = new Failed();
        }
        finally
        {
            _readers.Release();
        }
        _post(() =>
        {
            Set(path, state);
            Loaded?.Invoke(path);
        });
    }
}
