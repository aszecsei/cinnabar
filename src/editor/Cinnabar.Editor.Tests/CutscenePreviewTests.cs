using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Cutscenes;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
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

    // What an Open sends: the Open, then the mix of its ticket and the sub-sequences whose unsaved text it plays, none.
    CutscenePreviewOpen OpenWithSettings()
    {
        Assert.Equal(3, _sent.Count);
        var open = Assert.IsType<CutscenePreviewOpen>(_sent[0]);
        Assert.Equal(open.Ticket, Assert.IsType<CutscenePreviewSettings>(_sent[1]).Ticket);
        var children = Assert.IsType<CutscenePreviewChildren>(_sent[2]);
        Assert.Equal(open.Ticket, children.Ticket);
        Assert.Empty(children.Unsaved);
        return open;
    }

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

        var open = OpenWithSettings();
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

        editor.Checks.Show(editor.Document.Text, new PreviewResult("", [], []));

        Assert.Equal(first, Assert.Single(_sent.OfType<CutscenePreviewClose>()).Ticket);
        var open = Assert.Single(_sent.OfType<CutscenePreviewOpen>());
        Assert.True(open.Unsaved);
        Assert.True(open.Ticket > first);
        // A second clean cook changes nothing.
        _sent.Clear();
        editor.Checks.Show(editor.Document.Text, new PreviewResult("", [], []));
        Assert.Empty(_sent);
    }

    // A sub-sequence shown in context plays its unsaved text in the parent's preview once it cooks clean (see
    // docs/editor/cutscene-editor.md#sub-sequences).
    [Fact]
    public void AChildInContextThatCookedCleanGoesToTheGameAsUnsaved()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var ticket = Opened(shell);
        // The intro's shot plays the sample's fox walk by its own GUID.
        const string walk = "497bcb7bb533b902877cd8d56fbf97cd";
        shell.Assets.Apply(new AssetSnapshot([Make(Intro, "intro"), Make(walk, "fox_walk")], []));
        _sent.Clear();

        Assert.True(editor.OpenSubSequence("section:4"));
        Assert.Empty(Assert.Single(_sent.OfType<CutscenePreviewChildren>(), c => c.Ticket == ticket).Unsaved);
        // The preview stays the parent's.
        Assert.Empty(_sent.OfType<CutscenePreviewOpen>());
        _sent.Clear();

        editor.ShownChecks.Show(editor.Document.Text, new PreviewResult("", [], []));
        var children = Assert.Single(_sent.OfType<CutscenePreviewChildren>());
        Assert.Equal(ticket, children.Ticket);
        Assert.Equal(Convert.FromHexString(walk), Assert.Single(children.Unsaved));
        // Going up lets the child go, since it has no changes, and the game plays none.
        _sent.Clear();
        editor.UpOneLevel();
        Assert.Empty(Assert.Single(_sent.OfType<CutscenePreviewChildren>()).Unsaved);
    }

    [Fact]
    public void ANewCookLinkOpensTheSessionAgainOnTheSavedFile()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        Opened(shell);
        editor.Checks.Show(editor.Document.Text, new PreviewResult("", [], []));
        _sent.Clear();

        // The new daemon starts with an empty preview area, so the session follows the saved file until the text cooks.
        editor.Checks.Restart();

        Assert.False(editor.CookedClean);
        Assert.False(Assert.Single(_sent.OfType<CutscenePreviewOpen>()).Unsaved);
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
    public void AFiredEventFlashesItsKeyAndGoesInTheConsoleWithoutTouchingTheDocument()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var now = TimeSpan.FromSeconds(1);
        editor.Flashes.Clock = () => now;
        var text = editor.Document.Text;
        var ticket = Opened(shell);
        var trigger = CutsceneFile.PathOf(editor.File.Blocks.Single(b => b.Kind == CutsceneBlockKind.Trigger && b.Id == 1));
        var range = CutsceneFile.PathOf(editor.File.Blocks.Single(b => b.Kind == CutsceneBlockKind.Range && b.Id == 2));
        var flashed = 0;
        editor.Flashed += () => flashed++;
        shell.CutscenePreview.PlayPause();
        _sent.Clear();

        shell.OnGameMessage(new CutscenePreviewFired(ticket, 360000, 2, CutscenePreviewFiredKind.Begin, "guard_bark_begin", false));
        // The play stops at the end in the frame that sends intro_seen, so the stop comes first.
        shell.OnGameMessage(new CutscenePreviewTick(ticket, 600000, false));
        shell.OnGameMessage(new CutscenePreviewFired(ticket, 600000, 1, CutscenePreviewFiredKind.Trigger, "intro_seen", false));

        Assert.Equal(2, flashed);
        Assert.Equal(1, editor.Flashes.Strength(range));
        Assert.Equal(1, editor.Flashes.Strength(trigger));
        Assert.Contains(shell.Console.Lines, l => l.Text == "cutscene: guard_bark_begin at 00:06:00 on \"Story\"");
        Assert.Contains(shell.Console.Lines, l => l.Text == "cutscene: intro_seen at 00:10:00 on \"Story\"");
        now += CutsceneEventFlashes.Length;
        Assert.Equal(0, editor.Flashes.Strength(trigger));
        Assert.False(editor.Flashes.Live());

        Assert.False(editor.Document.IsDirty);
        Assert.Empty(editor.Document.History);
        Assert.Equal(text, editor.Document.Text);
        Assert.Empty(_sent);
    }

    [Fact]
    public void AFiredEventOfAnotherTicketASubSequenceOrAGoneKeyDoesNotFlash()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var ticket = Opened(shell);
        var flashed = 0;
        editor.Flashed += () => flashed++;
        var lines = shell.Console.Lines.Count;

        shell.OnGameMessage(new CutscenePreviewFired(ticket + 1, 0, 1, CutscenePreviewFiredKind.Trigger, "intro_seen", false));
        Assert.Equal(lines, shell.Console.Lines.Count);

        // A sub-sequence's event ID is the child's, and an ID that the text no longer has finds nothing: both only log.
        shell.OnGameMessage(new CutscenePreviewFired(ticket, 30000, 1, CutscenePreviewFiredKind.Trigger, "door_open", true));
        shell.OnGameMessage(new CutscenePreviewFired(ticket, 30000, 99, CutscenePreviewFiredKind.Trigger, "lost", false));

        Assert.Equal(0, flashed);
        Assert.Contains(shell.Console.Lines, l => l.Text == "cutscene: door_open at 00:00:15 in a sub-sequence");
        Assert.Contains(shell.Console.Lines, l => l.Text == "cutscene: lost at 00:00:15");
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

        var open = OpenWithSettings();
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
    public void ALinkLostDuringPlaybackPlaysAgainOnTheNextLink()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var ticket = Opened(shell);
        shell.CutscenePreview.PlayPause();
        shell.OnGameMessage(new CutscenePreviewTick(ticket, 42000, true));

        shell.Host.Stop();
        Assert.Equal(new CutscenePreviewState.Closed(null, Resume: new CutsceneTransport.Playing(1)), shell.CutscenePreview.State);
        shell.Host.LinkForTests(_sent.Add);

        var open = Assert.Single(_sent.OfType<CutscenePreviewOpen>());
        Assert.Equal(42000, open.Tick);
        _sent.Clear();
        Answer(shell, open.Ticket);
        Assert.Equal(42000, Assert.IsType<CutscenePreviewPlay>(Assert.Single(_sent)).Tick);
    }

    [Fact]
    public void APreviewThatTheGameRefusedWithoutASceneOpensWhenTheSceneIsSent()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var ticket = LastOpen.Ticket;
        shell.OnGameMessage(new CutscenePreviewEnded(ticket, CutscenePreviewEndReason.NotEditing));
        Assert.Equal(new CutscenePreviewState.Closed(CutscenePreviewEndReason.NotEditing), shell.CutscenePreview.State);
        _sent.Clear();

        // The scene that opens goes to the game, and the session opens again after it.
        File.WriteAllText(_temp.Combine("other.scene"), "scene 1\n");
        shell.OpenScene(_temp.Combine("other.scene"));

        Assert.IsType<LoadScene>(_sent.First(m => m is LoadScene or CutscenePreviewOpen));
        Assert.True(Assert.Single(_sent.OfType<CutscenePreviewOpen>()).Ticket > ticket);
    }

    [Fact]
    public void AScrubOrAStepWhileASessionOpensAgainKeepsItPaused()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var ticket = Opened(shell);
        shell.CutscenePreview.PlayPause();
        shell.Host.Receive(new GameReloaded(ReloadKind.SoftRestart));
        Assert.IsType<CutscenePreviewState.Opening>(shell.CutscenePreview.State);
        var open = LastOpen;
        Assert.True(open.Ticket > ticket);

        editor.SetPlayhead(18000);
        _sent.Clear();
        Answer(shell, open.Ticket);
        shell.CutscenePreview.Flush();

        Assert.Empty(_sent.OfType<CutscenePreviewPlay>());
        Assert.Equal(18000, Assert.Single(_sent.OfType<CutscenePreviewTime>()).Tick);
        Assert.False(shell.CutscenePreview.IsPlayingIn(editor));
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
        editor.SetKeyboardPane(CutscenePane.Timeline);

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

    static void Run(EditorShell shell, string id) => shell.Commands.Get(id).Execute();

    float[] Rates() => [.. _sent.OfType<CutscenePreviewPlay>().Select(p => p.Rate)];

    [Fact]
    public void JKAndLShuttleAtDoublingRatesAndHeldKStepsAFrame()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var ticket = Opened(shell);
        var frame = editor.FrameTicks;
        editor.SetKeyboardPane(CutscenePane.Timeline);

        // L plays forward at 1×, and each press doubles the rate up to 8×.
        for (var i = 0; i < 5; i++)
        {
            Run(shell, EditorCommands.CutsceneShuttleForward);
        }
        Assert.Equal([1f, 2f, 4f, 8f, 8f], Rates());
        Assert.Equal(8f, editor.PlayingRate);
        // J turns it around at 1×, from the end of the range when it is at the start, and doubles backward.
        _sent.Clear();
        Run(shell, EditorCommands.CutsceneShuttleBack);
        Run(shell, EditorCommands.CutsceneShuttleBack);
        Assert.Equal([-1f, -2f], Rates());
        Assert.Equal(720000, _sent.OfType<CutscenePreviewPlay>().First().Tick);

        // K pauses where the game is. While it is held, L and J step a frame, and play nothing.
        shell.OnGameMessage(new CutscenePreviewTick(ticket, 30000, true));
        _sent.Clear();
        Run(shell, EditorCommands.CutsceneShuttlePause);
        Assert.Null(editor.PlayingRate);
        Assert.Equal(30000, Assert.Single(_sent.OfType<CutscenePreviewTime>()).Tick);
        Run(shell, EditorCommands.CutsceneShuttleForward);
        Run(shell, EditorCommands.CutsceneShuttleForward);
        Run(shell, EditorCommands.CutsceneShuttleBack);
        Assert.Equal(30000 + frame, editor.Playhead);
        Assert.Empty(Rates());
        // The timeline's loss of the keyboard ends the hold, as the key's release does.
        editor.LeaveKeyboardPane(CutscenePane.Timeline);
        Assert.False(editor.ShuttleHeld);
        editor.SetKeyboardPane(CutscenePane.Timeline);
        Run(shell, EditorCommands.CutsceneShuttleForward);
        Assert.Equal([1f], Rates());

        // Space plays at the rate box's rate, which is clamped.
        Run(shell, EditorCommands.CutscenePlayPause);
        editor.PlayRate = 0.5f;
        _sent.Clear();
        Run(shell, EditorCommands.CutscenePlayPause);
        Assert.Equal([0.5f], Rates());
        editor.PlayRate = 10;
        Assert.Equal(CutsceneEditor.MaxPlayRate, editor.PlayRate);

        Assert.Empty(shell.KeyBindings.Warnings);
        Assert.Equal(("J", "K", "L"), (shell.KeyBindings.ShortcutOf(EditorCommands.CutsceneShuttleBack),
            shell.KeyBindings.ShortcutOf(EditorCommands.CutsceneShuttlePause), shell.KeyBindings.ShortcutOf(EditorCommands.CutsceneShuttleForward)));
    }

    [Fact]
    public void InAndOutPointsLoopThePlayAndAChangeWhilePlayingSendsItAgain()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var ticket = Opened(shell);
        editor.SetKeyboardPane(CutscenePane.Timeline);
        Assert.False(shell.Commands.Get(EditorCommands.CutsceneClearInOut).CanExecute);

        // The points go in time order, whichever is set first.
        editor.SetPlayhead(60000);
        Run(shell, EditorCommands.CutsceneSetIn);
        editor.SetPlayhead(30000);
        Run(shell, EditorCommands.CutsceneSetOut);
        Assert.Equal(new CutsceneLoop(30000, 60000), editor.LoopRange);
        Run(shell, EditorCommands.CutsceneLoop);
        Assert.True(shell.Commands.Get(EditorCommands.CutsceneLoop).IsChecked);
        // At the loop's end, a play starts at its start.
        editor.SetPlayhead(60000);
        shell.CutscenePreview.Flush();
        _sent.Clear();
        Run(shell, EditorCommands.CutscenePlayPause);
        Assert.Equal(new CutscenePreviewPlay(ticket, 30000, 1, true, 30000, 60000), Assert.Single(_sent.OfType<CutscenePreviewPlay>()));

        // A new out point while it plays sends the play again from the playhead, at its rate.
        shell.OnGameMessage(new CutscenePreviewTick(ticket, 45000, true));
        _sent.Clear();
        Run(shell, EditorCommands.CutsceneSetOut);
        Assert.Equal(new CutscenePreviewPlay(ticket, 45000, 1, true, 45000, 60000), Assert.Single(_sent.OfType<CutscenePreviewPlay>()));
        // Without the points, the loop is the cutscene's range; without the loop, the play does not loop.
        _sent.Clear();
        Run(shell, EditorCommands.CutsceneClearInOut);
        Assert.Equal(new CutscenePreviewPlay(ticket, 45000, 1, true, 0, 600000), Assert.Single(_sent.OfType<CutscenePreviewPlay>()));
        _sent.Clear();
        Run(shell, EditorCommands.CutsceneLoop);
        Assert.Equal(new CutscenePreviewPlay(ticket, 45000, 1, false, 0, 0), Assert.Single(_sent.OfType<CutscenePreviewPlay>()));
        // A paused preview sends nothing.
        Run(shell, EditorCommands.CutscenePlayPause);
        _sent.Clear();
        Run(shell, EditorCommands.CutsceneSetIn);
        Assert.Empty(_sent);
    }

    [Fact]
    public void UpAndDownMoveToTheKeysAndEdgesOfTheSelectedTracksOrOfEveryTrack()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        Opened(shell);
        editor.SetKeyboardPane(CutscenePane.Timeline);
        List<int> Walk(string id, int times)
        {
            var at = new List<int>();
            for (var i = 0; i < times; i++)
            {
                Run(shell, id);
                at.Add(editor.Playhead);
            }
            return at;
        }

        // With nothing selected, every track: the music's gain key comes before the first cut.
        var all = editor.KeyEdges();
        Assert.Equal([all[1], all[2]], Walk(EditorCommands.CutsceneNextKey, 2));
        Assert.True(all[1] < 200000);
        // The rack focus's section and its keys, at 200000 and 320000, and the end.
        editor.SetPlayhead(0);
        editor.Select(["section:8"], SelectMode.Replace);
        Assert.Equal([200000, 320000, 400000, 720000, 720000], Walk(EditorCommands.CutsceneNextKey, 5));
        Assert.Equal([400000, 320000], Walk(EditorCommands.CutscenePreviousKey, 2));
        // A folded binding's tracks count.
        editor.ToggleFold("binding:4");
        Assert.Equal([200000], Walk(EditorCommands.CutscenePreviousKey, 1));
        Assert.Equal(("Up", "Down"), (shell.KeyBindings.ShortcutOf(EditorCommands.CutscenePreviousKey), shell.KeyBindings.ShortcutOf(EditorCommands.CutsceneNextKey)));
    }

    [Fact]
    public void TheMixGoesWithEachOpenAndOnEachChangeOfMuteSoloAndTheToggles()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var settings = Assert.Single(_sent.OfType<CutscenePreviewSettings>());
        Assert.Equal((true, false, 0), (settings.ScrubSound, settings.Events, settings.Silent.Length));
        var ticket = Opened(shell);
        editor.SetKeyboardPane(CutscenePane.Timeline);
        CutscenePreviewSettings Last() => _sent.OfType<CutscenePreviewSettings>().Last();

        editor.SetMuted(6, true);
        Assert.Equal(ticket, Last().Ticket);
        Assert.Equal([6u], Last().Silent);
        // A solo silences every other track, and the muted one stays silent.
        editor.SetSoloed(1, true);
        Assert.Equal(editor.File.Tracks.Select(t => (uint)t.Id!.Value).Where(id => id != 1).Order(), Last().Silent.Order());
        Run(shell, EditorCommands.CutsceneScrubSound);
        Run(shell, EditorCommands.CutscenePreviewEvents);
        Assert.Equal((false, true), (Last().ScrubSound, Last().Events));
        Assert.True(shell.Commands.Get(EditorCommands.CutscenePreviewEvents).IsChecked);

        // A session that opens again carries the same mix.
        _sent.Clear();
        shell.OnGameMessage(new CutscenePreviewEnded(ticket, CutscenePreviewEndReason.CodeReloaded));
        var open = OpenWithSettings();
        Assert.Equal((open.Ticket, false, true, editor.File.Tracks.Count() - 1), (Last().Ticket, Last().ScrubSound, Last().Events, Last().Silent.Length));

        // The toggles are each user's, and a file from before them reads with their defaults.
        Assert.Equal((false, true), (shell.CutsceneTimelineSettingsOf(editor.Guid).ScrubSound, shell.CutsceneTimelineSettingsOf(editor.Guid).Events));
        var old = System.Text.Json.JsonSerializer.Deserialize<CutsceneTimelineView>("{\"ShowFrames\":true,\"Locked\":[1]}")!;
        Assert.Equal((true, false), (old.ScrubSound, old.Events));
    }

    [Fact]
    public void ALinkLostDuringAShuttlePlaysAgainAtItsRate()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var ticket = Opened(shell);
        editor.SetKeyboardPane(CutscenePane.Timeline);
        Run(shell, EditorCommands.CutsceneShuttleForward);
        Run(shell, EditorCommands.CutsceneShuttleForward);
        shell.OnGameMessage(new CutscenePreviewTick(ticket, 42000, true));

        shell.Host.Stop();
        Assert.Equal(new CutscenePreviewState.Closed(null, Resume: new CutsceneTransport.Playing(2)), shell.CutscenePreview.State);
        shell.Host.LinkForTests(_sent.Add);
        var open = Assert.Single(_sent.OfType<CutscenePreviewOpen>());
        _sent.Clear();
        Answer(shell, open.Ticket);
        var play = Assert.Single(_sent.OfType<CutscenePreviewPlay>());
        Assert.Equal((42000, 2f), (play.Tick, play.Rate));
    }

    [Fact]
    public void TheTimelinePagesToFollowThePlayheadUntilAPanByHand()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        var ticket = Opened(shell);
        var input = new CutsceneTimelineInput(editor);
        editor.PlayheadChanged += input.ShowPlayhead;
        editor.PlayStarted += input.OnPlayStarted;
        input.Resize(CutsceneTimelineLayout.Gutter + 1000, 400);
        input.SetView(new TimelineView(0, 100, TimelineZoom.Ticks));

        // Forward, the view pages to put the playhead near its left edge.
        shell.CutscenePreview.Play(1);
        shell.OnGameMessage(new CutscenePreviewTick(ticket, 150000, true));
        Assert.Equal(150000 - 100 * 100, input.View.Start, 3);
        // A pan by hand stops it until the next play.
        input.Wheel(CutsceneTimelineLayout.Gutter + 10, 10, 1, Avalonia.Input.KeyModifiers.Shift);
        Assert.False(input.Follow);
        var start = input.View.Start;
        shell.OnGameMessage(new CutscenePreviewTick(ticket, 400000, true));
        Assert.Equal(start, input.View.Start);
        // A change of the loop while it plays sends the play again, and is no new play.
        editor.Loop = true;
        shell.OnGameMessage(new CutscenePreviewTick(ticket, 500000, true));
        Assert.Equal(start, input.View.Start);
        // Backward, it pages to put the playhead near its right edge.
        shell.CutscenePreview.Play(-1);
        Assert.True(input.Follow);
        shell.OnGameMessage(new CutscenePreviewTick(ticket, 100000, true));
        Assert.Equal(100000 - 900 * 100, input.View.Start, 3);
    }

    [Fact]
    public void TheGameViewsFrameCounterShowsTheTimeTheFrameAndTheShot()
    {
        var (shell, editor) = NewShell();
        using var _ = shell;
        Assert.Null(shell.CutscenePreview.FrameCounter());
        Opened(shell);
        Assert.Equal("00:00:00  ·  frame 0  ·  Wide Shot", shell.CutscenePreview.FrameCounter());
        editor.SetPlayhead(250000);
        Assert.Equal("00:04:05  ·  frame 125  ·  Close Shot", shell.CutscenePreview.FrameCounter());
        editor.SetPlayhead(650000);
        Assert.EndsWith("gameplay", shell.CutscenePreview.FrameCounter());
        // A muted cut track shows no shot in the game, and none here.
        editor.SetPlayhead(250000);
        editor.SetMuted(5, true);
        Assert.EndsWith("gameplay", shell.CutscenePreview.FrameCounter());
    }
}
