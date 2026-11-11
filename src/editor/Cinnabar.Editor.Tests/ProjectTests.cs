using Cinnabar.Editor.Content;
using Cinnabar.Editor.Projects;
using Cinnabar.Editor.Shell;
using Xunit;

namespace Cinnabar.Editor.Tests;

/// <summary>Projects outside the engine (see docs/editor/processes-and-projects.md#projects).</summary>
public sealed class ProjectTests : IDisposable
{
    readonly TempDirectory _temp = new("projects");

    public void Dispose() => _temp.Dispose();

    static string Engine => EditorOptions.RepositoryRoot();

    [Fact]
    public void AProjectWithoutOdinRunsTheEnginesStandardGame()
    {
        var intel = EditorOptions.ForProject(Path.Combine(Engine, "samples", "intel"), Engine);

        Assert.Equal(Path.Combine(Engine, "build", "dev", "standard.dll"), intel.GamePath);
        Assert.Equal(Path.Combine(Engine, "build", "dev", "host.exe"), intel.HostPath);
        Assert.Equal(Path.Combine(Engine, "samples", "intel", "project.settings"), intel.ProjectPath);
        Assert.Equal(Path.Combine(Engine, "samples", "intel"), intel.ProjectDirectory);
        Assert.Equal(Path.Combine(Engine, "samples", "intel", "build", "cache"), intel.Cook.CachePath);
        Assert.Equal(Path.Combine(Engine, "samples", "intel", "build", "types", "cinnabar.d.luau"), intel.Cook.DefinitionsPath);
        Assert.Equal([("game", Path.Combine(Engine, "samples", "intel", "content")), ("engine", Path.Combine(Engine, "lib", "engine", "content"))], intel.Cook.Roots);
        Assert.Equal(Path.Combine(Engine, "samples", "intel", "build", "editor", "autosave"), intel.AutosaveDirectory);
        // The scene that game.main_scene names, by its .meta file.
        Assert.Equal(Path.Combine(Engine, "samples", "intel", "content", "scenes", "main.scene"), intel.ScenePath);
        // The host gets the project's cache and settings.
        Assert.Equal([intel.GamePath, "--content", intel.Cook.CachePath, "--project", intel.ProjectPath], intel.HostArguments());
    }

    [Fact]
    public void AProjectWithOdinRunsItsOwnDll()
    {
        var mygame = EditorOptions.ForProject(Path.Combine(Engine, "samples", "mygame"), Engine);

        Assert.True(ProjectLayout.HasOdin(Path.Combine(Engine, "samples", "mygame")));
        Assert.Equal(Path.Combine(Engine, "samples", "mygame", "build", "dev", "game.dll"), mygame.GamePath);
        Assert.Equal("mygame", ProjectLayout.Name(mygame.ProjectDirectory));
    }

    [Fact]
    public void AProjectIsAFolderWithSettings()
    {
        var project = _temp.Combine("game");
        Directory.CreateDirectory(project);
        Assert.Null(ProjectLayout.ProjectDirectory(project));
        File.WriteAllText(Path.Combine(project, "project.settings"), "game.name = Lantern\n");

        Assert.Equal(project, ProjectLayout.ProjectDirectory(project));
        Assert.Equal(project, ProjectLayout.ProjectDirectory(Path.Combine(project, "project.settings")));
        Assert.Equal("Lantern", ProjectLayout.Name(project));
        Assert.True(ProjectLayout.IsEngine(Engine));
        Assert.Equal("basic", ProjectLayout.Templates(Engine)[0]);
        Assert.Contains("odin", ProjectLayout.Templates(Engine));
        // The command line's one folder is a project to open.
        Assert.Equal(Path.Combine(project, "project.settings"), EditorOptions.Parse([project]).ProjectPath);
    }

    [Fact]
    public void RecentProjectsAreTheLatestFirstOnceEach()
    {
        var recent = new RecentProjects(new EditorSettings(_temp.Combine("settings")));
        string[] projects = [.. Enumerable.Range(0, RecentProjects.Capacity + 2).Select(i => _temp.Combine($"p{i}"))];
        foreach (var p in projects)
        {
            Directory.CreateDirectory(p);
            File.WriteAllText(Path.Combine(p, "project.settings"), "");
            recent.Add(p);
        }
        recent.Add(projects[3].ToUpperInvariant());

        var list = recent.List();
        Assert.Equal(RecentProjects.Capacity, list.Count);
        Assert.Equal(projects[3], list[0], ignoreCase: true);
        Assert.Equal(projects[^1], list[1]);
        Assert.DoesNotContain(projects[0], list);

        // A folder that is no longer a project is not listed.
        File.Delete(Path.Combine(projects[^1], "project.settings"));
        Assert.DoesNotContain(projects[^1], recent.List());
        recent.Remove(projects[3]);
        Assert.DoesNotContain(recent.List(), p => string.Equals(p, projects[3], StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void TheToolRunsOneCommandAtATime()
    {
        List<FakeTool> started = [];
        var tool = new ProjectTool("cinnabar.exe", "engine", (path, args, dir) =>
        {
            var p = new FakeTool([path, .. args]);
            started.Add(p);
            return p;
        });
        List<string> lines = [];
        List<(string, int)> finished = [];
        tool.Output += lines.Add;
        tool.Finished += (command, code) => finished.Add((command, code));

        Assert.True(tool.Run("export", "game"));
        Assert.False(tool.Run("build", "game"), "a second run waits for the first");
        Assert.Equal(["cinnabar.exe", "export", "game"], started.Single().Args);
        Assert.Equal("export", Assert.IsType<ProjectTool.Running>(tool.Current).Command);

        started[0].Say("cook: 3 assets cooked");
        started[0].Exit(0);
        Assert.Equal(["cook: 3 assets cooked"], lines);
        Assert.Equal([("export", 0)], finished);
        Assert.IsType<ProjectTool.Idle>(tool.Current);
        Assert.True(started[0].Disposed);

        // A run that the tool stopped says nothing more.
        Assert.True(tool.Run("build", "game"));
        tool.Dispose();
        started[1].Say("late");
        started[1].Exit(1);
        Assert.Single(finished);
        Assert.DoesNotContain("late", lines);
    }

    [Fact]
    public void ANewProjectsFolderIsItsNameAsAFileTakesIt()
    {
        Assert.Equal("My Game 2", NewProjectDialog.FolderName("My Game: 2?"));
        Assert.Equal("Lantern", NewProjectDialog.FolderName(" Lantern. "));
    }

    sealed class FakeTool(IReadOnlyList<string> args) : IChildProcess
    {
        public IReadOnlyList<string> Args => args;
        public bool Disposed { get; private set; }
        public int Id => 1;
        public event Action<string>? Output;
        public event Action<int>? Exited;
        public void Say(string line) => Output?.Invoke(line);
        public void Exit(int code) => Exited?.Invoke(code);
        public void Dispose() => Disposed = true;
    }
}
