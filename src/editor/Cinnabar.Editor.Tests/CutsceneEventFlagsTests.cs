using Cinnabar.Editor.Document;
using Cinnabar.Editor.Tools;
using Layout = Cinnabar.Editor.Tools.CutsceneTimelineLayout;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// Event keys as flags with their names, and triggers closer than a name is wide as a counted badge (see
/// docs/editor/cutscene-editor.md#flags-on-the-timeline).
/// </summary>
public sealed class CutsceneEventFlagsTests
{
    // Three triggers: a long name, then two short ones, 3000 and 30000 ticks after it. And a range.
    const string Text = """
        cutscene 1
        length = 600000
        rate = 30

        track 1 event "Story"
        	trigger 1 10000 a_long_name
        	trigger 2 13000 b
        	trigger 3 40000 c
        	range 4 100000 200000 alarm

        """;

    static (Layout Layout, CutsceneVisibleRow Row) Shown(double perPixel, double start = 0)
    {
        var file = CutsceneFile.Parse(Text.ReplaceLineEndings("\n")).File!;
        var layout = Layout.Build(file, new HashSet<string>());
        var row = layout.Visible(new TimelineView(start, perPixel, TimelineZoom.Ticks), 10000, 0, 1000).Single(r => r.Row.TrackKind == "event");
        return (layout, row);
    }

    static string[] Names(CutsceneEventFlag flag) => [.. flag.Items.Select(i => i.Label!)];

    [Fact]
    public void TriggersCloserThanANameIsWideCollapseIntoACountedBadge()
    {
        // Far apart, each is a flag with its name.
        var (_, row) = Shown(10);
        Assert.Equal(["a_long_name", "b", "c"], row.Flags.Select(f => f.Text));
        Assert.All(row.Flags, f => Assert.False(f.Badge));

        // At 100 ticks a pixel, b is 30 pixels after a_long_name, under its name, and c is past it.
        (_, row) = Shown(100);
        Assert.Equal(2, row.Flags.Count);
        Assert.True(row.Flags[0].Badge);
        Assert.Equal("2", row.Flags[0].Text);
        Assert.Equal(["a_long_name", "b"], Names(row.Flags[0]));
        Assert.Equal("c", row.Flags[1].Text);

        // Ten times further out, all three are one badge.
        (_, row) = Shown(1000);
        Assert.Equal("3", Assert.Single(row.Flags).Text);
    }

    [Fact]
    public void ABadgeIsHitAsAllOfItsTriggersAndAFlagsNameAsItsTrigger()
    {
        var (layout, row) = Shown(100);
        var badge = row.Flags[0];
        var y = row.Y + Layout.RowHeight / 2;
        var paths = badge.Paths.ToArray();

        // The diamond, and the badge right of it.
        var onDiamond = layout.HitTest(Layout.Gutter + badge.X, y, new TimelineView(0, 100, TimelineZoom.Ticks), 0);
        var onBadge = layout.HitTest(Layout.Gutter + badge.X + Layout.FlagInset + 2, y, new TimelineView(0, 100, TimelineZoom.Ticks), 0);
        Assert.Equal(CutsceneHitKind.Trigger, onDiamond.Kind);
        Assert.Equal(paths, onDiamond.Paths);
        Assert.Equal(CutsceneHitKind.Trigger, onBadge.Kind);
        Assert.Equal(paths, onBadge.Paths);

        // Zoomed in, the end of a flag's name hits its one trigger.
        (layout, row) = Shown(10);
        var flag = row.Flags[0];
        var hit = layout.HitTest(Layout.Gutter + flag.X + flag.Width - 2, row.Y + Layout.RowHeight / 2, new TimelineView(0, 10, TimelineZoom.Ticks), 0);
        Assert.Equal([.. flag.Paths], hit.Paths);
    }
}
