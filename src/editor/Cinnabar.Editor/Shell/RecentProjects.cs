namespace Cinnabar.Editor.Shell;

/// <summary>
/// The projects that the editor opened, the latest first, which its welcome window lists (see
/// docs/editor/processes-and-projects.md#projects). They are one folder to a line in the user's editor settings, so every
/// checkout of the engine shares them.
/// </summary>
public sealed class RecentProjects(EditorSettings settings)
{
    public const string FileName = "recent-projects.txt";

    /// <summary>The most that the list keeps.</summary>
    public const int Capacity = 10;

    /// <summary>The projects, the latest first, without those whose folder is no longer a project.</summary>
    public IReadOnlyList<string> List() => [.. Read().Where(p => ProjectLayout.ProjectDirectory(p) != null)];

    /// <summary>Puts a project first, once, and keeps the list to <see cref="Capacity"/>.</summary>
    public void Add(string projectDir)
    {
        var full = Path.GetFullPath(projectDir).TrimEnd('\\', '/');
        List<string> list = [full, .. Read().Where(p => !string.Equals(p, full, StringComparison.OrdinalIgnoreCase))];
        Write(list.Take(Capacity));
    }

    /// <summary>Takes a project out of the list, such as one that failed to open.</summary>
    public void Remove(string projectDir)
    {
        var full = Path.GetFullPath(projectDir).TrimEnd('\\', '/');
        Write(Read().Where(p => !string.Equals(p, full, StringComparison.OrdinalIgnoreCase)));
    }

    IEnumerable<string> Read() =>
        (settings.Read(FileName) ?? "").Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0);

    void Write(IEnumerable<string> list) => settings.Write(FileName, string.Join('\n', list) + "\n");
}
