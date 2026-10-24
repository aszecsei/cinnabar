using System.Collections.ObjectModel;
using System.Text.RegularExpressions;
using Cinnabar.Editor.Link.Protocol;

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

    public static LogLevel Level(Link.Protocol.LogLevel level) => level switch
    {
        Link.Protocol.LogLevel.Debug => LogLevel.Debug,
        Link.Protocol.LogLevel.Info => LogLevel.Info,
        Link.Protocol.LogLevel.Warning => LogLevel.Warning,
        _ => LogLevel.Error,
    };

    /// <summary>A line of the host's log as the host's own console shows it, in local time.</summary>
    public static string Format(Log log)
    {
        var level = log.Level switch
        {
            Link.Protocol.LogLevel.Debug => "DEBUG",
            Link.Protocol.LogLevel.Info => "INFO ",
            Link.Protocol.LogLevel.Warning => "WARN ",
            Link.Protocol.LogLevel.Error => "ERROR",
            _ => "FATAL",
        };
        var time = DateTimeOffset.FromUnixTimeMilliseconds(log.Time / 1_000_000).ToLocalTime();
        return $"[{level}] --- [{time:yyyy-MM-dd HH:mm:ss}] [{log.Location}] {log.Text}";
    }

    [GeneratedRegex(@"^\[(DEBUG|INFO|WARN|ERROR|FATAL) *\]")]
    private static partial Regex LevelPrefix();
}
