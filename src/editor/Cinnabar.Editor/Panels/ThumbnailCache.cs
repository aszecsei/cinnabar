using Avalonia.Media.Imaging;

namespace Cinnabar.Editor.Panels;

/// <summary>
/// The content browser's decoded thumbnails. A view can be rebuilt at any time, so this outlives it. Files decode off the
/// UI thread, two at a time, so a screen of tiles does not hold up the editor. A file's name holds a key of what it shows,
/// so what is cached for a path never goes stale. A tile holds what it shows until it leaves the screen, and the cache
/// keeps up to <see cref="Capacity"/> others that nothing holds, the least recently used going first.
/// </summary>
sealed class ThumbnailCache
{
    /// <summary>At 256 by 256, which is 256 KB each, this is about 64 MB of what nothing shows.</summary>
    public const int Capacity = 256;

    public static ThumbnailCache Shared { get; } = new();

    sealed class Entry(Task<Bitmap?> decoding)
    {
        public Task<Bitmap?> Decoding { get; } = decoding;
        public int Holders { get; set; }
    }

    readonly Dictionary<string, Entry> _entries = [];
    // What nothing holds, the least recently used first.
    readonly LinkedList<string> _idle = [];
    readonly SemaphoreSlim _decoders = new(2);

    /// <summary>The thumbnail, decoded if it has to be, held until <see cref="Release"/>, or null when it cannot be read. Use it on the UI thread.</summary>
    public async Task<Bitmap?> Acquire(string path)
    {
        if (!_entries.TryGetValue(path, out var entry))
        {
            entry = new Entry(Task.Run(() => Decode(path)));
            _entries[path] = entry;
        }
        else
        {
            _idle.Remove(path);
        }
        entry.Holders++;
        return await entry.Decoding;
    }

    /// <summary>Lets go of a thumbnail, which stays for a while in case it shows again.</summary>
    public void Release(string path)
    {
        if (!_entries.TryGetValue(path, out var entry) || --entry.Holders > 0)
        {
            return;
        }
        _idle.AddLast(path);
        while (_idle.Count > Capacity && _idle.First is { } oldest)
        {
            _idle.RemoveFirst();
            if (_entries.Remove(oldest.Value, out var gone))
            {
                _ = gone.Decoding.ContinueWith(d => d.Result?.Dispose(), TaskScheduler.Default);
            }
        }
    }

    async Task<Bitmap?> Decode(string path)
    {
        await _decoders.WaitAsync();
        try
        {
            await using var file = File.OpenRead(path);
            return new Bitmap(file);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or InvalidOperationException)
        {
            return null;
        }
        finally
        {
            _decoders.Release();
        }
    }
}
