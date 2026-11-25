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

/// <summary>
/// The sections' clips (see docs/editor/cutscene-editor.md#sections): drops of animations and sounds, the ease handles'
/// drags, and the section menu's commands, through the timeline's gestures without a window.
/// </summary>
public sealed class CutsceneClipTests : IDisposable
{
    const string Guid = "0123456789abcdef0123456789abcdef";
    const string Run = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const string Hum = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const string Line = "cde14b9399a74a289146a8362e6a9a9e";

    readonly TempDirectory _temp = new("cutscene-clips");

    public void Dispose() => _temp.Dispose();

    (EditorShell Shell, CutsceneEditor Editor, CutsceneTimelineInput Input, string Text) Intro(ulong runLength = 90000)
    {
        var text = CutsceneFileTests.Sample("intro").ReplaceLineEndings("\n");
        var shell = TestShell.Open(_temp, null, null);
        File.WriteAllText(_temp.Combine("intro.cutscene"), text);
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [], [], []));
        var asset = TestAssets.Make(Guid, AssetKind.Cutscene, "intro.cutscene");
        shell.Assets.Apply(new AssetSnapshot(
        [
            asset,
            TestAssets.Make(Run, AssetKind.Animation, "models/fox/Fox.gltf", parent: "dddddddddddddddddddddddddddddddd", subasset: "Run", length: runLength),
            TestAssets.Make(Hum, AssetKind.Audio, "audio/hum.wav", length: 120000),
            TestAssets.Make(Line, AssetKind.Audio, "audio/line.wav", length: 120000),
        ], []));
        var editor = shell.OpenCutscene(asset)!;
        var input = new CutsceneTimelineInput(editor);
        input.Resize(L.Gutter + 1000, 800);
        // A thousand ticks a pixel, from 0, so every tick in the tests is on a whole pixel.
        input.SetView(new TimelineView(0, 1000, TimelineZoom.Ticks));
        editor.Changed += input.Refresh;
        return (shell, editor, input, text);
    }

    static double X(int tick) => L.Gutter + tick / 1000.0;

    static double Y(CutsceneTimelineInput input, string path, CutsceneRowKind kind = CutsceneRowKind.Track) =>
        L.RulerHeight + input.Layout.Rows.First(r => r.Path == path && r.Kind == kind).Top - input.ScrollY + L.RowHeight / 2;

    // The top of a track's row, where a press is on an ease handle.
    static double Top(CutsceneTimelineInput input, string track) => Y(input, track) - L.RowHeight / 2 + 4;

    static void Drag(CutsceneTimelineInput input, double x0, double y, double x1, KeyModifiers modifiers = KeyModifiers.None)
    {
        Assert.True(input.Press(x0, y, MouseButton.Left, modifiers));
        input.Move((x0 + x1) / 2, y, modifiers);
        input.Move(x1, y, modifiers);
        input.Release(x1, y, modifiers);
    }

    const string BarkTrackEnd = """
        		max_distance = 30

        """;

    [Fact]
    public void AClipDroppedOnABindingAddsASectionOnANewAnimationTrackWithTheClipsLength()
    {
        var (shell, editor, input, text) = Intro();
        var guard = Y(input, "binding:2", CutsceneRowKind.Binding);
        Assert.True(input.CanDropClips([Run], X(450000), guard));
        Assert.Equal(["section:14"], input.DropClips([Run], X(450000), guard));
        // A new animation track for the guard, after its other tracks, with a section of the clip's length, selected.
        var dropped = text.Replace(BarkTrackEnd.ReplaceLineEndings("\n"), """
            		max_distance = 30
            track 11 animation "Animation"
            	binding = 2
            	section 14 450000 540000
            		asset = $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

            """.ReplaceLineEndings("\n"));
        Assert.Equal(dropped, editor.Document.Text);
        Assert.Equal(["section:14"], editor.SelectedPaths);
        Assert.Equal(["Add Section"], editor.Document.History);
        Assert.Equal("Run", input.Layout.Rows.SelectMany(r => r.Bars).Single(b => b.Path == "section:14").Label);
        shell.Commands.Get("edit.undo").Execute();
        Assert.Equal(text, editor.Document.Text);

        // An animation needs a binding: on the cuts, it has nowhere to go.
        Assert.False(input.CanDropClips([Run], X(450000), Y(input, "track:5")));
        Assert.Empty(input.DropClips([Run], X(450000), Y(input, "track:5")));
        Assert.Equal(text, editor.Document.Text);
    }

    [Fact]
    public void ASoundGoesOnItsRowsAudioTrackAndAClipThatHasNotCookedIsASecond()
    {
        var (_, editor, input, text) = Intro(runLength: 0);
        // A sound on the guard's row goes on the guard's audio track, the bark's, after the bark, in start order.
        Assert.Equal(["section:14"], input.DropClips([Hum], X(500000), Y(input, "binding:2", CutsceneRowKind.Binding)));
        Assert.Contains("""
            		max_distance = 30
            	section 14 500000 620000
            		asset = $bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
            track 4 sub_sequence
            """.ReplaceLineEndings("\n"), editor.Document.Text);
        // A sound on a track of another kind with no binding goes on the first audio track of no binding: the music's.
        input.DropClips([Hum], X(100000), Y(input, "track:5"));
        Assert.Contains("""
            		channel gain
            			key 0 0.6 auto
            			key 200000 1 auto
            			key 400000 0.8 auto
            	section 15 100000 220000
            		asset = $bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
            """.ReplaceLineEndings("\n"), editor.Document.Text);
        // A clip that has not cooked has no length yet: it is a second, and the sound after it starts there.
        Assert.Equal(["section:16", "section:17"], input.DropClips([Run, Hum], X(30000), Y(input, "track:1")));
        Assert.Contains("section 16 30000 90000", editor.Document.Text);
        Assert.Contains("section 17 90000 210000", editor.Document.Text);
        Assert.Equal(["Add Section", "Add Section", "Add Sections"], editor.Document.History);

        // A locked track takes nothing.
        editor.SetLocked(3, true);
        var before = editor.Document.Text;
        Assert.False(input.CanDropClips([Hum], X(650000), Y(input, "track:3")));
        Assert.Empty(input.DropClips([Hum], X(650000), Y(input, "track:3")));
        Assert.Equal(before, editor.Document.Text);
        Assert.NotEqual(text, before);
    }

    [Fact]
    public void ADragOfAnEaseHandleIsOneEntryThatUndoAndEscPutBack()
    {
        var (shell, editor, input, text) = Intro();
        var walks = Top(input, "track:1");
        // The fox's walk eases in over 15000 ticks: its handle dragged 15 pixels on eases it in over 30000.
        Drag(input, X(15000), walks, X(30000));
        var eased = text.Replace("""
            	section 1 0 600000
            		ease_in = 15000
            """.ReplaceLineEndings("\n"), """
            	section 1 0 600000
            		ease_in = 30000
            """.ReplaceLineEndings("\n"));
        Assert.Equal(eased, editor.Document.Text);
        Assert.Equal(["section:1"], editor.SelectedPaths);

        // Its ease out handle, at its end, dragged 60 pixels back adds an ease out of 60000.
        Drag(input, X(600000) - 1, walks, X(540000) - 1);
        var both = eased.Replace("""
            		ease_in = 30000
            		channel position_x
            """.ReplaceLineEndings("\n"), """
            		ease_in = 30000
            		ease_out = 60000
            		channel position_x
            """.ReplaceLineEndings("\n"));
        Assert.Equal(both, editor.Document.Text);
        Assert.Equal(["Set Ease", "Set Ease"], editor.Document.History);

        // The ease in stops where the ease out starts, and back to the start removes it.
        Drag(input, X(30000), walks, X(700000));
        Assert.Contains("ease_in = 540000", editor.Document.Text);
        Drag(input, X(540000) - 1, walks, X(0) - 50);
        Assert.DoesNotContain("ease_in", editor.Document.Text.Split("track 2")[0]);
        shell.Commands.Get("edit.undo").Execute();
        shell.Commands.Get("edit.undo").Execute();
        Assert.Equal(both, editor.Document.Text);
        shell.Commands.Get("edit.undo").Execute();
        shell.Commands.Get("edit.undo").Execute();
        Assert.Equal(text, editor.Document.Text);

        // Esc during the drag puts the text back, with no entry.
        var history = editor.Document.History.Count;
        Assert.True(input.Press(X(15000), walks, MouseButton.Left, KeyModifiers.None));
        input.Move(X(20000), walks, KeyModifiers.None);
        input.Move(X(80000), walks, KeyModifiers.None);
        Assert.True(input.Dragging);
        Assert.Equal("ease in 00:01:10", input.Tooltip);
        Assert.NotEqual(text, editor.Document.Text);
        Assert.True(input.Escape());
        Assert.Equal(text, editor.Document.Text);
        Assert.Equal(history, editor.Document.History.Count);

        // A locked track's handles do not drag.
        editor.SetLocked(1, true);
        Drag(input, X(15000), walks, X(30000));
        Assert.Equal(text, editor.Document.Text);
    }

    [Fact]
    public void TheBlendHandlesOfTwoOverlappingSectionsSnapToTheOverlapsEndsAsACrossfade()
    {
        var (shell, editor, input, _) = Intro();
        var bark = Y(input, "track:3");
        // A hum over the bark's last 20000 ticks: the bark is from 360000 to 420000, the hum from 400000 to 520000.
        input.DropClips([Hum], X(400000), bark);
        var overlapped = editor.Document.Text;
        Assert.Contains("section 14 400000 520000", overlapped);
        Assert.Equal([(400.0, 420.0)], L.Overlaps(input.Layout.Visible(input.View, input.TimeWidth, 0, 800).First(r => r.Row.Path == "track:3").Bars));

        // The bark's ease out handle, at its end, snaps to the hum's start, and the hum's ease in handle to the bark's end.
        var top = Top(input, "track:3");
        Drag(input, X(420000) - 1, top, X(400000) + 2);
        Drag(input, X(400000) + 1, top, X(420000) - 3);
        var crossfade = overlapped.Replace("""
            		max_distance = 30
            	section 14 400000 520000
            		asset = $bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
            """.ReplaceLineEndings("\n"), """
            		max_distance = 30
            		ease_out = 20000
            	section 14 400000 520000
            		asset = $bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
            		ease_in = 20000
            """.ReplaceLineEndings("\n"));
        Assert.Equal(crossfade, editor.Document.Text);
        Assert.Equal(["Add Section", "Set Ease", "Set Ease"], editor.Document.History);
        shell.Commands.Get("edit.undo").Execute();
        shell.Commands.Get("edit.undo").Execute();
        Assert.Equal(overlapped, editor.Document.Text);
    }

    [Fact]
    public void AClipsNameAndLengthFollowTheIndex()
    {
        var (shell, _, input, _) = Intro();
        CutsceneTimelineItem Spoken() => input.Layout.Rows.SelectMany(r => r.Bars).Single(b => b.Path == "section:10");
        Assert.Equal(("line", new CutsceneClipSpan(0, 1, false, 120000)), (Spoken().Label, Spoken().Clip));
        // A cook that has not reached the sound yet: the section shows its ID, and then its name once the index has it.
        shell.Assets.Apply(new AssetSnapshot([TestAssets.Make(Guid, AssetKind.Cutscene, "intro.cutscene")], []));
        Assert.Equal(("#10", null), (Spoken().Label, Spoken().Clip));
        shell.Assets.Apply(new AssetSnapshot([TestAssets.Make(Guid, AssetKind.Cutscene, "intro.cutscene"), TestAssets.Make(Line, AssetKind.Audio, "audio/line.wav")], []));
        Assert.Equal(("line", null), (Spoken().Label, Spoken().Clip));
    }

    [Fact]
    public void MatchClipLengthTrimsToWhatIsLeftOfTheClipAndTheMenuShowsTheClip()
    {
        var (shell, editor, input, text) = Intro();
        editor.SetKeyboardPane(CutscenePane.Timeline);
        var match = shell.Commands.Get(EditorCommands.CutsceneMatchClipLength);
        // The line plays from 30000 to 174000, and its sound is 120000 ticks long.
        Assert.Equal("section:10", input.ContextAt(X(100000), Y(input, "track:8")));
        Assert.Equal(["section:10"], editor.SelectedPaths);
        Assert.True(shell.Commands.Get(EditorCommands.CutsceneRevealClip).CanExecute);
        Assert.True(match.CanExecute);
        match.Execute();
        Assert.Equal(text.Replace("section 10 30000 174000", "section 10 30000 150000"), editor.Document.Text);
        Assert.Equal(["Match Clip Length"], editor.Document.History);
        // Matched, there is nothing to trim.
        Assert.False(match.CanExecute);

        // The music loops, so it has no end to match, and a section of another kind has no menu.
        Assert.Equal("section:9", input.ContextAt(X(100000), Y(input, "track:7")));
        Assert.False(match.CanExecute);
        Assert.Null(input.ContextAt(X(100000), Y(input, "track:1")));
    }
}
