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

    static void Blur(InputElement box) => box.RaiseEvent(new FocusChangedEventArgs(InputElement.LostFocusEvent));

    static void Enter(InputElement box) => box.RaiseEvent(new KeyEventArgs { RoutedEvent = InputElement.KeyDownEvent, Key = Key.Enter });

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

    static TextBox Inner(Control box) => (TextBox)((Border)box).Child!;

    static void Escape(InputElement box) => box.RaiseEvent(new KeyEventArgs { RoutedEvent = InputElement.KeyDownEvent, Key = Key.Escape });

    [Fact]
    public void ACommitThatTakesTheBoxAwayCommitsOnce()
    {
        var commits = new List<string>();
        TextBox? box = null;
        // The setter builds the panel again, which takes the focus from the box inside the commit.
        box = Inner(Kit.ValueBox("Door", "name", text =>
        {
            commits.Add(text);
            Blur(box!);
        }));

        Focus(box);
        box.Text = "Gate";
        Enter(box);
        Blur(box);

        Assert.Equal(["Gate"], commits);
        Assert.Equal("Gate", box.Text);
    }

    [Fact]
    public void ARefusedTextPutsTheLastTakenTextBackWithTheProblemUntilTheNextCommit()
    {
        var taken = new List<string>();
        var format = ValueFormats.Text.Where(t => t != "Wall", "not a name for a door");
        var box = Inner(Kit.ValueBox("Door", format, "name", taken.Add));

        Focus(box);
        box.Text = "Gate";
        Enter(box);
        box.Text = "Wall";
        Enter(box);
        Assert.Equal("Gate", box.Text);
        Assert.Equal("not a name for a door", ToolTip.GetTip(box));

        // Escape puts the text back and clears the problem; leaving the box then commits nothing.
        box.Text = "Wall";
        Escape(box);
        Assert.Equal("Gate", box.Text);
        Assert.Null(ToolTip.GetTip(box));
        Blur(box);

        Assert.Equal(["Gate"], taken);
    }

    [Fact]
    public void ASetterThatRefusesPutsTheValueBackWithItsReason()
    {
        var box = Inner(Kit.ValueBox("speed", ValueFormats.Text, "name", _ => false, "another parameter has it"));

        box.Text = "jump";
        Blur(box);

        Assert.Equal("speed", box.Text);
        Assert.Equal("another parameter has it", ToolTip.GetTip(box));
    }

    [Fact]
    public void AKeyBoxCommitsOnEnterAndPutsTheTextBackOnEscape()
    {
        var commits = new List<string>();
        var box = (AutoCompleteBox)((Border)Decisions.DecisionNodeDetails.KeyBox("health < 0.3", "a condition", ["health"], commits.Add)).Child!;

        box.Text = "health < 0.5";
        Enter(box);
        box.Text = "always";
        Escape(box);
        Blur(box);

        Assert.Equal(["health < 0.5"], commits);
        Assert.Equal("health < 0.5", box.Text);
    }

    [Theory]
    [InlineData("12", true, 12)]
    [InlineData(" -3 ", true, -3)]
    [InlineData("1,000", false, 0)]
    [InlineData("1.5", false, 0)]
    [InlineData("99", false, 0)]
    public void AnIntegerReadsTheInvariantCultureWithinItsRange(string text, bool parses, int expected)
    {
        var culture = Thread.CurrentThread.CurrentCulture;
        // A culture whose group separator is a dot reads 1.5 as 15.
        Thread.CurrentThread.CurrentCulture = new System.Globalization.CultureInfo("de-DE");
        try
        {
            var format = ValueFormats.Integer(-10, 50);
            Assert.Equal(parses, format.TryParse(text, out var value, out var problem));
            if (parses)
            {
                Assert.Equal(expected, value);
            }
            else
            {
                Assert.Equal("a whole number from -10 to 50", problem);
            }
        }
        finally
        {
            Thread.CurrentThread.CurrentCulture = culture;
        }
    }

    [Fact]
    public void TheFormatsReadWhatTheFilesWrite()
    {
        Assert.True(ValueFormats.Number(0.25, 4).TryParse("1.5", out var scale, out _));
        Assert.Equal(1.5, scale);
        Assert.False(ValueFormats.Number(0.25, 4).TryParse("5", out _, out var range));
        Assert.Equal("a number from 0.25 to 4", range);
        Assert.False(ValueFormats.Number().TryParse("NaN", out _, out _));

        Assert.True(ValueFormats.Numbers(3).TryParse("[1, 0.5, 0]", out var color, out _));
        Assert.Equal("[1, 0.5, 0]", ValueFormats.Numbers(3).Format(color));
        Assert.False(ValueFormats.Numbers(3).TryParse("[1, 0]", out _, out var count));
        Assert.Equal("3 numbers, such as [0, 0, 0]", count);

        // Empty is the default.
        Assert.True(ValueFormats.Optional(ValueFormats.Numbers(1)).TryParse(" ", out var none, out _));
        Assert.Null(none);
        Assert.False(ValueFormats.Optional(ValueFormats.Numbers(1)).TryParse("fast", out _, out _));
        Assert.True(ValueFormats.OptionalNumber().TryParse("", out var auto, out _));
        Assert.Null(auto);

        Assert.True(ValueFormats.Ticks.TryParse("1500", out var ticks, out _));
        Assert.Equal(1500, ticks);
        Assert.False(ValueFormats.Ticks.TryParse("1.5s", out _, out _));
    }
}
