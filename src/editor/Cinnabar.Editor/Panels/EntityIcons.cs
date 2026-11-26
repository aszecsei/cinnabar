namespace Cinnabar.Editor.Panels;

/// <summary>
/// The icon of an entity in the outliner, by what it is (see docs/editor/shell-and-panels.md#outliner): the first of its
/// components that says so, in an order that puts what a person looks for first. A guard with a mesh, a character and
/// an agent is an agent, and a camera with a listener is a camera.
/// </summary>
public static class EntityIcons
{
    // The components that say what an entity is, by name as the game registers them, the most telling first.
    static readonly (string Component, string Icon)[] Order =
    [
        ("Camera", "camera"),
        ("Directional_Light", "sun"),
        ("Point_Light", "light-point"),
        ("Spot_Light", "light-spot"),
        ("Quad_Light", "light-area"),
        ("Disk_Light", "light-area"),
        ("Line_Light", "light-area"),
        ("Reflection_Probe", "probe"),
        ("Nav_Mesh_Volume", "nav-path"),
        ("Mesh_Cutter", "block"),
        ("Volume", "volume"),
        ("Ui_Document", "ui-document"),
        ("Agent", "decision"),
        ("Character", "character"),
        ("Particle_System", "effect"),
        ("Audio_Source", "audio"),
        ("Sprite_Renderer", "sprite-sheet"),
        ("Mesh_Renderer", "mesh"),
        ("Instanced_Mesh_Renderer", "mesh"),
        ("Surface_Renderer", "mesh"),
        ("Rigid_Body", "collider"),
        ("Collider", "collider"),
        ("Audio_Listener", "audio"),
        ("Behaviours", "script"),
    ];

    /// <summary>The icon's key for an entity with these components, or null for an entity that is nothing in particular.</summary>
    public static string? For(IEnumerable<string> components)
    {
        var has = components.ToHashSet();
        foreach (var (component, icon) in Order)
        {
            if (has.Contains(component))
            {
                return icon;
            }
        }
        return null;
    }
}
