using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Panels;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// The shadow atlas's cache in the Resource Monitor (see docs/rendering/lighting-and-shadows.md#cached-shadow-maps).
/// </summary>
public sealed class AtlasCacheTests
{
    [Fact]
    public void TheResourceMonitorShowsTheSlotsThatTheCacheCopiedAndDrew()
    {
        // A frame whose cache holds no light has no rows.
        var reader = new LinkReader(new byte[1024]);
        var none = GameStats.Read(ref reader);
        Assert.Empty(ResourceMonitorView.AtlasCacheRows(none));

        var stats = none with
        {
            AtlasCacheLights = 3,
            AtlasCacheCopied = 13,
            AtlasCacheDrawn = 1,
        };
        var rows = ResourceMonitorView.AtlasCacheRows(stats).ToDictionary(r => r.Name, r => r.Value);
        Assert.Equal("3", rows["Cached shadow lights"]);
        Assert.Equal("13", rows["Shadow slots copied"]);
        Assert.Equal("1", rows["Shadow slots drawn"]);
        // The slots that a dynamic caster's report drew are a part of those drawn.
        rows = ResourceMonitorView.AtlasCacheRows(stats with { AtlasCacheDrawn = 7, AtlasCacheRefreshed = 6 }).ToDictionary(r => r.Name, r => r.Value);
        Assert.Equal("7, 6 refreshed", rows["Shadow slots drawn"]);
    }
}
