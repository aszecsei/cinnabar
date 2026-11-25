using Cinnabar.Editor.Document;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Tools;

namespace Cinnabar.Editor.Shell;

// An animation section's clip events (see docs/editor/cutscene-editor.md#events): the markers that its binding's
// Animator's graph gives the clip, which the runtime raises as the section plays it.
public sealed partial class CutsceneEditor
{
    /// <summary>The engine's Animator component (lib/engine/anim/anim.odin), whose graph names the clips' events.</summary>
    public const ulong AnimatorComponentId = 80;

    /// <summary>
    /// The events of a clip on an animation track, from the graph of its binding's Animator, as the scene or the prefab
    /// sets it: a possessed entity's, a spawned prefab's root's, or a slot's stand-in's. Empty when the binding has no
    /// Animator with a graph, or the graph does not name the clip. It is read each time the rows are built, so a changed
    /// graph shows at the next build.
    /// </summary>
    public IReadOnlyList<CutsceneClipEvent> EventsOf(CutsceneBlock track, string clip)
    {
        if (track.Get("binding") is not { } text || !CutsceneFile.TryParseId(text, out var id)
            || File.Bindings.FirstOrDefault(b => b.Id == id) is not { } binding || GraphOf(binding) is not { } graph)
        {
            return [];
        }
        return _shell.ClipEvents(graph, clip);
    }

    // The graph of a binding's Animator, by GUID, or null.
    string? GraphOf(CutsceneBlock binding)
    {
        var target = binding.Get("spawn") ?? binding.Get("possess");
        if (binding.Get("provided") != null)
        {
            target = binding.Id is { } id ? StandInOf(id) : null;
        }
        if (target == null)
        {
            return null;
        }
        if (target.Trim() is ['$', .. var prefab] && prefab.Length > 0)
        {
            return _shell.PrefabRootAsset(prefab, AnimatorComponentId, "graph");
        }
        if (PossessRef.Parse(target) is not { } entity || _shell.SceneOfGuid(entity.SceneGuid)?.Expanded.Flat.Find(entity.Id) is not { } found)
        {
            return null;
        }
        return found.Components.Find(c => c.Id == AnimatorComponentId)?.Fields.Find(f => f.Name == "graph")?.Value is { Kind: SceneValueKind.Asset, Asset.Length: > 0 } v
            ? v.Asset
            : null;
    }
}
