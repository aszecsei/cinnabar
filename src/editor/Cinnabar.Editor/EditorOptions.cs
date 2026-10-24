namespace Cinnabar.Editor;

/// <summary>
/// The command line: <c>editor [--host &lt;host.exe&gt;] [--game &lt;game.dll&gt;] [--scene &lt;file.scene&gt;]</c>.
/// Paths are relative to the working directory, which is also the host's, so <c>just edit</c> runs the editor from
/// the repository root. Without a scene, the host shows the scene that the game loads itself.
/// </summary>
public sealed record EditorOptions(string HostPath, string GamePath, string? ScenePath = null)
{
    /// <summary>Where autosaves go (see docs/editor.md#crash-recovery).</summary>
    public string AutosaveDirectory { get; init; } = Path.GetFullPath(Path.Combine("build", "editor", "autosave"));

    public static EditorOptions Parse(IReadOnlyList<string> args)
    {
        var host = Path.Combine("build", "host.exe");
        var game = Path.Combine("build", "mygame.dll");
        string? scene = null;
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
                default:
                    throw new ArgumentException($"unknown argument {args[i]}");
            }
        }
        return new EditorOptions(Path.GetFullPath(host), Path.GetFullPath(game), scene);
    }
}
