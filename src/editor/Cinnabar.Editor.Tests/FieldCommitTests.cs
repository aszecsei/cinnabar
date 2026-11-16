using Avalonia.Controls;
using Avalonia.Input;
using Cinnabar.Editor.Model;
using Cinnabar.Editor.Panels;

namespace Cinnabar.Editor.Tests;

/// <summary>When a field's box commits what was typed (see docs/editor/shell-and-panels.md#properties): once for each text.</summary>
public sealed class FieldCommitTests
{
    // Records the texts that a box commits.
    sealed class Recorder : IFieldEditor
    {
        public List<string> Commits { get; } = [];
        public bool Accepts { get; set; } = true;

        public bool Commit(int axis, string text)
        {
            Commits.Add(text);
            return Accepts;
        }

        public IReadOnlyList<string> Options => [];
        public void Choose(string option) { }
        public void BeginScrub(int axis) { }
        public void Scrub(int axis, double pixels, KeyModifiers modifiers) { }
        public void EndScrub() { }
        public void SetNumbers(double[] values) { }
    }

    static FieldDisplay Number(string text) => new(DisplayKind.Number, text, [], false, 0, null);

    static TextBox BoxOf(BoxView view) => (TextBox)((Border)view.Control).Child!;

    static void Focus(TextBox box) => box.RaiseEvent(new FocusChangedEventArgs(InputElement.GotFocusEvent));

    static void Blur(TextBox box) => box.RaiseEvent(new FocusChangedEventArgs(InputElement.LostFocusEvent));

    static void Enter(TextBox box) => box.RaiseEvent(new KeyEventArgs { RoutedEvent = InputElement.KeyDownEvent, Key = Key.Enter });

    [Fact]
    public void ABoxThatCommittedOnEnterDoesNotCommitAgainWhenItLosesTheFocus()
    {
        var editor = new Recorder();
        var view = new BoxView(numeric: true, editor);
        view.Show(Number("0°"));
        var box = BoxOf(view);

        Focus(box);
        box.Text = "45";
        Enter(box);
        // The game's value comes back formatted, and the box, which has the focus, keeps what was typed.
        view.Show(Number("45°"));
        Blur(box);

        Assert.Equal(["45"], editor.Commits);
    }

    [Fact]
    public void ABoxWithNothingTypedCommitsNothingAndShowsTheValueAgain()
    {
        var editor = new Recorder();
        var view = new BoxView(numeric: true, editor);
        view.Show(Number("1"));
        var box = BoxOf(view);

        // The field's name is dragged while the box has the focus: the value changes under it.
        Focus(box);
        view.Show(Number("7.5"));
        Blur(box);

        Assert.Empty(editor.Commits);
        Assert.Equal("7.5", box.Text);
    }

    [Fact]
    public void ATextThatTheFieldRefusesPutsTheValueBackAndIsNotTriedAgain()
    {
        var editor = new Recorder { Accepts = false };
        var view = new BoxView(numeric: true, editor);
        view.Show(Number("2"));
        var box = BoxOf(view);

        Focus(box);
        box.Text = "two";
        Enter(box);
        Assert.Equal("2", box.Text);
        Blur(box);

        Assert.Equal(["two"], editor.Commits);
    }

    [Fact]
    public void EscapePutsTheValueBackAndLosingTheFocusThenCommitsNothing()
    {
        var editor = new Recorder();
        var view = new BoxView(numeric: true, editor);
        view.Show(Number("3"));
        var box = BoxOf(view);

        Focus(box);
        box.Text = "9";
        box.RaiseEvent(new KeyEventArgs { RoutedEvent = InputElement.KeyDownEvent, Key = Key.Escape });
        Blur(box);

        Assert.Empty(editor.Commits);
        Assert.Equal("3", box.Text);
    }

    [Fact]
    public void AChoicePicksAnOptionThatItHadBefore() => Ui.Run(() =>
    {
        var picked = new List<string>();
        var box = Kit.Choice(["Coverage", "Precipitation", "Type"], "Coverage", picked.Add);

        box.SelectedItem = "Precipitation";
        box.SelectedItem = "Coverage";
        // The option that it has already is not picked again.
        box.SelectedItem = "Coverage";

        Assert.Equal(["Precipitation", "Coverage"], picked);
    });

    [Fact]
    public void ANameBoxCommitsATextOnceThroughEnterAndTheLossOfTheFocus()
    {
        var commits = new List<string>();
        var box = new TextBox { Text = "Door" };
        Kit.CommitOnEnterOrBlur(box, commits.Add);

        box.Text = "Gate";
        Enter(box);
        Blur(box);
        box.Text = "Gate";
        Blur(box);

        Assert.Equal(["Gate"], commits);
    }
}
