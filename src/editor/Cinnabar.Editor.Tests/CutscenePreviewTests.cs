using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Shell;
using Asset = Cinnabar.Editor.Link.Cook.Asset;
using Root = Cinnabar.Editor.Link.Cook.Root;
using Welcome = Cinnabar.Editor.Link.Cook.Welcome;

namespace Cinnabar.Editor.Tests;

/// <summary>The cutscene editor's preview session in the game (see docs/editor/cutscene-editor.md#preview).</summary>
public sealed class CutscenePreviewTests : IDisposable
{
    const string Intro = "0123456789abcdef0123456789abcdef";
    const string Fox = "fedcba9876543210fedcba9876543210";
    const string SceneText = "scene 1\n\nentity 0000000000000001\nname = \"Door\"\ncomponent 1 Transform\n\tposition = [0, 0, 0]\n\trotation = [0, 0, 0, 1]\n\tscale = [1, 1, 1]\n";

    readonly TempDirectory _temp = new("cutscene-preview");
    readonly List<ILinkMessage> _sent = [];

    public void Dispose() => _temp.Dispose();

    // A linked shell in Edit with the intro cutscene open, as the first tab. The Open that its tab sent is in _sent.
    (EditorShell Shell, CutsceneEditor Editor) NewShell(bool open = true)
    {
        var shell = TestShell.Open(_temp, "door.scene", SceneText);
        File.WriteAllText(_temp.Combine("intro.cutscene"), CutsceneFileTests.Sample("intro").ReplaceLineEndings("\n"));
        File.WriteAllText(_temp.Combine("fox_walk.cutscene"), CutsceneFileTests.Sample("fox_walk").ReplaceLineEndings("\n"));
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [], [], []));
        shell.Assets.Apply(new AssetSnapshot([Make(Intro, "intro"), Make(Fox, "fox_walk")], []));
        shell.Host.LinkForTests(_sent.Add);
        _sent.Clear();
        return (shell, open ? shell.OpenCutscene(shell.Assets.Find(Intro)!)! : null!);
    }

    static Asset Make(string guid, string name) => TestAssets.Make(guid, AssetKind.Cutscene, name + ".cutscene");

    static void Answer(EditorShell shell, ulong ticket, int start = 0, int end = 720000) =>
        shell.OnGameMessage(new CutscenePreviewOpened(ticket, 0, start, end));

    CutscenePreviewOpen LastOpen => _sent.OfType<CutscenePreviewOpen>().Last();

    // An open session at tick 0, with what was sent so far forgotten.
    ulong Opened(EditorShell shell)
    {
        var ticket = LastOpen.Ticket;
        Answer(shell, ticket);
        _sent.Clear();
        return ticket;
    }

    [Fact]
    public void AnOpenedCutsceneTabSendsOpenWithATicketAndTheGameAnswersIt()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;

        var open = Assert.IsType<CutscenePreviewOpen>(Assert.Single(_sent));
        Assert.Equal(Convert.FromHexString(Intro), open.Cutscene);
        Assert.False(open.Unsaved);
        Assert.Equal(0, open.Tick);
        Assert.Same(editor, shell.CutscenePreview.Owner);
        Assert.Equal(open.Ticket, Assert.IsType<CutscenePreviewState.Opening>(shell.CutscenePreview.State).Ticket);
        Assert.Equal("opening preview…", shell.CutscenePreview.Describe(editor));

        Answer(shell, open.Ticket);

        Assert.IsType<CutscenePreviewState.Open>(shell.CutscenePreview.State);
        Assert.Equal("previewing", shell.CutscenePreview.Describe(editor));
    }

    [Fact]
    public void TheFirstCleanCookOpensASessionThatFollowsTheUnsavedText()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var first = Opened(shell);

        editor.ShowProblems(editor.Document.Text, new PreviewResult("", [], []));

        Assert.Equal(first, Assert.Single(_sent.OfType<CutscenePreviewClose>()).Ticket);
        var open = Assert.Single(_sent.OfType<CutscenePreviewOpen>());
        Assert.True(open.Unsaved);
        Assert.True(open.Ticket > first);
        // A second clean cook changes nothing.
        _sent.Clear();
        editor.ShowProblems(editor.Document.Text, new PreviewResult("", [], []));
        Assert.Empty(_sent);
    }

    [Fact]
    public void ManyScrubsSendOneTimeWithTheLatestTickAtTheFrame()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var ticket = Opened(shell);

        foreach (var tick in new[] { 10000, 20000, 30000, 25000 })
        {
            editor.SetPlayhead(tick);
        }
        Assert.True(shell.CutscenePreview.Pending);
        Assert.Empty(_sent);
        shell.CutscenePreview.Flush();
        shell.CutscenePreview.Flush();

        var time = Assert.Single(_sent.OfType<CutscenePreviewTime>());
        Assert.Equal((ticket, 25000), (time.Ticket, time.Tick));
        Assert.False(shell.CutscenePreview.Pending);
    }

    [Fact]
    public void AScrubBeforeTheGameAnswersIsSentOnceItDoes()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var ticket = LastOpen.Ticket;
        editor.SetPlayhead(30000);

        shell.CutscenePreview.Flush();
        Assert.Empty(_sent.OfType<CutscenePreviewTime>());
        Answer(shell, ticket);
        shell.CutscenePreview.Flush();

        Assert.Equal(30000, Assert.Single(_sent.OfType<CutscenePreviewTime>()).Tick);
    }

    [Fact]
    public void ScrubbingAndPlayingLeaveTheDocumentsCleanAndTheirHistoriesEmpty()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var text = editor.Document.Text;
        var ticket = Opened(shell);

        editor.SetPlayhead(60000);
        shell.CutscenePreview.Flush();
        shell.CutscenePreview.PlayPause();
        shell.OnGameMessage(new CutscenePreviewTick(ticket, 90000, true));
        shell.OnGameMessage(new CutscenePreviewTick(ticket, 120000, false));

        Assert.False(shell.Scene!.IsDirty);
        Assert.Empty(shell.Scene.History);
        Assert.False(editor.Document.IsDirty);
        Assert.Empty(editor.Document.History);
        Assert.Equal(text, editor.Document.Text);
        Assert.Empty(_sent.OfType<ApplyOperations>());
    }

    [Fact]
    public void ALateAnswerForAnEarlierTicketDoesNothing()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var dropped = LastOpen.Ticket;
        shell.CutscenePreview.Take(editor);
        var current = LastOpen.Ticket;
        Assert.True(current > dropped);
        Assert.Equal(dropped, Assert.Single(_sent.OfType<CutscenePreviewClose>()).Ticket);
        var state = shell.CutscenePreview.State;
        editor.SetPlayhead(30000);
        shell.CutscenePreview.Flush();
        _sent.Clear();

        Answer(shell, dropped);
        shell.OnGameMessage(new CutscenePreviewTick(dropped, 50000, true));
        shell.OnGameMessage(new CutscenePreviewEnded(dropped, CutscenePreviewEndReason.Failed));

        Assert.Same(state, shell.CutscenePreview.State);
        Assert.Equal(30000, editor.Playhead);
        Assert.Empty(_sent);

        // The current ticket's answer is not late, and an Ended for an open session closes it and says why.
        Answer(shell, current);
        Assert.IsType<CutscenePreviewState.Open>(shell.CutscenePreview.State);
        shell.OnGameMessage(new CutscenePreviewEnded(current, CutscenePreviewEndReason.Failed));
        Assert.Equal(new CutscenePreviewState.Closed(CutscenePreviewEndReason.Failed), shell.CutscenePreview.State);
        Assert.Same(editor, shell.CutscenePreview.Owner);
        Assert.StartsWith("preview ended: ", shell.CutscenePreview.Describe(editor));
        Assert.Empty(_sent);
    }

    [Theory]
    [InlineData(CutscenePreviewEndReason.SceneLoaded)]
    [InlineData(CutscenePreviewEndReason.CodeReloaded)]
    public void ALoadOrACodeReloadOpensTheSessionAgainPlayingIfItPlayed(CutscenePreviewEndReason reason)
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var ticket = Opened(shell);
        shell.CutscenePreview.PlayPause();
        shell.OnGameMessage(new CutscenePreviewTick(ticket, 42000, true));
        _sent.Clear();

        shell.OnGameMessage(new CutscenePreviewEnded(ticket, reason));

        var open = Assert.IsType<CutscenePreviewOpen>(Assert.Single(_sent));
        Assert.True(open.Ticket > ticket);
        Assert.Equal(42000, open.Tick);
        _sent.Clear();
        Answer(shell, open.Ticket);
        var play = Assert.IsType<CutscenePreviewPlay>(Assert.Single(_sent));
        Assert.Equal(42000, play.Tick);
    }

    [Fact]
    public void ASecondTabDoesNotTakeThePreviewUntilItsButtonDoes()
    {
        var (shell, first) = NewShell();
        using var _ = shell;
        var firstTicket = Opened(shell);

        var second = shell.OpenCutscene(shell.Assets.Find(Fox)!)!;

        Assert.Same(second, shell.ActiveCutscene);
        Assert.Same(first, shell.CutscenePreview.Owner);
        Assert.Empty(_sent);
        Assert.Equal("preview inactive", shell.CutscenePreview.Describe(second));
        Assert.True(shell.CutscenePreview.CanTake(second));
        Assert.False(shell.CutscenePreview.CanTake(first));
        // Its scrubs go nowhere.
        second.SetPlayhead(30000);
        shell.CutscenePreview.Flush();
        Assert.Empty(_sent);

        shell.CutscenePreview.Take(second);

        Assert.Equal(firstTicket, Assert.Single(_sent.OfType<CutscenePreviewClose>()).Ticket);
        var open = Assert.Single(_sent.OfType<CutscenePreviewOpen>());
        Assert.Equal(Convert.FromHexString(Fox), open.Cutscene);
        Assert.Equal(30000, open.Tick);
        Assert.True(open.Ticket > firstTicket);
        Assert.Same(second, shell.CutscenePreview.Owner);
        Assert.Equal("preview inactive", shell.CutscenePreview.Describe(first));
    }

    [Fact]
    public void ClosingTheTabClosesTheSessionAndFreesThePreview()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var ticket = Opened(shell);

        shell.CloseGraph(editor, discard: true);

        Assert.Equal(ticket, Assert.Single(_sent.OfType<CutscenePreviewClose>()).Ticket);
        Assert.Null(shell.CutscenePreview.Owner);
        Assert.IsType<CutscenePreviewState.Closed>(shell.CutscenePreview.State);
    }

    [Fact]
    public void PlayEndsTheSessionWithoutSendingAndStopOpensItAgain()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var ticket = Opened(shell);
        editor.SetPlayhead(30000);

        shell.Play();

        Assert.Equal(new CutscenePreviewState.Closed(), shell.CutscenePreview.State);
        Assert.Empty(_sent.OfType<CutscenePreviewClose>());
        Assert.Same(editor, shell.CutscenePreview.Owner);
        Assert.Equal("no preview in Play", shell.CutscenePreview.Describe(editor));
        // The game's late word about the old session changes nothing.
        shell.OnGameMessage(new CutscenePreviewEnded(ticket, CutscenePreviewEndReason.Mode));
        Assert.Equal(new CutscenePreviewState.Closed(), shell.CutscenePreview.State);

        _sent.Clear();
        shell.Stop();

        var open = Assert.Single(_sent.OfType<CutscenePreviewOpen>());
        Assert.True(open.Ticket > ticket);
        Assert.Equal(30000, open.Tick);
    }

    [Fact]
    public void ALostLinkEndsTheSessionWithoutSendingAndAnotherOpensItAgain()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var ticket = Opened(shell);

        shell.Host.Stop();

        Assert.Equal(new CutscenePreviewState.Closed(), shell.CutscenePreview.State);
        Assert.Empty(_sent);
        Assert.Equal("no game", shell.CutscenePreview.Describe(editor));

        shell.Host.LinkForTests(_sent.Add);

        Assert.True(Assert.Single(_sent.OfType<CutscenePreviewOpen>()).Ticket > ticket);
    }

    [Fact]
    public void ASoftRestartOpensTheSessionAgainAtTheSameTick()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var ticket = Opened(shell);
        editor.SetPlayhead(30000);
        shell.CutscenePreview.Flush();
        _sent.Clear();

        shell.Host.Receive(new GameReloaded(ReloadKind.SoftRestart));

        var open = Assert.Single(_sent.OfType<CutscenePreviewOpen>());
        Assert.True(open.Ticket > ticket);
        Assert.Equal(30000, open.Tick);
        // The new state had no session to close.
        Assert.Empty(_sent.OfType<CutscenePreviewClose>());
        Assert.Empty(_sent.OfType<CutscenePreviewPlay>());
    }

    [Fact]
    public void ASoftRestartDuringPlaybackPlaysAgainFromTheLastReportedTick()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var ticket = Opened(shell);
        shell.CutscenePreview.PlayPause();
        shell.OnGameMessage(new CutscenePreviewTick(ticket, 90000, true));
        _sent.Clear();

        shell.Host.Receive(new GameReloaded(ReloadKind.SoftRestart));

        var open = Assert.Single(_sent.OfType<CutscenePreviewOpen>());
        Assert.Equal(90000, open.Tick);
        Assert.Empty(_sent.OfType<CutscenePreviewPlay>());
        Answer(shell, open.Ticket);
        var play = Assert.Single(_sent.OfType<CutscenePreviewPlay>());
        Assert.Equal((open.Ticket, 90000, 1f, false), (play.Ticket, play.Tick, play.Rate, play.Looping));
        Assert.Equal("playing", shell.CutscenePreview.Describe(editor));
    }

    [Fact]
    public void PlayingStartsTheGamesClockAndPausingGivesItBackTheTick()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var ticket = Opened(shell);
        editor.SetPlayhead(30000);
        shell.CutscenePreview.Flush();
        _sent.Clear();

        shell.CutscenePreview.PlayPause();

        var play = Assert.Single(_sent.OfType<CutscenePreviewPlay>());
        Assert.Equal((ticket, 30000, 1f, false, 0, 0), (play.Ticket, play.Tick, play.Rate, play.Looping, play.LoopStart, play.LoopEnd));
        Assert.True(shell.CutscenePreview.IsPlayingIn(editor));
        _sent.Clear();

        shell.OnGameMessage(new CutscenePreviewTick(ticket, 54000, true));
        Assert.Equal(54000, editor.Playhead);
        shell.CutscenePreview.Flush();
        // A tick from the game is not a scrub.
        Assert.Empty(_sent);

        shell.CutscenePreview.PlayPause();
        var time = Assert.Single(_sent.OfType<CutscenePreviewTime>());
        Assert.Equal((ticket, 54000), (time.Ticket, time.Tick));
        Assert.False(shell.CutscenePreview.IsPlayingIn(editor));
    }

    [Fact]
    public void ThePlayheadAtTheEndStartsFromTheRangesStartAndTheLastTickPauses()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var ticket = LastOpen.Ticket;
        Answer(shell, ticket, 30000, 600000);
        editor.SetPlayhead(600000);
        shell.CutscenePreview.Flush();
        _sent.Clear();

        shell.CutscenePreview.PlayPause();

        Assert.Equal(30000, Assert.Single(_sent.OfType<CutscenePreviewPlay>()).Tick);
        Assert.Equal(30000, editor.Playhead);
        shell.OnGameMessage(new CutscenePreviewTick(ticket, 600000, false));
        Assert.False(shell.CutscenePreview.IsPlayingIn(editor));
        Assert.Equal(600000, editor.Playhead);
    }

    [Fact]
    public void AScrubWhilePlayingPausesAndAnEarlyTickDoesNotMoveThePlayheadBack()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var ticket = Opened(shell);
        shell.CutscenePreview.PlayPause();

        editor.SetPlayhead(120000);
        shell.OnGameMessage(new CutscenePreviewTick(ticket, 54000, true));
        shell.CutscenePreview.Flush();

        Assert.False(shell.CutscenePreview.IsPlayingIn(editor));
        Assert.Equal(120000, editor.Playhead);
        Assert.Equal(120000, Assert.Single(_sent.OfType<CutscenePreviewTime>()).Tick);
    }

    [Fact]
    public void TheSpaceAndStepCommandsActOnlyWhileTheTimelineHasTheKeyboard()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var ticket = Opened(shell);
        var frame = editor.FrameTicks;
        Assert.False(shell.Commands.Get(EditorCommands.CutscenePlayPause).CanExecute);
        Assert.False(shell.Commands.Get(EditorCommands.CutsceneStepForward).CanExecute);
        editor.TimelineFocused = true;

        shell.Commands.Get(EditorCommands.CutsceneStepForward).Execute();
        Assert.Equal(frame, editor.Playhead);
        shell.Commands.Get(EditorCommands.CutsceneStepForward10).Execute();
        Assert.Equal(11 * frame, editor.Playhead);
        shell.Commands.Get(EditorCommands.CutsceneStepBack).Execute();
        shell.Commands.Get(EditorCommands.CutsceneStepBack10).Execute();
        Assert.Equal(0, editor.Playhead);
        // Back at the start, a step is clamped.
        shell.Commands.Get(EditorCommands.CutsceneStepBack).Execute();
        Assert.Equal(0, editor.Playhead);

        shell.CutscenePreview.Flush();
        _sent.Clear();
        shell.Commands.Get(EditorCommands.CutscenePlayPause).Execute();
        Assert.Single(_sent.OfType<CutscenePreviewPlay>());
        Assert.True(shell.Commands.Get(EditorCommands.CutscenePlayPause).IsChecked);

        // A step during playback pauses it at the tick that the game last reported, even when the step goes nowhere.
        shell.OnGameMessage(new CutscenePreviewTick(ticket, 0, true));
        _sent.Clear();
        shell.Commands.Get(EditorCommands.CutsceneStepBack).Execute();
        Assert.Equal((ticket, 0), (Assert.Single(_sent.OfType<CutscenePreviewTime>()).Ticket, 0));
        Assert.False(shell.Commands.Get(EditorCommands.CutscenePlayPause).IsChecked);

        Assert.Empty(shell.KeyBindings.Warnings);
        Assert.Equal("Space", shell.KeyBindings.ShortcutOf(EditorCommands.CutscenePlayPause));
        Assert.Equal("Shift+Right", shell.KeyBindings.ShortcutOf(EditorCommands.CutsceneStepForward10));
    }

    [Fact]
    public void NothingIsSentWithoutAGameOrOutsideEdit()
    {
        var (shell, editor) = NewShell(open: false);
        using var _ = shell;
        shell.Host.Stop();
        _sent.Clear();

        editor = shell.OpenCutscene(shell.Assets.Find(Intro)!)!;
        editor.SetPlayhead(30000);
        shell.CutscenePreview.Flush();
        shell.CutscenePreview.PlayPause();

        Assert.Empty(_sent);
        Assert.Same(editor, shell.CutscenePreview.Owner);
        Assert.False(shell.CutscenePreview.CanTake(editor));
    }
}
