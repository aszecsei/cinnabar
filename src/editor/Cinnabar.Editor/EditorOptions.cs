using Cinnabar.Editor.Content;

namespace Cinnabar.Editor;

/// <summary>
/// The command line: <c>editor [--host &lt;host.exe&gt;] [--game &lt;game.dll&gt;] [--scene &lt;file.scene&gt;]
/// [--cook &lt;cook.exe&gt;] [--cache &lt;dir&gt;] [--definitions &lt;file&gt;] [--dxc &lt;dxc.exe&gt;] [--include &lt;dir&gt;]...
/// [--root &lt;name&gt;=&lt;dir&gt;]... [--material &lt;file&gt;]... [--project &lt;project.settings&gt;]</c>. The daemon cooks shaders only with <c>--dxc</c>.
/// Each <c>--material</c> opens in the material editor once the cook daemon's index has it.
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

    /// <summary>The project's settings file, which the game reads (see docs/overview/architecture.md#project-settings).</summary>
    public string ProjectPath { get; init; } = InRepository("samples", "mygame", "project.settings");

    /// <summary>Where autosaves go (see docs/editor/processes-and-projects.md#crash-recovery).</summary>
    public string AutosaveDirectory { get; init; } = InRepository("build", "obj", "editor", "autosave");

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

    /// <summary>
    /// The repository root: the directory with the justfile above the editor's executable, else the working directory.
    /// </summary>
    public static string RepositoryRoot()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
        {
            if (File.Exists(Path.Combine(dir.FullName, "justfile")))
            {
                return dir.FullName;
            }
        }
        return Environment.CurrentDirectory;
    }

    static string InRepository(params string[] parts) => Path.GetFullPath(Path.Combine([RepositoryRoot(), .. parts]));

    public static EditorOptions Parse(IReadOnlyList<string> args)
    {
        var host = InRepository("build", "dev", "host.exe");
        var game = InRepository("build", "dev", "mygame.dll");
        string? scene = null;
        var cook = new EditorOptions("", "").Cook;
        List<(string Name, string Dir)> roots = [];
        List<string> includes = [];
        List<string> materials = [];
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
        var options = new EditorOptions(Path.GetFullPath(host), Path.GetFullPath(game), scene) { Cook = cook, MaterialPaths = materials };
        return project != null ? options with { ProjectPath = project } : options;
    }
}
