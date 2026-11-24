using Cinnabar.Editor.Content;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Host;

/// <summary>What the editor link has once the host sent its Welcome: the game that it runs, and how to send on the link.</summary>
public sealed record HostLink(string Game, Action<ILinkMessage> Send) : IChildLink
{
    public static string Child => "host";

    public static string LinkName => "editor link";

    public static string Waiting => "waiting for the viewport";

    public string Describe() => $"running {Game}, linked";
}

/// <summary>
/// The host's lifetime and its editor link (see docs/editor/processes-and-projects.md#processes): start, stop, restart, crashes, and the
/// connection to the running host. Events are raised on the synchronization context that the session was made on,
/// which is the UI thread in the editor.
/// </summary>
public sealed class HostSession : ChildLinkSession<HostLink>
{
    // The host listens soon after it starts, but loading the game can take a while on a cold disk.
    static readonly TimeSpan DefaultConnectTimeout = TimeSpan.FromSeconds(30);

    readonly EditorOptions _options;
    readonly LogQueue<Log> _logs;
    ulong _adapter;
    int _starts;

    internal HostSession(EditorOptions options) : this(options, ChildProcess.Start, DefaultConnectTimeout)
    {
    }

    /// <summary>For tests: starts the host with <paramref name="start"/>, and waits <paramref name="connectTimeout"/> for its link.</summary>
    internal HostSession(EditorOptions options, StartProcess start, TimeSpan connectTimeout)
        : base(new HostState.Waiting(), start, connectTimeout)
    {
        _options = options;
        _logs = new LogQueue<Log>(LogBacklog, Post, (logs, dropped) => LogsReceived?.Invoke(logs, dropped));
    }

    /// <summary>The game that the linked host runs.</summary>
    public string? Game => (State as HostState.Linked)?.Info.Game;

    /// <summary>The shared target name that the running host renders under. Each start gets a new one.</summary>
    public string? SharedName => RunName;

    /// <summary>The host can start once a viewport has found the adapter.</summary>
    public bool CanStart => _adapter != 0;

    /// <summary>The LUID of the adapter that the host renders on, or 0 before a viewport found it.</summary>
    public ulong Adapter => _adapter;

    /// <summary>The state changed, from the state that it gives. It is raised once for each change.</summary>
    public event Action<HostState>? StateChanged;

    /// <summary>
    /// Lines of the host's or the game's log, over the link, in batches: each batch has the lines that came since the last, and
    /// how many older ones were dropped because more than <see cref="ChildLinkSession{TLink}.LogBacklog"/> waited.
    /// </summary>
    public event Action<IReadOnlyList<Log>, int>? LogsReceived;

    public event Action<ReloadKind>? GameReloaded;

    /// <summary>A message from the game's side of the link, such as the entity list.</summary>
    public event Action<ILinkMessage>? GameMessage;

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
        Stop();
        var name = $"cinnabar-editor-{Environment.ProcessId}-{++_starts}";
        Launch(_options.HostPath,
            port => _options.HostArguments("--shared", name, "--adapter", _adapter.ToString("x16"), "--link", port.ToString()),
            _options.HostDirectory, name);
    }

    /// <summary>Sends a message to the host, if it is linked.</summary>
    public void Send(ILinkMessage message)
    {
        if (State is HostState.Linked linked)
        {
            linked.Info.Send(message);
        }
    }

    /// <summary>For tests: links to no host, as a <c>Welcome</c> does, and gives what the editor sends to <paramref name="send"/>.</summary>
    internal void LinkForTests(Action<ILinkMessage> send) => LinkWithoutChild(new HostLink("test", send));

    protected override MessageReader Read => LinkMessages.Read;

    protected override ILinkMessage MakeHello() => new Hello(LinkMessages.ProtocolVersion, "cinnabar editor");

    // A game that logs on each frame costs one post a batch.
    protected override bool TakeLog(ILinkMessage message)
    {
        if (message is not Log log)
        {
            return false;
        }
        _logs.Add(log);
        return true;
    }

    protected override void OnMessage(ILinkMessage message, uint request) => Receive(message);

    /// <summary>Handles a message from the linked host. Tests call it in place of the link.</summary>
    internal void Receive(ILinkMessage message)
    {
        switch (message)
        {
            case Welcome welcome:
                if (State is HostState.Handshaking)
                {
                    Say($"editor: linked to the host, which runs {welcome.Game}");
                    CompleteHandshake(link => new HostLink(welcome.Game, m => link.Send(m)));
                }
                break;
            case Refused refused:
                Refuse(refused.Reason);
                break;
            case Log log:
                LogsReceived?.Invoke([log], 0);
                break;
            case GameReloaded reloaded:
                GameReloaded?.Invoke(reloaded.Kind);
                break;
            case Hello or GameSize or OpenViewport or CloseViewport or ViewportAcknowledged or WatchEntity or UnwatchEntity:
                Say($"editor: the host sent a message that only the editor sends: {message.GetType().Name}");
                break;
            default:
                GameMessage?.Invoke(message);
                break;
        }
    }

    protected override void OnStateChanged(HostState previous) => StateChanged?.Invoke(previous);
}
