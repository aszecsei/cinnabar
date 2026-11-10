using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// The pool of mesh pages in the Resource Monitor (see docs/rendering/assets.md#mesh-pages).
/// </summary>
public sealed class MeshPageTests
{
    [Fact]
    public void TheResourceMonitorShowsThePoolOfMeshPages()
    {
        // A game without a paged mesh has no pool, and no rows.
        var reader = new LinkReader(new byte[1024]);
        var none = GameStats.Read(ref reader);
        Assert.Empty(ResourceMonitorView.MeshPageRows(none));

        var stats = none with { MeshPagesResident = 2048, MeshPagesCapacity = 8192, MeshPagesPending = 37, MeshPagesStreamedBytes = 3 << 19 };
        var rows = ResourceMonitorView.MeshPageRows(stats).ToDictionary(r => r.Name, r => r.Value);
        Assert.Equal("2,048 / 8,192 (25% full)", rows["Mesh pages resident"]);
        // A page is 128 KiB, so the pool is its slots' bytes.
        Assert.Equal($"{ResourceStats.Bytes(256 << 20)} / {ResourceStats.Bytes(1 << 30)}", rows["Mesh page pool"]);
        Assert.Equal("37", rows["Mesh pages pending"]);
        Assert.Equal($"{ResourceStats.Bytes(3 << 19)} / s", rows["Mesh pages streamed"]);
    }
}
