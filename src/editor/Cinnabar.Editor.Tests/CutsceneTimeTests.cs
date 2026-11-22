using Cinnabar.Editor.Cutscenes;

namespace Cinnabar.Editor.Tests;

/// <summary>Times as the cutscene editor shows them and reads them back (see docs/editor/cutscene-editor.md#scrub-play-and-step).</summary>
public sealed class CutsceneTimeTests
{
    [Theory]
    [InlineData("00:04:05", 30, 250000)]
    [InlineData("4:05", 30, 250000)]
    [InlineData("1:00:00:00", 24, 216000000)]
    [InlineData("125", 30, 250000)]
    [InlineData("125f", 30, 250000)]
    [InlineData(" 0 ", 60, 0)]
    [InlineData("75:00", 30, 4500000)]
    public void ATypedTimeReadsAsTimecodeOrFrames(string text, int rate, int ticks)
    {
        Assert.True(CutsceneTime.TryParse(text, rate, out var read));
        Assert.Equal(ticks, read);
    }

    [Theory]
    [InlineData("", 30)]
    [InlineData("00:00:30", 30)]
    [InlineData("00:60:00", 30)]
    [InlineData("1:2:3:4:5", 30)]
    [InlineData("-5", 30)]
    [InlineData("1.5", 30)]
    [InlineData("abc", 30)]
    [InlineData("99999999999", 30)]
    public void AFrameAtTheRateOrAFieldPastItsLimitDoesNotRead(string text, int rate) =>
        Assert.False(CutsceneTime.TryParse(text, rate, out _));

    [Fact]
    public void TimecodeReadsBackToTheStartOfItsFrame()
    {
        foreach (var rate in new[] { 24, 25, 30, 60 })
        {
            for (var ticks = 0; ticks < 10 * 60000; ticks += 7919)
            {
                Assert.True(CutsceneTime.TryParse(CutsceneTime.Timecode(ticks, rate), rate, out var read));
                Assert.Equal(ticks / CutsceneTime.FrameTicks(rate) * CutsceneTime.FrameTicks(rate), read);
            }
        }
    }
}
