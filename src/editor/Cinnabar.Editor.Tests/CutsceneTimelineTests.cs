using Avalonia.Input;
using Cinnabar.Editor.Cutscenes;
using Cinnabar.Editor.Document;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Shell;
using Cinnabar.Editor.Tools;
using L = Cinnabar.Editor.Tools.CutsceneTimelineLayout;
using Root = Cinnabar.Editor.Link.Cook.Root;
using Welcome = Cinnabar.Editor.Link.Cook.Welcome;

namespace Cinnabar.Editor.Tests;

/// <summary>The cutscene editor's timeline, driven through its gestures and commands without a window.</summary>
public sealed class CutsceneTimelineTests : IDisposable
{
    const string Guid = "0123456789abcdef0123456789abcdef";

    readonly TempDirectory _temp = new("cutscene-timeline");

    public void Dispose() => _temp.Dispose();

    (EditorShell Shell, CutsceneEditor Editor, CutsceneTimelineInput Input, string Text) Intro()
    {
        var text = CutsceneFileTests.Sample("intro").ReplaceLineEndings("\n");
        var shell = TestShell.Open(_temp, null, null);
        File.WriteAllText(_temp.Combine("intro.cutscene"), text);
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [], [], []));
        var asset = TestAssets.Make(Guid, AssetKind.Cutscene, "intro.cutscene");
        shell.Assets.Apply(new AssetSnapshot([asset], []));
        var editor = shell.OpenCutscene(asset)!;
        var input = new CutsceneTimelineInput(editor);
        input.Resize(L.Gutter + 1000, 800);
        // A thousand ticks a pixel, from 0, so every tick in the tests is on a whole pixel.
        input.SetView(new TimelineView(0, 1000, TimelineZoom.Ticks));
        editor.Changed += input.Refresh;
        return (shell, editor, input, text);
    }

    static double X(int tick) => L.Gutter + tick / 1000.0;

    static double Y(CutsceneTimelineInput input, string track) =>
        L.RulerHeight + input.Layout.Rows.First(r => r.Path == track && r.Kind == CutsceneRowKind.Track).Top - input.ScrollY + L.RowHeight / 2;

    // A press, a drag to a point and a release, as the view passes them on.
    static void Drag(CutsceneTimelineInput input, double x0, double y, double x1, KeyModifiers modifiers = KeyModifiers.None)
    {
        Assert.True(input.Press(x0, y, MouseButton.Left, modifiers));
        input.Move((x0 + x1) / 2, y, modifiers);
        input.Move(x1, y, modifiers);
        input.Release(x1, y, modifiers);
    }

    static readonly string Bark = """
        	section 3 360000 420000
        		asset = $7ce894b4b95e68b918869459e5cd9c93
        		bus = 2
        		min_distance = 2
        		max_distance = 30

        """.ReplaceLineEndings("\n");

    static string BarkAs(string text, string sections) => text.Replace(Bark, sections.ReplaceLineEndings("\n"));

    [Fact]
    public void AMoveTrimSplitSlipAndRippleEachGiveTheExactTextAndUndoGoesBackOverThem()
    {
        var (shell, editor, input, text) = Intro();
        Assert.Contains(Bark, text);
        var bark = Y(input, "track:3");

        // Move: the bark's body by 40 pixels lands its start on 400000, where the close shot ends.
        Drag(input, X(390000), bark, X(430000));
        Assert.Equal(["section:3"], editor.SelectedPaths);
        var moved = BarkAs(text, Bark.Replace("section 3 360000 420000", "section 3 400000 460000"));
        Assert.Equal(moved, editor.Document.Text);

        // Trim: its end by 20 pixels.
        Drag(input, X(460000) - 1, bark, X(480000) - 1);
        var trimmed = BarkAs(text, Bark.Replace("section 3 360000 420000", "section 3 400000 480000"));
        Assert.Equal(trimmed, editor.Document.Text);

        // Split at the playhead: the second half's sound starts 40000 ticks in.
        editor.TimelineFocused = true;
        editor.SetPlayhead(440000);
        shell.Commands.Get(EditorCommands.CutsceneSplit).Execute();
        var split = BarkAs(text, """
            	section 3 400000 440000
            		asset = $7ce894b4b95e68b918869459e5cd9c93
            		bus = 2
            		min_distance = 2
            		max_distance = 30
            	section 14 440000 480000
            		asset = $7ce894b4b95e68b918869459e5cd9c93
            		bus = 2
            		min_distance = 2
            		max_distance = 30
            		offset = 40000

            """);
        Assert.Equal(split, editor.Document.Text);
        Assert.Equal(["section:3", "section:14"], editor.SelectedPaths);

        // Slip: Alt and a drag of the second half 20 pixels to the left plays 20000 ticks later in the sound.
        Drag(input, X(460000), bark, X(440000), KeyModifiers.Alt);
        var slipped = split.Replace("offset = 40000", "offset = 60000");
        Assert.Equal(slipped, editor.Document.Text);

        // Ripple: Shift and a drag of the first half's end lengthens it, and the second half moves on as far.
        Drag(input, X(440000) - 2, bark, X(450000) - 2, KeyModifiers.Shift);
        var rippled = slipped.Replace("section 3 400000 440000", "section 3 400000 450000").Replace("section 14 440000 480000", "section 14 450000 490000");
        Assert.Equal(rippled, editor.Document.Text);

        Assert.Equal(["Move", "Trim", "Split", "Slip", "Ripple Trim"], editor.Document.History);
        foreach (var expected in new[] { slipped, split, trimmed, moved, text })
        {
            shell.Commands.Get("edit.undo").Execute();
            Assert.Equal(expected, editor.Document.Text);
        }
    }

    [Fact]
    public void EscDuringADragLeavesTheTextAndTheUndoStackAsTheyWere()
    {
        var (_, editor, input, text) = Intro();
        var bark = Y(input, "track:3");
        Assert.True(input.Press(X(390000), bark, MouseButton.Left, KeyModifiers.None));
        input.Move(X(400000), bark, KeyModifiers.None);
        input.Move(X(450000), bark, KeyModifiers.None);
        Assert.True(input.Dragging);
        Assert.NotEqual(text, editor.Document.Text);
        Assert.NotNull(input.Tooltip);

        Assert.True(input.Escape());
        Assert.False(input.Dragging);
        Assert.False(editor.Document.InTransaction);
        Assert.Equal(text, editor.Document.Text);
        Assert.Empty(editor.Document.History);
        Assert.Equal(0, editor.Document.Position);
        // The release after Esc does nothing.
        input.Release(X(450000), bark, KeyModifiers.None);
        Assert.Equal(text, editor.Document.Text);
        Assert.Empty(editor.Document.History);
    }

    [Fact]
    public void EscDuringADragOfAKeyPastAnotherSelectsTheSameKeyAgain()
    {
        var (_, editor, input, text) = Intro();
        var music = Y(input, "track:7");
        // The music's first key, at 0, dragged past the one at 200000, takes the second place in its channel.
        Assert.True(input.Press(X(0), music, MouseButton.Left, KeyModifiers.None));
        Assert.Equal(["section:9/channel:gain/key:0"], editor.SelectedPaths);
        input.Move(X(100000), music, KeyModifiers.None);
        input.Move(X(300000), music, KeyModifiers.None);
        Assert.Equal(["section:9/channel:gain/key:1"], editor.SelectedPaths);
        Assert.Equal(300000, editor.File.Find("section:9/channel:gain/key:1")!.Start);

        // After Esc, the key at 200000 is the second again, and the dragged key, the first, is selected.
        Assert.True(input.Escape());
        Assert.Equal(text, editor.Document.Text);
        Assert.Equal(["section:9/channel:gain/key:0"], editor.SelectedPaths);

        // A release of another button does not end a drag.
        Assert.True(input.Press(X(0), music, MouseButton.Left, KeyModifiers.None));
        input.Move(X(50000), music, KeyModifiers.None);
        input.Release(X(50000), music, KeyModifiers.None, MouseButton.Right);
        Assert.True(input.Dragging);
        input.Release(X(50000), music, KeyModifiers.None);
        Assert.Equal(["Move"], editor.Document.History);

        // An undo changes the line at a selected key's path, so the editor cannot tell that it is the same key, and drops
        // it; a selected key whose line the undo leaves stays.
        editor.Select(["section:9/channel:gain/key:0", "section:9/channel:gain/key:2"], SelectMode.Replace);
        editor.Document.Undo();
        Assert.Equal(text, editor.Document.Text);
        Assert.Equal(["section:9/channel:gain/key:2"], editor.SelectedPaths);
    }

    [Fact]
    public void ALengthDragKeepsARangeThatWasAllOfTheLength()
    {
        var (_, editor, input, _) = Intro();
        editor.Select(editor.File.Root);
        editor.EditSelected("No range", b => b.Set("range", null));
        Assert.Equal((0, 720000), input.Layout.Range);
        Assert.True(input.Press(X(720000), 4, MouseButton.Left, KeyModifiers.None));
        input.Move(X(740000), 4, KeyModifiers.None);
        input.Move(X(760000), 4, KeyModifiers.None);
        input.Move(X(780000), 4, KeyModifiers.None);
        input.Release(X(780000), 4, KeyModifiers.None);
        Assert.Equal(780000, editor.File.Length);
        Assert.Null(editor.File.Root.Get("range"));
    }

    [Fact]
    public void AHeldNudgeIsOneUndoEntryUntilItsKeyIsReleased()
    {
        var (shell, editor, input, text) = Intro();
        input.Press(X(390000), Y(input, "track:3"), MouseButton.Left, KeyModifiers.None);
        input.Release(X(390000), Y(input, "track:3"), KeyModifiers.None);
        editor.TimelineFocused = true;
        var later = shell.Commands.Get(EditorCommands.CutsceneNudgeLater);
        later.Execute();
        later.Execute();
        later.Execute();
        Assert.Equal(["Nudge"], editor.Document.History);
        Assert.Equal(366000, editor.File.Find("section:3")!.Start);
        // The key's release ends the entry.
        editor.EndNudge();
        shell.Commands.Get(EditorCommands.CutsceneNudgeEarlier10).Execute();
        Assert.Equal(["Nudge", "Nudge"], editor.Document.History);
        Assert.Equal(346000, editor.File.Find("section:3")!.Start);
        // No entry is open between repeats, so Save runs, and the next nudge is an entry of its own.
        Assert.True(shell.Commands.Get("file.save").CanExecute);
        shell.Commands.Get("file.save").Execute();
        Assert.False(editor.Document.IsDirty);
        later.Execute();
        Assert.Equal(["Nudge", "Nudge", "Nudge"], editor.Document.History);
        Assert.True(editor.Document.IsDirty);
        // Each undo takes back a run.
        shell.Commands.Get("edit.undo").Execute();
        shell.Commands.Get("edit.undo").Execute();
        shell.Commands.Get("edit.undo").Execute();
        Assert.Equal(text, editor.Document.Text);
    }

    [Fact]
    public void ALockedTracksSectionsDoNotMove()
    {
        var (_, editor, input, text) = Intro();
        // The lock in the track's header.
        input.Press(L.Gutter - 10, Y(input, "track:3"), MouseButton.Left, KeyModifiers.None);
        Assert.Contains(3, editor.Locked);
        Drag(input, X(390000), Y(input, "track:3"), X(430000));
        Assert.Equal(text, editor.Document.Text);
        Assert.Empty(editor.Document.History);
        editor.TimelineFocused = true;
        editor.Nudge(5);
        Assert.Empty(editor.Document.History);

        // The lock is the user's, and stays for the next time the cutscene opens.
        var view = editor.Locked;
        Assert.Contains("\"Locked\":[3]", File.ReadAllText(Path.Combine(_temp.Path, "settings", EditorSettings.CutsceneTimelineFileName)));
        editor.SetLocked(3, false);
        Assert.Empty(view);
    }

    [Fact]
    public void ABoxSelectsAndAClickInEmptySpaceClears()
    {
        var (_, editor, input, _) = Intro();
        // From the cuts' row to the music's, over 150000 to 250000.
        Assert.True(input.Press(X(150000), Y(input, "track:5"), MouseButton.Left, KeyModifiers.None));
        Assert.Equal(CutsceneHitKind.Body, input.Layout.HitTest(X(150000), Y(input, "track:5"), input.View, 0).Kind);
        input.Release(X(150000), Y(input, "track:5"), KeyModifiers.None);
        Assert.Equal(["section:5"], editor.SelectedPaths);
        // Ctrl adds the section after it.
        input.Press(X(300000), Y(input, "track:5"), MouseButton.Left, KeyModifiers.Control);
        input.Release(X(300000), Y(input, "track:5"), KeyModifiers.Control);
        Assert.Equal(["section:5", "section:6"], editor.SelectedPaths);

        // A box from empty space, after the cutscene's length.
        Drag(input, X(700000), Y(input, "track:5"), X(380000));
        Assert.Equal(["section:6", "section:7"], editor.SelectedPaths);
        input.Press(X(700000), Y(input, "track:5"), MouseButton.Left, KeyModifiers.None);
        input.Release(X(700000), Y(input, "track:5"), KeyModifiers.None);
        Assert.Empty(editor.SelectedPaths);
    }

    [Fact]
    public void TheRulerMovesThePlayheadAndItsHandlesSetTheRangeAndTheLength()
    {
        var (_, editor, input, text) = Intro();
        Assert.True(input.Press(X(123456), 4, MouseButton.Left, KeyModifiers.None));
        // The playhead is on a frame: 2000 ticks at 30 fps.
        Assert.Equal(124000, editor.Playhead);
        input.Release(X(123456), 4, KeyModifiers.None);
        Assert.Empty(editor.Document.History);

        Drag(input, X(600000), L.RulerHeight - 2, X(500000));
        Assert.Equal(text.Replace("range = [0, 600000]", "range = [0, 500000]"), editor.Document.Text);
        Drag(input, X(720000), 4, X(800000));
        Assert.Equal(["Set Range", "Set Length"], editor.Document.History);
        Assert.Equal(800000, editor.File.Length);
    }

    [Fact]
    public void TheTimelinesCommandsActOnlyWhileItHasTheKeyboardAndDeleteActsOnIt()
    {
        var (shell, editor, input, text) = Intro();
        input.Press(X(390000), Y(input, "track:3"), MouseButton.Left, KeyModifiers.None);
        input.Release(X(390000), Y(input, "track:3"), KeyModifiers.None);
        editor.SetPlayhead(390000);
        Assert.False(shell.Commands.Get(EditorCommands.CutsceneSplit).CanExecute);
        Assert.False(shell.Commands.Get(EditorCommands.CutsceneFrame).CanExecute);
        editor.TimelineFocused = true;
        Assert.True(shell.Commands.Get(EditorCommands.CutsceneSplit).CanExecute);

        shell.Commands.Get(EditorCommands.CutsceneGoToEnd).Execute();
        Assert.Equal(720000, editor.Playhead);
        shell.Commands.Get(EditorCommands.CutscenePreviousEdge).Execute();
        Assert.Equal(600000, editor.Playhead);
        shell.Commands.Get(EditorCommands.CutscenePreviousEdge).Execute();
        Assert.Equal(420000, editor.Playhead);
        shell.Commands.Get(EditorCommands.CutsceneGoToStart).Execute();
        shell.Commands.Get(EditorCommands.CutsceneNextEdge).Execute();
        Assert.Equal(30000, editor.Playhead);
        shell.Commands.Get(EditorCommands.CutsceneSnap).Execute();
        Assert.False(editor.Snap);
        shell.Commands.Get(EditorCommands.CutsceneShowFrames).Execute();
        Assert.True(editor.ShowFrames);

        // The scene's Delete deletes the timeline's selection while the timeline has the keyboard.
        shell.Commands.Get(EditorCommands.DeleteEntity).Execute();
        Assert.Equal(text.Replace(Bark, ""), editor.Document.Text);
        shell.Commands.Get("edit.undo").Execute();
        Assert.Equal(text, editor.Document.Text);

        // Every one of them has a key that a window can bind, except the two toggles without one, and no key is bound twice.
        Assert.Empty(shell.KeyBindings.Warnings);
        foreach (var id in EditorCommands.CutsceneTimelineCommands)
        {
            Assert.NotNull(shell.Commands.Find(id));
            if (shell.KeyBindings.ShortcutOf(id) is { } shortcut)
            {
                Assert.NotNull(KeyGesture.Parse(shortcut));
            }
        }
        Assert.Equal("OemComma", shell.KeyBindings.ShortcutOf(EditorCommands.CutsceneNudgeEarlier));
    }
}
