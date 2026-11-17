using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Panels;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// The scenes that stream in, in the Resource Monitor (see docs/world/scenes.md#streaming).
/// </summary>
public sealed class SceneLoadTests
{
    [Fact]
    public void TheResourceMonitorShowsTheScenesThatLoad()
    {
        // A game that loads no scene has no rows.
        var reader = new LinkReader(new byte[1024]);
        var none = GameStats.Read(ref reader);
        Assert.Empty(ResourceMonitorView.SceneLoadRows(none));

        var stats = none with { ScenesLoading = 2, SceneEntitiesSpawned = 1024, SceneEntitiesFilled = 128 };
        var rows = ResourceMonitorView.SceneLoadRows(stats).ToDictionary(r => r.Name, r => r.Value);
        Assert.Equal("2", rows["Scenes loading"]);
        Assert.Equal("1,024", rows["Scene entities spawned"]);
        Assert.Equal("128", rows["Scene entities filled"]);
    }
}
