using System.Collections.Specialized;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Tests;

public class ConsoleLogTests
{
    [Theory]
    [InlineData("[WARN ] --- [2026-10-24 07:50:23] [host.odin:1:main()] careful", LogLevel.Warning)]
    [InlineData("[FATAL] --- [2026-10-24 07:50:23] [host.odin:1:main()] gone", LogLevel.Error)]
    [InlineData("a line without a prefix", LogLevel.Info)]
    public void TheOdinPrefixGivesTheLevel(string text, LogLevel level)
    {
        var log = new ConsoleLog();

        log.Add(text);

        Assert.Equal(new LogLine(level, text), Assert.Single(log.Lines));
    }

    [Fact]
    public void ABatchIsOneChangeAndSaysHowManyLinesWereDropped()
    {
        var log = new ConsoleLog();
        log.Add(LogLevel.Info, "before");
        var changes = new List<NotifyCollectionChangedAction>();
        log.Lines.CollectionChanged += (_, e) => changes.Add(e.Action);

        log.AddRange([.. Enumerable.Range(0, 10).Select(i => new LogLine(LogLevel.Error, $"line {i}"))], 0, "game");
        Assert.Equal([NotifyCollectionChangedAction.Reset], changes);
        Assert.Equal(11, log.Lines.Count);
        Assert.Equal("line 9", log.Lines[^1].Text);

        // More than the console keeps, after lines that were dropped on the way: the newest stay.
        changes.Clear();
        log.AddRange([.. Enumerable.Range(0, ConsoleLog.Capacity + 5).Select(i => new LogLine(LogLevel.Error, $"flood {i}"))], 1234, "game");
        Assert.Equal([NotifyCollectionChangedAction.Reset], changes);
        Assert.Equal(ConsoleLog.Capacity, log.Lines.Count);
        Assert.Equal($"flood {ConsoleLog.Capacity + 4}", log.Lines[^1].Text);
        Assert.Equal("flood 5", log.Lines[0].Text);

        // A batch that fits keeps the warning about the lines that it lost.
        log.AddRange([new LogLine(LogLevel.Info, "after")], 7, "cook daemon");
        Assert.Equal(LogLevel.Warning, log.Lines[^2].Level);
        Assert.Contains("7 lines of the cook daemon log", log.Lines[^2].Text);
        Assert.Equal(ConsoleLog.Capacity, log.Lines.Count);
    }

    [Fact]
    public async Task ALinksLogLinesReachTheUiThreadInOnePostABatchAndTheOldestGoPastCapacity()
    {
        var posted = new List<Action>();
        var batches = new List<(IReadOnlyList<int> Lines, int Dropped)>();
        var queue = new LogQueue<int>(100, posted.Add, (lines, dropped) => batches.Add((lines, dropped)));

        // A flood from the link's thread, while the UI thread is busy.
        await Task.Run(() =>
        {
            for (var i = 0; i < 10_000; i++)
            {
                queue.Add(i);
            }
        }, TestContext.Current.CancellationToken);
        var post = Assert.Single(posted);
        post();
        var (lines, dropped) = Assert.Single(batches);
        Assert.Equal(Enumerable.Range(9_900, 100), lines);
        Assert.Equal(9_900, dropped);

        // The next line posts again.
        queue.Add(1);
        Assert.Equal(2, posted.Count);
        posted[1]();
        Assert.Equal([1], batches[1].Lines);
        Assert.Equal(0, batches[1].Dropped);
        Assert.Equal(2, batches.Count);
    }
}
