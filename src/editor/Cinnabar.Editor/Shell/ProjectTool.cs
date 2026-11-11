using Cinnabar.Editor.Content;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// Runs <c>cinnabar.exe</c> for the editor (see docs/editor/processes-and-projects.md#projects): <c>new</c>, <c>build</c>
/// and <c>export</c>, one at a time. Its state is one value, <see cref="Idle"/> or <see cref="Running"/>, which only
/// <see cref="Run"/> and the run's end change. Its events are raised on the synchronization context that it was made
/// on, which is the UI thread in the editor.
/// </summary>
public sealed class ProjectTool(string toolPath, string workingDirectory, StartProcess start) : IDisposable
{
    public abstract record State;

    public sealed record Idle : State;

    /// <summary>A run of a command, such as <c>export</c>, and its process.</summary>
    public sealed record Running(string Command, IChildProcess Process) : State;

    readonly SynchronizationContext? _context = SynchronizationContext.Current;

    public State Current { get; private set; } = new Idle();

    public bool IsRunning => Current is Running;

    /// <summary>The tool that this runs.</summary>
    public string ToolPath => toolPath;

    /// <summary>A line of the tool's output.</summary>
    public event Action<string>? Output;

    /// <summary>A run ended: its command and the tool's exit code, which is 0 when it did what it was asked.</summary>
    public event Action<string, int>? Finished;

    /// <summary>
    /// Runs the tool with a command and its arguments. It does nothing and returns false while another run goes on, or
    /// when the tool does not start, which it reports as a line of output.
    /// </summary>
    public bool Run(string command, params string[] args)
    {
        if (Current is Running)
        {
            return false;
        }
        IChildProcess process;
        try
        {
            process = start(toolPath, [command, .. args], workingDirectory);
        }
        catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception or FileNotFoundException)
        {
            Post(() => Output?.Invoke($"cinnabar: cannot start {toolPath}: {e.Message}. Build it with `just engine` in the engine's checkout."));
            return false;
        }
        var running = new Running(command, process);
        Current = running;
        process.Output += line => Post(() =>
        {
            if (Current == running)
            {
                Output?.Invoke(line);
            }
        });
        process.Exited += code => Post(() => End(running, code));
        return true;
    }

    // Only the run that is current ends, once: a disposed tool's late exit changes nothing.
    void End(Running running, int code)
    {
        if (Current != running)
        {
            return;
        }
        Current = new Idle();
        running.Process.Dispose();
        Finished?.Invoke(running.Command, code);
    }

    void Post(Action action)
    {
        if (_context == null)
        {
            action();
        }
        else
        {
            _context.Post(_ => action(), null);
        }
    }

    /// <summary>Stops a run that goes on. Its process exits with the editor's job, and no event follows.</summary>
    public void Dispose()
    {
        if (Current is Running running)
        {
            Current = new Idle();
            running.Process.Dispose();
        }
    }
}
