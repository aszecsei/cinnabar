using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Commands.Ribbon;
using Cinnabar.Editor.Docking;
using Cinnabar.Editor.Document;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The editor's ribbon (see docs/editor/shell-and-panels.md#ribbon), a tab for each kind of work (see
/// docs/editor/workflows.md#who-the-editor-is-for). It holds only commands that work today, and only commands that act
/// on the scene, the project or the window: what is one viewport's, such as its view, and what is the Scene's, such as
/// the tool and mesh mode, is where the work is (see docs/editor/viewport.md#toolbar).
/// </summary>
static class DefaultRibbon
{
    // The categories' bands over their tabs: the disciplines that the tabs are for.
    const string Art = "art";
    const string Design = "design";
    const string Audio = "audio";

    public static RibbonLayout Create(IEnumerable<PanelTool> panels)
    {
        var panelCommands = panels.Select(p => EditorCommands.Panel(p.Id)).ToList();
        return new RibbonLayout(
            Categories:
            [
                new RibbonCategory(Art, "Art", "#3F8F5F"),
                new RibbonCategory(Design, "Design", "#7A62C9"),
                new RibbonCategory(Audio, "Audio", "#3B82B8"),
            ],
            Tabs:
            [
                // What everyone does to a scene: open and save it, undo, add to it, and act on the selection.
                new RibbonTab("home", "Home",
                [
                    new RibbonGroup("Scene",
                    [
                        new LargeButton(EditorCommands.OpenScene),
                        new LargeButton(EditorCommands.Save),
                        new SmallStack([EditorCommands.SaveAs, EditorCommands.SaveAll]),
                        new SmallStack([EditorCommands.AddScene, EditorCommands.CloseScene]),
                    ]),
                    new RibbonGroup("Edit",
                    [
                        new SmallStack([EditorCommands.Undo, EditorCommands.Redo]),
                        new SmallStack([EditorCommands.DuplicateEntity, EditorCommands.DeleteEntity, EditorCommands.SelectAll]),
                    ]),
                    new RibbonGroup("Add",
                    [
                        new Dropdown("Add", "add", AddMenu()) { Description = "Add an entity of a common kind, ready to use: a light, a camera, a volume, a sound." },
                        new SmallStack([Add(EntityCatalog.EmptyId), Add("mesh"), Add("camera")]),
                    ]),
                    new RibbonGroup("Visibility",
                    [
                        new SmallStack([EditorCommands.HideSelected, EditorCommands.ShowAll, EditorCommands.LockSelected]),
                    ]),
                    new RibbonGroup("Prefab",
                    [
                        new LargeButton(EditorCommands.MakePrefab),
                        new SmallStack([EditorCommands.OpenPrefab, EditorCommands.SelectPrefabAsset, EditorCommands.MakeVariant]),
                        new SmallStack([EditorCommands.ApplyAllPrefab, EditorCommands.RevertAllPrefab]),
                        new SmallStack([EditorCommands.UnpackPrefab, EditorCommands.UnpackPrefabCompletely]),
                    ]),
                ]),
                // The lighting artist's: the lights, the probes, and the scene's atmosphere, whose panel has every
                // setting (see docs/editor/shell-and-panels.md#atmosphere).
                new RibbonTab("lighting", "Lighting",
                [
                    new RibbonGroup("Lights",
                    [
                        new LargeButton(Add("directionalLight")),
                        new LargeButton(Add("pointLight")),
                        new LargeButton(Add("spotLight")),
                        new Dropdown("Area Light", "light-area", [Add("quadLight"), Add("diskLight"), Add("lineLight")]) { Description = "Add a light with a shape: a rectangle, a disk or a tube." },
                    ]),
                    new RibbonGroup("Reflections",
                    [
                        new LargeButton(Add("reflectionProbe")),
                        new SmallStack([EditorCommands.CaptureProbe, EditorCommands.CaptureAllProbes]),
                    ]),
                    new RibbonGroup("Volumes",
                    [
                        new Dropdown("Volume", "volume", [.. Kinds(EntityCatalog.Volumes)]) { Description = "Add a volume, which gives the settings inside it: the post-processing, the fog, the sky." },
                    ]),
                    new RibbonGroup("Atmosphere", [new LargeButton(EditorCommands.AtmosphereSelect), new ComboBox(EditorCommands.AtmosphereMode)]),
                    new RibbonGroup("Sun",
                    [
                        new LargeButton(EditorCommands.LinkSun),
                        new Dropdown("Time of Day", "sun", [.. Atmosphere.TimesOfDay.Select(t => EditorCommands.TimeOfDay(t.Name))]),
                    ]),
                    new RibbonGroup("Sky",
                    [
                        new Dropdown("Air", "sky", [.. Atmosphere.Skies.Select(s => EditorCommands.SkyPreset(s.Name))]),
                        new SmallStack([EditorCommands.Stars, EditorCommands.Moon, EditorCommands.AimSun]),
                    ]),
                    // The fog and the clouds are on or off here, with their presets. The panel has their settings, the
                    // weather's source and Center Weather Here.
                    new RibbonGroup("Weather",
                    [
                        new SmallStack([EditorCommands.AtmosphereFog, EditorCommands.AtmosphereClouds]),
                        new Dropdown("Fog Density", "fog", [.. Atmosphere.Fogs.Select(f => EditorCommands.FogPreset(f.Name))]),
                        new Dropdown("Weather", "cloud", [.. Atmosphere.Weathers.Select(w => EditorCommands.WeatherPreset(w.Name))]),
                    ]),
                    new RibbonGroup("Panels", [new SmallStack([EditorCommands.Panel("atmosphere"), EditorCommands.Panel("weather")])]),
                ]) { Category = Art },
                // The environment artist's: what a level is dressed with, and the assets that it is made of. The mesh
                // tools are in the Scene, where the meshes are (see docs/editor/mesh-editing.md#mesh-mode).
                new RibbonTab("environment", "Environment",
                [
                    new RibbonGroup("Place",
                    [
                        new LargeButton(Add("mesh")),
                        new SmallStack([Add("particleSystem"), Add("sprite")]),
                    ]),
                    new RibbonGroup("New Asset",
                    [
                        new LargeButton(EditorCommands.NewMaterial),
                        new SmallStack([EditorCommands.NewMaterialFunction, EditorCommands.NewMesh, EditorCommands.NewPrefab]),
                        new SmallStack([EditorCommands.NewEffect, EditorCommands.NewSpriteSheet, EditorCommands.NewFolder]),
                    ]),
                    new RibbonGroup("Panels", [new SmallStack([EditorCommands.Panel("contentBrowser"), EditorCommands.Panel("faceEditor")])]),
                ]) { Category = Art },
                // The level and gameplay designer's: what makes a level play, and the assets that say how. A game's own
                // commands that name this tab join it (see docs/editor/shell-and-panels.md#game-commands).
                new RibbonTab("gameplay", "Gameplay",
                [
                    new RibbonGroup("Place",
                    [
                        new LargeButton(Add("camera")),
                        new SmallStack([Add("trigger"), Add("collider"), Add("rigidBody")]),
                        new SmallStack([Add("character"), Add("agent"), Add("navigationVolume")]),
                        new SmallStack([Add("uiDocument")]),
                    ]),
                    new RibbonGroup("AI",
                    [
                        new Dropdown("New Decision", "decision", NewDecisionMenu)
                        { Description = "Make a decision asset, which says how an agent thinks, in the content browser's folder." },
                        new SmallStack([EditorCommands.NewBlackboard]),
                    ]),
                    new RibbonGroup("New Asset",
                    [
                        new SmallStack([EditorCommands.NewSceneAsset, EditorCommands.NewPrefab]),
                        new SmallStack([EditorCommands.NewUiDocument, EditorCommands.NewAnimationGraph]),
                        new SmallStack([EditorCommands.NewCutscene]),
                    ]),
                ]) { Category = Design },
                // The gameplay programmer's: scripts, the build, and where a frame's time goes.
                new RibbonTab("scripting", "Scripting",
                [
                    new RibbonGroup("Scripts",
                    [
                        new LargeButton(EditorCommands.NewBehaviour),
                        new SmallStack([EditorCommands.NewScript]),
                    ]),
                    new RibbonGroup("Code", [new LargeButton(EditorCommands.BuildProject)]),
                    new RibbonGroup("Profiler",
                    [
                        new LargeButton(EditorCommands.CaptureFrame),
                        new SmallStack([EditorCommands.CaptureWorstFrame, EditorCommands.RecordZones]),
                    ]),
                    new RibbonGroup("Panels",
                    [
                        new SmallStack([EditorCommands.Panel("console"), EditorCommands.Panel("profiler"), EditorCommands.Panel("resourceMonitor")]),
                    ]),
                ]) { Category = Design },
                // The sound designer's.
                new RibbonTab("audio", "Audio",
                [
                    new RibbonGroup("Place", [new LargeButton(Add("audioSource")), new LargeButton(Add("audioListener"))]),
                ]) { Category = Audio },
                // The project as a whole: the game in its own window, the build that ships, and the processes behind the editor.
                new RibbonTab("project", "Project",
                [
                    new RibbonGroup("Game Window",
                    [
                        new SplitButton(EditorCommands.RunGame, [EditorCommands.RunGame, EditorCommands.StopGame]),
                        new ComboBox(EditorCommands.ProjectOutput),
                        new ComboBox(EditorCommands.UserOutput),
                        new ComboBox(EditorCommands.ProjectQuality),
                        new ComboBox(EditorCommands.UserQuality),
                    ]),
                    new RibbonGroup("Release", [new LargeButton(EditorCommands.ExportProject)]),
                    new RibbonGroup("Project", [new LargeButton(EditorCommands.OpenProject)]),
                    new RibbonGroup("Processes",
                    [
                        new SplitButton(EditorCommands.RestartHost, [EditorCommands.RestartHost, EditorCommands.StopHost]),
                        new SmallStack([EditorCommands.RestartCook]),
                    ]),
                ]),
                // The editor's own window: how the panels are arranged, which show, and pictures of the viewport.
                new RibbonTab("window", "Window",
                [
                    new RibbonGroup("Workspace", [new ComboBox(EditorCommands.Workspace), new SmallStack([EditorCommands.ResetLayout])]),
                    new RibbonGroup("Panels", panelCommands.Chunk(SmallStack.MaxCommands).Select(c => (RibbonItem)new SmallStack(c)).ToList()),
                    new RibbonGroup("Documents", [new SmallStack([EditorCommands.SceneView, EditorCommands.GameView])]),
                    new RibbonGroup("Capture", [new LargeButton(EditorCommands.Screenshot), new SmallStack([EditorCommands.CaptureGif])]),
                ]),
            ])
        {
            // Play is every discipline's, whatever tab shows.
            QuickAccess = [EditorCommands.PlayMode, EditorCommands.PauseMode, EditorCommands.StepFrame, EditorCommands.StopMode],
        };
    }

    static string Add(string template) => EditorCommands.AddEntity(template);

    static IEnumerable<MenuEntry> Kinds(string category) =>
        EntityCatalog.All.Where(t => t.Category == category).Select(t => (MenuEntry)Add(t.Id));

    // The four kinds of decision, one for each technique.
    static readonly IReadOnlyList<MenuEntry> NewDecisionMenu =
        [EditorCommands.NewDecision, EditorCommands.NewUtilityDecision, EditorCommands.NewGoapDecision, EditorCommands.NewHtnDecision];

    /// <summary>
    /// The New menu of the content browser's folders: a command for each kind of asset that the content browser makes,
    /// with the decisions in a menu of their own, as the ribbon has them, and a folder last.
    /// </summary>
    public static IReadOnlyList<MenuEntry> NewAssetMenu() =>
    [
        EditorCommands.NewScript, EditorCommands.NewBehaviour, EditorCommands.NewSceneAsset,
        EditorCommands.NewMaterial, EditorCommands.NewMaterialFunction, EditorCommands.NewMesh,
        EditorCommands.NewPrefab, EditorCommands.NewEffect,
        EditorCommands.NewAnimationGraph, EditorCommands.NewUiDocument,
        EditorCommands.NewSpriteSheet, EditorCommands.NewBlackboard, EditorCommands.NewCutscene,
        new Submenu("New Decision", "decision", NewDecisionMenu),
        EditorCommands.NewFolder,
    ];

    /// <summary>
    /// The Add menu, which the ribbon, the outliner and the Scene's tool strip show: the empty entity, then a menu for
    /// each category of the catalog, in the catalog's order.
    /// </summary>
    public static IReadOnlyList<MenuEntry> AddMenu() =>
    [
        Add(EntityCatalog.EmptyId),
        new MenuSeparator(),
        .. EntityCatalog.Categories.Select(c => (MenuEntry)new Submenu(c, CategoryIcon(c), [.. Kinds(c)])),
    ];

    static string CategoryIcon(string category) => category switch
    {
        EntityCatalog.Lighting => "light-point",
        EntityCatalog.Rendering => "camera",
        EntityCatalog.Volumes => "volume",
        EntityCatalog.Physics => "collider",
        EntityCatalog.Audio => "audio",
        EntityCatalog.Navigation => "nav-path",
        _ => "ui-document",
    };
}
