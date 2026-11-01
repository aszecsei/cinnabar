using System.Text.Json;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Shell;

namespace Cinnabar.Editor.Tests;

/// <summary>The automation's viewport command: settings changed by their sidecar names, and the names and values it refuses.</summary>
public sealed class ViewportSettingsPatchTests
{
    static Dictionary<string, JsonElement> Changes(string json) => JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(json)!;

    [Fact]
    public void ASettingChangesByItsSidecarName()
    {
        var settings = EditorShell.DefaultViewportSettings;
        Assert.True(ViewportSettingsPatch.TryApply(settings, Changes("""{"visibilityBuffer":true,"shadingStats":true,"debugView":"QuadOverdraw"}"""), out var result, out var error), error);
        Assert.Equal(settings with { VisibilityBuffer = true, ShadingStats = true, DebugView = DebugView.QuadOverdraw }, result);
    }

    [Fact]
    public void AnUnknownNameOrAValueOfTheWrongKindChangesNothing()
    {
        var settings = EditorShell.DefaultViewportSettings;
        Assert.False(ViewportSettingsPatch.TryApply(settings, Changes("""{"visibility":true}"""), out var result, out var error));
        Assert.Contains("visibilityBuffer", error);
        Assert.Equal(settings, result);
        Assert.False(ViewportSettingsPatch.TryApply(settings, Changes("""{"noBloom":"yes"}"""), out result, out _));
        Assert.Equal(settings, result);
    }
}
