namespace Cinnabar.Editor;

/// <summary>
/// The command line: <c>editor [--host &lt;host.exe&gt;] [--game &lt;game.dll&gt;]</c>. Paths are relative to the
/// working directory, which is also the host's, so <c>just edit</c> runs the editor from the repository root.
/// </summary>
public sealed record EditorOptions(string HostPath, string GamePath)
{
    public static EditorOptions Parse(IReadOnlyList<string> args)
    {
        var host = Path.Combine("build", "host.exe");
        var game = Path.Combine("build", "mygame.dll");
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
                default:
                    throw new ArgumentException($"unknown argument {args[i]}");
            }
        }
        return new EditorOptions(Path.GetFullPath(host), Path.GetFullPath(game));
    }
}
