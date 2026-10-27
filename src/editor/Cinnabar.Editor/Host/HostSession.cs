using System.Net;
using System.Net.Sockets;
using Avalonia.Threading;
using Cinnabar.Editor.Content;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Protocol;

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
/// The host's lifetime and its editor link (see docs/editor/processes-and-projects.md#processes): start, stop, restart, crashes, and the
/// connection to the running host. Events are raised on the UI thread.
/// </summary>
public sealed class HostSession : IDisposable
{
    // The host listens soon after it starts, but loading the game can take a while on a cold disk.
    static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(30);
    static readonly TimeSpan ConnectRetry = TimeSpan.FromMilliseconds(100);

    readonly EditorOptions _options;
    ChildProcess? _process;
    LinkClient? _link;
    CancellationTokenSource? _connecting;
    ulong _adapter;
    int _starts;

    public HostState State { get; private set; } = HostState.Waiting;

    /// <summary>The exit code, when <see cref="State"/> is <see cref="HostState.Exited"/>.</summary>
    public int ExitCode { get; private set; }

    /// <summary>The shared target name that the running host renders under. Each start gets a new one.</summary>
    public string? SharedName { get; private set; }

    /// <summary>True between the host's Welcome and the end of the link.</summary>
    public bool Linked { get; private set; }

    /// <summary>The game that the linked host runs.</summary>
    public string? Game { get; private set; }

    /// <summary>The running host's process id, for the capture sidecar and the automation status.</summary>
    public int? ProcessId => _process?.Id;

    /// <summary>The host can start once the viewport has found the adapter.</summary>
    public bool CanStart => _adapter != 0;

    /// <summary><see cref="State"/> or <see cref="Linked"/> changed.</summary>
    public event Action? StateChanged;

    /// <summary>A line of the host's output that did not come through its logger, or a line about the host from the editor.</summary>
    public event Action<string>? Output;

    /// <summary>A line of the host's or the game's log, over the link.</summary>
    public event Action<Log>? LogReceived;

    public event Action<FrameTarget>? FrameTargetChanged;

    public event Action<ReloadKind>? GameReloaded;

    /// <summary>A message from the game's side of the link, such as the entity list.</summary>
    public event Action<ILinkMessage>? GameMessage;

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
        var port = LinkClient.FreePort();
        ChildProcess process;
        try
        {
            process = ChildProcess.Start(_options.HostPath,
                _options.HostArguments("--shared", name, "--adapter", _adapter.ToString("x16"), "--link", port.ToString()),
                _options.HostDirectory);
        }
        catch (Exception e)
        {
            Output?.Invoke($"editor: cannot start {_options.HostPath}: {e.Message}");
            SetState(HostState.Exited, -1);
            return;
        }
        process.Output += line => Dispatcher.UIThread.Post(() => Output?.Invoke(line));
        process.Exited += code => Dispatcher.UIThread.Post(() => OnExited(process, code));
        _process = process;
        SharedName = name;
        SetState(HostState.Running);
        _connecting = new CancellationTokenSource(ConnectTimeout);
        _ = ConnectAsync(process, port, _connecting.Token);
    }

    public void Stop()
    {
        if (State == HostState.Running)
        {
            StopProcess();
            SetState(HostState.Stopped);
        }
    }

    /// <summary>Sends a message to the host, if it is linked.</summary>
    public void Send(ILinkMessage message)
    {
        if (Linked)
        {
            _link?.Send(message);
        }
    }

    async Task ConnectAsync(ChildProcess process, int port, CancellationToken cancel)
    {
        while (process == _process)
        {
            try
            {
                var link = await LinkClient.ConnectAsync(port, LinkMessages.Read, cancel);
                if (process != _process)
                {
                    await link.DisposeAsync();
                    return;
                }
                _link = link;
                link.Received += (message, _) => Dispatcher.UIThread.Post(() => OnReceived(link, message));
                link.Closed += error => Dispatcher.UIThread.Post(() => OnLinkClosed(link, error));
                link.Start();
                link.Send(new Hello(LinkMessages.ProtocolVersion, "cinnabar editor"));
                return;
            }
            catch (SocketException)
            {
                // The host is not listening yet.
                await Task.Delay(ConnectRetry, CancellationToken.None);
            }
            catch (OperationCanceledException)
            {
                if (process == _process)
                {
                    Output?.Invoke($"editor: the host did not open the editor link on port {port} within {ConnectTimeout.TotalSeconds} s");
                }
                return;
            }
        }
    }

    void OnReceived(LinkClient link, ILinkMessage message)
    {
        if (link != _link)
        {
            return;
        }
        switch (message)
        {
            case Welcome welcome:
                Linked = true;
                Game = welcome.Game;
                Output?.Invoke($"editor: linked to the host, which runs {welcome.Game}");
                StateChanged?.Invoke();
                break;
            case Refused refused:
                Output?.Invoke($"editor: the host refused the editor link: {refused.Reason}");
                _ = link.DisposeAsync();
                break;
            case Log log:
                LogReceived?.Invoke(log);
                break;
            case FrameTarget target:
                FrameTargetChanged?.Invoke(target);
                break;
            case GameReloaded reloaded:
                GameReloaded?.Invoke(reloaded.Kind);
                break;
            case Hello or ViewportSize or FrameAcknowledged or WatchEntity or UnwatchEntity:
                Output?.Invoke($"editor: the host sent a message that only the editor sends: {message.GetType().Name}");
                break;
            default:
                GameMessage?.Invoke(message);
                break;
        }
    }

    void OnLinkClosed(LinkClient link, Exception? error)
    {
        if (link != _link)
        {
            return;
        }
        _link = null;
        if (error != null)
        {
            Output?.Invoke($"editor: the editor link failed: {error.Message}");
        }
        if (Linked)
        {
            Linked = false;
            StateChanged?.Invoke();
        }
    }

    void OnExited(ChildProcess process, int code)
    {
        // A process that the editor stopped or replaced has already been dealt with.
        if (process != _process)
        {
            return;
        }
        StopProcess();
        Output?.Invoke($"editor: the host exited with code {code}");
        SetState(HostState.Exited, code);
    }

    void StopProcess()
    {
        _connecting?.Cancel();
        _connecting = null;
        if (_link != null)
        {
            _ = _link.DisposeAsync();
            _link = null;
        }
        Linked = false;
        Game = null;
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
