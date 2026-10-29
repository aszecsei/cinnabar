using Cinnabar.Editor.Document;
using UnwatchEntity = Cinnabar.Editor.Link.Protocol.UnwatchEntity;
using WatchEntity = Cinnabar.Editor.Link.Protocol.WatchEntity;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The scene's atmosphere (see docs/editor/shell-and-panels.md#atmosphere): the global volume whose Environment and Fog
/// the Atmosphere tab and panel edit, and the watches that give the panel its values when they are not selected.
/// </summary>
public sealed partial class EditorShell
{
    // Entities that a panel other than the properties panel watches, by handle, with how many times, so a change of
    // the selection does not stop their values.
    readonly Dictionary<ulong, int> _watches = [];

    /// <summary>The volume that holds the open scene's atmosphere, or null without one, or while the game plays.</summary>
    public SceneEntity? AtmosphereVolume => IsEditing && Scene != null ? Atmosphere.Find(Scene.Expanded.Flat) : null;

    /// <summary>The directional light that the atmosphere's sky takes its sun from, or null.</summary>
    public SceneEntity? AtmosphereSun => Scene != null && AtmosphereVolume is { } volume ? Atmosphere.SunOf(Scene.Expanded.Flat, volume) : null;

    /// <summary>
    /// Edits the atmosphere as one undo entry, giving the scene one first when it has none (see
    /// <see cref="Atmosphere.Create"/>). The edit takes the scene and the volume, which may be new.
    /// </summary>
    public bool EditAtmosphere(string label, Func<Scene, SceneEntity, Operation[]> edit)
    {
        if (Scene == null || !IsEditing)
        {
            return false;
        }
        var scene = Scene.Expanded.Flat;
        var (create, volume) = Atmosphere.Create(scene);
        return Edit(label, [.. create, .. edit(scene, volume)]);
    }

    /// <summary>Selects the atmosphere's volume, giving the scene one first when it has none.</summary>
    public void SelectAtmosphere()
    {
        if (Scene == null || !IsEditing)
        {
            return;
        }
        var (create, volume) = Atmosphere.Create(Scene.Expanded.Flat);
        if (create.Length == 0 || Edit("Create Atmosphere", create))
        {
            SelectScene(volume.Id);
        }
    }

    /// <summary>
    /// Links the sky's sun to the selected directional light, or the scene's first, or unlinks it when it is linked.
    /// </summary>
    public void ToggleSunLink()
    {
        if (AtmosphereSun != null)
        {
            EditAtmosphere("Unlink Sun", (_, volume) => Atmosphere.Link(volume, 0));
            return;
        }
        var scene = Scene?.Expanded.Flat;
        var light = SelectedSceneEntities.FirstOrDefault(e => e.Components.Any(c => c.Id == SceneEdits.DirectionalLightId))
            ?? (scene == null ? null : Atmosphere.DirectionalLights(scene).FirstOrDefault());
        if (light != null)
        {
            EditAtmosphere("Link Sun", (_, volume) => Atmosphere.Link(volume, light.Id));
        }
    }

    /// <summary>Watches an entity's values for a panel, as the selection's are, until as many <see cref="Unwatch"/>.</summary>
    public void Watch(ulong handle)
    {
        if (handle == 0)
        {
            return;
        }
        var count = _watches.GetValueOrDefault(handle);
        _watches[handle] = count + 1;
        if (count == 0 && !Selection.Contains(handle))
        {
            Host.Send(new WatchEntity(handle));
        }
    }

    public void Unwatch(ulong handle)
    {
        if (!_watches.TryGetValue(handle, out var count))
        {
            return;
        }
        if (count > 1)
        {
            _watches[handle] = count - 1;
            return;
        }
        _watches.Remove(handle);
        if (!Selection.Contains(handle))
        {
            Host.Send(new UnwatchEntity(handle));
        }
    }
}
