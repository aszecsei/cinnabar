using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Content;

/// <summary>What cooks a document's unsaved text for its preview: the cook session, or a fake one in tests.</summary>
public interface IPreviewCooker
{
    /// <summary>Whether a cook can be sent now.</summary>
    bool Linked { get; }

    /// <summary>
    /// Cooks an asset's unsaved text into the cache's preview area, or checks a decision's and plans its plan query, and
    /// completes with the answer.
    /// </summary>
    Task<PreviewResult> CookPreview(string guid, string text, PlanQuery? plan = null);
}

/// <summary>What the cook link has once the daemon sent its index: how to send on it.</summary>
public sealed record CookLink(Action<ILinkMessage, uint> Send) : IChildLink
{
    public static string Child => "cook daemon";

    public static string LinkName => "cook link";

    public static string Waiting => "waiting to start";

    public string Describe() => "watching";
}

/// <summary>
/// How the editor runs the cook daemon: its executable, the loose cache that the game reads, which the daemon writes
/// into as it is, the definition file, the content roots by name, and what it compiles shaders with: DXC and the include
/// directories. Paths are relative to <see cref="WorkingDirectory"/>.
/// </summary>
public sealed record CookOptions(
    string CookPath,
    string CachePath,
    string? DefinitionsPath,
    IReadOnlyList<(string Name, string Dir)> Roots,
    string WorkingDirectory,
    string? DxcPath = null,
    IReadOnlyList<string>? Includes = null);

/// <summary>
/// The cook daemon's lifetime and its cook link (see docs/editor/processes-and-projects.md#processes): start, stop, restart, crashes, and the
/// connection, which fills an <see cref="AssetIndex"/>. Events are raised, and the index changes, on the
/// synchronization context that the session was made on, which is the UI thread in the editor.
/// </summary>
public sealed class CookSession : ChildLinkSession<CookLink>, IPreviewCooker
{
    // The daemon listens soon after it starts.
    static readonly TimeSpan DefaultConnectTimeout = TimeSpan.FromSeconds(30);
    // A daemon that exits sooner than this after it starts, as when another cook holds the cache, is not started
    // again, so the editor does not start it over and over.
    static readonly TimeSpan RestartAfter = TimeSpan.FromSeconds(10);

    readonly CookOptions _options;
    readonly LogQueue<Log> _logs;
    // The operations that wait for the daemon's answer, by request ID.
    readonly PendingReplies<TaskCompletionSource<OperationResult>> _requests;
    readonly PendingReplies<TaskCompletionSource<PreviewResult>> _previews;

    public CookSession(CookOptions options, AssetIndex index) : this(options, index, ChildProcess.Start, DefaultConnectTimeout)
    {
    }

    /// <summary>For tests: starts the daemon with <paramref name="start"/>, and waits <paramref name="connectTimeout"/> for its link.</summary>
    internal CookSession(CookOptions options, AssetIndex index, StartProcess start, TimeSpan connectTimeout)
        : base(new CookState.Stopped(), start, connectTimeout)
    {
        _options = options;
        Index = index;
        _logs = new LogQueue<Log>(LogBacklog, Post, (logs, dropped) => LogsReceived?.Invoke(logs, dropped));
        // Both kinds of request count from one ID. ID 0 is a message that wants no answer.
        var ids = new ReplyIds(skipZero: true);
        _requests = new(ids);
        _previews = new(ids);
    }

    public AssetIndex Index { get; }

    /// <summary>The daemon's last cook since the link came up.</summary>
    public CookFinished? LastCook { get; private set; }

    /// <summary>How far the daemon's pass has got, while it cooks one that takes a while, or null.</summary>
    public CookProgress? Progress { get; private set; }

    /// <summary>The state changed. It is raised once for each change.</summary>
    public event Action? StateChanged;

    /// <summary>
    /// Lines of the daemon's log, over the link, in batches: each batch has the lines that came since the last, and
    /// how many older ones were dropped because more than <see cref="ChildLinkSession{TLink}.LogBacklog"/> waited.
    /// </summary>
    public event Action<IReadOnlyList<Log>, int>? LogsReceived;

    public event Action<CookFinished>? Cooked;

    public event Action? ProgressChanged;

    public void Start()
    {
        // The old daemon goes first, as two daemons of one cache cannot both run.
        Stop();
        if (!File.Exists(Path.Combine(_options.WorkingDirectory, _options.CookPath)))
        {
            Fail($"there is no cook daemon at {_options.CookPath}. Build it with just cook.");
            return;
        }
        Launch(_options.CookPath, Arguments, _options.WorkingDirectory);
    }

    List<string> Arguments(int port)
    {
        List<string> args = ["daemon", "--link", port.ToString(), "--cache", _options.CachePath];
        if (_options.DefinitionsPath != null)
        {
            args.AddRange(["--definitions", _options.DefinitionsPath]);
        }
        if (_options.DxcPath != null)
        {
            args.AddRange(["--dxc", _options.DxcPath]);
        }
        foreach (var include in _options.Includes ?? [])
        {
            args.AddRange(["--include", include]);
        }
        foreach (var (name, dir) in _options.Roots)
        {
            args.AddRange(["--root", $"{name}={dir}"]);
        }
        return args;
    }

    /// <summary>
    /// Asks the daemon for an asset operation (see docs/content/daemon-and-operations.md#asset-operations), and completes with its
    /// answer, which comes after the index's changes. Without the cook link, it fails at once.
    /// </summary>
    public Task<OperationResult> Request(ILinkMessage operation)
    {
        if (State is not CookState.Linked linked)
        {
            return Task.FromResult(new OperationResult("The cook daemon is not running, so the content cannot change.", [], [], []));
        }
        var answer = new TaskCompletionSource<OperationResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var request = _requests.Add(answer);
        linked.Info.Send(operation, request);
        return answer.Task;
    }

    /// <summary>
    /// Asks the daemon to cook a material's unsaved text into the cache's preview area (see
    /// docs/rendering/materials.md#material-previews), and completes with its answer. Without the cook link, it fails at once.
    /// </summary>
    public Task<PreviewResult> CookPreview(string guid, string text, PlanQuery? plan = null)
    {
        if (State is not CookState.Linked linked)
        {
            return Task.FromResult(new PreviewResult("The cook daemon is not running.", [], []));
        }
        var answer = new TaskCompletionSource<PreviewResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var request = _previews.Add(answer);
        linked.Info.Send(new CookPreview(guid, text, plan == null ? [] : [plan]), request);
        return answer.Task;
    }

    protected override MessageReader Read => CookMessages.Read;

    protected override ILinkMessage MakeHello() => new Hello(CookMessages.ProtocolVersion, "cinnabar editor");

    // A cook that logs thousands of lines costs one post a batch.
    protected override bool TakeLog(ILinkMessage message)
    {
        if (message is not Log log)
        {
            return false;
        }
        _logs.Add(log);
        return true;
    }

    protected override void OnMessage(ILinkMessage message, uint request)
    {
        switch (message)
        {
            case Welcome:
                Index.Apply(message);
                break;
            case AssetSnapshot:
                Index.Apply(message);
                // The daemon sends its index after the Welcome. From here the index is the daemon's latest.
                CompleteHandshake(link => new CookLink(link.Send));
                break;
            case Refused refused:
                Refuse(refused.Reason);
                break;
            case Log log:
                LogsReceived?.Invoke([log], 0);
                break;
            case CookProgress progress:
                Progress = progress;
                ProgressChanged?.Invoke();
                break;
            case CookFinished finished:
                LastCook = finished;
                Progress = null;
                Cooked?.Invoke(finished);
                break;
            case OperationResult result:
                if (_requests.TryTake(request, out var answer))
                {
                    answer.SetResult(result);
                }
                break;
            case PreviewResult preview:
                if (_previews.TryTake(request, out var cooked))
                {
                    cooked.SetResult(preview);
                }
                break;
            case Hello:
                Say("editor: the cook daemon sent a message that only the editor sends: Hello");
                break;
            default:
                Index.Apply(message);
                break;
        }
    }

    protected override void OnExitedByItself(TimeSpan uptime)
    {
        if (uptime >= RestartAfter)
        {
            Say("editor: starting the cook daemon again");
            Start();
        }
    }

    // The link's requests and cooks end with it.
    protected override void OnStateChanged(CookState previous)
    {
        if (previous is CookState.Linked)
        {
            FailRequests();
            LastCook = null;
            Progress = null;
        }
        Index.SetLinked(Linked);
        StateChanged?.Invoke();
    }

    // The daemon may have done an operation that it could not answer. Its next snapshot has the content as it is.
    void FailRequests()
    {
        _requests.FailAll(answer => answer.TrySetResult(new OperationResult("The cook link closed before the cook daemon answered.", [], [], [])));
        _previews.FailAll(answer => answer.TrySetResult(new PreviewResult("The cook link closed before the cook daemon answered.", [], [])));
    }
}
