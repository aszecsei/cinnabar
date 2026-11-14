using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Panels;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// The virtual shadow map's pages in the Resource Monitor (see docs/rendering/lighting-and-shadows.md#caching).
/// </summary>
public sealed class VirtualShadowTests
{
    [Fact]
    public void TheResourceMonitorShowsTheShadowPagesThatWereCachedDrawnAndEvicted()
    {
        // A frame without the virtual shadow map has no pool, and no rows.
        var reader = new LinkReader(new byte[1024]);
        var none = GameStats.Read(ref reader);
        Assert.Empty(ResourceMonitorView.VirtualShadowRows(none));

        var stats = none with
        {
            VirtualPagesRequested = 300,
            VirtualPagesAllocated = 290,
            VirtualPagesMissed = 10,
            VirtualPagesCapacity = 2048,
            VirtualPagesCached = 280,
            VirtualPagesDrawn = 10,
            VirtualPagesEvicted = 4,
            VirtualPagesResident = 1024,
        };
        var rows = ResourceMonitorView.VirtualShadowRows(stats).ToDictionary(r => r.Name, r => r.Value);
        Assert.Equal("300", rows["Shadow pages requested"]);
        Assert.Equal("290", rows["Shadow pages allocated"]);
        Assert.Equal("10", rows["Shadow pages missed"]);
        Assert.Equal("280", rows["Shadow pages cached"]);
        Assert.Equal("10", rows["Shadow pages drawn"]);
        Assert.Equal("4", rows["Shadow pages evicted"]);
        // The pool's fill is the pages that it holds, which the cache keeps whether or not the frame asked for them.
        Assert.Equal("1,024 / 2,048 (50% full)", rows["Shadow page pool"]);
    }
}
