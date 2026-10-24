using Avalonia.Threading;

namespace Cinnabar.Editor.Host;

public enum HostState
{
    /// <summary>The viewport has not yet found the adapter that the host must render on.</summary>
    Waiting,
    Running,
    /// <summary>The user stopped the host.</summary>
    Stopped,
    /// <summary>The host exited by itself: it crashed or quit.</summary>
    Exited,
}

/// <summary>
/// The host's lifetime: start, stop, restart, and crashes (see docs/editor.md#processes). Events are raised on the UI
/// thread.
/// </summary>
public sealed class HostSession : IDisposable
{
    readonly EditorOptions _options;
    HostProcess? _process;
    ulong _adapter;
    int _starts;

    public HostState State { get; private set; } = HostState.Waiting;

    /// <summary>The exit code, when <see cref="State"/> is <see cref="HostState.Exited"/>.</summary>
    public int ExitCode { get; private set; }

    /// <summary>The shared target that the running host renders into. Each start gets a new one, so a new host never meets the old host's objects.</summary>
    public string? SharedName { get; private set; }

    /// <summary>The host can start once the viewport has found the adapter.</summary>
    public bool CanStart => _adapter != 0;

    public event Action? StateChanged;

    /// <summary>A line of the host's log, or a line about the host from the editor.</summary>
    public event Action<string>? Output;

    internal HostSession(EditorOptions options) => _options = options;

    /// <summary>Starts the host on the adapter whose LUID the viewport found.</summary>
    public void Start(ulong adapter)
    {
        _adapter = adapter;
        Restart();
    }

    public void Restart()
    {
        if (!CanStart)
        {
            return;
        }
        StopProcess();
        var name = $"cinnabar-editor-{Environment.ProcessId}-{++_starts}";
        try
        {
            var process = HostProcess.Start(_options.HostPath,
                [_options.GamePath, "--shared", name, "--adapter", _adapter.ToString("x16")],
                Environment.CurrentDirectory);
            process.Output += line => Dispatcher.UIThread.Post(() => Output?.Invoke(line));
            process.Exited += code => Dispatcher.UIThread.Post(() => OnExited(process, code));
            _process = process;
        }
        catch (Exception e)
        {
            Output?.Invoke($"editor: cannot start {_options.HostPath}: {e.Message}");
            SetState(HostState.Exited, -1);
            return;
        }
        SharedName = name;
        SetState(HostState.Running);
    }

    public void Stop()
    {
        if (State == HostState.Running)
        {
            StopProcess();
            SetState(HostState.Stopped);
        }
    }

    void OnExited(HostProcess process, int code)
    {
        // A process that the editor stopped or replaced has already been dealt with.
        if (process != _process)
        {
            return;
        }
        _process.Dispose();
        _process = null;
        Output?.Invoke($"editor: the host exited with code {code}");
        SetState(HostState.Exited, code);
    }

    void StopProcess()
    {
        // Closing the job kills the host.
        _process?.Dispose();
        _process = null;
        SharedName = null;
    }

    void SetState(HostState state, int exitCode = 0)
    {
        State = state;
        ExitCode = exitCode;
        StateChanged?.Invoke();
    }

    public void Dispose() => StopProcess();
}
