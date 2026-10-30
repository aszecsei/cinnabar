using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Tests;

public class ConsoleLogTests
{
    [Theory]
    [InlineData("[INFO ] --- [2026-10-24 07:50:23] [script.odin:431:log_binding()] hello", LogLevel.Info)]
    [InlineData("[WARN ] --- [2026-10-24 07:50:23] [host.odin:1:main()] careful", LogLevel.Warning)]
    [InlineData("[ERROR] --- [2026-10-24 07:50:23] [host.odin:1:main()] broken", LogLevel.Error)]
    [InlineData("[FATAL] --- [2026-10-24 07:50:23] [host.odin:1:main()] gone", LogLevel.Error)]
    [InlineData("[DEBUG] --- [2026-10-24 07:50:23] [host.odin:1:main()] noise", LogLevel.Debug)]
    [InlineData("a line without a prefix", LogLevel.Info)]
    public void TheOdinPrefixGivesTheLevel(string text, LogLevel level)
    {
        var log = new ConsoleLog();

        log.Add(text);

        Assert.Equal(new LogLine(level, text), Assert.Single(log.Lines));
    }

    [Fact]
    public void TheOldestLinesGoFirst()
    {
        var log = new ConsoleLog();

        for (var i = 0; i < ConsoleLog.Capacity + 10; i++)
        {
            log.Add(LogLevel.Info, $"line {i}");
        }

        Assert.Equal(ConsoleLog.Capacity, log.Lines.Count);
        Assert.Equal("line 10", log.Lines[0].Text);
    }
}
