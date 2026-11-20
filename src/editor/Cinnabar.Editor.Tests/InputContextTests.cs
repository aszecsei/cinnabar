using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Panels;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// The input contexts' stacks in the Resource Monitor (see docs/core/input.md#contexts).
/// </summary>
public sealed class InputContextTests
{
    [Fact]
    public void TheResourceMonitorShowsEachPushOverTheDefault()
    {
        var reader = new LinkReader(new byte[1024]);
        var none = GameStats.Read(ref reader);
        Assert.Equal([("default", "every action")], ResourceMonitorView.InputContextRows(none));

        var stats = none with
        {
            InputContexts =
            [
                new InputContextStats("menu", 0b0010, "PauseMenu"),
                new InputContextStats("cutscene", 0b1111, "Cutscene"),
                new InputContextStats("dialog", 0b0101, "script"),
            ],
        };
        Assert.Equal(
            [
                ("menu", "PauseMenu, pad 2"),
                ("cutscene", "Cutscene, every pad"),
                ("dialog", "script, pads 1, 3"),
                ("default", "every action"),
            ],
            ResourceMonitorView.InputContextRows(stats));
    }
}
