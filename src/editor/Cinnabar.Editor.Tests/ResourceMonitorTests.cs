using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;

namespace Cinnabar.Editor.Tests;

public class ResourceMonitorTests
{
    [Fact]
    public void TheResourceMonitorShowsTheBottomLevelStructuresMemory()
    {
        var reader = new LinkReader(new byte[1024]);
        var none = HostStats.Read(ref reader);
        Assert.Empty(ResourceMonitorView.AccelMemoryRows(none));

        var compacted = none with { BottomAccelMemory = 3 << 20, BottomAccelMemoryUncompacted = 8 << 20 };
        var row = Assert.Single(ResourceMonitorView.AccelMemoryRows(compacted));
        Assert.Equal("Bottom-level structures", row.Name);
        Assert.Equal($"{ResourceStats.Bytes(3 << 20)} ({ResourceStats.Bytes(8 << 20)} before compaction)", row.Value);

        // Before any structure is compacted, the memory is all there is.
        var uncompacted = none with { BottomAccelMemory = 8 << 20, BottomAccelMemoryUncompacted = 8 << 20 };
        Assert.Equal(ResourceStats.Bytes(8 << 20), Assert.Single(ResourceMonitorView.AccelMemoryRows(uncompacted)).Value);
    }

    [Fact]
    public void TheResourceMonitorShowsTheResourcesShareOfTheHeaps()
    {
        var reader = new LinkReader(new byte[1024]);
        var none = HostStats.Read(ref reader);
        // A backend without heaps, the null one, has no row.
        Assert.Empty(ResourceMonitorView.HeapMemoryRows(none));

        var heaps = none with { HeapMemory = 512UL << 20, ResourceMemory = 300UL << 20 };
        var row = Assert.Single(ResourceMonitorView.HeapMemoryRows(heaps));
        Assert.Equal("Resource heaps", row.Name);
        Assert.Equal($"{ResourceStats.Bytes(300UL << 20)} / {ResourceStats.Bytes(512UL << 20)}", row.Value);
    }
}
