using CutscenePreviewClose = Cinnabar.Editor.Link.Protocol.CutscenePreviewClose;
using CutscenePreviewEndReason = Cinnabar.Editor.Link.Protocol.CutscenePreviewEndReason;
using CutscenePreviewEnded = Cinnabar.Editor.Link.Protocol.CutscenePreviewEnded;
using CutscenePreviewOpen = Cinnabar.Editor.Link.Protocol.CutscenePreviewOpen;
using CutscenePreviewOpened = Cinnabar.Editor.Link.Protocol.CutscenePreviewOpened;
using CutscenePreviewPlay = Cinnabar.Editor.Link.Protocol.CutscenePreviewPlay;
using CutscenePreviewTick = Cinnabar.Editor.Link.Protocol.CutscenePreviewTick;
using CutscenePreviewTime = Cinnabar.Editor.Link.Protocol.CutscenePreviewTime;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// Where the cutscene preview is. Each state carries what belongs to it: a session its ticket and the tab that holds it.
/// Only <see cref="CutscenePreview"/> makes them.
/// </summary>
public abstract record CutscenePreviewState
{
    private protected CutscenePreviewState()
    {
    }

    /// <summary>
    /// No session. The reason is why the game ended the last one, or null when the editor did or there was none. With
    /// <paramref name="Resume"/>, the last one played when the link or the game state went, so the next one plays.
    /// </summary>
    public sealed record Closed(CutscenePreviewEndReason? Reason = null, bool Resume = false) : CutscenePreviewState;

    /// <summary>A session, which the game has not yet answered.</summary>
    public abstract record Live(ulong Ticket, CutsceneEditor Editor, bool Unsaved) : CutscenePreviewState;

    /// <summary>
    /// The editor sent Open and waits for Opened. With <paramref name="Resume"/>, the session replaces one that was
    /// playing, so it plays again when the game answers.
    /// </summary>
    public sealed record Opening(ulong Ticket, CutsceneEditor Editor, bool Unsaved, bool Resume) : Live(Ticket, Editor, Unsaved);

    /// <summary>The game holds the session, with the cutscene's range in ticks, and the clock is the game's while it plays.</summary>
    public sealed record Open(ulong Ticket, CutsceneEditor Editor, bool Unsaved, int RangeStart, int RangeEnd, bool Playing) : Live(Ticket, Editor, Unsaved);
}

/// <summary>
/// The cutscene preview in the game (see docs/editor/cutscene-editor.md#preview): one session at a time, for the tab
/// that <see cref="Owner"/> names. The game evaluates the cutscene and the editor only sends the time, so nothing here
/// touches a document. <see cref="Become"/> is the one place that <see cref="State"/> changes. Tickets only go up, even
/// across game states, so the game drops a late message, and the editor drops an answer to a ticket that is not the
/// session's.
/// </summary>
public sealed class CutscenePreview(EditorShell shell)
{
    // The last ticket given.
    ulong _last;

    // The latest tick of a scrub that Flush has not sent.
    int? _pending;

    public CutscenePreviewState State { get; private set; } = new CutscenePreviewState.Closed();

    /// <summary>
    /// The tab that holds the preview, or null for none. It changes only when that tab closes or another takes the
    /// preview, so it outlives a session: a new game state or Stop opens a session for it again.
    /// </summary>
    public CutsceneEditor? Owner { get; private set; }

    /// <summary>Whether a scrub is waiting for <see cref="Flush"/>.</summary>
    public bool Pending => _pending != null;

    /// <summary>The state, the owner or the pending scrub changed.</summary>
    public event Action? Changed;

    bool CanSend => shell.Host.Linked && shell.IsEditing;

    static bool Allowed(CutscenePreviewState from, CutscenePreviewState to) => (from, to) switch
    {
        (CutscenePreviewState.Closed, CutscenePreviewState.Opening) => true,
        (CutscenePreviewState.Opening o, CutscenePreviewState.Opening n) => o.Ticket == n.Ticket,
        (CutscenePreviewState.Opening o, CutscenePreviewState.Open n) => o.Ticket == n.Ticket,
        (CutscenePreviewState.Open o, CutscenePreviewState.Open n) => o.Ticket == n.Ticket,
        (CutscenePreviewState.Live, CutscenePreviewState.Closed) => true,
        _ => false,
    };

    void Become(CutscenePreviewState next)
    {
        var previous = State;
        if (!Allowed(previous, next))
        {
            throw new InvalidOperationException($"the cutscene preview cannot go from {previous.GetType().Name} to {next.GetType().Name}");
        }
        State = next;
        if (next is CutscenePreviewState.Closed || (next is CutscenePreviewState.Opening && previous is not CutscenePreviewState.Opening))
        {
            // A new Open names the playhead, and a closed session has no game to send to.
            _pending = null;
        }
        Changed?.Invoke();
        shell.Commands.InvalidateAll();
    }

    /// <summary>Takes the preview for a tab, and ends the session of another. Without a game in Edit, the tab holds it until there is one.</summary>
    public void Take(CutsceneEditor editor)
    {
        Owner = editor;
        Start(editor, resume: false);
    }

    // Ends the session, which tells the game, and opens one for the editor at its playhead.
    void Start(CutsceneEditor editor, bool resume)
    {
        Shut(send: true, null);
        if (!CanSend)
        {
            Changed?.Invoke();
            return;
        }
        var unsaved = editor.CookedClean;
        var ticket = ++_last;
        Become(new CutscenePreviewState.Opening(ticket, editor, unsaved, resume));
        shell.Host.Send(new CutscenePreviewOpen(ticket, Convert.FromHexString(editor.Guid), unsaved, editor.Playhead));
    }

    void Shut(bool send, CutscenePreviewEndReason? reason, bool resume = false)
    {
        if (State is not CutscenePreviewState.Live live)
        {
            return;
        }
        if (send && shell.Host.Linked)
        {
            shell.Host.Send(new CutscenePreviewClose(live.Ticket));
        }
        Become(new CutscenePreviewState.Closed(reason, resume));
    }

    // A session for the owner, or for the active cutscene tab when there is no owner. The game's state has none.
    void Reopen(bool resume)
    {
        if ((Owner ?? shell.ActiveCutscene) is { } editor)
        {
            Owner = editor;
            Start(editor, resume);
        }
    }

    static bool IsPlaying(CutscenePreviewState state) =>
        state is CutscenePreviewState.Open { Playing: true } or CutscenePreviewState.Opening { Resume: true } or CutscenePreviewState.Closed { Resume: true };

    /// <summary>A cutscene tab became the active one. It takes the preview when no session is live.</summary>
    internal void OnActivated(CutsceneEditor? editor)
    {
        if (editor != null && State is CutscenePreviewState.Closed)
        {
            Take(editor);
        }
    }

    /// <summary>A cutscene tab closed. Its session ends, and nobody holds the preview.</summary>
    internal void OnTabClosed(CutsceneEditor editor)
    {
        if (Owner != editor)
        {
            return;
        }
        Shut(send: true, null);
        Owner = null;
        Changed?.Invoke();
    }

    /// <summary>Play began. The game ends its session when the mode changes.</summary>
    internal void OnPlay() => Shut(send: false, null);

    /// <summary>The link closed, and the game ended its session. One that played plays again in the next.</summary>
    internal void OnLinkLost() => Shut(send: false, null, IsPlaying(State));

    /// <summary>
    /// The game has a new state, which has no session. The scene's send opens one again (see <see cref="OnSceneSent"/>):
    /// a session that played opens at the tab's playhead, which is the game's last reported tick, and plays again when
    /// the game answers Opened.
    /// </summary>
    internal void OnNewGameState()
    {
        if (State is CutscenePreviewState.Live live)
        {
            Shut(send: false, null, IsPlaying(live));
        }
    }

    /// <summary>
    /// The editor sent its scene, which the game mirrors in Edit: after Stop, in a new game state, or when a scene opens.
    /// A closed session opens again for the owner, so one that the game could not open without a scene opens now.
    /// </summary>
    internal void OnSceneSent()
    {
        if (State is CutscenePreviewState.Closed closed && shell.IsEditing)
        {
            Reopen(closed.Resume);
        }
    }

    /// <summary>A tab's text cooked clean for the first time, so the game follows the preview area and not the saved file.</summary>
    internal void OnCooked(CutsceneEditor editor)
    {
        if (State is CutscenePreviewState.Live { Unsaved: false } live && live.Editor == editor)
        {
            Start(editor, IsPlaying(live));
        }
    }

    /// <summary>The playhead of a tab moved by the editor: the preview shows it at the next <see cref="Flush"/>, and pauses.</summary>
    internal void OnScrub(CutsceneEditor editor)
    {
        if (State is not CutscenePreviewState.Live live || live.Editor != editor)
        {
            return;
        }
        _pending = editor.Playhead;
        switch (live)
        {
            case CutscenePreviewState.Open { Playing: true } open:
                Become(open with { Playing = false });
                break;
            case CutscenePreviewState.Opening { Resume: true } opening:
                Become(opening with { Resume = false });
                break;
            default:
                Changed?.Invoke();
                break;
        }
    }

    /// <summary>Sends the latest scrubbed tick, once, and nothing when there is none or no session is open. The view calls it once a frame.</summary>
    public void Flush()
    {
        if (_pending is { } tick && State is CutscenePreviewState.Open open)
        {
            _pending = null;
            shell.Host.Send(new CutscenePreviewTime(open.Ticket, tick));
        }
    }

    /// <summary>Whether the tab can play or pause: its session is open.</summary>
    public bool CanPlay(CutsceneEditor editor) => State is CutscenePreviewState.Open open && open.Editor == editor;

    public bool IsPlayingIn(CutsceneEditor editor) => State is CutscenePreviewState.Open { Playing: true } open && open.Editor == editor;

    /// <summary>Starts the game's clock at the playhead, or from the range's start at its end, or pauses it where it is.</summary>
    public void PlayPause()
    {
        if (State is not CutscenePreviewState.Open open)
        {
            return;
        }
        if (open.Playing)
        {
            Pause();
            return;
        }
        _pending = null;
        var tick = open.Editor.Playhead >= open.RangeEnd ? open.RangeStart : open.Editor.Playhead;
        open.Editor.SetPlayheadFromGame(tick);
        shell.Host.Send(new CutscenePreviewPlay(open.Ticket, tick, 1f, false, 0, 0));
        Become(open with { Playing = true });
    }

    /// <summary>Pauses the game's clock at the playhead, which is the last tick that the game reported.</summary>
    internal void Pause()
    {
        switch (State)
        {
            case CutscenePreviewState.Open { Playing: true } open:
                _pending = null;
                shell.Host.Send(new CutscenePreviewTime(open.Ticket, open.Editor.Playhead));
                Become(open with { Playing = false });
                break;
            case CutscenePreviewState.Opening { Resume: true } opening:
                // The session that replaces a playing one opens paused.
                Become(opening with { Resume = false });
                break;
        }
    }

    /// <summary>The game opened the session.</summary>
    internal void OnOpened(CutscenePreviewOpened opened)
    {
        if (State is not CutscenePreviewState.Opening opening || opening.Ticket != opened.Ticket)
        {
            return;
        }
        Become(new CutscenePreviewState.Open(opening.Ticket, opening.Editor, opening.Unsaved, opened.RangeStart, opened.RangeEnd, false));
        if (opening.Resume)
        {
            PlayPause();
        }
    }

    /// <summary>
    /// The game ended the session, or did not start it. The tab keeps the preview, and its view says why. A load of the
    /// scene or a code reload ends it under the editor, which opens it again at once, playing if it played.
    /// </summary>
    internal void OnEnded(CutscenePreviewEnded ended)
    {
        if (State is not CutscenePreviewState.Live live || live.Ticket != ended.Ticket)
        {
            return;
        }
        var resume = IsPlaying(live);
        Become(new CutscenePreviewState.Closed(ended.Reason));
        if (ended.Reason is CutscenePreviewEndReason.SceneLoaded or CutscenePreviewEndReason.CodeReloaded && Owner is { } owner)
        {
            Start(owner, resume);
        }
    }

    /// <summary>The game's tick while it plays, and once when it stops. It moves the playhead and sends nothing back.</summary>
    internal void OnTick(CutscenePreviewTick tick)
    {
        if (State is not CutscenePreviewState.Open { Playing: true } open || open.Ticket != tick.Ticket)
        {
            return;
        }
        open.Editor.SetPlayheadFromGame(tick.Tick);
        if (!tick.Playing)
        {
            Become(open with { Playing = false });
        }
    }

    /// <summary>Whether the tab can take the preview from where it is, which the tab's button does.</summary>
    public bool CanTake(CutsceneEditor editor) => CanSend && !(Owner == editor && State is CutscenePreviewState.Live);

    /// <summary>What the tab's view says about the preview.</summary>
    public string Describe(CutsceneEditor editor)
    {
        if (!shell.Host.Linked)
        {
            return "no game";
        }
        if (!shell.IsEditing)
        {
            return "no preview in Play";
        }
        if (Owner != editor)
        {
            return "preview inactive";
        }
        return State switch
        {
            CutscenePreviewState.Opening => "opening preview…",
            CutscenePreviewState.Open { Playing: true } => "playing",
            CutscenePreviewState.Open => "previewing",
            CutscenePreviewState.Closed { Reason: { } reason } => $"preview ended: {Why(reason)}",
            _ => "no preview",
        };
    }

    static string Why(CutscenePreviewEndReason reason) => reason switch
    {
        CutscenePreviewEndReason.NotEditing => "the game is not in Edit",
        CutscenePreviewEndReason.Failed => "the game could not load the cutscene",
        CutscenePreviewEndReason.Mode => "the mode changed",
        CutscenePreviewEndReason.SceneLoaded => "the scene loaded",
        CutscenePreviewEndReason.CodeReloaded => "the code reloaded",
        _ => throw new ArgumentOutOfRangeException(nameof(reason), reason, "an end that the editor does not know"),
    };
}
