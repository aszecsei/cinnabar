using System.Text.Json;
using System.Text.Json.Nodes;
using Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Model;

/// <summary>
/// Changes viewport settings by their names as the sidecar spells them, such as <c>visibilityBuffer</c> or
/// <c>noBloom</c>, for the automation's <c>viewport</c> command (see docs/editor/capture.md#automation).
/// </summary>
public static class ViewportSettingsPatch
{
    /// <summary>The settings with each change made, or why one cannot be: a name that the settings do not have, or a value of the wrong kind.</summary>
    public static bool TryApply(ViewportSettings current, IReadOnlyDictionary<string, JsonElement> changes, out ViewportSettings result, out string? error)
    {
        result = current;
        var node = JsonSerializer.SerializeToNode(current, CaptureModel.SidecarJson)!.AsObject();
        foreach (var (name, value) in changes)
        {
            if (!node.ContainsKey(name))
            {
                error = $"the viewport has no setting {name}; the settings are {string.Join(", ", node.Select(p => p.Key))}";
                return false;
            }
            node[name] = JsonNode.Parse(value.GetRawText());
        }
        try
        {
            result = node.Deserialize<ViewportSettings>(CaptureModel.SidecarJson)!;
        }
        catch (JsonException e)
        {
            error = $"a setting's value is not of its kind: {e.Message}";
            return false;
        }
        error = null;
        return true;
    }
}
