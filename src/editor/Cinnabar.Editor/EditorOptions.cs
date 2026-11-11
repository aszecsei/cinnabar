using Cinnabar.Editor.Content;
using Cinnabar.Editor.Document;

namespace Cinnabar.Editor;

/// <summary>
/// The command line: <c>editor &lt;project&gt;</c> opens a project's folder with the engine that the editor is in (see
/// <see cref="ForProject"/>), and with no arguments the editor shows its welcome window (see
/// docs/editor/processes-and-projects.md#projects). The full form, which <c>just edit</c> uses, is <c>editor [--host &lt;host.exe&gt;] [--game &lt;game.dll&gt;] [--scene &lt;file.scene&gt;]
/// [--cook &lt;cook.exe&gt;] [--cache &lt;dir&gt;] [--definitions &lt;file&gt;] [--dxc &lt;dxc.exe&gt;] [--include &lt;dir&gt;]...
/// [--root &lt;name&gt;=&lt;dir&gt;]... [--material &lt;file&gt;]... [--effect &lt;file&gt;]... [--animation-graph &lt;file&gt;]... [--project &lt;project.settings&gt;]</c>. The daemon
/// cooks shaders only with <c>--dxc</c>. Each <c>--material</c> opens in the material editor, and each <c>--effect</c> in an
/// effect preview, once the cook daemon's index has it.
/// Paths on the command line are relative to the working directory. The defaults are the repository's build layout
/// (see docs/overview/building-and-running.md#build-layout), relative to the repository root, which the editor finds above its own
/// executable, so an editor started from an IDE finds them too. The host and the cook daemon run in their executables'
/// directories, and the host is told the content and the project in full, so the editor's working directory never
/// matters to them. Without a scene, the host shows the scene that the game loads itself.
/// </summary>
public sealed record EditorOptions(string HostPath, string GamePath, string? ScenePath = null)
{
    /// <summary>Materials and material functions to open in the material editor, by their files' full paths.</summary>
    public IReadOnlyList<string> MaterialPaths { get; init; } = [];

    /// <summary>Effects to open in effect previews, by their files' full paths.</summary>
    public IReadOnlyList<string> EffectPaths { get; init; } = [];

    /// <summary>Animation graphs to open in the animation graph editor, by their files' full paths.</summary>
    public IReadOnlyList<string> AnimationGraphPaths { get; init; } = [];

    /// <summary>UI documents to open in the UI editor, by their files' full paths.</summary>
    public IReadOnlyList<string> UiDocumentPaths { get; init; } = [];

    /// <summary>The project's folder, which Build Project and Export Project build: the settings file's.</summary>
    public string ProjectDirectory => Path.GetDirectoryName(ProjectPath) ?? Environment.CurrentDirectory;

    /// <summary>The engine's checkout, whose <c>cinnabar.exe</c> builds and exports the project.</summary>
    public string EngineRoot { get; init; } = RepositoryRoot();

    /// <summary>The project's settings file, which the game reads (see docs/overview/architecture.md#project-settings).</summary>
    public string ProjectPath { get; init; } = InRepository("samples", "mygame", "project.settings");

    /// <summary>Where autosaves go (see docs/editor/processes-and-projects.md#crash-recovery).</summary>
    public string AutosaveDirectory { get; init; } = InRepository("build", "obj", "editor", "autosave");

    /// <summary>Where screenshots, GIFs and their sidecars go (see docs/editor/capture.md#capture).</summary>
    public string CaptureDirectory { get; init; } = InRepository("build", "captures");

    /// <summary>Where the editor writes its automation port for tools such as editorctl (see docs/editor/capture.md#automation).</summary>
    public string AutomationFile { get; init; } = InRepository("build", "obj", "editor", "automation.json");

    /// <summary>How the editor runs the cook daemon (see docs/editor/processes-and-projects.md#processes). The defaults are the repository's.</summary>
    public CookOptions Cook { get; init; } = new(
        InRepository("build", "tools", "cook.exe"),
        InRepository("build", "dev", "content"),
        InRepository("build", "obj", "script-types", "cinnabar.d.luau"),
        [("game", InRepository("samples", "mygame", "content")), ("engine", InRepository("lib", "engine", "content"))],
        RepositoryRoot());

    /// <summary>
    /// The host's arguments: the game, where its content and its project settings are, and then the given ones (see
    /// docs/editor/processes-and-projects.md#processes).
    /// </summary>
    public string[] HostArguments(params string[] rest) =>
        [GamePath, "--content", Cook.CachePath, "--project", ProjectPath, .. rest];

    /// <summary>The host runs in its executable's directory.</summary>
    public string HostDirectory => Path.GetDirectoryName(HostPath) is { Length: > 0 } dir ? dir : RepositoryRoot();

    /// <summary>The engine's checkout (see <see cref="ProjectLayout.EngineRoot"/>), else the working directory.</summary>
    public static string RepositoryRoot() => ProjectLayout.EngineRoot() ?? Environment.CurrentDirectory;

    /// <summary>
    /// The options of a project's folder with an engine's checkout: the paths that <c>cinnabar.exe</c> builds (see
    /// docs/overview/getting-started.md#a-project). The game is the project's <c>build/dev/game.dll</c> when it has Odin,
    /// and the engine's <c>standard.dll</c> otherwise. The scene is the one that its settings' <c>game.main_scene</c>
    /// names. The editor's own files, its autosaves and captures, go in the project's <c>build/editor</c>.
    /// </summary>
    public static EditorOptions ForProject(string projectDir, string engineRoot)
    {
        projectDir = Path.GetFullPath(projectDir);
        engineRoot = Path.GetFullPath(engineRoot);
        string Engine(params string[] parts) => Path.Combine([engineRoot, .. parts]);
        string Project(params string[] parts) => Path.Combine([projectDir, .. parts]);
        var settings = Project(ProjectLayout.SettingsFileName);
        var game = ProjectLayout.HasOdin(projectDir) ? Project("build", "dev", "game.dll") : Engine("build", "dev", "standard.dll");
        var content = Project("content");
        var scene = ProjectSettings.Get(settings, ProjectLayout.MainSceneKey) is { Length: > 0 } guid ? ProjectLayout.FindAsset(content, guid) : null;
        return new EditorOptions(Engine("build", "dev", "host.exe"), game, scene)
        {
            EngineRoot = engineRoot,
            ProjectPath = settings,
            AutosaveDirectory = Project("build", "editor", "autosave"),
            CaptureDirectory = Project("build", "editor", "captures"),
            AutomationFile = Project("build", "editor", "automation.json"),
            Cook = new CookOptions(
                Engine("build", "tools", "cook.exe"),
                Project("build", "cache"),
                Project("build", "types", "cinnabar.d.luau"),
                [("game", content), ("engine", Engine("lib", "engine", "content"))],
                engineRoot,
                ProjectLayout.Dxc(engineRoot),
                [Engine("lib", "core", "gpu", "shaders"), Engine("lib", "engine", "content", "shaders"), Engine("vendor", "smaa")]),
        };
    }

    static string InRepository(params string[] parts) => Path.GetFullPath(Path.Combine([RepositoryRoot(), .. parts]));

    public static EditorOptions Parse(IReadOnlyList<string> args)
    {
        if (args.Count == 1 && !args[0].StartsWith("--", StringComparison.Ordinal))
        {
            var dir = ProjectLayout.ProjectDirectory(args[0]) ?? throw new ArgumentException($"{args[0]} is not a project: it has no {ProjectLayout.SettingsFileName}");
            return ForProject(dir, RepositoryRoot());
        }
        var host = InRepository("build", "dev", "host.exe");
        var game = InRepository("build", "dev", "mygame.dll");
        string? scene = null;
        var cook = new EditorOptions("", "").Cook;
        List<(string Name, string Dir)> roots = [];
        List<string> includes = [];
        List<string> materials = [];
        List<string> effects = [];
        List<string> animationGraphs = [];
        List<string> uiDocuments = [];
        string? project = null;
        for (var i = 0; i < args.Count; i++)
        {
            switch (args[i])
            {
                case "--host" when i + 1 < args.Count:
                    host = args[++i];
                    break;
                case "--game" when i + 1 < args.Count:
                    game = args[++i];
                    break;
                case "--scene" when i + 1 < args.Count:
                    scene = Path.GetFullPath(args[++i]);
                    break;
                case "--cook" when i + 1 < args.Count:
                    cook = cook with { CookPath = Path.GetFullPath(args[++i]) };
                    break;
                case "--cache" when i + 1 < args.Count:
                    cook = cook with { CachePath = Path.GetFullPath(args[++i]) };
                    break;
                case "--definitions" when i + 1 < args.Count:
                    cook = cook with { DefinitionsPath = Path.GetFullPath(args[++i]) };
                    break;
                case "--dxc" when i + 1 < args.Count:
                    cook = cook with { DxcPath = Path.GetFullPath(args[++i]) };
                    break;
                case "--include" when i + 1 < args.Count:
                    includes.Add(Path.GetFullPath(args[++i]));
                    break;
                case "--project" when i + 1 < args.Count:
                    project = Path.GetFullPath(args[++i]);
                    break;
                case "--material" when i + 1 < args.Count:
                    materials.Add(Path.GetFullPath(args[++i]));
                    break;
                case "--effect" when i + 1 < args.Count:
                    effects.Add(Path.GetFullPath(args[++i]));
                    break;
                case "--animation-graph" when i + 1 < args.Count:
                    animationGraphs.Add(Path.GetFullPath(args[++i]));
                    break;
                case "--ui-document" when i + 1 < args.Count:
                    uiDocuments.Add(Path.GetFullPath(args[++i]));
                    break;
                case "--root" when i + 1 < args.Count && args[i + 1].IndexOf('=') > 0:
                    var root = args[++i];
                    var equals = root.IndexOf('=');
                    roots.Add((root[..equals], Path.GetFullPath(root[(equals + 1)..])));
                    break;
                default:
                    throw new ArgumentException($"unknown argument {args[i]}");
            }
        }
        if (roots.Count > 0)
        {
            cook = cook with { Roots = roots };
        }
        if (includes.Count > 0)
        {
            cook = cook with { Includes = includes };
        }
        var options = new EditorOptions(Path.GetFullPath(host), Path.GetFullPath(game), scene) { Cook = cook, MaterialPaths = materials, EffectPaths = effects, AnimationGraphPaths = animationGraphs, UiDocumentPaths = uiDocuments };
        return project != null ? options with { ProjectPath = project } : options;
    }
}
