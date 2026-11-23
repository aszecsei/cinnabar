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

/// <summary>The cutscene editor's curve editor, driven through its gestures and commands without a window.</summary>
public sealed class CutsceneCurveEditorTests : IDisposable
{
    const string Guid = "0123456789abcdef0123456789abcdef";
    const string Gain = "section:9/channel:gain";
    const string Peak = "\t\t\tkey 200000 1 auto";

    readonly TempDirectory _temp = new("cutscene-curves");

    public void Dispose() => _temp.Dispose();

    // The sample's intro with the music's gain curve shown: keys of 0.6, 1 and 0.8 at 0, 200000 and 400000. A thousand
    // ticks a pixel from 0, and a hundredth of a value a pixel with 2 at the top: the key of 1 at 200000 is at
    // (Gutter + 200, 100).
    (EditorShell Shell, CutsceneEditor Editor, CutsceneCurveInput Input, string Text) Intro()
    {
        var text = CutsceneFileTests.Sample("intro").ReplaceLineEndings("\n");
        var shell = TestShell.Open(_temp, null, null);
        File.WriteAllText(_temp.Combine("intro.cutscene"), text);
        shell.Assets.Apply(new Welcome(1, "dev", [new Root("game", _temp.Path)], [], [], []));
        var asset = TestAssets.Make(Guid, AssetKind.Cutscene, "intro.cutscene");
        shell.Assets.Apply(new AssetSnapshot([asset], []));
        var editor = shell.OpenCutscene(asset)!;
        var input = new CutsceneCurveInput(editor);
        editor.Changed += input.Refresh;
        editor.FrameCurvesRequested += input.Frame;
        editor.Select(["track:7"], SelectMode.Replace);
        input.Resize(L.Gutter + 1000, 400);
        editor.SetTimeView(new TimelineView(0, 1000, TimelineZoom.Ticks));
        input.SetValue(new ValueAxis(2, 0.01));
        editor.Snap = false;
        Assert.Contains(Peak + "\n", text);
        return (shell, editor, input, text);
    }

    static double X(int tick) => L.Gutter + tick / 1000.0;

    static double Y(double value) => (2 - value) / 0.01;

    static void Click(CutsceneCurveInput input, double x, double y, KeyModifiers modifiers = KeyModifiers.None)
    {
        input.Press(x, y, MouseButton.Left, modifiers);
        input.Release(x, y, modifiers);
    }

    static void Drag(CutsceneCurveInput input, double x0, double y0, double x1, double y1, KeyModifiers modifiers = KeyModifiers.None)
    {
        Assert.True(input.Press(x0, y0, MouseButton.Left, modifiers));
        input.Move((x0 + x1) / 2, (y0 + y1) / 2, modifiers);
        input.Move(x1, y1, modifiers);
        input.Release(x1, y1, modifiers);
    }

    [Fact]
    public void ASelectedTracksChannelsShowAndAClickOnAKeyKeepsThem()
    {
        var (_, editor, input, _) = Intro();
        Assert.Equal([Gain], editor.ShownCurves);
        Assert.Equal([Gain], input.Layout.Rows.Select(r => r.Path));
        Click(input, X(200000), Y(1));
        Assert.Equal([$"{Gain}/key:1"], editor.SelectedPaths);
        Assert.Equal([Gain], editor.ShownCurves);
        // A click in empty space clears the selection, and the curves stay.
        Click(input, X(600000), Y(1.9));
        Assert.Empty(editor.SelectedPaths);
        Assert.Equal([Gain], editor.ShownCurves);
        // The list's eye hides a curve, which then has no keys to hit.
        input.Press(4, 10, MouseButton.Left, KeyModifiers.None);
        Assert.Contains(Gain, editor.HiddenCurves);
        Assert.Empty(input.Layout.Rows);
        Assert.Single(input.List.Rows);
    }

    [Fact]
    public void FlattenBreakAndAHandleDragGiveTheExactTextAndUndoGoesBackOverThem()
    {
        var (shell, editor, input, text) = Intro();
        Click(input, X(200000), Y(1));
        // The tangent keys act only while the curve editor has the keyboard.
        editor.SetKeyboardPane(CutscenePane.Timeline);
        Assert.False(shell.Commands.Get(EditorCommands.CutsceneTangentFlatten).CanExecute);
        editor.SetKeyboardPane(CutscenePane.Curves);
        Assert.True(shell.Commands.Get(EditorCommands.CutsceneTangentFlatten).CanExecute);

        shell.Commands.Get(EditorCommands.CutsceneTangentFlatten).Execute();
        var flat = text.Replace(Peak + "\n", "\t\t\tkey 200000 1 bezier 0\n");
        Assert.Equal(flat, editor.Document.Text);
        shell.Commands.Get(EditorCommands.CutsceneTangentBreak).Execute();
        var broken = text.Replace(Peak + "\n", "\t\t\tkey 200000 1 bezier 0 0\n");
        Assert.Equal(broken, editor.Document.Text);

        // The out handle is 40 pixels right of the key. Dragged to 40 right and 40 up: 0.4 over 2/3 of a second, 0.6 a
        // second, on the out side only, as the key is broken.
        Drag(input, X(200000) + 40, Y(1), X(200000) + 40, Y(1) - 40);
        var dragged = text.Replace(Peak + "\n", "\t\t\tkey 200000 1 bezier 0 0.6\n");
        Assert.Equal(dragged, editor.Document.Text);
        Assert.Equal([$"{Gain}/key:1"], editor.SelectedPaths);

        Assert.Equal(["Flatten Tangents", "Break Tangents", "Drag Tangent"], editor.Document.History.TakeLast(3));
        shell.Commands.Get("edit.undo").Execute();
        Assert.Equal(broken, editor.Document.Text);
        shell.Commands.Get("edit.undo").Execute();
        Assert.Equal(flat, editor.Document.Text);
        shell.Commands.Get("edit.undo").Execute();
        Assert.Equal(text, editor.Document.Text);
    }

    [Fact]
    public void AKeyDragIsOneEntryThatEscCancelsAndShiftKeepsOneAxis()
    {
        var (_, editor, input, text) = Intro();
        var history = editor.Document.History.Count;
        var position = editor.Document.Position;
        // 20 pixels up is 0.2.
        Drag(input, X(200000), Y(1), X(200000), Y(1.2));
        Assert.Equal(text.Replace(Peak + "\n", "\t\t\tkey 200000 1.2 auto\n"), editor.Document.Text);
        Assert.Equal(history + 1, editor.Document.History.Count);
        editor.Document.Undo();
        (history, position) = (editor.Document.History.Count, editor.Document.Position);

        // Esc during a drag puts the text and the history back.
        Assert.True(input.Press(X(200000), Y(1), MouseButton.Left, KeyModifiers.None));
        input.Move(X(200000) + 10, Y(1) - 10, KeyModifiers.None);
        input.Move(X(200000) + 30, Y(1) - 30, KeyModifiers.None);
        Assert.True(input.Dragging);
        Assert.NotEqual(text, editor.Document.Text);
        Assert.True(input.Escape());
        Assert.Equal(text, editor.Document.Text);
        Assert.Equal((history, position), (editor.Document.History.Count, editor.Document.Position));
        input.Release(X(200000) + 30, Y(1) - 30, KeyModifiers.None);
        Assert.Equal(text, editor.Document.Text);

        // With Shift, the axis that moved more moves alone: 30 pixels right and 3 up is 30000 ticks later, at 1.
        Drag(input, X(200000), Y(1), X(200000) + 30, Y(1) - 3, KeyModifiers.Shift);
        Assert.Equal(text.Replace(Peak + "\n", "\t\t\tkey 230000 1 auto\n"), editor.Document.Text);
    }

    [Fact]
    public void ADoubleClickOnACurveAddsAKeyThereAndDeleteInTheCurvesRemovesIt()
    {
        var (shell, editor, input, text) = Intro();
        var row = input.Layout.Rows[0];
        var value = row.ValueAt(300000);
        Assert.False(input.Press(X(300000), Y(value), MouseButton.Left, KeyModifiers.None, clicks: 2));
        var line = $"\t\t\tkey 300000 {CutsceneKeying.Format(CutsceneCurve.Value(row.Keys, 300000))} auto\n";
        Assert.Equal(text.Replace(Peak + "\n", Peak + "\n" + line), editor.Document.Text);
        Assert.Equal([$"{Gain}/key:2"], editor.SelectedPaths);

        // The scene's Delete deletes the selected keys while the curve editor has the keyboard.
        editor.SetKeyboardPane(CutscenePane.Curves);
        shell.Commands.Get(EditorCommands.DeleteEntity).Execute();
        Assert.Equal(text, editor.Document.Text);
    }

    [Fact]
    public void TheCurvesShareTheTimelinesTimeAndItsKeys()
    {
        var (shell, editor, input, _) = Intro();
        var timeline = new CutsceneTimelineInput(editor);
        // The timeline's first size fits the whole cutscene, in the time that both show.
        timeline.Resize(L.Gutter + 1000, 400);
        Assert.Equal(editor.TimeView, timeline.View);
        Assert.NotEqual(1000, editor.TimeView.PerPixel);
        editor.SetTimeView(new TimelineView(0, 1000, TimelineZoom.Ticks));
        input.Wheel(X(200000), 100, 1, KeyModifiers.None);
        Assert.Equal(editor.TimeView, timeline.View);
        Assert.Equal(200000, timeline.View.At(200), 6);
        Assert.True(timeline.View.PerPixel < 1000);
        // Shift and the wheel zoom the values, and leave the time.
        var time = editor.TimeView;
        input.Wheel(X(200000), 100, 1, KeyModifiers.Shift);
        Assert.Equal(time, editor.TimeView);
        Assert.True(input.Value.PerPixel < 0.01);

        // The transport keys act with the curves' keyboard, and F frames the curves there.
        editor.SetKeyboardPane(CutscenePane.Curves);
        Assert.True(editor.TimelineFocused);
        shell.Commands.Get(EditorCommands.CutsceneStepForward).Execute();
        Assert.Equal(editor.FrameTicks, editor.Playhead);
        shell.Commands.Get(EditorCommands.CutsceneFrame).Execute();
        // The gain's keys span 0 to 400000, and its values 0.6 to 1.
        Assert.Equal(0, editor.TimeView.At(0) + 400000 / 20, 6);
        Assert.Equal(1.04, input.Value.Top, 6);

        // Ctrl+E opens and closes the curves; closing gives the keyboard back to the timeline.
        shell.Commands.Get(EditorCommands.CutsceneCurves).Execute();
        Assert.True(editor.CurvesOpen);
        shell.Commands.Get(EditorCommands.CutsceneCurves).Execute();
        Assert.False(editor.CurvesOpen);
        Assert.Equal(CutscenePane.Timeline, editor.KeyboardPane);
        shell.Commands.Get(EditorCommands.CutsceneCurvesNormalized).Execute();
        Assert.True(editor.CurvesNormalized);

        // Every curve command has a key, and no key is bound twice.
        Assert.Empty(shell.KeyBindings.Warnings);
        Assert.Equal("Ctrl+E", shell.KeyBindings.ShortcutOf(EditorCommands.CutsceneCurves));
        Assert.Equal("D6", shell.KeyBindings.ShortcutOf(EditorCommands.CutsceneTangentFlatten));
        // Leaving the tab lets the keyboard go.
        editor.LeaveKeyboardPane(CutscenePane.Curves);
        Assert.Equal(CutscenePane.Timeline, editor.KeyboardPane);
        editor.LeaveKeyboardPane(CutscenePane.Timeline);
        Assert.False(editor.TimelineFocused);
    }

    [Fact]
    public void AFieldThatStepsDrawsAsStepsAndTakesNoTangents()
    {
        var (shell, editor, input, text) = Intro();
        const string Focus = "section:8/channel:value";
        editor.Select(["track:6"], SelectMode.Replace);
        Assert.False(input.Layout.Rows[0].Stepped);
        // Once the game says that the field is an integer, its curve steps.
        static Link.Protocol.FieldInfo Field(string name, Link.Protocol.FieldKind kind) => new(name, 0, kind, kind, [], false, false, 0, 0, false, false, 0, "");
        shell.OnGameMessage(new Link.Protocol.ComponentTypes([new Link.Protocol.ComponentType(160, "Lens", "Rendering", 4, [Field("focus_distance", Link.Protocol.FieldKind.I32)])]));
        editor.Select(["track:6"], SelectMode.Replace);
        input.Refresh();
        var row = input.Layout.Rows[0];
        Assert.True(row.Stepped);
        Assert.Equal(6, row.ValueAt(200000 + 119999));
        Assert.False(row.HasHandle(0, TangentSide.Out));
        editor.Select([$"{Focus}/key:0"], SelectMode.Replace);
        editor.SetKeyboardPane(CutscenePane.Curves);
        Assert.False(shell.Commands.Get(EditorCommands.CutsceneTangentFlatten).CanExecute);
        Assert.Equal(text, editor.Document.Text);
    }

    [Fact]
    public void ALockedTracksCurveTakesNoKeysOrTangents()
    {
        var (shell, editor, input, text) = Intro();
        Click(input, X(200000), Y(1));
        editor.SetLocked(7, true);
        editor.SetKeyboardPane(CutscenePane.Curves);
        Assert.False(shell.Commands.Get(EditorCommands.CutsceneTangentFlatten).CanExecute);
        Drag(input, X(200000), Y(1), X(200000), Y(1.5));
        // A double-click on its curve adds nothing.
        var y = Y(input.Layout.Rows[0].ValueAt(300000));
        input.Press(X(300000), y, MouseButton.Left, KeyModifiers.None, clicks: 2);
        input.Release(X(300000), y, KeyModifiers.None);
        Assert.Equal(text, editor.Document.Text);
    }
}
