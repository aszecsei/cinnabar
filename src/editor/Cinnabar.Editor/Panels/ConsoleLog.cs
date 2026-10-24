using System.Collections.ObjectModel;
using System.Text.RegularExpressions;

namespace Cinnabar.Editor.Panels;

public enum LogLevel
{
    Debug,
    Info,
    Warning,
    Error,
}

public sealed record LogLine(LogLevel Level, string Text);

/// <summary>
/// The log that the console panel shows: the host's output, and the editor's own lines. It keeps the newest
/// <see cref="Capacity"/> lines. Use it on the UI thread.
/// </summary>
public sealed partial class ConsoleLog
{
    public const int Capacity = 5000;

    public ObservableCollection<LogLine> Lines { get; } = [];

    /// <summary>Adds a line, with the level that its Odin log prefix gives, such as <c>[WARN ]</c>.</summary>
    public void Add(string text)
    {
        var match = LevelPrefix().Match(text);
        var level = !match.Success ? LogLevel.Info : match.Groups[1].Value switch
        {
            "DEBUG" => LogLevel.Debug,
            "WARN" => LogLevel.Warning,
            "ERROR" or "FATAL" => LogLevel.Error,
            _ => LogLevel.Info,
        };
        Add(level, text);
    }

    public void Add(LogLevel level, string text)
    {
        if (Lines.Count >= Capacity)
        {
            Lines.RemoveAt(0);
        }
        Lines.Add(new LogLine(level, text));
    }

    public void Clear() => Lines.Clear();

    [GeneratedRegex(@"^\[(DEBUG|INFO|WARN|ERROR|FATAL) *\]")]
    private static partial Regex LevelPrefix();
}
