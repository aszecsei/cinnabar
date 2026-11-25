using System.Diagnostics;

namespace Cinnabar.Editor.Tools;

/// <summary>
/// The events that the preview fired a moment ago, which their flags and bars flash for (see
/// docs/editor/cutscene-editor.md#events-in-the-preview), by their items' paths. It is the view's: it touches no
/// document and no undo entry. A flash fades over <see cref="Length"/> from when the game reported it, and is gone after.
/// </summary>
public sealed class CutsceneEventFlashes
{
    public static readonly TimeSpan Length = TimeSpan.FromMilliseconds(400);

    static readonly Stopwatch Watch = Stopwatch.StartNew();

    // When each path's last flash began, on the clock.
    readonly Dictionary<string, TimeSpan> _started = [];

    /// <summary>The time that flashes fade by. Tests replace it.</summary>
    public Func<TimeSpan> Clock { get; set; } = () => Watch.Elapsed;

    /// <summary>Starts the path's flash again, at full strength.</summary>
    public void Flash(string path) => _started[path] = Clock();

    /// <summary>How bright the path's flash is now: 1 when it began, down to 0 at <see cref="Length"/>, and 0 for none.</summary>
    public double Strength(string path)
    {
        if (!_started.TryGetValue(path, out var started))
        {
            return 0;
        }
        var age = Clock() - started;
        return age >= Length ? 0 : 1 - age / Length;
    }

    /// <summary>Whether a flash still fades, so the view should draw again. It forgets the flashes that are over.</summary>
    public bool Live()
    {
        var now = Clock();
        foreach (var path in _started.Where(p => now - p.Value >= Length).Select(p => p.Key).ToList())
        {
            _started.Remove(path);
        }
        return _started.Count > 0;
    }
}
