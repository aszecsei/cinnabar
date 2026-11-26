using Cinnabar.Editor.Maths;

namespace Cinnabar.Editor.Document;

/// <summary>
/// A kind of entity that the editor adds in one step (see docs/editor/shell-and-panels.md#add): what the Add menu calls
/// it and where it offers it, and the components that the entity starts with. A component has the fields that make the
/// entity useful at once, and no more: a light that is added as a component alone has an intensity of 0, and shows
/// nothing until its user finds out why.
/// </summary>
public sealed record EntityTemplate(string Id, string Label, string Category, string Icon, string Description, IReadOnlyList<SceneComponent> Components)
{
    /// <summary>Which way the new entity faces. A light that shines along its +z starts turned down.</summary>
    public Quat Rotation { get; init; } = Quat.Identity;
}

/// <summary>
/// The kinds of entity that the Add menu offers, in its order: a folder for each category, and in it the kinds as they
/// are listed here. A project's own kinds are its prefabs, which the content browser places.
/// </summary>
public static class EntityCatalog
{
    /// <summary>The kind without components beyond its Transform, which the Add menu has first, outside the folders.</summary>
    public const string EmptyId = "empty";

    public const string Lighting = "Lighting";
    public const string Rendering = "Rendering";
    public const string Volumes = "Volumes";
    public const string Physics = "Physics";
    public const string Audio = "Audio";
    public const string Navigation = "Navigation and AI";
    public const string LevelDesign = "Level Design";
    public const string Interface = "UI";

    // A quarter turn about x points an entity's +z down, as a ceiling's light shines.
    static readonly Quat Down = new(0.7071068, 0, 0, 0.7071068);
    // The sun in mid afternoon: 50 degrees down, and 30 degrees round, so that walls along the axes have a lit and a shaded side.
    static readonly Quat Afternoon = new(0.4082, 0.2346, -0.1094, 0.8754);

    public static IReadOnlyList<EntityTemplate> All { get; } =
    [
        new(EmptyId, "Empty Entity", "", "add", "An entity with a Transform, to add components to.", []),

        new("directionalLight", "Directional Light", Lighting, "sun", "A light from far away, as the sun's, that shines along its +z and casts shadows.",
            [Component(SceneEdits.DirectionalLightId, "Directional_Light", ("intensity", Number(3)), ("cast_shadows", Flag(true)))])
        { Rotation = Afternoon },
        new("pointLight", "Point Light", Lighting, "light-point", "A light in every direction from a point, which reaches 10 m.",
            [Component(35, "Point_Light", ("intensity", Number(10)), ("cast_shadows", Flag(true)))]),
        new("spotLight", "Spot Light", Lighting, "light-spot", "A light in a cone along its +z, which starts pointing down.",
            [Component(36, "Spot_Light", ("intensity", Number(25)), ("inner_angle", Number(0.45)), ("outer_angle", Number(0.7)), ("cast_shadows", Flag(true)))])
        { Rotation = Down },
        new("quadLight", "Quad Light", Lighting, "light-area", "A rectangle of light, 1 m each way, that shines along its +z, which starts pointing down.",
            [Component(39, "Quad_Light", ("intensity", Number(4)), ("cast_shadows", Flag(true)))])
        { Rotation = Down },
        new("diskLight", "Disk Light", Lighting, "light-area", "A disk of light, 1 m across, that shines along its +z, which starts pointing down.",
            [Component(40, "Disk_Light", ("intensity", Number(4)), ("cast_shadows", Flag(true)))])
        { Rotation = Down },
        new("lineLight", "Line Light", Lighting, "light-area", "A tube of light, 1 m long, along its x.",
            [Component(41, "Line_Light", ("intensity", Number(4)), ("cast_shadows", Flag(true)))]),
        new("reflectionProbe", "Reflection Probe", Lighting, "probe", "Captures the world around it for the surfaces in its box to reflect. Its handles resize its boxes in the viewport.",
            [Component(SceneEdits.ReflectionProbeId, "Reflection_Probe")]),

        new("camera", "Camera", Rendering, "camera", "A camera that the game can draw from. The Game view shows the game's own.",
            [Component(32, "Camera")]),
        new("mesh", "Mesh", Rendering, "mesh", "An entity that draws a mesh asset. Choose its mesh and materials in the properties panel, or drag them from the content browser.",
            [Component(SceneEdits.MeshRendererId, "Mesh_Renderer", ("cast_shadows", Flag(true)))]),
        new("sprite", "Sprite", Rendering, "sprite-sheet", "An entity that draws a frame of a sprite sheet.",
            [Component(56, "Sprite_Renderer")]),
        new("particleSystem", "Particle System", Rendering, "effect", "An entity that plays an effect asset.",
            [Component(52, "Particle_System")]),

        new("globalVolume", "Global Volume", Volumes, "volume", "A volume that reaches everywhere, for the settings that the scene starts from: add its settings components in the properties panel.",
            [Volume("Global")]),
        new("boxVolume", "Box Volume", Volumes, "volume", "A box that changes the settings inside it, and blends at its edge.",
            [Volume("Box")]),
        new("sphereVolume", "Sphere Volume", Volumes, "volume", "A sphere that changes the settings inside it, and blends at its edge.",
            [Volume("Sphere")]),
        new("postVolume", "Post-Processing Volume", Volumes, "volume", "A global volume with the exposure, the tone mapping and the bloom, ready to set.",
            [Volume("Global"), Component(44, "Exposure"), Component(45, "Tone_Mapping"), Component(46, "Bloom")]),
        new("fogVolume", "Fog Volume", Volumes, "fog", "A box of fog, which blends at its edge.",
            [Volume("Box"), Component(SceneEdits.FogId, "Fog")]),

        new("collider", "Static Collider", Physics, "collider", "A shape that bodies and characters collide with, and that does not move.",
            [Component(65, "Collider")]),
        new("rigidBody", "Rigid Body", Physics, "collider", "A body that the physics moves, with a collider for its shape.",
            [Component(64, "Rigid_Body"), Component(65, "Collider")]),
        new("trigger", "Trigger", Physics, "collider", "A sensor that reports the bodies that enter and leave it to its entity's behaviours, and touches none.",
            [Component(65, "Collider", ("sensor", Flag(true)))]),
        new("character", "Character", Physics, "character", "A capsule that walks, climbs steps and slides along walls, for a player or an agent.",
            [Component(75, "Character")]),

        new("audioSource", "Audio Source", Audio, "audio", "Plays a sound where it is. Choose its sound in the properties panel.",
            [Component(96, "Audio_Source")]),
        new("audioListener", "Audio Listener", Audio, "audio", "Where the world is heard from. The first one in the world counts, so a scene needs one, usually on its camera.",
            [Component(97, "Audio_Listener")]),

        new("navigationVolume", "Navigation Volume", Navigation, "nav-path", "A box that the cooker bakes navmeshes in, from the static colliders inside it.",
            [Volume("Box"), Component(128, "Nav_Mesh_Volume")]),
        new("agent", "Agent", Navigation, "decision", "A character that walks on the navmesh and thinks with a decision over a blackboard. Choose both in the properties panel.",
            [Component(75, "Character"), Component(134, "Nav_Agent"), Component(130, "Agent")]),

        new("cutter", "Cutter", LevelDesign, "block", "A box that cuts its opening in the meshes it overlaps that have a Cut_Target, as a door's does. Put it in a prefab with its door.",
            [Component(SceneEdits.MeshCutterId, "Mesh_Cutter")]),

        new("uiDocument", "UI Document", Interface, "ui-document", "Shows a UI document on the screen: a menu or a HUD.",
            [Component(112, "Ui_Document")]),
    ];

    /// <summary>The categories that have a kind, in the Add menu's order.</summary>
    public static IReadOnlyList<string> Categories { get; } = [.. All.Select(t => t.Category).Where(c => c != "").Distinct()];

    public static EntityTemplate? Find(string id) => All.FirstOrDefault(t => t.Id == id);

    /// <summary>
    /// The operation that makes a root entity of a kind at a position: named for its kind, facing as the kind starts,
    /// with a copy of each of the kind's components.
    /// </summary>
    public static CreateEntity Create(Scene scene, EntityTemplate template, long[] position)
    {
        var create = SceneEdits.NewEntity(scene, new Pose(position, template.Rotation, [1, 1, 1]), template.Id == EmptyId ? "Entity" : template.Label);
        foreach (var component in template.Components)
        {
            create.Created.Components.Add(component with { Fields = [.. component.Fields] });
        }
        return create;
    }

    static SceneComponent Component(ulong id, string name, params (string Name, SceneValue Value)[] fields) =>
        new(id, name, [.. fields.Select(f => new SceneField(f.Name, f.Value))]);

    static SceneComponent Volume(string shape) => Component(SceneEdits.VolumeId, "Volume", ("shape", SceneValue.Name(shape)));

    static SceneValue Number(double value) => SceneEdits.Floats(value);

    static SceneValue Flag(bool value) => SceneValue.Of(value);
}
