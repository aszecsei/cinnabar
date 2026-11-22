using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;
using System.Text.RegularExpressions;
using Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Model;

public enum LogLevel
{
    Debug,
    Info,
    Warning,
    Error,
}

public sealed record LogLine(LogLevel Level, string Text);

/// <summary>
/// The log that the console panel shows: the host's and the cook daemon's output, and the editor's own lines. It keeps the newest
/// <see cref="Capacity"/> lines. Use it on the UI thread.
/// </summary>
public sealed partial class ConsoleLog
{
    public const int Capacity = 5000;

    public LogLines Lines { get; } = [];

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

    /// <summary>
    /// Adds a batch of lines as one change, as a process's log comes, keeping the newest <see cref="Capacity"/>. When
    /// lines were dropped on the way, a warning in their place says how many, from where.
    /// </summary>
    public void AddRange(IReadOnlyList<LogLine> lines, int dropped, string source)
    {
        if (dropped > 0)
        {
            List<LogLine> all = [new(LogLevel.Warning, $"console: {dropped} lines of the {source} log were dropped, as they came faster than the console shows them"), .. lines];
            Lines.Append(all, Capacity);
        }
        else
        {
            Lines.Append(lines, Capacity);
        }
    }

    public void Clear() => Lines.Clear();

    public static LogLevel Level(Link.Protocol.LogLevel level) => level switch
    {
        Link.Protocol.LogLevel.Debug => LogLevel.Debug,
        Link.Protocol.LogLevel.Info => LogLevel.Info,
        Link.Protocol.LogLevel.Warning => LogLevel.Warning,
        _ => LogLevel.Error,
    };

    /// <summary>The cook daemon's levels are the host's.</summary>
    public static LogLevel Level(Link.Cook.LogLevel level) => Level((Link.Protocol.LogLevel)level);

    /// <summary>A line of the host's log as the host's own console shows it, in local time.</summary>
    public static string Format(Log log) => Format(log.Level, log.Time, log.Location, log.Text);

    /// <summary>A line of the cook daemon's log as its own console shows it, in local time.</summary>
    public static string Format(Link.Cook.Log log) => Format((Link.Protocol.LogLevel)log.Level, log.Time, log.Location, log.Text);

    static string Format(Link.Protocol.LogLevel level, long nanoseconds, string location, string text)
    {
        var name = level switch
        {
            Link.Protocol.LogLevel.Debug => "DEBUG",
            Link.Protocol.LogLevel.Info => "INFO ",
            Link.Protocol.LogLevel.Warning => "WARN ",
            Link.Protocol.LogLevel.Error => "ERROR",
            _ => "FATAL",
        };
        var time = DateTimeOffset.FromUnixTimeMilliseconds(nanoseconds / 1_000_000).ToLocalTime();
        return $"[{name}] --- [{time:yyyy-MM-dd HH:mm:ss}] [{location}] {text}";
    }

    [GeneratedRegex(@"^\[(DEBUG|INFO|WARN|ERROR|FATAL) *\]")]
    private static partial Regex LevelPrefix();
}

/// <summary>
/// The console's lines. A batch of them is one change, a reset, so a view lays out once a batch, not once a line.
/// </summary>
public sealed class LogLines : ObservableCollection<LogLine>
{
    /// <summary>Adds lines, dropping the oldest past capacity. One line is an add; more are one reset.</summary>
    public void Append(IReadOnlyList<LogLine> lines, int capacity)
    {
        switch (lines.Count)
        {
            case 0:
                return;
            case 1:
                if (Count >= capacity)
                {
                    RemoveAt(0);
                }
                Add(lines[0]);
                return;
        }
        CheckReentrancy();
        var keep = Math.Min(lines.Count, capacity);
        var remove = Math.Max(Count + keep - capacity, 0);
        if (Items is List<LogLine> list)
        {
            list.RemoveRange(0, Math.Min(remove, list.Count));
            list.AddRange(lines.Skip(lines.Count - keep));
        }
        else
        {
            for (var i = 0; i < remove; i++)
            {
                Items.RemoveAt(0);
            }
            foreach (var line in lines.Skip(lines.Count - keep))
            {
                Items.Add(line);
            }
        }
        OnPropertyChanged(new PropertyChangedEventArgs(nameof(Count)));
        OnPropertyChanged(new PropertyChangedEventArgs("Item[]"));
        OnCollectionChanged(new NotifyCollectionChangedEventArgs(NotifyCollectionChangedAction.Reset));
    }
}
